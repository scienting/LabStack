# local.cluster

Reusable Ansible roles for provisioning an on-prem research cluster.

This is the public half of a two-repo split.
It contains generic, parameterized roles and playbooks.
The private repo (yours, with real IPs, hostnames, SSH keys, vaulted secrets) consumes this collection and adds machine-specific inventory.

```text
your laptop
    │
    ├── clones cluster-config (private)   <- inventory, secrets
    │     │
    │     └── requirements.yml pulls in...
    │
    └── installs local.cluster (this repo, public)  <- roles, playbooks
```

## Layout

```text
ansible_collections/local/cluster/
├── galaxy.yml             collection metadata
├── playbooks/
│   ├── site.yml           runs everything
│   ├── bootstrap.yml      first-contact on a new node
│   ├── head.yml           head-node-only roles
│   └── compute.yml        compute-node-only roles
└── roles/
    ├── common/            firewall, time, base packages, SSH hardening
    ├── pxe/               net-boot service: dnsmasq ProxyDHCP + nginx
    ├── storage-server/    NFS exports (Gluster/Ceph later)        [stub]
    ├── storage-client/    NFS mounts on compute                   [stub]
    ├── ldap-server/       self-hosted OpenLDAP                    [stub]
    ├── ldap-client/       SSSD                                    [stub]
    ├── slurm-controller/  slurmctld + munge, configless mode      [stub]
    ├── slurm-worker/      slurmd, configless                      [stub]
    └── spack/             scientific software                     [stub]
```

## Using this collection from a private repo

```yaml
# cluster-config/ansible/requirements.yml
collections:
  - name: https://example.com/your-org/cluster-public.git
    type: git
    version: v0.1.0
```

Then in the private repo's playbook:

```yaml
- import_playbook: local.cluster.head
- import_playbook: local.cluster.compute
```

