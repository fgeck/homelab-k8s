# Homelab Architecture

## Hardware

- 3x TinyMiniMicro PCs
  - 2x HP EliteDesk 800 G6 (32 GB RAM)
  - 1x HP EliteDesk 800 G6 or Dell OptiPlex 7080 Micro (16 GB RAM)
- UniFi Flex Mini 2.5G
- 10" rack with 9" monitor and HDMI patch panel
- Mean Well UHP-200-12 PSU for HDDs and rack fans
- M.2 NVMe to SATA controller passed through to TrueNAS
- 1x WD Red Plus 8 TB initially
- Later: 2x WD Red Plus 8 TB as ZFS mirror

## Platform

### All nodes

- Proxmox VE

### NAS node

- TrueNAS Community Edition VM
- Proxmox Backup Server LXC
- Pi-hole LXC
- Home Assistant VM
- Talos control-plane VM

### Kubernetes nodes

- `k8s-01`: Talos control-plane + worker VM
- `k8s-02`: Talos control-plane + worker VM

## Kubernetes

### Cluster

- Talos Linux
- 3 control-plane nodes
- 2 worker nodes

### GitOps

- FluxCD
- SOPS-encrypted secrets

### Ingress

- Envoy Gateway
- Kube-VIP

### Storage class

- OpenEBS LocalPV hostpath
- Default storage class: `openebs-hostpath`

### Storage strategy

- Dedicated second worker disk for Kubernetes workload data
- Talos system disk separated from OpenEBS PVC data
- Talos provisions `openebs-local` on `/dev/sdb`
- OpenEBS stores PVC data under `/var/mnt/openebs-local`
- No Longhorn
- No Ceph/Rook
- No distributed storage layer

## Storage

### TrueNAS datasets

- Photos
- Documents
- Media
- Shared storage
- `k8s-restic` repository over NFS for VolSync / Restic
- Kubernetes backups
- Database backups
- PBS datastore

### Kubernetes PVCs

- OpenEBS LocalPV hostpath
- Local node storage backed by dedicated worker data disk
- No live replication

## Networking

```text
Cloudflare DNS
  ↓
FRITZ!Box
  ↓
Port Forward 80/443
  ↓
Kube-VIP
  ↓
Envoy Gateway
  ↓
Kubernetes Services
```

### Internal services

- Static IPs for infrastructure
- SMB/NFS provided by TrueNAS
- 2.5 GbE internal networking

## Failure Model

### Kubernetes

- PVCs are node-local
- Node loss requires restore or workload rebuild
- No automatic storage failover

### TrueNAS

- Single disk initially
- Later upgraded to 2x8 TB ZFS mirror

### PBS on NAS node

- PBS LXC and TrueNAS datastore live on same physical NAS node
- This protects against guest-level failure, not full NAS node failure
- Offsite or secondary backup target still required for real disaster recovery

## Recovery Model

- Rebuild cluster from Flux GitOps repository
- Restore secrets via SOPS
- Restore PVC data via VolSync backups
- Restore databases from application-native backups
- Restore Proxmox guests from PBS where that is faster than rebuilding
