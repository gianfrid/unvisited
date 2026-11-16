# Nightly workflow: verify the keystore secret before building

Implements: —

## Problem

`packageRelease` still fails with `KeytoolException: Failed to read key
from store "/tmp/unvisited-release*.jks": Tag number over 30 is not
supported` even with store-type auto-detection on `034a2f7`. The blank
alias in the message also hints `UNVISITED_KEY_ALIAS` may be empty. The
base64 secret may be corrupted/wrapped, or not a keystore at all — both
JKS and PKCS12 readers then fail with ASN.1 tag errors.

## Plan

1. `.github/workflows/nightly.yml`: add a step before the build that
   - base64-decodes `UNVISITED_KEYSTORE_B64` to a file,
   - prints its first 4 magic bytes (`xxd`) and `file` output,
   - runs `keytool -list -v` with the store password (never prints it),
   - checks the alias/password secrets are set (presence only, not values).
   The build then proceeds as before; the log shows exactly what the
   keystore contains if signing still fails.
2. Commit plan + workflow, push to `slop`, re-run; read the new log.
