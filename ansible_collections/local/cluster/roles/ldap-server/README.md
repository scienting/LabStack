# `ldap-server` role

Self-hosted OpenLDAP directory on the head node.
Provides centralized user accounts so a user defined once is visible on every cluster node.

## What this role should do

1. Install `slapd` and `ldap-utils`.
2. Configure `slapd` non-interactively (avoid `dpkg-reconfigure`) by pre-seeding the debconf answers, OR by writing the config DB via `ldif` files.
3. Set up the base DIT:
   - `ou=People,{{ ldap_base_dn }}`
   - `ou=Groups,{{ ldap_base_dn }}`
   - `ou=Hosts,{{ ldap_base_dn }}`  (for host-based access policies)
4. Configure TLS (snakeoil cert or a real one from your CA).
5. Open 389/tcp (ldap) and 636/tcp (ldaps) in ufw.
6. Enable + start `slapd`.

## A warning about OpenLDAP automation

OpenLDAP configures itself through LDAP via the `cn=config` backend.
Plain config-file editing doesn't work.
Ansible has the `community.general` `ldap_attrs` and `ldap_entry` modules for this, but they're brittle.

Two cleaner alternatives if this becomes painful:

- **`lldap`**: a Rust-based LDAP server with a web UI and a flat config file.
   Much easier to manage with Ansible (`config.toml` + restart).
   Sufficient for `posixAccount` / `posixGroup` schemas, which is all you need for a cluster.
- **389-ds**: heavier than slapd but with a saner admin model.

If you find yourself fighting `cn=config`, switch backends.
Same client side (`ldap-client` role), different server.

## Variables

See `group_vars/all.yml`:

- `ldap_base_dn` — e.g. `dc=cluster,dc=local`
- `ldap_admin_dn`
- `ldap_min_uid` — start UIDs at 20000

## Adding users

Out of scope for this role.
Use a separate playbook or a small CLI tool (`cluster-useradd`) that wraps `ldapadd` with sensible defaults.

