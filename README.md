# homelab-k8s

Kubernetes homelab running [Talos Linux](https://www.talos.dev/) on Proxmox, managed by [Flux](https://fluxcd.io/).

## Setup

See [SETUP.md](SETUP.md) for the full cluster setup guide.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for the target homelab design, infrastructure layout, storage model, and failure assumptions.

## Backup / Recovery

See [BACKUP-RECOVERY.md](BACKUP-RECOVERY.md) for the backup strategy, retention goals, and restore order.

```bash
just setup   # quick-reference checklist
just --list  # all available commands
```

## Structure

```
talos/        machine config templates + per-node patches
bootstrap/    one-time cluster bootstrap (Cilium, Flux, secrets)
clusters/     Flux-managed Kubernetes manifests
```

## How-to / Troubleshooting

### Check cluster state at a glance

```bash
just debug status          # machine stage + ready for all nodes
just bootstrap check-nodes # talosctl reachability + version
just bootstrap check-etcd  # etcd members + status
just bootstrap check-k8s   # kubectl nodes + kube-system pods
```

### Inspect a node

```bash
just debug services nas          # all service states (etcd, kubelet, …)
just debug addresses nas         # active IP addresses on the node
just debug links nas             # network interface names (e.g. ens18 vs eth0)
just debug dmesg nas             # Talos system log (last entries)
just debug dmesg-follow nas      # stream Talos system log live
just debug logs nas etcd         # logs for a specific service
just debug logs-follow k8s-01 kubelet
```

### etcd

```bash
just debug etcd-members   # list all etcd members
just debug etcd-status    # leader, db size, raft term per node
```

### Kubernetes

```bash
just debug nodes                  # kubectl get nodes -o wide
just debug pods                   # kubectl get pods -A -o wide
just debug describe-node k8s-01   # kubectl describe node
```

### Common issues

**Nodes stuck in `booting` / `ready=false`**
This is normal before Cilium is installed — no CNI means no node Ready signal.
Run `just bootstrap all` to install Cilium and Flux.

**kubeconfig context renamed to `admin@main-1`, `admin@main-2`, etc.**
This happens when `talosctl kubeconfig` finds an existing file and avoids overwriting it.
`just talos get-kubeconfig` handles this automatically using `--force` and switches to
`admin@main`. If you fetched it manually, run:
`KUBECONFIG=secrets/kubeconfig kubectl config use-context admin@main`

**Static IP not applied after first config apply**
Talos applies config without an immediate reboot in maintenance mode. The node
reboots itself shortly after. If it comes up on the wrong IP, check the interface
name: `just debug links nas`. Proxmox VMs use `ens18`, not `eth0`.

**VIP shows up on nas alongside its static IP**
Expected. The VIP (`192.168.1.20`) is a layer-2 virtual IP that floats across
all controlplane nodes. Whichever node currently holds it will show two IPs on
`ens18`. This is how `kubectl` always reaches the API server regardless of which
node is active.

**kubelet stuck pulling image (IPv6 failures)**
Talos tries IPv6 first. If your network doesn't route IPv6 to container registries
it will fall back to IPv4 and succeed — just takes longer. Monitor with:
`just debug dmesg-follow k8s-01`

**`interface: eth0` config ignored**
Proxmox VMs expose the NIC as `ens18`. Verify with `just debug links <node>` and
update the patch if the name differs.
