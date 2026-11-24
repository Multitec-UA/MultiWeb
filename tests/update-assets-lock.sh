#!/usr/bin/env bash
# Re-record the assets/ manifest hash after a deliberate asset change.
#
# The site caches /assets/vN/... for a year with `immutable`, which is only safe because N
# changes whenever an asset does. This script records the pair (version, hash of assets/)
# so tests/verify.sh can fail when they drift apart. Bump the version in the four HTML
# pages FIRST, then run this — it reads the version out of the pages, it does not invent one.
set -euo pipefail
# The asset lock hashes `find | sort -z`, and sort orders by the locale's collation: the
# same tree hashed 84f33e00... under en_US.UTF-8 and c902fcbd... under C (audit L-012), so
# a normal shell reported "assets/ changed without a version bump" on an untouched tree.
# A false failure trains people to ignore the real one. Pin the locale for the whole run.
export LC_ALL=C
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

V=$(grep -hoE 'assets/v[0-9]+/' src/*.html | sed -E 's#assets/(v[0-9]+)/#\1#' | sort -u)
[ "$(printf '%s\n' "$V" | wc -l)" -eq 1 ] || { echo "pages disagree on the asset version: $V" >&2; exit 1; }
H=$(find assets -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
printf 'version=%s\nsha256=%s\n' "$V" "$H" > tests/assets.lock
echo "recorded $V $H"
