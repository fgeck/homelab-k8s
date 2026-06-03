# Backup and Recovery

## Principles

- Treat backups as separate layers, not one tool.
- Prefer rebuild from GitOps for cluster config.
- Prefer application-native database backups for databases.
- Use VolSync with Restic for Kubernetes PVC backups to TrueNAS over NFS.
- Keep backup storage outside workload nodes.
- Test restore paths regularly.

## Backup Scope

### Proxmox

- Daily VM and LXC backups to Proxmox Backup Server
- Typical targets: Home Assistant, Pi-hole, PBS config, selected infrastructure guests

### Kubernetes

- VolSync + Restic for persistent workload data
- Backup target on TrueNAS via NFS
- No dedicated Restic server required
- Restic writes directly to repository stored on TrueNAS dataset exported over NFS
- Use per-application schedules and retention based on data value and change rate

### Databases

- Application-native backups
- PostgreSQL: `pg_dump`
- MariaDB: `mysqldump`
- Store dumps on TrueNAS

### TrueNAS

- ZFS snapshots for local data protection
- Future replication to offsite or secondary backup target

### Critical configuration and keys

- Flux Git repository
- SOPS age key
- Talos secrets and client config
- Flux deploy key
- Cloudflare credentials
- TrueNAS configuration export
- Proxmox and PBS configuration

## Risk Notes

- PBS datastore on TrueNAS and PBS LXC on same physical NAS node is not full disaster protection.
- Single-disk TrueNAS is not redundant storage.
- ZFS mirror protects against one disk failure, not deletion, corruption, or site loss.
- Node-local Kubernetes PVCs mean node loss becomes restore event for stateful workloads.

## Recovery Order

1. Restore keys, secrets, and management access.
2. Rebuild Talos cluster and bootstrap Flux from Git.
3. Restore core infrastructure services.
4. Restore database dumps.
5. Restore Kubernetes PVC data from VolSync / Restic backups.
6. Restore Proxmox guests from PBS where appropriate.

## Restore Expectations

- Stateless workloads should be rebuilt from GitOps.
- Stateful workloads should have explicit restore procedure per app.
- Database restore path should be documented separately from PVC restore path.
- Every important workload should have defined RPO and RTO.

## Restic Repository Notes

- Restic does not require a dedicated backup server for this design.
- TrueNAS only needs to provide storage for the Restic repository.
- Recommended pattern:
  - Create dedicated dataset such as `k8s-restic`
  - Export it via NFS
  - Point VolSync / Restic backups at that repository path
- `rest-server` is optional and not part of this design.

## Reference Documentation

- Proxmox VE backup: <https://pve.proxmox.com/pve-docs/pve-admin-guide.html#chapter_vzdump>
- Proxmox Backup Server: <https://pbs.proxmox.com/docs/>
- Talos disaster recovery: <https://www.talos.dev/latest/advanced/disaster-recovery/>
- Flux backup and migration: <https://fluxcd.io/flux/installation/configuration/backup/>
- VolSync: <https://volsync.readthedocs.io/>
- VolSync Restic mover: <https://volsync.readthedocs.io/en/stable/usage/restic/index.html>
- Restic: <https://restic.readthedocs.io/en/stable/>
- Restic repository backends: <https://restic.readthedocs.io/en/stable/030_preparing_a_new_repo.html>
- TrueNAS data protection: <https://www.truenas.com/docs/core/coretutorials/dataprotection/>
- TrueNAS NFS shares: <https://www.truenas.com/docs/core/coretutorials/sharing/nfsshare/>
- OpenZFS snapshots: <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Snapshots.html>
- PostgreSQL `pg_dump`: <https://www.postgresql.org/docs/current/app-pgdump.html>
- MariaDB dump: <https://mariadb.com/kb/en/mariadb-dump/>
