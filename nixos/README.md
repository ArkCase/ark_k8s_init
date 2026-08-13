# ArkCase single-node Kubernetes on NixOS

This is the NixOS counterpart to the Ubuntu path in the repository root. It targets the
same end state — a single-node `kubeadm` cluster running Calico, HAProxy ingress,
cert-manager, Vault, the Vault Secrets Operator, Keda and the ArkCase root CA.

## Why this exists as a separate layer

The Ubuntu `./initialize` spends most of its time as root doing things NixOS does
declaratively: installing packages, writing `/etc/sysctl.d` drop-ins, enabling services,
editing `/etc/hosts`. None of that survives a `nixos-rebuild`.

So the split here is along the line that already exists in the repository:

| Layer | Ubuntu | NixOS |
|---|---|---|
| Host (packages, kernel, CRI, kubelet, DNS, firewall) | `initialize` root phase, `init-node` | **`nixos/module.nix`** |
| Cluster (kubeadm) | `.scripts/init-node` | **`.scripts/init-node-nixos`** |
| Workload (Calico, Helm stack, CA) | `.scripts/init-*` | **the same scripts, unchanged** |

The workload layer is pure `kubectl` and `helm`, so it is reused verbatim. Fixes to the
ArkCase stack benefit both operating systems.

## Setup

**1. Add the module.** With flakes:

```nix
{
  inputs.ark-k8s-init.url = "github:ArkCase/ark_k8s_init/nixos?dir=nixos";

  outputs = { self, nixpkgs, ark-k8s-init, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        ark-k8s-init.nixosModules.default
        {
          services.arkcase-k8s.enable = true;
          swapDevices = [ ];          # Kubernetes requires swap to be off
        }
      ];
    };
  };
}
```

Or without flakes, `imports = [ /path/to/ark_k8s_init/nixos/module.nix ];`.

**2. Rebuild.** `sudo nixos-rebuild switch`

The kubelet will crash-loop until step 3. That is expected and matches Ubuntu, where the
kubelet `.deb` is installed before `kubeadm init` has produced `/var/lib/kubelet/config.yaml`.

**3. Initialize.**

```bash
./initialize-nixos --check     # verify the host layer, change nothing
./initialize-nixos             # create the cluster and deploy the stack
```

**4. Trust the generated CAs system-wide** (see *CA trust* below):

```bash
./initialize-nixos --export-ca
# add the printed paths to services.arkcase-k8s.caCertificates, then rebuild
```

To tear down: `./.scripts/clear-node-nixos`.

## What differs from the Ubuntu path

These are behavioural differences, not just implementation ones. Read them before
assuming parity.

**containerd instead of cri-dockerd.** `cri-dockerd` is not packaged in nixpkgs, so this
branch uses containerd directly. `.scripts/init-node` already probed for a containerd
socket as a fallback, so this is the path of least resistance rather than a redesign.
Docker keeps working alongside it — they use separate daemons and do not conflict.

**kubeadm config is v1beta4, not v1beta3.** nixpkgs ships Kubernetes 1.36, where
`v1beta3` still validates but is deprecated. The schemas are not interchangeable: in
v1beta4 `etcd.extraArgs` is a list of `{name, value}` pairs rather than a map, and the
v1beta3 map form is rejected outright. `.scripts/init-node-nixos` emits v1beta4;
`.scripts/init-node` still emits v1beta3. Keep that in mind when porting changes between
them.

**Helm 4.** nixpkgs ships Helm 4.x while the Ubuntu path pins 3.18.5. The ArkCase charts
have not been verified against Helm 4 here. If you hit chart incompatibilities, pin Helm
in the module:

```nix
environment.systemPackages = [ (pkgs.kubernetes-helm.overrideAttrs (_: { version = "3.18.5"; })) ];
```
(or supply a 3.x package from a pinned nixpkgs — the override above is illustrative, not
a drop-in.)

**CNI plugin directory.** This is the subtle one. The NixOS containerd module defaults
`cni.bin_dir` to a read-only `/nix/store` path. Calico's `install-cni` container copies
its binaries into that directory at runtime, so with the default it fails — and it fails
*after* initialization appears to have succeeded. The module forces `bin_dir` to
`/opt/cni/bin` and seeds it with **copies** of `pkgs.cni-plugins`. Copies, not symlinks:
Calico overwrites some of the base plugins, and `cp` through a symlink would follow it
into the store and fail with `EROFS`.

**CA trust is two-step.** NixOS has no persistent imperative system trust store, so the
`update-ca-certificates` half of `.scripts/trust-cert` is a silent no-op. The per-user NSS
half still works and takes effect immediately, so browsers trust the CA right away.
For system-wide trust, `--export-ca` writes the CAs to `nixos/certs/` and you reference
them from `services.arkcase-k8s.caCertificates` and rebuild. This is the one place where
the NixOS path needs a manual step the Ubuntu path does not.

**DNS is scoped.** Ubuntu's `init-local-dns` writes a resolved drop-in with a bare
`Domains=` list, which routes *all* queries at kube-dns. Here the domains are `~`-prefixed
routing-only domains, so cluster names resolve through the cluster and ordinary DNS is
untouched. `clusterDnsIp` defaults to `10.96.0.10`; if you change `serviceCidr`, update it
to match — kubeadm assigns kube-dns the tenth address of the service subnet.

**firewalld.** Replaced by `networking.firewall`. `.scripts/init-firewalld` already exits
early when `/etc/firewalld` is absent, so it is harmless if it ends up in the pipeline.

**The dummy interface is a oneshot, not networkd.** `kubelocal0` is created by a systemd
oneshot rather than `systemd.network.netdevs`, so it works whether the host uses
NetworkManager or systemd-networkd.

## Options

All under `services.arkcase-k8s`:

| Option | Default | Notes |
|---|---|---|
| `enable` | `false` | |
| `package` | `pkgs.kubernetes` | Provides kubeadm + kubelet |
| `clusterCidr` | `10.96.0.0/12` | kubeadm `podSubnet` |
| `serviceCidr` | `10.96.0.0/12` | kubeadm `serviceSubnet` |
| `clusterDnsIp` | `10.96.0.10` | Must stay in sync with `serviceCidr` |
| `controlPlaneEndpoint` | `k8s.cluster.prv` | Set to a real endpoint to skip the dummy interface |
| `interface` | `kubelocal0` | |
| `interfaceAddress` | `10.255.255.254` | |
| `cniBinDir` | `/opt/cni/bin` | Must not be a store path |
| `openFirewall` | `true` | Control plane, Calico, NodePort and ingress ports |
| `caCertificates` | `[ ]` | Populate from `--export-ca` |

## Verified

Evaluated against nixpkgs 26.05 (Kubernetes 1.36.3, containerd 2.3.3):

- the module evaluates with no assertion failures alongside `virtualisation.docker`
- `cni.bin_dir` resolves to `/opt/cni/bin`, not a store path
- the generated v1beta4 kubeadm config passes `kubeadm config validate` on both the
  local-only and HA endpoint paths

Not verified: a full `nixos-rebuild switch` followed by an end-to-end cluster bring-up.
The kubelet unit in particular replaces one that Ubuntu gets from a `.deb`, and is the
most likely thing to need adjustment on first real use.
