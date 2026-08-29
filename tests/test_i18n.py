#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Two languages that stay two languages.

The failure this file exists to prevent is the ordinary one: somebody edits a Spanish
sentence, forgets the English, and the page ships half-translated with no error anywhere.
Everything here is a direct descendant of claude-seats/tests/test_i18n.py, which already
guards the members' portal — the difference is that this site has no request-time lookup,
so there is one extra and very important check: the generated pages in src/ must still be
what i18n/templates + i18n/strings.json produce. That is the check that makes "generate
and commit" safe.

Run it directly (no pytest, no dependencies — this repo has neither):

    python3 tests/test_i18n.py

It prints one PASS/FAIL line per check, which is how tests/verify.sh folds it into its
own count, and exits 1 if anything failed.
"""
from __future__ import annotations

import io
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "i18n"))

import build  # noqa: E402  (i18n/build.py)

FAILED = []
CHECKS = []


def check(ok, description, detail=""):
    CHECKS.append(ok)
    if ok:
        print("PASS %s" % description)
    else:
        FAILED.append(description)
        print("FAIL %s%s" % (description, (" — " + detail) if detail else ""))


def main() -> int:
    table = build.load()
    strings = table["strings"]
    variables = table["vars"]
    same_in_both = set(table["same_in_both"])
    templates = {p.name: p.read_text(encoding="utf-8") for p in build.TEMPLATES.glob("*.html")}

    # -- 1. both languages, always ------------------------------------------------
    missing = {k: sorted(set(build.LANGUAGES) - set(v))
               for k, v in strings.items() if set(v) != set(build.LANGUAGES)}
    check(not missing, "every string exists in both languages (%d strings)" % len(strings),
          repr(missing)[:200])

    empty = ["%s.%s" % (k, l) for k, v in strings.items()
             for l in build.LANGUAGES if not (v.get(l) or "").strip()]
    check(not empty, "no string is blank in either language", ", ".join(empty[:8]))

    # -- 2. placeholders ----------------------------------------------------------
    # `{fee}` in Spanish and `{cuota}` in English renders the wrong thing, silently.
    bad = []
    for key, row in strings.items():
        fields = {l: set(build.FIELD.findall(row[l])) for l in build.LANGUAGES}
        if fields["es"] != fields["en"]:
            bad.append("%s %s" % (key, fields))
    check(not bad, "the {placeholders} match between the two languages", "; ".join(bad[:5]))

    unknown = sorted({f for row in strings.values() for l in build.LANGUAGES
                      for f in build.FIELD.findall(row[l])} - set(variables))
    check(not unknown, "every {placeholder} names a variable that exists", ", ".join(unknown))

    # -- 3. a string that is the same in both languages is a decision, not an oversight
    # Proper nouns (Cienciathon, Instagram) and quoted press headlines are legitimately
    # identical. Anything else that is identical is almost certainly an untranslated
    # sentence, so it has to be listed in same_in_both by hand.
    identical = {k for k, v in strings.items() if v["es"] == v["en"]}
    undeclared = sorted(identical - same_in_both)
    check(not undeclared, "%d strings are identical in both languages, all declared" % len(identical),
          "not declared in same_in_both: " + ", ".join(undeclared[:8]))
    stale = sorted(same_in_both - identical)
    check(not stale, "same_in_both lists nothing that is no longer identical", ", ".join(stale[:8]))

    # -- 4. templates and table agree both ways -----------------------------------
    used = set()
    for text in templates.values():
        used |= set(build.KEY.findall(text))
    prose_used = {k for k in used if not k.startswith("@")}
    unknown_keys = sorted(prose_used - set(strings))
    check(not unknown_keys, "every {{key}} a template asks for exists in the table",
          ", ".join(unknown_keys[:8]))
    dead = sorted(set(strings) - prose_used)
    check(not dead, "no string in the table is unused by every template", ", ".join(dead[:8]))

    computed = sorted(k for k in used if k.startswith("@"))
    known_computed = set(build.context("index.html", "es", table))
    unknown_computed = sorted(set(computed) - known_computed)
    check(not unknown_computed, "every {{@computed}} value a template asks for is produced",
          ", ".join(unknown_computed))

    # -- 5. nothing is left hard-coded in a template -------------------------------
    # A cheap smell test, not a parser: a run of words sitting as a text node, or an
    # alt/aria-label/meta-content that is not a hole, is a sentence that will never be
    # translated. It caught nothing when it was written, which is the point — it fires
    # the day somebody adds a paragraph straight to a template.
    leftovers = []
    for name, text in templates.items():
        stripped = re.sub(r"<!--.*?-->", "", text, flags=re.S)
        stripped = re.sub(r"<(script|style|svg)\b.*?</\1>", "", stripped, flags=re.S | re.I)
        for run in re.findall(r">([^<>{}]{12,})<", stripped):
            # three SPACE-separated words, so an email address or a file name — which
            # are not prose and are not translated — does not trip it.
            if len(re.findall(r"(?:^|\s)[A-Za-zÁÉÍÓÚÑáéíóúñ]{2,}", run)) >= 3:
                leftovers.append("%s: %s" % (name, run.strip()[:60]))
        for attr in ("alt", "aria-label"):
            for value in re.findall(r'\b%s="([^"]*)"' % attr, stripped):
                if value and not value.startswith("{{"):
                    leftovers.append("%s: %s=%s" % (name, attr, value[:50]))
        for value in re.findall(r'<meta name="(?:description|twitter:[a-z0-9]+)"[^>]*content="([^"]*)"',
                                stripped):
            if value and not value.startswith("{{") and re.search(r"[A-Za-z]{2,} [a-z]{2,} ", value):
                leftovers.append("meta: %s" % value[:50])
    check(not leftovers, "no template carries a sentence outside the table",
          "; ".join(leftovers[:5]))

    # -- 6. what is committed is what the table renders ----------------------------
    # The whole safety of "generate the pages and commit them" rests on this one.
    stale_pages = []
    for page, lang, path in build.targets():
        want = build.render(page, lang, table)
        if not path.exists():
            stale_pages.append("%s (missing)" % path.relative_to(ROOT))
        elif path.read_text(encoding="utf-8") != want:
            stale_pages.append(str(path.relative_to(ROOT)))
    check(not stale_pages, "every page in src/ matches the templates and the table",
          "run `python3 i18n/build.py`: " + ", ".join(stale_pages))

    # -- 7. the rendered pair really is a pair --------------------------------------
    for page in build.PAGES:
        es = (build.SRC / page)
        en = (build.SRC / "en" / page)
        check(es.exists() and en.exists(), "%s exists in both languages" % page)

    for page, lang, path in build.targets():
        if not path.exists():
            continue
        html = path.read_text(encoding="utf-8")
        want = 'lang="%s"' % build.LANG_TAG[lang]
        check('<html %s>' % want in html,
              "%s declares %s" % (path.relative_to(ROOT), want))

    # -- 8. the hreflang pair points at pages that exist ----------------------------
    dangling = []
    for page, cfg in build.PAGES.items():
        if not cfg["indexable"]:
            continue
        for lang, path in ((l, build.SRC / page if l == "es" else build.SRC / "en" / page)
                           for l in build.LANGUAGES):
            html = path.read_text(encoding="utf-8")
            for href in re.findall(r'<link rel="alternate" hreflang="[^"]+" href="([^"]+)">', html):
                rel = href[len(build.SITE):].lstrip("/") or "index.html"
                if rel.endswith("/"):
                    rel += "index.html"
                if not (build.SRC / rel).exists():
                    dangling.append("%s -> %s" % (path.name, href))
    check(not dangling, "every hreflang alternate resolves to a page in src/", "; ".join(dangling))

    print()
    print("test_i18n: %d checks, %d failed" % (len(CHECKS), len(FAILED)))
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
