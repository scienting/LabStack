# `slurm-worker` role

`slurmd` on compute nodes.

## What this role should do

1. Install `slurm-wlm` + `munge`.
2. Receive the Munge key from the controller (via vault or slurp).
   Permissions: `0400 munge:munge`. Slurmd refuses to start otherwise.
3. Drop a tiny `/etc/default/slurmd` (or `slurmd.conf`) pointing at the
   controller:
   ```
   SLURMD_OPTIONS="--conf-server {{ cluster_head_host }}"
   ```
4. Enable + start `munge` and `slurmd`.
5. (Optional) Install GPU vendor drivers if `slurm_gres` has any entries with `name: gpu`.
   This is a per-node task and may belong in `common` or a separate `nvidia` role.

## Configless mode

The whole point: no local copy of `slurm.conf`.
If you ever find yourself editing `slurm.conf` on a worker, something's wrong.
The role should be doing the wrong thing on the controller instead.

## Variables

Only what `slurm-controller` exports + the inventory-level `slurm_cpus`, `slurm_real_memory_mb`, `slurm_gres` (read by the controller when it generates the worker's `NodeName` line).

