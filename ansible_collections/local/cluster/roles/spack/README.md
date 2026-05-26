# `spack` role

Scientific software stack via [Spack](https://spack.io).

## Layout

- **Install prefix**: `{{ spack_install_prefix }}` (default `/opt/spack`)
- **Shared install**: clone to head node first, expose to compute nodes via NFS.
  Compute nodes don't need their own clone.
- **Modules**: Lmod-based; module tree lives under `{{ spack_install_prefix }}/share/spack/modules/`.

## What this role should do

### Head node

1. Install dependencies: `git`, `gcc`, `g++`, `gfortran`, `make`, `cmake`, `lmod`.
2. Clone Spack to `{{ spack_install_prefix }}` (idempotent: skip if dir exists and is a git repo).
3. Pin to `{{ spack_version }}` (`develop`, or a release tag).
4. Render `/etc/profile.d/spack.sh` so all users get Spack on their PATH.
5. Render configuration files:
   - `etc/spack/modules.yaml` (Lmod + module projections)
   - `etc/spack/compilers.yaml` (run `spack compiler find`)
   - `etc/spack/packages.yaml` (system OpenMPI / CUDA preferences)
6. Create a default cluster environment (`spack env create hpc`).

## What this role should do

### Compute node

Almost nothing.
Just `/etc/profile.d/spack.sh` pointing at the same NFS-mounted `{{ spack_install_prefix }}`.

## Gotchas

- Enable a binary cache early (`spack mirror add ...`).
  Recompiling from source per-host is wasteful with 5+ compute nodes.
- Compiler discovery on the controller, not workers.
  Run `spack compiler find` once on the head node; compute nodes inherit through the shared install.

