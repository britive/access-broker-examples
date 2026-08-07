# AD scan, library-based variant

`ad-scan.sh` in the arrangement that **shares** one copy of the LDAP plumbing
rather than carrying it inline.

**This is optional.** The standalone [`../ad-scan.sh`](../ad-scan.sh) does
exactly the same work and needs nothing installed alongside it. See
[`../../lib/README.md`](../../lib/README.md) for when each arrangement is worth
choosing.

## What differs

Only the top of the file — the inlined library is replaced by a loader that reads
`/opt/britive-broker/lib/ad_common.sh` (override with `AD_COMMON_LIB`). Every
attribute, every output field, and every failure message is identical.

Install the library into the broker image first:

```dockerfile
COPY lib/ad_common.sh /opt/britive-broker/lib/ad_common.sh
```

## This is the source

[`../ad-scan.sh`](../ad-scan.sh) is **generated from this file** by
[`../../lib/build-standalone.sh`](../../lib/build-standalone.sh). Edit here and
re-run the generator; editing the generated copy means the next run overwrites it.

## Documentation

Attributes, output schema, and identity resolution are documented in
[`../README.md`](../README.md) and apply unchanged.
