# `storage-server` role

Provides the cluster's shared filesystems from the head node.

## Backend selection

Driven by the `storage_backend` variable in `group_vars/all.yml`.
Today only `nfs` is implemented (or will be); future backends can be added without touching the rest of the codebase.

| Value     | Notes                                                              |
| --------- | ------------------------------------------------------------------ |
| `nfs`     | Plain NFSv4 from head node. Right for 5–10 nodes, no extra HW.     |
| `gluster` | Future. Adds a second storage server, replication, no SPOF.        |
| `ceph`    | Future. Multi-server, multi-pool, vastly more complex.             |

## What this role should do (NFS backend)

1. Install `nfs-kernel-server`.
2. Ensure the export directories exist with sensible perms:
   - `{{ cluster_home_mount }}` — user homes
   - `{{ cluster_data_mount }}` — shared data
3. Render `/etc/exports` from `storage_server_exports` in `group_vars/head.yml`.
   Each entry is a dict with `path`, `options`, and `networks`.
4. Run `exportfs -ra` on changes.
5. Open NFS-related ports in ufw (2049/tcp).
6. Enable `nfs-kernel-server`.

## Why root_squash by default

The default in `group_vars/head.yml` uses `root_squash`.
This means root on a compute node cannot read/write files owned by root on the server.
For most research workloads this is safe and prevents a compromised compute node from clobbering anything important.
Set `no_root_squash` per-export only when a specific tool needs it.

## Decisions still open

- Quota enforcement on /ihome? (`quota` package + `usrquota` mount opt)
- Snapshots — LVM thinpool or btrfs subvolumes on the underlying LV?

