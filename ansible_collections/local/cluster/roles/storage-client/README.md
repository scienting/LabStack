# `storage-client` role

Mounts the cluster's shared filesystems on compute nodes.

## What this role should do

1. Install `nfs-common` (NFSv4 client + mount.nfs).
2. For each entry in `storage_client_mounts`:
   - Ensure the local mount point exists.
   - Add an `/etc/fstab` entry (use `ansible.posix.mount` with `state: mounted` so it both mounts now and persists across reboots).
3. If using autofs later, switch to `auto.cluster` map files instead.

## Variables consumed

From `group_vars/compute.yml`:

```yaml
storage_client_mounts:
  - server: "{{ cluster_head_host }}"
    remote: /ihome
    local: /ihome
    options: "rw,hard,intr,nfsvers=4"
```

## Gotchas

- Mount order matters at boot. `/ihome` should mount before `slurmd` starts so users' jobs can resolve their home dir.
  Use `x-systemd.requires` or `_netdev` mount options to make systemd order the units correctly.
- First boot race: if compute boots before head, NFS mounts fail.
  Add `x-systemd.automount,nofail` so the system doesn't refuse to boot.

