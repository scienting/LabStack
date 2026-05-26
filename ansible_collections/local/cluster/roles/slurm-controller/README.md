# `slurm-controller` role

Workload manager controller (`slurmctld`) on the head node.

## Configless mode

We use Slurm's configless mode: compute nodes don't need a local copy of `slurm.conf`.
Instead they fetch it from the controller on startup.
This means no manual `scp`-ing and no risk of drift between controller and workers.

How it works:

- `slurmctld` runs on the head node with the canonical `slurm.conf`.
- Compute nodes run `slurmd` with `--conf-server tandy`.
- Compute nodes resolve the config via DNS SRV records OR a `slurmd.conf` snippet pointing at the controller.

## What this role should do

1. Install `slurm-wlm` + `munge` (auth daemon).
2. Generate a Munge key, distribute to all nodes via the `slurm-worker` role (Ansible vault or `slurp` + `copy`).
3. Render `/etc/slurm/slurm.conf` with:
   - `SlurmctldHost={{ cluster_head_host }}`
   - `SelectType=select/cons_tres`         # cons_tres, not cons_res
   - `SelectTypeParameters=CR_CPU_Memory`
   - `GresTypes=gpu`                       # if any node has GPUs
   - `NodeName=...` lines generated from the inventory's `compute` group
4. Render `/etc/slurm/gres.conf` for any node with `slurm_gres`.
5. Enable + start `slurmctld` and `munge`.

## Variables

From `group_vars/all.yml`:

- `slurm_cluster_name`
- `slurm_partition_name`

From per-host inventory:

- `slurm_cpus`
- `slurm_real_memory_mb`
- `slurm_gres` — list of `{name, type, count}` dicts

## Munge key handling

The Munge key (`/etc/munge/munge.key`) must be identical on every node.
Two options:

- Generate on the controller, slurp + distribute to workers. Simple, but the key sits in `host_vars` on disk.
- Use `ansible-vault` to encrypt the key in the repo. Slightly more ceremony, much better security.

Default to vault when this role is implemented.
