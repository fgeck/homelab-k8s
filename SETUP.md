# homelab-k8s — Full Setup Guide

## Prerequisites

### Hardware

| Node   | Role                  | Disks                              |
|--------|-----------------------|------------------------------------|
| nas    | Controlplane (quorum) | `/dev/sda` — 32 GB+ system         |
| k8s-01 | Controlplane + worker | `/dev/sda` — 32 GB+ system, `/dev/sdb` — 200 GB+ data |
| k8s-02 | Controlplane + worker | `/dev/sda` — 32 GB+ system, `/dev/sdb` — 200 GB+ data |

All three VMs run Talos as controlplane nodes. `nas` only provides etcd quorum — no workloads are scheduled there. `k8s-01` and `k8s-02` run all workloads and use `/dev/sdb` for persistent storage via local-path-provisioner.

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

- **nas**: 1 disk (`/dev/sda`, 32 GB+), boot from ISO
- **k8s-01**: 2 disks (`/dev/sda` 32 GB+, `/dev/sdb` 200 GB+), boot from ISO
- **k8s-02**: 2 disks (`/dev/sda` 32 GB+, `/dev/sdb` 200 GB+), boot from ISO

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

Wait until all three nodes have finished rebooting and are in the **"booting"** stage (visible in `check-nodes` output or on the Proxmox console).

```bash
just talos bootstrap
```

This bootstraps the etcd cluster on `nas`. **Run this exactly once.** Running it again on an existing cluster is safe (Talos returns `AlreadyExists`) but unnecessary.

---

## Step 9 — Validate nodes

```bash
just bootstrap check-nodes   # talosctl reachability + machine stage
just bootstrap check-etcd    # etcd member list + status
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
just bootstrap all
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

Flux reconciles the repo and deploys all remaining workloads. Cilium L2 announcement, local-path-provisioner, cert-manager, and your apps will come up in dependency order.

---

## Adding VolSync replication to an app

VolSync is deployed cluster-wide by Flux (`clusters/building-blocks/base/apps/volsync/`). To add PVC replication for a specific app, add three things alongside that app's other manifests.

### 1. Generate a TLS pre-shared key

```bash
echo "volsync:$(openssl rand -hex 32)" > /tmp/psk.txt
kubectl create secret generic volsync-tls-key \
  --namespace <app-namespace> \
  --from-file=psk.txt=/tmp/psk.txt \
  --dry-run=client -o yaml | sops --encrypt --input-type=yaml --output-type=yaml /dev/stdin \
  > clusters/.../apps/<app>/app/volsync-tls-key.sops.yaml
rm /tmp/psk.txt
```

Commit the encrypted secret. Both `ReplicationSource` and `ReplicationDestination` reference the same secret.

### 2. ReplicationDestination (receives data, runs on k8s-02)

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: <app>-dst
  namespace: <app-namespace>
spec:
  trigger:
    manual: first-sync        # change to force a manual resync
  rsyncTLS:
    keySecret: volsync-tls-key
    copyMethod: Direct        # no VolumeSnapshot needed
    capacity: 5Gi
    accessModes: [ReadWriteOnce]
    storageClassName: local-path
    # Pin to k8s-02 so the replica PVC lives on the second worker
    moverServiceAccount: volsync-privileged
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
          nodeSelectorTerms:
            - matchExpressions:
                - key: kubernetes.io/hostname
                  operator: In
                  values: [k8s-02]
```

After the destination is created, read the address Flux assigned:
```bash
kubectl get replicationdestination <app>-dst -n <app-namespace> \
  -o jsonpath='{.status.rsyncTLS.address}'
```

### 3. ReplicationSource (reads live PVC, runs on k8s-01)

```yaml
apiVersion: volsync.backube/v1alpha1
kind: ReplicationSource
metadata:
  name: <app>-src
  namespace: <app-namespace>
spec:
  sourcePVC: <app-pvc-name>
  trigger:
    schedule: "0 * * * *"    # hourly; adjust per-app
  rsyncTLS:
    keySecret: volsync-tls-key
    address: <address-from-destination-status>
    copyMethod: Direct
```

### Notes

- `copyMethod: Direct` works with local-path-provisioner (no CSI snapshots required). The source PVC must not be in use by a running pod during sync — schedule syncs during low-traffic windows or use a pre/post hook to scale down the app.
- The destination PVC name is auto-generated. Use `kubectl get replicationdestination <app>-dst -o jsonpath='{.status.latestMoverStatus}'` to find it.
- Both resources must reference the **same** `keySecret` content — copy the encrypted secret to both namespaces if source and destination are in different namespaces.
- To force an immediate resync, patch the `manual` trigger field with a new unique string.

---

## Day-2 operations

| Task | Command |
|------|---------|
| Upgrade Talos on one node | `just talos upgrade-node nas` |
| Upgrade Kubernetes | `just talos upgrade-k8s` |
| Re-render and apply config to a node | `just talos apply-node k8s-01 192.168.1.22` |
| Reset a node (destructive) | `just talos reset-node nas` |
| Defragment etcd | `just talos etcd-defrag` |
| Decrypt secrets file | `just sops cat talos/talos-secrets.sops.yaml` |
| Edit secrets file | `just sops edit talos/talos-secrets.sops.yaml` |
