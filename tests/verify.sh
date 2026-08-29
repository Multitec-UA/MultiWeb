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

# Eight files, four pages: since 2026-08-29 every page of this site exists in Spanish
# at the URL it always had and in English under /en/, and both are generated from
# i18n/templates + i18n/strings.json (see group 24). Every check below that iterates
# HTML_PAGES therefore checks the English half too, which is the point — an accessibility
# or SEO regression that only lands on one language is exactly the kind that ships.
HTML_PAGES=(src/index.html src/inscripcion.html src/enlaces.html src/404.html
            src/en/index.html src/en/inscripcion.html src/en/enlaces.html src/en/404.html)
ES_PAGES=(src/index.html src/inscripcion.html src/enlaces.html src/404.html)

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
# Resolution is done in Python because it now has to be exact: with a second language
# tree under src/en/ a reference is only correct relative to the directory the page is
# SERVED from, and "../assets/x" means one thing from / and another from /en/. Doing it
# with sed the old way would have silently passed a link that 404s in the container.
python3 - > /tmp/verify-missing.$$ 2>&1 <<'PYREF'
import pathlib, posixpath, re

ROOT = pathlib.Path(".")
pages = sorted(ROOT.glob("src/*.html")) + sorted(ROOT.glob("src/en/*.html"))
# nginx serves a few pretty URLs that are not files: /enlaces, /en/enlaces, /stream.
conf = (ROOT / "nginx/default.conf").read_text(encoding="utf-8")
locations = set(re.findall(r"location\s*=\s*(/\S*)", conf))

for page in pages:
    served = "/" + str(page.relative_to("src")).replace("index.html", "")
    base = posixpath.dirname(posixpath.join("/", str(page.relative_to("src")))) + "/"
    for ref in re.findall(r'(?:href|src)="([^"]+)"', page.read_text(encoding="utf-8")):
        if re.match(r"^(https?:|//|data:|mailto:|tel:|#)", ref):
            continue
        clean = ref.split("?")[0].split("#")[0]
        if not clean:
            continue
        url = clean if clean.startswith("/") else posixpath.join(base, clean)
        url = posixpath.normpath(url)
        if clean.endswith("/") and not url.endswith("/"):
            url += "/"
        if url in locations or url.rstrip("/") in locations:
            continue                      # nginx answers this one without a file
        rel = url.lstrip("/")
        rel = re.sub(r"^assets/v[0-9]+/", "assets/", rel)
        if rel.endswith("/") or rel == "":
            rel += "index.html"
        disk = ROOT / rel if rel.startswith("assets/") else ROOT / "src" / rel
        if not disk.is_file():
            print("MISSING %s -> %s (looked for %s)" % (page, ref, disk))
PYREF
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
unnamed=$(tr '\n' ' ' < src/index.html src/en/index.html \
  | grep -oE '<a [^>]*>[[:space:]]*(<li>[[:space:]]*)?<span class="ion-[^"]*"[^>]*></span>' \
  | grep -vc 'aria-label=')
[ "${unnamed:-0}" -eq 0 ] && pass "no icon-only link without aria-label" \
                          || fail "$unnamed icon-only link(s) with no accessible name"

invalid=$(tr '\n' ' ' < src/index.html src/en/index.html | grep -cE '<ul[^>]*>[[:space:]]*<a ')
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
head1 "9. The webfonts are ours, and they are the same faces"
# WHY: three @import rules against fonts.googleapis.com sat at the top of style.css, so the
# browser had to download and parse this stylesheet before it even learned those requests
# existed — two extra DNS+TLS hops in front of first paint, and every visitor's IP going to
# Google on every page view. They are @font-face rules over self-hosted woff2 now (item 2.8).
#
# This check is what stops the move being half-done: a page that loads BOTH would download
# every family twice, and a page that loads NEITHER renders in Times New Roman.
# Comments in these files name the Google hosts on purpose (they explain what moved), so
# match the ways a file can actually *request* one: an @import, a <link href>, or a src: url().
goog_hits() {
  grep -nE "@import[^;]*['\"(]https?://fonts\.(googleapis|gstatic)\.com|(href|src)=\"[^\"]*fonts\.(googleapis|gstatic)\.com|url\(['\"]?https?://fonts\.(googleapis|gstatic)\.com" \
    "${HTML_PAGES[@]}" assets/css/*.css 2>/dev/null
}
goog=$(goog_hits | wc -l)
[ "$goog" -eq 0 ] && pass "no page or stylesheet requests fonts from Google" \
                  || { goog_hits; fail "$goog reference(s) still request a Google-hosted font"; }

missingface=0
for fam in Ubuntu Poppins Lora Raleway; do
  grep -q "font-family: '$fam';" assets/css/style.css || { echo "  no @font-face for $fam"; missingface=$((missingface+1)); }
done
[ "$missingface" -eq 0 ] && pass "all four families are declared as @font-face" \
                         || fail "$missingface family/families lost their @font-face"

# WHY: the whole point of self-hosting is that the bytes are ours and bounded. latin +
# latin-ext only: the cyrillic, greek, vietnamese and devanagari subsets Google was
# offering were downloaded by nobody on a Spanish site. A budget so a "just add a weight"
# never quietly triples the image.
#
# The budget was 300000 for ten files and it did its job: adding Ubuntu 700 on 2026-08-29
# tripped it. Raised to 345000 for twelve, deliberately — that weight is not an extra, it
# is the weight `h1..h6 { font-weight: 700 }` has been asking for since this site was
# written and the browser had been faking with a synthetic smear of the regular face.
# Raised again to 360000 on 2026-08-29 for Poppins 700 (13,248 B, two files), the same
# defect as Ubuntu's and the last one: .faq-question is `font-weight: bold` and every
# <strong> in a FAQ answer is 700, in a family that only ever shipped 400.
nfonts=$(find assets/fonts -name '*.woff2' 2>/dev/null | wc -l)
fontbytes=$(find assets/fonts -name '*.woff2' -printf '%s\n' 2>/dev/null | awk '{t+=$1} END {print t+0}')
if [ "$nfonts" -gt 0 ] && [ "$fontbytes" -le 360000 ]; then
  pass "$nfonts self-hosted woff2, $fontbytes B on disk (budget 360000)"
else
  fail "self-hosted fonts: $nfonts file(s), $fontbytes B (budget 360000)"
fi

# WHY: every heading on this site is Ubuntu at font-weight 700, and until 2026-08-29 no
# 700 face was ever delivered — the @imports asked fonts.googleapis.com for
# `Ubuntu:wght@400;700`, which is v2 syntax against the v1 css? endpoint, so it silently
# returned regular and the browser synthesised the bold. Both weights must be here.
for wght in 400:ubuntu-latin 700:ubuntu-700-latin; do
  f="assets/fonts/${wght#*:}.woff2"
  [ -s "$f" ] || fail "Ubuntu ${wght%%:*} is missing: $f"
done
grep -q "font-weight: 700;" assets/css/style.css \
  && grep -q "ubuntu-700-latin.woff2" assets/css/style.css \
  && pass "Ubuntu ships a real 700, not a synthetic one" \
  || fail "style.css declares no Ubuntu 700 @font-face"
grep -q "ubuntu-700-latin.woff2" assets/css/404.css \
  && pass "404.css carries the same Ubuntu 700" \
  || fail "404.css draws headings at 700 with no 700 face"

# WHY: the identical defect in the other family, found while fixing Ubuntu's and left
# open until 2026-08-29. Poppins is --second-font: it draws .faq-question (font-weight:
# bold), every <strong> inside a .faq-answer, and .link-item on enlaces.html at 600. With
# only a 400 face on disk the browser smeared all of them. 404.css is deliberately NOT
# included: nothing on that page asks Poppins for a weight above 500, so the face would
# be downloaded by nobody.
for f in assets/fonts/poppins-latin.woff2 assets/fonts/poppins-700-latin.woff2; do
  [ -s "$f" ] || fail "Poppins is missing a weight: $f"
done
grep -q "poppins-700-latin.woff2" assets/css/style.css \
  && pass "Poppins ships a real 700, not a synthetic one" \
  || fail "style.css declares no Poppins 700 @font-face"

# WHY: a src: url() that 404s is a font that silently falls back to Times. Group 1 resolves
# every url(../...) in our stylesheets, but only if the rules are actually reachable from
# there, so count them here too.
faces=$(grep -c '^@font-face' assets/css/style.css)
srcs=$(grep -c 'url(\.\./fonts/' assets/css/style.css)
[ "$faces" -gt 0 ] && [ "$faces" -eq "$srcs" ] \
  && pass "$faces @font-face rules, $srcs local src: url() — none points off-site" \
  || fail "@font-face rules ($faces) and local font src ($srcs) do not match"

# ---------------------------------------------------------------------------
head1 "10. Body text meets WCAG AA on white"
# WHY: p { color: #818181 } on white is 3.90:1 and fails AA for normal text — every
# paragraph on every page. #767676 is 4.54:1 and is the minimum that passes.
grep -qE '^\s*color:\s*#818181' assets/css/style.css \
  && fail "style.css still sets #818181 body text (3.90:1, fails WCAG AA)" \
  || pass "body text is not #818181"

# ---------------------------------------------------------------------------
head1 "11. A phone has navigation"
# WHY: below 995px .menu-links is display:none, and for years nothing replaced it — a phone
# got the logo and nothing else. No way to reach any section of an 11,000px page, and no
# INSCRÍBETE, on the page students arrive at from Instagram. style.css styled the panel and
# script.js drove it; only the markup was ever missing. Audit item 2.1.
for page in src/index.html src/inscripcion.html src/en/index.html src/en/inscripcion.html; do
  flat=$(tr '\n' ' ' < "$page")
  ok=1
  case "$flat" in *'id="menu-item"'*) ;; *) echo "  $page: no #menu-item panel"; ok=0 ;; esac
  case "$flat" in *'id="menu-toggle"'*) ;; *) echo "  $page: no #menu-toggle control"; ok=0 ;; esac
  case "$flat" in *'aria-controls="menu-item"'*) ;; *) echo "  $page: toggle does not point at the panel"; ok=0 ;; esac
  case "$flat" in *'aria-expanded="false"'*) ;; *) echo "  $page: toggle has no aria-expanded"; ok=0 ;; esac
  # An inline SVG and not the template's ion-navicon: inscripcion.html loads the Ionicons
  # stylesheet without drawing a single glyph from it, so one hamburger there would have
  # pulled 110 KB of icon font onto the payment page, on a phone.
  case "$flat" in *'class="menu-icon"'*) ;; *) echo "  $page: no hamburger glyph"; ok=0 ;; esac
  case "$flat" in *'ion-navicon'*) echo "  $page: the toggle needs an icon font again"; ok=0 ;; esac
  # the panel must carry the join CTA — restoring the navigation without it misses the point
  case "$flat" in *'menu-item-cta'*) ;; *) echo "  $page: the panel has no INSCRÍBETE"; ok=0 ;; esac
  n=$(printf '%s' "$flat" | grep -oE '<div id="menu-item".*</ul>' | grep -o '<li>' | wc -l)
  [ "${n:-0}" -ge 7 ] || { echo "  $page: panel has ${n:-0} items, expected 7"; ok=0; }
  [ "$ok" -eq 1 ] && pass "$page has a working mobile menu (panel, toggle, 7 items, CTA)" \
                  || fail "$page is missing part of the mobile menu"
  # WHY: script.js binds the toggle to `.menu`, and the desktop nav container used to carry
  # that class too. With a panel in the page, an idle click anywhere in the desktop navigation
  # would have slid it open — a regression above 995px caused by a fix below it.
  case "$flat" in
    *'flex-row menu text-right'*) fail "$page: the desktop nav still carries the .menu class" ;;
    *) pass "$page: only the toggle is .menu, so the desktop nav cannot open the panel" ;;
  esac
done

# WHY: the toggle sits in its own .col-xs-8. If it were merely invisible rather than
# display:none above 995px it would still take grid columns and wrap the desktop navigation
# onto a second line.
grep -qE '^\.menu-toggle-wrap \{' assets/css/style.css && \
  awk '/^\.menu-toggle-wrap \{/{f=1} f{print} f&&/\}/{exit}' assets/css/style.css | grep -q 'display: *none' \
  && pass "the toggle is display:none by default (desktop keeps one nav row)" \
  || fail "the mobile toggle is not display:none above the breakpoint"
grep -q 'max-width: 995px' assets/css/style.css \
  && pass "the menu breakpoint is still the site's own 995px" \
  || fail "no 995px breakpoint in style.css"

# WHY: aria-expanded that never changes is worse than none — it tells a screen reader the
# menu is shut while it is open.
grep -q "attr('aria-expanded'" assets/js/script.js \
  && pass "script.js keeps aria-expanded in sync with the panel" \
  || fail "script.js never updates aria-expanded"

# ---------------------------------------------------------------------------
head1 "12. The FAQ can be opened without a mouse"
# WHY: the seven questions were <p> with a click listener — not focusable, no role, no
# aria-expanded, no key handler. A keyboard or switch user could not open any of them,
# including "¿Cómo puedo unirme?", the answer most likely to decide whether somebody pays
# the 12 euros. Audit item 2.4.
qs=$(cat src/index.html src/en/index.html | grep -c 'class="faq-question"')
btn=$(cat src/index.html src/en/index.html | grep -c 'class="faq-question" role="button" tabindex="0" aria-expanded="false"')
[ "$qs" -gt 0 ] && [ "$qs" -eq "$btn" ] \
  && pass "all $qs FAQ questions are role=button, tabindex=0, aria-expanded (both languages)" \
  || fail "$btn of $qs FAQ questions are keyboard-reachable"
# every aria-controls must point at an id that exists, or the answer is announced by nobody
danglers=0
for f in src/index.html src/en/index.html; do
for id in $(grep -oE 'aria-controls="faq-answer-[0-9]+"' "$f" | sed -E 's/.*"(.*)"/\1/'); do
  grep -q "id=\"$id\"" "$f" || { echo "  $f aria-controls=$id points at nothing"; danglers=$((danglers+1)); }
done
done
[ "$danglers" -eq 0 ] && pass "every FAQ aria-controls resolves to an answer" \
                      || fail "$danglers dangling aria-controls"
grep -q 'keydown' assets/js/script.js && grep -q '"Enter"' assets/js/script.js \
  && pass "script.js answers Enter and Space like a real button" \
  || fail "script.js has no Enter/Space handler for the FAQ"

# ---------------------------------------------------------------------------
head1 "13. The targets a thumb has to hit"
# WHY: 25 of 39 tap targets on the homepage and 8 of 8 on the Instagram bio page were under
# 44px at 390px — and the same targets were fine at 1100px, so the page shrank them exactly
# where a finger, not a cursor, was going to be used. Audit item 2.5. These are the ones the
# CSS is responsible for; the sizes are asserted here rather than in a browser because a
# rendered measurement needs Chrome and this file must run offline.
tap_rule() { # <file> <selector-regex> <description>
  awk -v s="$2" '$0 ~ s"[ ,{]" {f=1} f{print} f&&/\}/{f=0}' "$1" | grep -q 'min-height: *44px\|line-height: *44px\|width: *44px' \
    && pass "$3" || fail "$3 — no 44px floor found"
}
tap_rule assets/css/enlaces.css '^\.link-item' "enlaces: .link-item has a 44px floor"
tap_rule assets/css/style.css   '^\.menu'      "the mobile menu toggle is at least 44px"
tap_rule assets/css/style.css   '\.menu-item ul li a' "menu panel entries are at least 44px"
awk '/max-width: 995px/{f=1} f&&/\.social-icons-form ul li a/{g=1} g{print} g&&/\}/{exit}' assets/css/style.css \
  | grep -q '44px' && pass "social icons are 44px on a phone (36px desktop row untouched)" \
                   || fail "social icons have no 44px floor below 995px"

# ---------------------------------------------------------------------------
head1 "14. The heading outline is navigable"
# WHY: a screen reader navigates by heading. The hero subtitle was an <h2> that is not a
# section, the FAQ title was an <h3> among <h2> sections, the contact title was a <p> styled
# to look like a heading, inscripcion.html had no <h1> at all and jumped <h2> to <h4>, and
# enlaces.html started at <h3>. Audit item 2.6. Every tag swap here is paired with a pinned
# font-size/line-height in the CSS, so the outline changed and the page did not.
for page in "${HTML_PAGES[@]}"; do
  levels=$(tr '\n' ' ' < "$page" | grep -oE '<h[1-6][ >]' | grep -oE '[1-6]')
  h1s=$(printf '%s\n' "$levels" | grep -c '^1$' || true)
  prev=0; skips=0
  for l in $levels; do
    [ "$prev" -ne 0 ] && [ $((l - prev)) -gt 1 ] && { echo "  $page: h$prev followed by h$l"; skips=$((skips+1)); }
    prev=$l
  done
  if [ "$h1s" -eq 1 ] && [ "$skips" -eq 0 ]; then
    pass "$(printf '%-22s outline: %s' "$(basename "$page")" "$(printf '%s' "$levels" | tr '\n' ' ')")"
  else
    fail "$(basename "$page"): $h1s <h1> (want 1), $skips skipped level(s)"
  fi
done

# ---------------------------------------------------------------------------
head1 "15. No layout is decided by JavaScript at DOM-ready"
# WHY: this is the defect that ambushed Stage 1. script.js sized the #inscription photo panel
# from $('.expert').height() read at DOM-ready, so below 768px the panel came out 729px if the
# webfont had not landed yet and 761px if it had — the page rendered differently on a fast
# connection than on a slow one, and every future speed-up silently moved a 32px band.
# Flex does the same job at the layout level with nothing to race. Audit item 2.0.
# The comment left in script.js quotes the code it replaced, so read the code only.
CODE=$(sed -E 's://.*::' assets/js/script.js)
printf '%s' "$CODE" | grep -q "\$('.expert').height()" \
  && fail "script.js still measures .expert at DOM-ready — the font-timing race is back" \
  || pass "no DOM-ready height measurement drives the layout"
# .height() with an argument is a write; $(window).height() with none is a read, and fine.
printf '%s' "$CODE" | grep -qE "\.height\([^)]" \
  && fail "script.js writes an element height from JavaScript" \
  || pass "script.js writes no element heights at all"
awk '/#inscription \.row/{f=1} f{print} f&&/\}/{exit}' assets/css/style.css | grep -q 'display: *flex' \
  && pass "#inscription matches its two columns with flex instead" \
  || fail "#inscription has no CSS that makes its columns equal"

# ---------------------------------------------------------------------------
head1 "16. Nothing pushes the page sideways"
# WHY: .vira-btn carried 80px of horizontal padding at every width, which made GESTIONAR
# SUSCRIPCIÓN 419px wide inside a 390px viewport and scrolled the payment page sideways by
# 14px. clamp() keeps the desktop value exactly. Audit items 2.2 and 2.3.
awk '/^\.vira-btn \{/{f=1} f{print} f&&/\}/{exit}' assets/css/style.css > /tmp/verify-btn.$$
grep -q 'padding: 15px clamp(' /tmp/verify-btn.$$ \
  && pass ".vira-btn padding is clamped (80px on desktop, ~24-31px on a phone)" \
  || fail ".vira-btn still has fixed horizontal padding"
grep -q '80px' /tmp/verify-btn.$$ \
  && pass ".vira-btn keeps its 80px desktop padding" || fail ".vira-btn lost its desktop padding"
grep -q 'border-color' /tmp/verify-btn.$$ \
  && pass ".vira-btn has a visible border (the ghost variant reads as a button)" \
  || fail ".vira-btn has no border — the ghost variant reads as plain text"
rm -f /tmp/verify-btn.$$

# ---------------------------------------------------------------------------
head1 "17. 404.html says what it is"
# WHY: it shipped with no lang attribute, an empty <title>, an empty description and no
# favicon — a page a search engine and a screen reader both had to guess at. Audit item 2.7.
ok=1
grep -q '<html lang=' src/404.html || { echo "  no lang attribute"; ok=0; }
grep -qE '<title>.+</title>' src/404.html || { echo "  empty <title>"; ok=0; }
grep -qE '<meta name="description" content=".+">' src/404.html || { echo "  empty description"; ok=0; }
grep -q 'rel="shortcut icon"' src/404.html || { echo "  no favicon"; ok=0; }
[ "$ok" -eq 1 ] && pass "404.html has lang, title, description and favicon" \
                || fail "404.html is still missing page metadata"

# ---------------------------------------------------------------------------
head1 "18. No third party sits in front of first paint"
# WHY: this site used to load its icons from three different third-party hosts.
# assets/css/style.css opened with an @import of the Ionicons 2.0.1 stylesheet from a 2015
# CDN — render-blocking on all three pages that load style.css, 9,216 B of CSS plus
# 110,963 B of icon font on index.html to draw five social marks, and an @import is the
# worst possible place for it because the browser cannot even discover the request until it
# has fetched and parsed the stylesheet. index.html also loaded a Font Awesome Kit script
# minted in 2016 (84,372 B behind it, plus a stats beacon fired at a third-party CDN on
# every visit). enlaces.html and inscripcion.html each pulled Font Awesome 6 from a public
# CDN — 212,733 B and 120,268 B measured. Every one of them is an inline SVG sprite now:
# no icon on this site is fetched from anywhere but this repo, and none of these hosts may
# come back.
tp=0
for host in code.ionicframework.com fonts.googleapis.com fonts.gstatic.com maps.googleapis.com use.fontawesome.com cdn.fontawesome.com cdnjs.cloudflare.com; do
  hits=$(grep -rn "$host" src assets --include='*.html' --include='*.css' --include='*.js' 2>/dev/null | grep -v '^\s*/\*' | grep -vE '^\S+:[0-9]+:\s*(\*|//|#)' || true)
  if [ -n "$hits" ]; then printf '%s\n' "$hits" | sed 's/^/    /'; tp=$((tp+1)); fi
done
[ "$tp" -eq 0 ] && pass "no CDN font or icon host is referenced from any page or stylesheet" \
                || fail "$tp third-party font/icon host(s) are back in the critical path"

# WHY: the ionicons removal only holds if the glyphs it drew were actually replaced. Five
# social marks, three places each on index.html, and every one of them must resolve to a
# <symbol> that exists in the same document — a <use href="#ic-x"> pointing at nothing
# renders as absolutely nothing, silently, and looks exactly like a page with no icons.
grep -qE 'class="(ion-social|fa fa-[a-z]|fa-solid|fa-brands|fa-regular)' src/*.html src/en/*.html \
  && fail "an icon-font glyph class is back" || pass "no icon-font glyph class left in any page"
# Every <use href="#x"> must resolve to a <symbol id="x"> in the SAME document. A <use>
# pointing at nothing renders as absolutely nothing, silently, and looks exactly like a
# page whose icons were never there — which is how the first build of the Font Awesome
# swap shipped six invisible glyphs past every other check in this file.
badref=0; totaluse=0
for page in "${HTML_PAGES[@]}"; do
  for id in $(grep -oE 'href="#ic-[a-z0-9-]+"' "$page" | sed 's/href="#//; s/"//' | sort -u); do
    grep -q "<symbol id=\"$id\"" "$page" || { echo "    $page: <use href=\"#$id\"> has no <symbol>"; badref=1; }
  done
  totaluse=$((totaluse + $(grep -cE '<use href="#ic-' "$page" || true)))
done
[ "$badref" -eq 0 ] && [ "$totaluse" -ge 74 ] \
  && pass "$totaluse inline SVG icons, every one resolving to a <symbol> in its own page" \
  || fail "the inline SVG sprites are broken ($totaluse <use>, badref=$badref)"
# And every <symbol> must carry a SQUARE viewBox. Font Awesome's are 0 0 640 512 and
# 0 0 448 512; dropped into a square CSS box they either squash or, with width:auto,
# blow out to the CSS default 300px and push the glyph clean out of its container.
sq=0; nsq=0
for vb in $(grep -ohE '<symbol id="ic-[a-z0-9-]+" viewBox="[^"]+"' src/*.html src/en/*.html | sed -E 's/.*viewBox="([^"]+)"/\1/' | tr ' ' ':'); do
  w=$(echo "$vb" | cut -d: -f3); h=$(echo "$vb" | cut -d: -f4)
  if [ "$w" = "$h" ]; then sq=$((sq+1)); else echo "    non-square symbol viewBox: $vb"; nsq=$((nsq+1)); fi
done
[ "$nsq" -eq 0 ] && pass "$sq icon symbols, all with a square viewBox" || fail "$nsq icon symbol(s) have a non-square viewBox"

# WHY: the chat widget injected https://chat.lixsa.ai/lixsa-chat.umd.cjs at parse time —
# 265,065 B measured, a quarter of the homepage, racing the association's own images for a
# bubble most visitors never press. It is live and answering, so it stays; it just may not
# be in the critical path. The guard is that lixsa.js must never contain a bare top-level
# injection again: the src has to be set inside a function that an event or an idle
# callback calls.
if grep -q 'lixsa-chat.umd.cjs' assets/js/lixsa.js; then
  grep -q 'requestIdleCallback' assets/js/lixsa.js && grep -q "addEventListener" assets/js/lixsa.js \
    && pass "the chat widget loads on interaction or on idle, not at parse time" \
    || fail "lixsa.js injects the widget without deferring it"
else
  pass "no chat widget is loaded at all"
fi

# ---------------------------------------------------------------------------
head1 "19. sitemap.xml and robots.txt describe the site that exists"
# WHY: the sitemap listed exactly one URL — the homepage — with a lastmod of 2023-03-22,
# and left out inscripcion.html, the canonical, indexable page that carries the whole
# conversion flow. robots.txt Disallowed /inscripciones/curso-programacion, a path that has
# never existed. Both are files nothing reads back, so both rotted quietly.
# With two language trees the sitemap has two jobs, so this is Python: every <loc> has
# to resolve to a real, indexable file, every indexable file has to appear once, and the
# xhtml:link alternates have to be RECIPROCAL — Google discards a whole hreflang set the
# moment one side does not point back, which fails silently and would leave the English
# pages competing with the Spanish ones instead of complementing them.
python3 - > /tmp/verify-sitemap.$$ 2>&1 <<'PYSM'
import pathlib, re
SITE = "https://multitecua.com"
xml = pathlib.Path("src/sitemap.xml").read_text(encoding="utf-8")

def to_file(url):
    rel = url[len(SITE):].lstrip("/")
    if rel == "" or rel.endswith("/"):
        rel += "index.html"
    return pathlib.Path("src") / rel

locs = re.findall(r"<loc>([^<]+)</loc>", xml)
for loc in locs:
    f = to_file(loc)
    if not f.is_file():
        print("    sitemap lists %s but %s does not exist" % (loc, f))
    elif re.search(r'<meta name="robots" content="[^"]*noindex', f.read_text(encoding="utf-8")):
        print("    sitemap lists %s but %s is noindex" % (loc, f))

want = []
for f in sorted(pathlib.Path("src").glob("*.html")) + sorted(pathlib.Path("src/en").glob("*.html")):
    if re.search(r'<meta name="robots" content="[^"]*noindex', f.read_text(encoding="utf-8")):
        continue
    rel = str(f.relative_to("src"))
    want.append(SITE + "/" + rel.replace("index.html", ""))
for url in want:
    if url not in locs:
        print("    %s is indexable but is not in sitemap.xml" % url)
for url in locs:
    if url not in want:
        print("    sitemap lists %s, which is not an indexable page" % url)

# reciprocity: inside every <url> block the alternates must name this loc as one of them
for block in re.findall(r"<url>(.*?)</url>", xml, re.S):
    loc = re.search(r"<loc>([^<]+)</loc>", block).group(1)
    alts = dict(re.findall(r'<xhtml:link rel="alternate" hreflang="([^"]+)" href="([^"]+)"', block))
    if set(alts) != {"es", "en", "x-default"}:
        print("    %s: alternates are %s, expected es/en/x-default" % (loc, sorted(alts)))
        continue
    if loc not in (alts["es"], alts["en"]):
        print("    %s does not list itself among its own alternates" % loc)
    if alts["x-default"] != alts["es"]:
        print("    %s: x-default is %s, it must be the Spanish URL" % (loc, alts["x-default"]))
    if not to_file(alts["es"]).is_file() or not to_file(alts["en"]).is_file():
        print("    %s: an alternate points at a file that does not exist" % loc)
PYSM
if [ ! -s /tmp/verify-sitemap.$$ ]; then
  pass "sitemap.xml lists every indexable page in both languages, with reciprocal hreflang"
else
  cat /tmp/verify-sitemap.$$
  fail "sitemap.xml and src/ disagree"
fi
rm -f /tmp/verify-sitemap.$$
grep -qE '^Sitemap: https://multitecua.com/sitemap.xml' src/robots.txt \
  && pass "robots.txt points at the sitemap" || fail "robots.txt lost its Sitemap line"
rbfail=0
while read -r line; do
  case "$line" in
    Disallow:*)
      path="$(printf '%s' "$line" | sed 's/^Disallow:[[:space:]]*//; s#/$##; s#^/##')"
      [ -z "$path" ] && continue
      # a Disallowed path must be a page in src/ or a location nginx actually defines
      [ -e "src/$path.html" ] || grep -q "location = /$path" nginx/default.conf \
        || { echo "    robots.txt Disallows /$path, which is not a page and not an nginx location"; rbfail=1; }
      ;;
  esac
done < src/robots.txt
[ "$rbfail" -eq 0 ] && pass "every Disallow names something that exists" || fail "robots.txt disallows a path that does not exist"

# ---------------------------------------------------------------------------
head1 "20. The structured data parses, and says true things"
# WHY: the JSON-LD block on index.html claimed sameAs https://www.youtube.com/@multitecua7745,
# which answers 404 — a dead handle inside the block Google reads to decide what this
# organisation is — and gave contactPoint.telephone as "601143845" with no country code.
# Nothing had ever parsed the block, either: a trailing comma would have made Google discard
# the whole thing without a word.
ld=$(python3 - <<'PY' 2>&1
import json, re, sys
s = "".join(open(f, encoding="utf-8").read() for f in ("src/index.html", "src/en/index.html"))
blocks = re.findall(r'<script type="application/ld\+json">(.*?)</script>', s, re.S)
if not blocks:
    print("NO-JSONLD"); sys.exit()
for b in blocks:
    try:
        d = json.loads(b)
    except Exception as e:
        print("PARSE-ERROR", e); sys.exit()
    for u in d.get("sameAs", []):
        if "@multitecua7745" in u:
            print("DEAD-YOUTUBE-HANDLE"); sys.exit()
    for c in d.get("contactPoint", []):
        t = c.get("telephone", "")
        if t and not t.startswith("+"):
            print("PHONE-NO-COUNTRY-CODE", t); sys.exit()
print("OK", len(blocks))
PY
)
case "$ld" in
  OK*) pass "JSON-LD parses, has no dead handle and an E.164 phone ($ld block(s))" ;;
  *)   fail "JSON-LD: $ld" ;;
esac

# ---------------------------------------------------------------------------
head1 "21. Outbound links"
# WHY: two links on this site were dead and had been for a long time. enlaces.html's primary
# call to action — the one button every visitor arriving from the Instagram bio is meant to
# press — went to https://forms.gle/NsEx9PLxG9cKZWiV8, which answers 401 to the public. And
# the JSON-LD carried a YouTube handle that 404s. Neither would ever have surfaced from
# inside the repo.
#
# The offline half runs always: the two known-dead URLs may not come back. The network half
# runs only if a control URL resolves, and it is loud about being skipped — a check that
# quietly skips is a check that lies.
deadfail=0
for dead in 'forms.gle/NsEx9PLxG9cKZWiV8' 'youtube.com/@multitecua7745'; do
  if grep -rqF "$dead" src assets 2>/dev/null; then echo "    known-dead URL is back: $dead"; deadfail=1; fi
done
[ "$deadfail" -eq 0 ] && pass "neither known-dead URL is referenced anywhere" || fail "a known-dead URL is back in the tree"

# WHY: the members' Claude seats service must NOT be reachable from the public site.
# Sergio, 2026-08-29: "ahora mismo no tiene que ser accesible desde ningún sitio". It is
# still in Stripe test mode and the board has not opened it, so a link to it from the
# page students arrive at from Instagram sends them to something that cannot serve them.
# Three links to it were added earlier the same day, on index.html, inscripcion.html and
# enlaces.html, on an instruction that turned out to be wrong; they are gone. This check
# is what stops them coming back in six months when nobody remembers the conversation.
# When the board does open the service, delete this check in the same commit that adds
# the link, so the decision is visible in one diff.
seats=$(grep -rniE 'claude\.multitecua|//claude\.' src assets i18n 2>/dev/null || true)
if [ -z "$seats" ]; then
  pass "nothing links to the members-only seats service (it is not public yet)"
else
  printf '%s\n' "$seats" | sed 's/^/    /'
  fail "a link to the members-only seats service is back — it must not be reachable from the public site"
fi

if curl -sS -o /dev/null --max-time 12 https://www.ua.es/ 2>/dev/null; then
  UA_STR='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
  bad=0; n=0
  for u in $(grep -rhoE 'https://[^"'"'"' >]+' src/*.html src/en/*.html | sed 's/[",)]*$//' \
             | grep -vE 'schema\.org|w3\.org|multitecua\.com|sitemaps\.org' | sort -u); do
    n=$((n+1))
    code=$(curl -sS -o /dev/null -w '%{http_code}' -L --max-time 25 -A "$UA_STR" "$u" 2>/dev/null || echo 000)
    case "$code" in
      4*|5*|000) echo "    $code $u"; bad=$((bad+1)) ;;
    esac
  done
  [ "$bad" -eq 0 ] && pass "$n outbound links, none returning 4xx/5xx" \
                   || fail "$bad of $n outbound links are broken"
else
  printf '  \033[33mSKIP\033[0m the network check — https://www.ua.es/ is unreachable from here\n'
fi

# ---------------------------------------------------------------------------
if [ -n "${BASE_URL:-}" ]; then
head1 "22. Live headers from a running preview ($BASE_URL)"
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

# WHY: the whole language policy is a claim about what the SERVER does with an
# unqualified request. Sergio's rule is that multitecua.com is Spanish — not
# browser-negotiated, not geolocated — so this asks for the homepage with an English
# Accept-Language and insists on getting Spanish back. It is the one check that would
# catch somebody "helpfully" adding content negotiation later.
es_html=$(curl -sS -H 'Accept-Language: en-GB,en;q=0.9' "$BASE_URL/")
printf '%s' "$es_html" | grep -q '<html lang="es-ES">' \
  && pass "/ is Spanish even when the browser asks for English" \
  || fail "/ did not answer in Spanish — something is negotiating on Accept-Language"
en_html=$(curl -sS -H 'Accept-Language: es-ES,es;q=0.9' "$BASE_URL/en/")
printf '%s' "$en_html" | grep -q '<html lang="en">' \
  && pass "/en/ is English even when the browser asks for Spanish" \
  || fail "/en/ did not answer in English"
for pair in "/en:301" "/en/:200" "/en/inscripcion.html:200" "/en/enlaces:200" "/enlaces:200"; do
  u="${pair%%:*}"; want="${pair##*:}"
  got=$(curl -sS -o /dev/null -w '%{http_code}' "$BASE_URL$u")
  [ "$got" = "$want" ] && pass "$u -> $got" || fail "$u -> $got, expected $want"
done
# WHY: without `error_page 404 /en/404.html` inside `location /en/`, a dead English URL
# answers with the SPANISH 404 — the one place on this site the language could flip
# under a visitor without them touching anything.
en404=$(curl -sS "$BASE_URL/en/no-such-page")
printf '%s' "$en404" | grep -q 'Page not found' \
  && pass "a dead URL under /en/ gets the English 404" \
  || fail "a dead URL under /en/ does not get the English 404"
es404=$(curl -sS "$BASE_URL/no-such-page")
printf '%s' "$es404" | grep -q 'Página no encontrada' \
  && pass "a dead URL at the root gets the Spanish 404" \
  || fail "a dead URL at the root does not get the Spanish 404"
else
  head1 "22. Live headers — SKIPPED (set BASE_URL to a running preview to include)"
fi

# ---------------------------------------------------------------------------
head1 "24. Two languages that stay two languages"
# WHY: this site is Spanish by default with English one tap away (Sergio, 2026-08-29).
# The failure that needs a test is not "the translation is bad" — it is somebody editing
# the Spanish and forgetting the English, which produces a page that looks completely
# fine and is half-translated. Both languages live in ONE table, i18n/strings.json, and
# the pages in src/ are GENERATED from it; tests/test_i18n.py proves the table is
# complete and that what is committed is still what the table renders.
if python3 tests/test_i18n.py > /tmp/verify-i18n.$$ 2>&1; then
  while IFS= read -r line; do
    case "$line" in PASS\ *) pass "${line#PASS }" ;; esac
  done < /tmp/verify-i18n.$$
else
  cat /tmp/verify-i18n.$$
  fail "tests/test_i18n.py failed — the two languages have diverged"
fi
rm -f /tmp/verify-i18n.$$

# WHY: the switch is the entire mechanism. It is a plain <a> so that it works with
# JavaScript off and so that a shared URL carries its language; if it ever became a
# button, a <select> or an onclick, both of those properties would go without anything
# else in this file noticing.
python3 - > /tmp/verify-switch.$$ 2>&1 <<'PYSW'
import pathlib, re

pages = sorted(pathlib.Path("src").glob("*.html")) + sorted(pathlib.Path("src/en").glob("*.html"))
ANCHOR = re.compile(r"<a\b[^>]*>")
for page in pages:
    html = page.read_text(encoding="utf-8")
    anchors = ANCHOR.findall(html)
    # A switch is an <a> that declares the language of what is on the other end. That is
    # the marker rather than a class name, because the phone panel's copy is styled by
    # the panel and carries no class of its own.
    switches = [a for a in anchors if "hreflang=" in a]
    if not switches:
        print("    %s has no language switch" % page)
    for a in switches:
        if 'href="' not in a:
            print("    %s: the switch has no href — it is not a link" % page)
        if " lang=" not in a:
            print("    %s: the switch must carry lang= as well as hreflang=" % page)
    if re.search(r"onclick=|<select\b", html):
        print("    %s: the switch must stay a plain link, with no script" % page)
    # An English page that links back into the Spanish tree drops the visitor's language
    # without warning. The English pages link relatively (inscripcion.html, #faq), which
    # keeps them inside /en/ for free; the only root-absolute hrefs they may carry are
    # /en/..., /assets/... and the one switch back to Spanish.
    own, other = ("/en/", "/") if page.parent.name == "en" else ("/", "/en/")
    for a in anchors:
        if a in switches:
            continue
        m = re.search(r'href="(/[^"]*)"', a)
        if not m or m.group(1).startswith("/assets/"):
            continue
        href = m.group(1)
        in_en = href == "/en" or href.startswith("/en/")
        if (page.parent.name == "en") != in_en:
            print("    %s links into the other language outside the switch: %s" % (page, href))
PYSW
if [ ! -s /tmp/verify-switch.$$ ]; then
  pass "all 8 pages carry a plain-link language switch, and no English page leaks into Spanish"
else
  cat /tmp/verify-switch.$$
  fail "the language switch is broken on at least one page"
fi
rm -f /tmp/verify-switch.$$

# WHY: Spanish is the default, and the default is a property of the FILES, not of a
# redirect or a header — /index.html is the Spanish page and always will be.
grep -q '<html lang="es-ES">' src/index.html \
  && pass "the page at the site root is the Spanish one" \
  || fail "src/index.html is not Spanish — the default language moved"

# WHY: nginx has to answer /en/ and /en/enlaces, and a missing page under /en/ has to
# get the English 404. These are directives; group 22 checks the responses.
for d in 'location /en/' 'error_page 404 /en/404.html' 'location = /en/enlaces' 'location = /en '; do
  grep -qF "$d" nginx/default.conf && pass "nginx: ${d}" || fail "nginx: missing ${d}"
done

# ---------------------------------------------------------------------------
if [ -n "${DETECT:-}" ]; then
head1 "23. Design detector"
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
# The ceiling is what stops "tracked findings" from becoming a place to hide new ones.
# 2026-08-29, after Stages 1-4: 10. Seven are inside vendored library CSS we do not own
# (bootstrap.min.css 5, owl.carousel.css 2); three are on inscripcion.html and are
# deliberate — the red left rule on the board-approval notice, and two full-bleed page
# sections the rule reads as unpadded cards. Lower this number when you clear one; never
# raise it without saying in the commit which finding you accepted and why.
DETECT_CEILING=${DETECT_CEILING:-10}
case "$rc" in
  0) pass "detector exit 0 — clean" ;;
  2) if [ "${n:-999}" -le "$DETECT_CEILING" ]; then
       pass "detector exit 2 — ${n:-?} findings (ceiling $DETECT_CEILING; all in vendored CSS or tracked)"
     else
       fail "detector exit 2 — ${n:-?} findings, above the ceiling of $DETECT_CEILING"
     fi ;;
  *) fail "detector exit $rc — the page was NOT checked" ;;
esac
else
  head1 "23. Design detector — SKIPPED (set DETECT=/path/to/detect.sh to include)"
fi

# ---------------------------------------------------------------------------
printf '\n'
if [ "$FAILED" -eq 0 ]; then printf '\033[32mverify.sh: all checks passed\033[0m\n'; else printf '\033[31mverify.sh: FAILURES above\033[0m\n'; fi
exit "$FAILED"
