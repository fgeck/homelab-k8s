# homelab-k8s — Full Setup Guide

See [ARCHITECTURE.md](ARCHITECTURE.md) for the target platform design and [BACKUP-RECOVERY.md](BACKUP-RECOVERY.md) for backup and restore policy.

## Prerequisites

### Hardware

| Node   | Role                  | Disks                              |
|--------|-----------------------|------------------------------------|
| nas    | Controlplane (quorum) | `/dev/sda` — 16 GB+ system         |
| k8s-01 | Controlplane + worker | `/dev/sda` — 16 GB+ system, `/dev/sdb` — 200 GB+ OpenEBS data |
| k8s-02 | Controlplane + worker | `/dev/sda` — 16 GB+ system, `/dev/sdb` — 200 GB+ OpenEBS data |

All three VMs run Talos as controlplane nodes. `nas` only provides etcd quorum — no workloads are scheduled there. `k8s-01` and `k8s-02` run all workloads. Target storage layout is OpenEBS LocalPV hostpath on a dedicated worker data disk, exposed through the default storage class `openebs-hostpath`.

Talos itself does not need a large root disk in this layout. `16 GB` is a practical minimum for Talos, kubelet, container images, and upgrades when persistent app data lives on `/dev/sdb`.

Actual storage flow in this repo:

1. Talos installs to `/dev/sda`.
2. Each worker provisions a Talos `UserVolumeConfig` named `openebs-local` on `/dev/sdb`.
3. Talos mounts that volume at `/var/mnt/openebs-local`.
4. OpenEBS hostpath stores PVC data under that mount.

### Required tools

```bash
just check-tools
```

Install missing tools via Homebrew: `talosctl`, `minijinja-cli`, `sops`, `yq`, `flux`, `kubectl`, `helmfile`, `age`.

### Required files (gitignored, never committed)

| File | Purpose |
|------|---------|
| `~/.age/key.txt` | Age private key for SOPS decryption |
| `~/.ssh/fluxGithubReadKeyK8s` | SSH key for Flux → GitHub access |
| `talos/network.yaml` | Node IPs and network config (create from `talos/network.yaml.example`) |

---

## Step 1 — Talos schematic ID

The schematic bundles the Talos extensions you need (Intel GPU, NFS, etc.) into the installer image.

```bash
just talos schematic-id
```

Paste the printed ID into `talos/values.yaml` → `schematicId`.

---

## Step 2 — Download the ISO

```bash
just talos installer-url
```

Download the ISO URL printed and upload it to Proxmox local storage.

---

## Step 3 — Create Proxmox VMs

Create 3 VMs in Proxmox:

- **nas**: 1 disk (`/dev/sda`, 16 GB+), boot from ISO
- **k8s-01**: 2 disks (`/dev/sda` 16 GB+, `/dev/sdb` 200 GB+), boot from ISO
- **k8s-02**: 2 disks (`/dev/sda` 16 GB+, `/dev/sdb` 200 GB+), boot from ISO

Boot each VM from the ISO. Wait until the Proxmox console shows **"maintenance"** — this means Talos is running in maintenance mode and is ready to receive a machine config.

> Do not configure anything in the Talos console — all configuration is applied via `apply-node` below.

---

## Step 4 — Create network config

```bash
cp talos/network.yaml.example talos/network.yaml
```

Fill in your IPs in `talos/network.yaml`:

```yaml
network:
  vip: 192.168.1.20       # Virtual IP — shared by all controlplane nodes
  gateway: 192.168.1.1
  nodeSubnet: 192.168.1.0/24
nodes:
  nas:
    ip: 192.168.1.21
  k8s-01:
    ip: 192.168.1.22
  k8s-02:
    ip: 192.168.1.23
```

This file is gitignored — it never leaves your machine.

---

## Step 5 — Generate cluster secrets

```bash
just talos gen-secrets
```

Generates Talos PKI (CA, tokens, etcd certs, etc.), merges in your network config, and SOPS-encrypts the result to `talos/talos-secrets.sops.yaml`.

---

## Step 6 — Apply config to all nodes

Apply the machine config to each node while it is still in maintenance mode. Use the **current maintenance-mode IP** (shown on the Proxmox console), not the final static IP — the static IP only takes effect after the first reboot.

```bash
just talos apply-node nas    192.168.1.21 --insecure
just talos apply-node k8s-01 192.168.1.22 --insecure
just talos apply-node k8s-02 192.168.1.23 --insecure
```

> **`--insecure`** is required for the first-time apply because the node has no TLS cert yet.

Each node will:
1. Receive the config
2. Install Talos to `/dev/sda`
3. Reboot automatically from disk

**As soon as a node reboots, detach the ISO in Proxmox.** Talos boots from disk from this point on — the ISO is never needed again. You can detach each VM's ISO independently as it reboots, without waiting for all three.

---

## Step 7 — Generate talosconfig

```bash
just talos gen-talosconfig
```

Generates `secrets/talosconfig` — the client config that lets `talosctl` communicate with your cluster. Sets all three node IPs as endpoints and `k8s-01` as the default node.

---

## Step 8 — Bootstrap etcd

Wait until all three nodes have finished rebooting and are in the **"booting"** stage (visible in `just talos check-nodes` output or on the Proxmox console).

```bash
just talos bootstrap
```

This bootstraps the etcd cluster on `nas`. **Run this exactly once.** Running it again on an existing cluster is safe (Talos returns `AlreadyExists`) but unnecessary.

---

## Step 9 — Validate nodes

```bash
just talos check-nodes       # talosctl reachability + machine stage
just talos check-etcd        # etcd member list + status
```

All three nodes should show stage `running` and etcd should show 3 healthy members.

---

## Step 10 — Get kubeconfig

```bash
just talos get-kubeconfig
```

Fetches `secrets/kubeconfig` from the cluster VIP. Test it:

```bash
KUBECONFIG=secrets/kubeconfig kubectl get nodes
```

Nodes will show `NotReady` at this point — Cilium is not installed yet, so there is no CNI. This is expected.

---

## Step 11 — Bootstrap the cluster

```bash
just bootstrap kubernetes
```

This runs in order:

1. **Namespaces** — applies `bootstrap/namespaces.yaml` (`flux-system`, `cert-manager`)
2. **SOPS secret** — renders and applies the `sops-age` secret in `flux-system` (Flux needs this to decrypt SOPS-encrypted resources)
3. **Cilium** — installs Cilium via helmfile, waits for the daemonset to roll out. Nodes become `Ready` once Cilium is up.
4. **Flux** — bootstraps Flux from `github.com/fgeck/homelab-k8s`, path `clusters/homelab-k8s`

---

## Step 12 — Validate Kubernetes

```bash
just bootstrap check-k8s
```

All nodes should now be `Ready`. Cilium and CoreDNS pods should be running in `kube-system`.

---

## Step 13 — Watch Flux deploy everything

```bash
KUBECONFIG=secrets/kubeconfig flux get kustomizations -A --watch
```

Flux reconciles the repo and deploys all remaining workloads. Cilium L2 announcement, OpenEBS, cert-manager, and your apps will come up in dependency order.

---

## Backup assumptions for stateful workloads

Stateful apps should assume node-local PVC loss is possible. Backup and restore design should follow [BACKUP-RECOVERY.md](BACKUP-RECOVERY.md):

- Use VolSync with Restic for PVC backups.
- Use TrueNAS over NFS as backup target.
- Restic does not require a dedicated server in this design; it writes to a repository stored on a TrueNAS NFS dataset.
- Use application-native backups for databases in addition to PVC backups where applicable.
- Define backup cadence, retention, and restore procedure per app.
- Treat stateless workloads as GitOps rebuilds, not backup restores.

Implementation details for VolSync resources are intentionally left generic here until the corresponding manifests are added to the repository.

---

## Day-2 operations

| Task | Command |
|------|---------|
| Upgrade Talos on one node | `just talos upgrade-node nas` |
| Upgrade Kubernetes | `just talos upgrade-k8s` |
| Re-render and apply config to a node | `just talos apply-node k8s-01 192.168.1.22` |
| Reset a node (destructive) | `just talos reset-node nas` |
| Defragment etcd | `just talos etcd-defrag` |
| Check Talos mounts on a worker | `just debug mounts k8s-01` |
| Check Talos volume status on a worker | `just debug volumes k8s-01` |
| Decrypt secrets file | `just sops cat talos/talos-secrets.sops.yaml` |
| Edit secrets file | `just sops edit talos/talos-secrets.sops.yaml` |
