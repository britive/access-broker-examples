# The shared AD library — an optional way to run these scripts

**You do not need anything in this folder.** The scripts in
[`../rotate/`](../rotate/) and [`../scans/`](../scans/) are self-contained: each
one is a single file that carries everything it needs. Upload one to the Britive
console, paste it into a resource type, and it runs.

This folder describes a **second arrangement** that produces exactly the same
results. It exists because once you are running more than a handful of AD
scripts, having one copy of the LDAP plumbing beats having twenty.

| | Standalone (default) | Shared library |
|---|---|---|
| What you deploy | one `.sh` file per action | one `.sh` file per action **plus** `ad_common.sh` on the broker |
| Where the file lives | pasted into the Britive console, or on disk | script in the console, library baked into the broker image |
| Fixing a bug in the LDAP plumbing | re-generate and re-upload **every** script | rebuild the image once |
| Fixing a bug in one action | edit that one script | edit that one script |
| Auditing one action | read one file | read two files |
| Works on a broker image you don't build | **Yes** | No — the library has to be installed |

Neither is more correct. Pick standalone when you deploy a handful of scripts, or
when the broker image is not yours to change. Pick the library when you run many
AD actions on a broker image you build.

## What the library is

`ad_common.sh` replaces the Windows RSAT `ActiveDirectory` PowerShell module used
by the `.ps1` examples in this repo. The Britive Bridge broker is an Alpine
container, so every AD read and write goes over **LDAPS** with `ldapsearch` and
`ldapmodify` from `openldap-clients`.

| PowerShell cmdlet | Helper here |
|---|---|
| `Get-ADUser` | `ad_get_user` / `ad_find_user_dn` |
| `Get-ADGroup` | `ad_get_group` / `ad_find_group_dn` |
| `Get-ADGroupMember -Recursive` | `ad_is_member_recursive` |
| `New-ADUser` | `ad_create_user` |
| `Set-ADAccountPassword` | `ad_set_password` |
| `Enable-ADAccount` / `Disable-ADAccount` | `ad_set_account_enabled` |
| `Add-ADGroupMember` / `Remove-ADGroupMember` | `ad_group_add_member` / `ad_group_remove_member` |

It also owns the parts that are easy to get wrong once and then wrong everywhere:
the quoted-UTF-16LE-base64 `unicodePwd` encoding, LDIF base64 for DNs containing
awkward characters, paged searches, LDAP filter escaping, and reading the bind
credential out of Secrets Manager into a `0600` file rather than a command line.

### LDAPS is mandatory

Active Directory refuses `unicodePwd` writes over a cleartext connection.
`ad_init` hard-fails on a non-`ldaps://` URI rather than letting the write fail
later with an opaque `unwilling to perform`.

## Connection variables

These are the same whichever arrangement you choose — set them on the Britive
**resource**, not per script. The broker delivers a resource attribute
upper-cased with a `RESOURCE_` prefix, and each script assigns it across to the
`AD_*` name at the top.

| Variable | Required | Default | Description |
|---|---|---|---|
| `AD_HOST` | Yes | — | Domain controller FQDN |
| `AD_BASE_DN` | No | RootDSE `defaultNamingContext` | Search base, e.g. `DC=contoso,DC=local`. Set it to scope work to a subtree |
| `AD_PORT` | No | `636` | LDAPS port |
| `AD_SECRET` | No | — | Secrets Manager id holding `{bind_dn\|username, password}` |
| `AD_BIND_DN` | Conditional | — | Bind DN, when `AD_SECRET` is not used |
| `AD_BIND_PASSWORD` | Conditional | — | Bind password, when `AD_SECRET` is not used |
| `AD_USER_OU` | No | `CN=Users,<AD_BASE_DN>` | OU new accounts land in |
| `AD_CA_CERT` | No | `/etc/ssl/certs/ca-certificates.crt` | CA bundle for LDAPS chain validation |
| `AD_TLS_REQCERT` | No | `demand` | `demand` / `allow` / `never`. `never` is test-only |
| `AD_TIMEOUT` | No | `15` | LDAP network/search timeout, seconds |
| `AD_PAGE_SIZE` | No | `1000` | Paged-results page size, scans only |
| `AWS_REGION` | No | `us-west-2` | Secrets Manager region |

## Installing the library

Bake it into the broker image and point the scripts at it:

```dockerfile
COPY lib/ad_common.sh /opt/britive-broker/lib/ad_common.sh
```

The library-based scripts look for `/opt/britive-broker/lib/ad_common.sh` and
fail with a clear message if it is missing. `AD_COMMON_LIB` overrides the path
for local testing.

The library-based variants live in
[`../rotate/with-library/`](../rotate/with-library/) and
[`../scans/with-library/`](../scans/with-library/).

## Going the other way: `build-standalone.sh`

`build-standalone.sh` is what produces the standalone files. It inlines
`ad_common.sh` into each script, replacing the loader block, and verifies the
result parses:

```sh
cd "Active Directory"
./lib/build-standalone.sh [output-dir]      # default: ./standalone
```

The generated tree mirrors the source directories it walks — `permissions/`,
`rotate/`, `scans/`. A script that does not use the library
(`rotate-env-diagnostic.sh`) is copied through unchanged, so the output is always
the complete set a broker without the library needs.

**Generated files are derived artifacts.** Edit the source under
`with-library/`, then re-run the generator — never edit an inlined copy, because
the next run overwrites it.

## Which files carry which arrangement

```
Active Directory/
├── rotate/
│   ├── rotate-ad-account.sh              standalone  ← default
│   ├── rotate-ad-account-aws-secret.sh   standalone
│   ├── rotate-ad-service-account.sh      standalone
│   ├── rotate-env-diagnostic.sh          needs no library either way
│   └── with-library/                     the same three, sourcing ad_common.sh
├── scans/
│   ├── ad-scan.sh                        standalone
│   └── with-library/ad-scan.sh           the same, sourcing ad_common.sh
└── lib/
    ├── ad_common.sh                      the library
    └── build-standalone.sh               library → standalone
```

Behaviour, variables, and output are identical across the pair. A standalone file
is simply its `with-library/` twin with the library pasted in.

## Prerequisites (both arrangements)

`ldapsearch`, `ldapmodify`, `ldapwhoami` (`openldap-clients`), `python3`,
`openssl`, plus `aws` and `jq` when `AD_SECRET` is used. All ship in the
`britive/bridge` image.
