# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A collection of Bash scripts (plus one vendored Python file, `tools/md4`) that turn a fresh Debian/Ubuntu
machine into a single-node `kubeadm` Kubernetes cluster preloaded with the support stack ArkCase development
needs. There is no build system, no test suite, and no linter — the scripts *are* the deliverable, and they
are validated by running them on a real (or throwaway) host.

## Commands

```bash
./initialize                  # full install/upgrade; idempotent, safe to re-run
sudo ./clear-node             # DESTRUCTIVE: kubeadm reset + tears down interface/DNS/CA/kubectl context
./create-arkcase-ca           # regenerate the arkcase-system/arkcase-root-ca secret if invalid/missing
./trust-arkcase-ca [release]  # pull CA certs from running acme pods and add them to local truststores
```

Tuning knobs are environment variables read with the `[ -v X ] || X=""` / `[ -n "${X}" ] || X="default"`
idiom, so they can be overridden on the command line:

```bash
K8S_VER=1.33 HELM_VER=3.18.5 CRI_VER=0.3.24 DOCKER_DISTRO=jammy CRI_DISTRO=jammy ./initialize
CLUSTER_CIDR=192.168.0.0/16 SERVICE_CIDR=10.96.0.0/12 ./initialize   # must be set before cluster init
CONTROL_PLANE_ENDPOINT=ha.example.com ./initialize                   # HA endpoint instead of the local-only one
BOOT_TIMEOUT=600 ./initialize                                        # pod-readiness wait, min 15s
```

Installed onto `PATH` (`/usr/local/bin`) by `initialize` from `tools/`:

```bash
k8s start|stop|restart|cleanup|unjam|help   # drive docker+containerd+kubelet as a unit; unjam bounces Calico
login-aws (stdin|-|sso|local) [profile:X] [secret:Y] [region:Z]   # refresh ECR creds + aws-arkcase-pull secret
wait-pod [--context C] [-n NS] [-t TIMEOUT] POD                   # block until Running
wait-log [--context C] [-n NS] [-t TIMEOUT] POD [CONTAINER]       # block until Running, then follow the log
purge-old-kernels
```

## Layout and control flow

- **`initialize`** — the only entry point. Exports `BASE_DIR`, `SCRIPT_DIR`, `CONF_DIR`, then re-execs *itself*
  under `sudo -EH`. Everything below the "EVERYTHING BELOW THIS POINT" banner is the root phase; the code above
  it is the user phase, which runs *after* the root phase returns. Adding a step means knowing which phase it
  belongs to.
  - Root phase: apt packages, swap off, Docker + cri-dockerd, Helm, GitHub CLI, `act`, `kubectl-view-secret`,
    base container scripts, `tools/` → `/usr/local/bin`, kubeadm install/upgrade, `init-cluster`, CA trust,
    local DNS, firewalld, AWS CLI.
  - User phase: `init-kubeconfig`, `init-user`, `init-aws-config`, `init-act-config`, `create-arkcase-ca`,
    `wait-for-pods`.
- **`.scripts/`** — implementation scripts, deliberately *not* copied to `PATH`. Two orchestrators:
  - `init-cluster` (root, cluster layer): `clear-node` → `init-node` (kubeadm) → `init-calico` →
    dashboard manifest → `init-metrics`, then waits for pods (ignoring coredns, which can't settle until CNI
    finishes).
  - `init-user` (user, workload layer): cert-manager + trust-manager → HAProxy ingress → `aws-arkcase-pull`
    template secret → ArkCase helm repo → hostpath-provisioner → Vault → Vault Secrets Operator → Keda.
- **`conf/`** — values/manifests passed by path into the above (`haproxy-ingress-values.yaml`,
  `aws-arkcase-pull.yaml`, `k8s-dashboard.yaml`). `.scripts/values/` and `.scripts/resources/` hold the
  Vault/VSO chart values and post-install CRs.
- **`tools/`** — user-facing utilities. This whole directory is tarred into `/usr/local/bin` verbatim, so
  anything added here becomes a global command and must be self-contained (no `BASE_DIR`, no sourcing siblings).
- **Not wired into `initialize`:** `init-istio` and `init-bgp` are optional/manual. `init-bgp` takes peer IPs.

## Conventions to follow when editing

- **Always pin the context explicitly**: `kubectl --context "local" …`, `helm --kube-context "local" …`.
  Nothing in this repo may depend on the user's current-context.
- **Helper functions are duplicated, not sourced.** Each script re-declares `timestamp`/`say`/`ok`/`doing`/
  `err`/`fail` (and often `echo_run`) because scripts are individually re-exec'd under `sudo` and must stand
  alone. Match the surrounding style rather than factoring out a shared library.
- **Error style**: capture and report, don't let output scroll — `OUT="$(cmd 2>&1)" || fail "msg (rc=${?}): ${OUT}"`.
  `fail` honors `EXIT_CODE`. Use `echo_run` when the user should see the command being run.
- **Self-escalation**: scripts needing root do `[ "$(id -u)" != "0" ] && exec sudo -EH "${0}" "${@}"` — note
  `-E`, the exported `BASE_DIR`/`SCRIPT_DIR`/`CONF_DIR` must survive. `init-cluster` and `init-user` hard-fail
  if those aren't exported, so they cannot be run standalone without setting them.
- Scripts run under `set -euo pipefail`; guard optional variables with `[ -v X ]` before use.
- Tabs for indentation, `${VAR}` braces everywhere.

## Non-obvious mechanics

- **The `local` context is built by hand.** `init-kubeconfig` never copies `/etc/kubernetes/admin.conf` over
  the user's config. It surgically sets a cluster/user/context all named `local`, referencing *external* files
  `~/.kube/local.crt` and `~/.kube/local.tok` (`--embed-certs=false`, `tokenFile` rather than `token`). The
  token is a 10-year (`87600h`) ServiceAccount token for `kube-system:admin` bound to `cluster-admin`. Preserve
  this shape — other tooling assumes the context name and the on-disk file layout.
- **Local-only API endpoint.** `init-node` creates a dummy interface `kubelocal0` at `10.255.255.254` (via
  nmcli or systemd-networkd), maps it to `k8s.cluster.prv` in `/etc/hosts`, and advertises the apiserver and
  etcd there. This keeps the cluster reachable across DHCP/Wi-Fi changes. Setting `CONTROL_PLANE_ENDPOINT`
  skips all of that (HA path). Calico is then pinned to that same interface via `nodeAddressAutodetectionV4`.
- **Calico CIDR is discovered, not configured.** `init-calico` polls `cluster-info dump` for `--cluster-cidr=`
  and rewrites the upstream `custom-resources.yaml` with `sed`. Version is pinned in-script (`CALICO_VERSION`).
- **Encrypted credential blobs.** `.scripts/aws-marketplace.bin` (raw credentials text) and
  `.scripts/act-config.bin` (a **gzipped tar** of the `act` config dir) are AES-256-CBC. Any regeneration must
  use exactly `openssl aes-256-cbc -a -A -salt -iter 1000` or the installers won't decrypt them. Both installers
  degrade gracefully — missing/undecryptable blob prints instructions instead of failing. `init-act-config`
  refuses to overwrite an existing `~/.config/act`.
- **Certificate trust is two-sided.** `.scripts/trust-cert` installs into the system store (`update-ca-trust`
  *or* `update-ca-certificates`, whichever exists) *and* into every NSS database it finds — hence the
  `libnss3-tools` dependency. Browsers won't trust the ArkCase CA without the NSS half.
- **DNS integration** (`init-local-dns`) points systemd-resolved at the `kube-dns` ClusterIP and derives the
  search domains by parsing `--service-account-issuer` off the apiserver pod spec.
- **Upgrade path**: re-running `initialize` on an existing cluster bounces Calico first, then runs
  `kubeadm upgrade plan -o json` and applies the new apiserver version — it does *not* re-run `init-cluster`
  (which would `clear-node` and wipe everything). Cluster init only happens when `kubectl get pods -A` fails.
- Ingress defaults to ports **8080/8443**, not 80/443 (developer-machine assumption in
  `conf/haproxy-ingress-values.yaml`).

## Known rough edges

`initialize` calls `warn` in the Docker/CRI service checks but never defines it, and references `UPGRADE_FLAGS`
unset in the AWS CLI install block — both only fire on already-failing paths, but don't copy those patterns.
