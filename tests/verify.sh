#!/usr/bin/env bash
# tests/verify.sh — the deterministic check that MultiWeb is in the state we think it is.
#
# Runs OFFLINE against the working tree. No network, no build step, no npm. Everything it
# asserts is something that has actually been wrong on this site at least once, and the
# comment above each check says which.
#
# Optional: if a preview container is already serving the site, point BASE_URL at it and
# the last group also checks the response headers nginx really sends:
#
#   docker build -t multiweb-preview . && docker run -d --rm --name multiweb-preview -p 8088:80 multiweb-preview
#   BASE_URL=http://localhost:8088 bash tests/verify.sh
#
# Exit: 0 all checks pass, 1 at least one check failed.
#
# Design detector: run separately, it needs Docker and the qpc-impeccable image.
#   DETECT=/path/to/detect.sh bash tests/verify.sh
# Exit 0 (clean) and 2 (findings) are both accepted here; 3 is NOT — 3 means the detector
# never ran, and a green build on a page nobody looked at is exactly the failure that let
# gmap.js 404 in production for years.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

FAILED=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=1; }
head1() { printf '\n== %s\n' "$1"; }

HTML_PAGES=(src/index.html src/inscripcion.html src/enlaces.html src/404.html)

# ---------------------------------------------------------------------------
head1 "1. Every local asset a page references actually exists"
# WHY: index.html shipped <script src="../assets/js/gmap.js"> for years against a file that
# is not in the repo. nginx answered it with 404.html, so the browser downloaded 2 KB of
# HTML and tried to execute it as JavaScript, on every single page view. Nothing in the
# repo noticed. This check is the one that would have caught it.
#
# The served tree is not the source tree: the Dockerfile copies src/ to the web root and
# assets/ *beneath* it, so a page's "../assets/x" resolves to "<root>/assets/x" because the
# browser clamps ".." at the root. We resolve references the same way the browser does.
missing=0
refs=0
for page in "${HTML_PAGES[@]}"; do
  # href/src attributes plus url(...) inside inline <style>, local ones only.
  grep -oE '(href|src)="[^"]+"' "$page" | sed -E 's/^(href|src)="//; s/"$//' \
  | grep -vE '^(https?:|//|data:|mailto:|tel:|#)' \
  | while read -r ref; do
      clean="${ref%%\?*}"; clean="${clean%%#*}"
      [ -z "$clean" ] && continue
      # strip any number of leading ../ and any /assets/vN/ cache-busting segment
      p="$(printf '%s' "$clean" | sed -E 's#^(\.\./)+##; s#^/##; s#^assets/v[0-9]+/#assets/#')"
      case "$p" in
        assets/*) disk="$p" ;;
        *)        disk="src/$p" ;;
      esac
      [ -e "$disk" ] || echo "MISSING $page -> $ref (looked for $disk)"
    done
done > /tmp/verify-missing.$$ 2>/dev/null
missing=$(wc -l < /tmp/verify-missing.$$)
if [ "$missing" -eq 0 ]; then
  pass "no page references a local file that does not exist"
else
  cat /tmp/verify-missing.$$
  fail "$missing reference(s) point at a file that is not in the repo"
fi
rm -f /tmp/verify-missing.$$

# WHY: CSS can 404 too. style.css referenced ../images/3.jpg and ../images/7.jpg for years.
# Those are on dead selectors so no visitor requests them, but a dead reference in a
# stylesheet is a dead reference.
cssmissing=0
while IFS= read -r line; do
  f="${line%%:*}"; u="${line#*:}"
  clean="${u%%\?*}"; clean="${clean%%#*}"
  d="$(dirname "$f")/$clean"
  d="$(printf '%s' "$d" | sed -E 's#/[^/]+/\.\./#/#g; s#/[^/]+/\.\./#/#g')"
  [ -e "$d" ] || { echo "MISSING $f -> $u"; cssmissing=$((cssmissing+1)); }
done < <(grep -rhoE "url\(\.\./[^)\"']+\)" assets/css/style.css assets/css/enlaces.css assets/css/404.css 2>/dev/null \
         | sed -E "s#^url\(##; s#\)\$##" | sed "s#^#assets/css/x.css:#")
[ "$cssmissing" -eq 0 ] && pass "our own stylesheets reference no missing image" \
                        || fail "$cssmissing stylesheet reference(s) point at a missing file"

# ---------------------------------------------------------------------------
head1 "2. Every <img> declares width and height"
# WHY: none of the 16 <img> on the homepage declared dimensions, so the browser could not
# reserve their space and an 11,000 px document reflowed as 2.4 MB of imagery arrived.
# The attributes give the browser the aspect ratio; the CSS still decides the rendered size,
# which is why every rule that sizes an <img> must also say height: auto (checked below).
noattr=0
for page in "${HTML_PAGES[@]}"; do
  # tolerate img tags broken across lines
  imgs=$(tr '\n' ' ' < "$page" | grep -oE '<img[^>]*>')
  while IFS= read -r img; do
    [ -z "$img" ] && continue
    case "$img" in
      *width=*) ;; *) echo "NO width/height in $page: $img"; noattr=$((noattr+1)); continue ;;
    esac
    case "$img" in
      *height=*) ;; *) echo "NO width/height in $page: $img"; noattr=$((noattr+1)) ;;
    esac
  done <<< "$imgs"
done
[ "$noattr" -eq 0 ] && pass "all <img> carry width and height" \
                    || fail "$noattr <img> without width/height"

# WHY: a width/height attribute on an image the CSS also sizes will stretch it unless the
# CSS says height: auto. Adding the attributes without this is how a "no visual change"
# change becomes a squashed logo.
sizedmissingauto=0
for cls in association-logo menu-logo; do
  block=$(awk -v c=".$cls" '$0 ~ "^"c" *\\{" {f=1} f {print} f && /\}/ {f=0}' assets/css/style.css)
  printf '%s' "$block" | grep -q 'height: *auto' \
    || { echo "  .$cls sizes an <img> but never says height: auto"; sizedmissingauto=$((sizedmissingauto+1)); }
done
[ "$sizedmissingauto" -eq 0 ] && pass "CSS rules that size an <img> also set height: auto" \
                              || fail "$sizedmissingauto rule(s) size an <img> without height: auto"

# ---------------------------------------------------------------------------
head1 "3. Every target=\"_blank\" carries a rel"
# WHY: all 16 external links on the homepage opened a new tab with no rel, leaking the full
# referrer. enlaces.html already did it right — the pattern existed in the repo and simply
# had not been applied anywhere else.
norel=0
for page in "${HTML_PAGES[@]}"; do
  n=$(tr '\n' ' ' < "$page" | grep -oE '<a[^>]*target="_blank"[^>]*>' | grep -vc 'rel=')
  [ "$n" -gt 0 ] && { echo "  $page: $n"; norel=$((norel+n)); }
done
[ "$norel" -eq 0 ] && pass "every target=_blank has a rel" || fail "$norel target=_blank without rel"

# ---------------------------------------------------------------------------
head1 "4. Every icon-only link has an accessible name"
# WHY: the 15 social icons were <a> wrapping <li> wrapping an empty <span> styled by an icon
# font. A screen reader announced "link" fifteen times with no destination. Also: <a> is not
# a permitted child of <ul> — the nesting was inverted.
unnamed=$(tr '\n' ' ' < src/index.html \
  | grep -oE '<a [^>]*>[[:space:]]*(<li>[[:space:]]*)?<span class="ion-[^"]*"[^>]*></span>' \
  | grep -vc 'aria-label=')
[ "${unnamed:-0}" -eq 0 ] && pass "no icon-only link without aria-label" \
                          || fail "$unnamed icon-only link(s) with no accessible name"

invalid=$(tr '\n' ' ' < src/index.html | grep -cE '<ul[^>]*>[[:space:]]*<a ')
[ "$invalid" -eq 0 ] && pass "no <a> is a direct child of a <ul>" \
                     || fail "$invalid <ul> with an <a> as a direct child (invalid HTML)"

# ---------------------------------------------------------------------------
head1 "5. Image byte budgets"
# WHY: the byte budget on this site was precisely inverted — the hero photograph every
# visitor sees first was 58 KB while a press thumbnail eight scrolls down was 394 KB, and
# three event cards were stored at 1536 px to be displayed at 360. Budgets are set from the
# measured post-optimisation sizes with ~15% headroom, so a re-export that quietly balloons
# fails here instead of on someone's phone data plan.
# A budget that has to be raised is a decision, not an accident: raise it in this file and
# say why in the commit.
budget_check() { # <path> <max bytes>
  if [ ! -e "$1" ]; then fail "missing image $1"; return; fi
  sz=$(stat -c%s "$1")
  if [ "$sz" -le "$2" ]; then pass "$(printf '%-34s %7d B  (budget %d)' "$1" "$sz" "$2")"
  else fail "$(printf '%-34s %7d B  OVER budget %d' "$1" "$sz" "$2")"; fi
}
budget_check assets/images/news_1.webp   50000
budget_check assets/images/news_2.webp   46000
budget_check assets/images/news_3.webp   58000
budget_check assets/images/news_4.webp   58000
budget_check assets/images/news_5.webp   40000
budget_check assets/images/news_6.webp   50000
budget_check assets/images/news_7.webp   62000
budget_check assets/images/news_8.webp   82000
budget_check assets/images/cianciathon.webp    32000
budget_check assets/images/gamejam.webp        50000
budget_check assets/images/uagames-devcon.webp 68000
budget_check assets/images/eps.webp        13000
budget_check assets/images/ua.webp         18000
budget_check assets/images/pca.webp        12000
budget_check assets/images/mtua-logo.webp  30000
budget_check assets/images/multitec-logo.webp 10000

# WHY: total page weight is the number a visitor actually feels. 3.68 MB was the homepage
# before Stage 1. This is the sum on disk of every image the homepage references.
total=0
for f in $(grep -oE 'assets/(v[0-9]+/)?images/[A-Za-z0-9_.-]+' src/index.html assets/css/style.css \
           | sed -E 's#^[^:]*:##; s#assets/v[0-9]+/#assets/#' | sort -u); do
  [ -e "$f" ] && total=$((total + $(stat -c%s "$f")))
done
if [ "$total" -le 900000 ]; then pass "homepage imagery totals $total B on disk (budget 900000)"
else fail "homepage imagery totals $total B on disk, over the 900000 budget"; fi

# ---------------------------------------------------------------------------
head1 "6. nginx serves compressed, cacheable bytes"
# WHY: gzip was simply never turned on, and Cloud Run does not compress for you — 450 KB of
# text went over the wire uncompressed on every cold visit. And there was no Cache-Control
# at all, on HTML or on assets, so every repeat visitor revalidated all 48 requests.
CONF=nginx/default.conf
# whitespace-tolerant: the directives in default.conf are column-aligned
for d in 'gzip +on;' 'gzip_min_length +256;' 'gzip_types' 'gzip_vary +on;'; do
  grep -qE "^ *$d" "$CONF" && pass "nginx: ${d/ +/ }" || fail "nginx: missing ${d/ +/ }"
done
grep -q 'max-age=31536000, immutable' "$CONF" && pass "nginx: immutable cache on versioned assets" \
  || fail "nginx: no immutable Cache-Control"
grep -q 'Cache-Control "no-cache"' "$CONF" && pass "nginx: no-cache on HTML" \
  || fail "nginx: HTML is not marked no-cache"

# ---------------------------------------------------------------------------
head1 "7. The cache-busting version is consistent, and matches the assets on disk"
# WHY: 'immutable, max-age=31536000' without a busting scheme is a trap — the next edit to
# style.css would never reach a returning visitor. The scheme here is a version segment in
# the URL (/assets/v3/css/style.css), rewritten back to /assets/css/style.css by nginx, so
# bumping one number retires every cached asset at once and no build step is needed.
#
# The failure mode of that scheme is forgetting to bump it. So this check pins a manifest
# hash of assets/: change any asset without bumping the version and it fails here, with the
# exact command to fix it. That is the whole reason the long cache is safe.
declare -A vers=()
for page in "${HTML_PAGES[@]}"; do
  for v in $(grep -oE 'assets/v[0-9]+/' "$page" | sed -E 's#assets/(v[0-9]+)/#\1#' | sort -u); do
    vers["$v"]=1
  done
done
if [ "${#vers[@]}" -eq 0 ]; then
  fail "no page uses a versioned /assets/vN/ URL — the immutable cache has no busting scheme"
elif [ "${#vers[@]}" -gt 1 ]; then
  fail "pages disagree on the asset version: ${!vers[*]}"
else
  ASSET_VERSION="${!vers[*]}"
  pass "all pages use one asset version ($ASSET_VERSION)"
  # every local /assets/ URL in a page must be versioned, or it gets the short cache and
  # silently loses the benefit
  unver=0
  for page in "${HTML_PAGES[@]}"; do
    n=$(grep -oE '(href|src)="[^"]*assets/[^"]+"' "$page" | grep -cv "assets/v[0-9]*/") || true
    [ "$n" -gt 0 ] && { echo "  $page: $n unversioned /assets/ URL(s)"; unver=$((unver+n)); }
  done
  [ "$unver" -eq 0 ] && pass "no page links an unversioned /assets/ URL" \
                     || fail "$unver unversioned /assets/ URL(s)"

  LOCK=tests/assets.lock
  NOW="$(find assets -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)"
  if [ ! -f "$LOCK" ]; then
    fail "$LOCK is missing — run: tests/update-assets-lock.sh"
  else
    WANT_V=$(grep '^version=' "$LOCK" | cut -d= -f2)
    WANT_H=$(grep '^sha256=' "$LOCK" | cut -d= -f2)
    if [ "$WANT_H" = "$NOW" ] && [ "$WANT_V" = "$ASSET_VERSION" ]; then
      pass "assets/ matches the lock recorded for $ASSET_VERSION"
    else
      echo "  assets/ hash now:      $NOW"
      echo "  assets/ hash recorded: $WANT_H (for $WANT_V)"
      echo "  -> an asset changed. Bump the version in all four HTML pages, then run:"
      echo "     tests/update-assets-lock.sh"
      fail "assets/ changed without a version bump — returning visitors would keep the old file for a year"
    fi
  fi
fi

# ---------------------------------------------------------------------------
head1 "8. Nothing loads a library nothing uses"
# WHY: Magnific Popup (48 KB of JS+CSS) was loaded on two pages and driven by a selector
# that matched zero elements, and the Google Maps JS API (313 KB) was loaded only to feed a
# script that 404s. Dead weight is invisible, so it needs a test to stay dead.
for lib in magnific gmap.js maps.googleapis.com; do
  n=$(grep -rl "$lib" src/ 2>/dev/null | wc -l)
  [ "$n" -eq 0 ] && pass "no page loads $lib" || fail "$n page(s) still load $lib"
done
grep -q 'magnificPopup' assets/js/script.js \
  && fail "script.js still calls .magnificPopup() — it will throw once the library is gone" \
  || pass "script.js does not call a library that is not loaded"

# WHY: jQuery shipped unminified — 267 KB where the minified build is 86 KB. The repo had
# minified copies of its other libraries and used the unminified one anyway.
grep -rq 'jquery-3\.1\.1\.js' src/ \
  && fail "a page still loads the unminified jquery-3.1.1.js" \
  || pass "jQuery is served minified"

# ---------------------------------------------------------------------------
head1 "9. Fonts are requested once, from one place"
# WHY: four Google Fonts / Ionicons @import rules sit at the top of style.css, so the browser
# must download and parse style.css before it even learns those four requests exist — three
# hops in front of first paint. Moving them to <link> is audit item 1.12 and it is DEFERRED,
# not forgotten: it is measurably visible below 767px, because script.js sets the height of
# the inscription photo panel from `$('.expert').height()` read at DOM-ready, and discovering
# the fonts one hop earlier changes what that measurement returns (729px -> 761px, proved by
# isolation on 2026-08-29). Do 1.12 together with making that height sync deterministic.
#
# What this check defends meanwhile: the fonts must be requested from exactly one place. A
# half-done move that leaves both the @import and the <link> would download every family twice.
imp=$(grep -c '^@import' assets/css/style.css)
lnk=$(grep -lc 'fonts.googleapis.com' "${HTML_PAGES[@]}" 2>/dev/null | wc -l)
if [ "$imp" -gt 0 ] && [ "$lnk" -gt 0 ]; then
  fail "fonts are loaded BOTH by @import in style.css and by <link> in $lnk page(s) — every family downloads twice"
elif [ "$imp" -eq 0 ] && [ "$lnk" -eq 0 ]; then
  fail "no page loads the webfonts at all"
elif [ "$imp" -gt 0 ]; then
  pass "fonts load via @import in style.css ($imp rules) — item 1.12 deferred, see comment"
else
  pass "fonts load via <link> in $lnk page(s)"
fi

# ---------------------------------------------------------------------------
head1 "10. Body text meets WCAG AA on white"
# WHY: p { color: #818181 } on white is 3.90:1 and fails AA for normal text — every
# paragraph on every page. #767676 is 4.54:1 and is the minimum that passes.
grep -qE '^\s*color:\s*#818181' assets/css/style.css \
  && fail "style.css still sets #818181 body text (3.90:1, fails WCAG AA)" \
  || pass "body text is not #818181"

# ---------------------------------------------------------------------------
if [ -n "${BASE_URL:-}" ]; then
head1 "11. Live headers from a running preview ($BASE_URL)"
# WHY: a directive in nginx.conf is a claim; the response header is the fact. gzip in
# particular is easy to configure into a location that never matches.
ASSET_V=$(grep -oE 'assets/v[0-9]+/' src/index.html | head -1 | sed -E 's#assets/(v[0-9]+)/#\1#')
css_hdr=$(curl -sSI -H 'Accept-Encoding: gzip' "$BASE_URL/assets/${ASSET_V}/css/style.css")
printf '%s' "$css_hdr" | grep -qi '^content-encoding: gzip' \
  && pass "css is served gzipped" || fail "css is NOT gzipped"
printf '%s' "$css_hdr" | grep -qi 'max-age=31536000, immutable' \
  && pass "versioned css carries the immutable cache header" || fail "versioned css has no immutable cache header"
html_hdr=$(curl -sSI -H 'Accept-Encoding: gzip' "$BASE_URL/")
printf '%s' "$html_hdr" | grep -qi '^content-encoding: gzip' \
  && pass "html is served gzipped" || fail "html is NOT gzipped"
printf '%s' "$html_hdr" | grep -qi 'cache-control: no-cache' \
  && pass "html carries no-cache" || fail "html has no no-cache header"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL/assets/css/style.css")
[ "$code" = "200" ] && pass "unversioned asset URLs still resolve (200)" \
                    || fail "unversioned asset URL returned $code — old links would break"
else
  head1 "11. Live headers — SKIPPED (set BASE_URL to a running preview to include)"
fi

# ---------------------------------------------------------------------------
if [ -n "${DETECT:-}" ]; then
head1 "12. Design detector"
# WHY: exit 3 means the detector never ran. On 2026-08-29 impeccable exited 0 when its own
# browser failed to start and an agent recorded that as a pass. 3 is an UNCHECKED page, and
# it must never be read as a clean one. 0 and 2 are both accepted here: 2 is the site's
# known, tracked backlog of findings, most of them inside vendored libraries.
STAGE="$(mktemp -d)"
cp -r src/. "$STAGE"/ && cp -r assets "$STAGE"/assets
bash "$DETECT" "$STAGE" > /tmp/verify-detect.$$ 2>&1
rc=$?
n=$(grep -oE '^[0-9]+ anti-patterns found' /tmp/verify-detect.$$ | head -1 | cut -d' ' -f1)
rm -rf "$STAGE" /tmp/verify-detect.$$
case "$rc" in
  0) pass "detector exit 0 — clean" ;;
  2) pass "detector exit 2 — ${n:-?} findings (tracked; see docs/research audit)" ;;
  *) fail "detector exit $rc — the page was NOT checked" ;;
esac
else
  head1 "12. Design detector — SKIPPED (set DETECT=/path/to/detect.sh to include)"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -eq 0 ]; then printf '\033[32mverify.sh: all checks passed\033[0m\n'; else printf '\033[31mverify.sh: FAILURES above\033[0m\n'; fi
exit "$FAILED"
