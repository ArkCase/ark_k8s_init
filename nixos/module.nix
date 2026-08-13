#
# ArkCase single-node Kubernetes -- NixOS host layer.
#
# This module replaces the root phase of the Ubuntu ./initialize script: packages,
# kernel modules, sysctls, the CRI, the kubelet unit, the kubelocal0 interface,
# DNS and firewall. Everything that is genuinely dynamic (kubeadm init, Calico,
# the Helm stack, the ArkCase CA) stays in ./initialize-nixos and .scripts/.
#
# Usage: add this module to your configuration, then:
#
#     services.arkcase-k8s.enable = true;
#
# ...rebuild, then run ./initialize-nixos from the repository.
#
{ config, lib, pkgs, ... }:

let
  cfg = config.services.arkcase-k8s;
in
{
  options.services.arkcase-k8s = {
    enable = lib.mkEnableOption "the ArkCase single-node Kubernetes host layer";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.kubernetes;
      defaultText = lib.literalExpression "pkgs.kubernetes";
      description = "The Kubernetes distribution providing kubeadm and kubelet.";
    };

    clusterCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.0/12";
      description = "Pod network CIDR (kubeadm podSubnet). Must match the Ubuntu path's CLUSTER_CIDR.";
    };

    serviceCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.0/12";
      description = "Service network CIDR (kubeadm serviceSubnet).";
    };

    clusterDnsIp = lib.mkOption {
      type = lib.types.str;
      default = "10.96.0.10";
      description = ''
        ClusterIP of the kube-dns service. kubeadm assigns this deterministically as
        the tenth address of serviceCidr, so it must be kept in sync by hand if you
        change serviceCidr. Used to point systemd-resolved at the cluster.
      '';
    };

    controlPlaneEndpoint = lib.mkOption {
      type = lib.types.str;
      default = "k8s.cluster.prv";
      description = ''
        Control plane endpoint. Left at the default, the module creates a local-only
        dummy interface and maps this name to it, so the cluster survives DHCP and
        Wi-Fi changes. Set to a real HA endpoint to skip the dummy interface.
      '';
    };

    interface = lib.mkOption {
      type = lib.types.str;
      default = "kubelocal0";
      description = "Name of the local-only dummy interface.";
    };

    interfaceAddress = lib.mkOption {
      type = lib.types.str;
      default = "10.255.255.254";
      description = "Address assigned to the local-only dummy interface.";
    };

    cniBinDir = lib.mkOption {
      type = lib.types.str;
      default = "/opt/cni/bin";
      description = ''
        Writable directory for CNI plugin binaries.

        This must NOT be a /nix/store path. Calico's install-cni container copies its
        own binaries into this directory at runtime, which fails against a read-only
        store path. The module seeds it with copies (not symlinks) of pkgs.cni-plugins
        for the same reason -- Calico overwrites some of the base plugins, and cp
        through a symlink would follow it into the store and fail with EROFS.
      '';
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the control plane, Calico and ingress ports, and trust the CNI interfaces.";
    };

    caCertificates = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      example = lib.literalExpression ''[ ./arkcase-root-ca.crt ./k8s-ca.crt ]'';
      description = ''
        Certificates to add to the system trust store.

        NixOS has no persistent imperative CA store, so the Ubuntu path's
        `update-ca-certificates` half of .scripts/trust-cert is a silent no-op here.
        After running ./initialize-nixos, export the generated CAs with
        `./initialize-nixos --export-ca`, commit them next to your configuration, and
        list them here. The per-user NSS half of trust-cert still works imperatively
        and takes effect immediately, so browsers are trusted without a rebuild.

        Use paths relative to the file that sets this option (`./arkcase-root-ca.crt`).
        Under flakes, an absolute path fails pure evaluation even when it points into
        the flake's own directory, and a certificate that is not tracked by git is
        missing from the source tree Nix actually evaluates.
      '';
    };
  };

  config = lib.mkIf cfg.enable {

    #
    # Tooling. The Ubuntu path installs these with apt and drops tools/ into
    # /usr/local/bin; here they come from the store and land on PATH directly.
    #
    environment.systemPackages = with pkgs; [
      cfg.package
      kubernetes-helm
      cni-plugins
      cri-tools
      nssTools        # certutil, for the per-user half of .scripts/trust-cert
      gh
      act
      kubectl-view-secret
      # Utilities the reused .scripts/ expect to find on PATH
      jq
      yq-go
      moreutils       # sponge
      gettext         # envsubst
      openssl
      curl
      wget
      gnupg
      gzip
      gnutar
      iproute2
      util-linux
    ];

    #
    # CRI. cri-dockerd is not packaged in nixpkgs, so this branch uses containerd
    # directly -- .scripts/init-node-nixos probes for its socket.
    #
    virtualisation.containerd = {
      enable = true;
      settings = {
        plugins."io.containerd.grpc.v1.cri" = {
          # mkForce: the NixOS containerd module defaults this to a read-only
          # /nix/store path, which breaks Calico's install-cni. See cniBinDir.
          cni.bin_dir = lib.mkForce cfg.cniBinDir;
          cni.conf_dir = "/etc/cni/net.d";
          # Must agree with the kubelet cgroupDriver set in init-node-nixos.
          containerd.runtimes.runc.options.SystemdCgroup = true;
        };
      };
    };

    #
    # Seed the writable CNI directory. Copies, not symlinks -- see cniBinDir.
    # Re-run on every boot so a nixpkgs upgrade propagates; Calico's install-cni
    # re-installs its own plugins whenever calico-node starts, so this is self-healing.
    #
    systemd.services.arkcase-k8s-cni-plugins = {
      description = "Seed the writable CNI plugin directory for Kubernetes";
      wantedBy = [ "multi-user.target" ];
      before = [ "containerd.service" "kubelet.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        mkdir -p "${cfg.cniBinDir}"
        for f in ${pkgs.cni-plugins}/bin/* ; do
          install -m 0755 "$f" "${cfg.cniBinDir}/$(basename "$f")"
        done
      '';
    };

    #
    # The local-only dummy interface. The Ubuntu path builds this with nmcli or
    # systemd-networkd; a oneshot works regardless of which network backend is in
    # use, which matters because NixOS desktops usually run NetworkManager.
    #
    systemd.services.arkcase-k8s-interface = lib.mkIf (cfg.controlPlaneEndpoint == "k8s.cluster.prv") {
      description = "Local-only Kubernetes control plane interface";
      wantedBy = [ "multi-user.target" ];
      before = [ "kubelet.service" "containerd.service" ];
      after = [ "network-pre.target" ];
      path = [ pkgs.iproute2 ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ip link show ${cfg.interface} >/dev/null 2>&1 || ip link add ${cfg.interface} type dummy
        ip addr replace ${cfg.interfaceAddress}/32 dev ${cfg.interface}
        ip link set ${cfg.interface} up
      '';
      preStop = ''
        ip link del ${cfg.interface} || true
      '';
    };

    networking.extraHosts = lib.mkIf (cfg.controlPlaneEndpoint == "k8s.cluster.prv")
      "${cfg.interfaceAddress} ${cfg.controlPlaneEndpoint}";

    #
    # The kubelet unit. On Ubuntu this ships in the kubelet .deb along with the
    # 10-kubeadm.conf drop-in; on NixOS we have to provide both ourselves. The
    # Environment/EnvironmentFile layout below mirrors that drop-in exactly, so
    # kubeadm's generated /var/lib/kubelet/kubeadm-flags.env is picked up as usual.
    #
    # Expect this to crash-loop until `kubeadm init` has run -- that is also how the
    # Ubuntu path behaves, since /var/lib/kubelet/config.yaml does not exist yet.
    #
    systemd.services.kubelet = {
      description = "kubelet: The Kubernetes Node Agent";
      documentation = [ "https://kubernetes.io/docs/" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" "containerd.service" ];

      # kubelet shells out to these; without them on PATH, volume mounting and
      # iptables programming fail in ways that are painful to diagnose.
      path = with pkgs; [
        util-linux      # mount, umount, nsenter
        iproute2
        iptables
        ethtool
        socat
        conntrack-tools
        kmod
        e2fsprogs       # mkfs.ext4 for PVCs
        xfsprogs
        cfg.package
      ];

      environment = {
        KUBELET_KUBECONFIG_ARGS = "--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf";
        KUBELET_CONFIG_ARGS = "--config=/var/lib/kubelet/config.yaml";
      };

      serviceConfig = {
        # Written by kubeadm init/join; absent on a fresh machine, hence the '-'.
        EnvironmentFile = [
          "-/var/lib/kubelet/kubeadm-flags.env"
          "-/etc/default/kubelet"
        ];
        ExecStart = "${cfg.package}/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS";
        Restart = "always";
        RestartSec = "10";
        # kubelet manages mounts and cgroups for the whole node; sandboxing breaks it.
        KillMode = "process";
      };

      # kubelet crash-loops until kubeadm init lands its config, so the unit must
      # never be rate-limited out of restarting.
      startLimitIntervalSec = 0;
    };

    # Directories kubeadm and the kubelet expect to exist and be writable.
    systemd.tmpfiles.rules = [
      "d /etc/kubernetes 0755 root root -"
      "d /etc/kubernetes/manifests 0755 root root -"
      "d /etc/cni/net.d 0755 root root -"
      "d /var/lib/kubelet 0700 root root -"
      "d /var/lib/etcd 0700 root root -"
      "d ${cfg.cniBinDir} 0755 root root -"
    ];

    #
    # Kernel prerequisites -- the Ubuntu path does these with modprobe and
    # /etc/sysctl.d drop-ins inside init-node.
    #
    boot.kernelModules = [ "br_netfilter" "overlay" "dummy" ];

    boot.kernel.sysctl = {
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
      "net.ipv4.ip_forward" = 1;
      # Mirrors the Ubuntu path's 98-more-watches.conf. These values are extreme;
      # they are kept identical for behavioural parity. Lower them with
      # boot.kernel.sysctl."fs.inotify.max_user_instances" = lib.mkForce 8192;
      "fs.inotify.max_user_watches" = 2147483647;
      "fs.inotify.max_user_instances" = 2147483647;
      "fs.inotify.max_queued_events" = 2147483647;
    };

    #
    # Kubernetes refuses to start with swap enabled unless explicitly configured.
    #
    warnings = lib.optional (config.swapDevices != [ ]) ''
      services.arkcase-k8s: swapDevices is non-empty. Kubernetes requires swap to be
      disabled; set `swapDevices = [];` (and `zramSwap.enable = false;` if used) or
      the kubelet will fail to start.
    '';

    #
    # DNS. The Ubuntu init-local-dns writes a resolved drop-in with a bare Domains=
    # list, which routes *all* queries at kube-dns. Here the domains are prefixed
    # with '~' so only cluster names are sent to the cluster resolver and ordinary
    # DNS is left alone.
    #
    services.resolved = {
      enable = lib.mkDefault true;
      settings.Resolve = {
        DNS = [ cfg.clusterDnsIp ];
        # '~' marks these as routing-only domains, so cluster names go to kube-dns
        # while ordinary DNS continues to use the normal per-link resolvers.
        Domains = [ "~cluster.local" "~svc.cluster.local" ];
        Cache = "no";
      };
    };

    #
    # Firewall. The Ubuntu path's init-firewalld already no-ops when /etc/firewalld
    # is absent, so it is harmless to leave in the pipeline; this replaces it.
    #
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [
        6443    # kube-apiserver
        2379    # etcd client
        2380    # etcd peer
        10250   # kubelet API
        10257   # kube-controller-manager
        10259   # kube-scheduler
        179     # Calico BGP
        5473    # Calico Typha
        8080    # HAProxy ingress (developer default, see conf/haproxy-ingress-values.yaml)
        8443    # HAProxy ingress TLS
      ];
      allowedUDPPorts = [
        4789    # Calico VXLAN
      ];
      allowedTCPPortRanges = [
        { from = 30000; to = 32767; }  # NodePort range
      ];
      # Pod traffic must not be filtered. Wildcard interface names are handled by
      # the iptables backend; if you have switched to networking.nftables, verify
      # these are translated as you expect.
      trustedInterfaces = [ cfg.interface "cali+" "tunl0" "vxlan.calico" ];
    };

    security.pki.certificateFiles = cfg.caCertificates;
  };
}
