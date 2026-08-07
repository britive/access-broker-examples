# Rotation scripts, library-based variant

The same three rotations as the parent folder, in the arrangement that **shares**
one copy of the LDAP plumbing instead of carrying it in every file.

```
rotate-ad-account.sh
rotate-ad-account-aws-secret.sh
rotate-ad-service-account.sh
```

**This is optional.** The standalone files in [`../`](../) do exactly the same
work and need nothing installed. Use these when you build the broker image
yourself and run enough AD scripts that one shared copy of the plumbing is worth
maintaining. See [`../../lib/README.md`](../../lib/README.md) for the trade-off
in full.

`rotate-env-diagnostic.sh` has no library variant — it never used the library.

## What differs

Only the top of the file. Each script here replaces the inlined library with a
loader:

```bash
AD_COMMON_LIB="${AD_COMMON_LIB:-/opt/britive-broker/lib/ad_common.sh}"
if [ ! -r "$AD_COMMON_LIB" ]; then
  printf 'ERROR: AD helper library not readable at %s\n' "$AD_COMMON_LIB" >&2
  exit 1
fi
. "$AD_COMMON_LIB"
```

Everything below that line is identical, and so are the variables, the output,
and the failure messages.

## Install the library first

```dockerfile
COPY lib/ad_common.sh /opt/britive-broker/lib/ad_common.sh
```

`AD_COMMON_LIB` overrides the path for local testing. Without the library on
disk, these scripts fail immediately with the message above rather than partway
through a rotation.

## These are the sources

The standalone files in `../` are **generated from these** by
[`../../lib/build-standalone.sh`](../../lib/build-standalone.sh). Edit here, then
re-run the generator:

```sh
cd "Active Directory"
./lib/build-standalone.sh
```

Editing a generated file instead means the next run silently overwrites your change.

## Documentation

Variables, ordering, IAM, and output are documented once in
[`../README.md`](../README.md) and apply unchanged to these files.
