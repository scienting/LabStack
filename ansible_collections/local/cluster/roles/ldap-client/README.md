# `ldap-client` role

Configure SSSD to authenticate against the cluster's LDAP server.

## Why SSSD instead of nss-ldap + pam-ldap

The older stack (`libnss-ldap`, `libpam-ldap`, `nscd`) is deprecated and has well-known caching/failover problems.
SSSD:

- Caches credentials so users can log in when the directory is down
- Handles failover between multiple LDAP URIs
- Pluggable backends (LDAP, AD, IPA), so it is easy to swap later
- nss + pam in one daemon; no separate `nscd`

## What this role should do

1. Install `sssd-ldap`, `libnss-sss`, `libpam-sss`, `oddjob-mkhomedir`.
2. Render `/etc/sssd/sssd.conf`:
   - `id_provider = ldap`
   - `auth_provider = ldap`
   - `ldap_uri = {{ ldap_uri }}`
   - `ldap_search_base = {{ ldap_base_dn }}`
   - TLS settings pointing at the cluster CA
3. Permission `/etc/sssd/sssd.conf` `0600 root:root` (SSSD refuses to start otherwise).
4. Run `pam-auth-update --enable sss mkhomedir` to wire SSSD into PAM and ensure home directories get created on first login.
5. Update `/etc/nsswitch.conf` (`passwd:`, `group:`, `shadow:` to include `sss`).
6. Enable + start `sssd`.

## Per-host trust

Each compute node needs to trust the head node's LDAP TLS certificate.
Either:

- Use the cluster CA, distributed via the `common` role
- Use a self-signed cert and `ldap_tls_reqcert = allow` (lax, OK on isolated management subnet)

