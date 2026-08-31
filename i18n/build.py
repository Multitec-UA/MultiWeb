#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Render every page of multitecua.com in both languages, from one table of strings.

    python3 i18n/build.py            # write src/*.html and src/en/*.html
    python3 i18n/build.py --check    # write nothing; fail if what is on disk is stale

Why this shape, and not the two obvious alternatives
----------------------------------------------------
This site is four hand-written static pages served by nginx out of a container. It has
never had a build step and it does not have one now: the Dockerfile still just COPYs
`src/`, and Cloud Build still just runs `docker build`. What changed is that `src/*.html`
is no longer written by hand — it is *generated here and committed*, and
`tests/verify.sh` fails if regenerating would change a byte. So the deploy path carries
no new dependency and cannot break on a Python error, while there is still exactly one
place a sentence lives.

  - Swapping text with JavaScript on a single URL was rejected: one URL means one page
    for a search engine and for anyone who shares a link, and it dies with scripting off.
  - Negotiating on Accept-Language was rejected: Sergio's rule is that an unqualified
    visit to multitecua.com is Spanish, full stop. A student in Alicante with an English
    phone is still written to in Spanish; the switch is right there for the exceptions.

So: Spanish keeps every URL it has (`/`, `/inscripcion.html`, `/enlaces`) and English
lives under `/en/`. The switch is a plain <a> between the two, which is why it survives
JavaScript being off, why a shared link keeps its language, and why a crawler can follow
it. hreflang ties the pair together and x-default points at the Spanish.

The two rules this file exists to enforce come from claude-seats/app/i18n.py, which
solved the same problem for the members' portal:

  1. both languages live side by side in ONE table (i18n/strings.json), never in two
     copies of a page that can drift apart;
  2. a test fails when they diverge — tests/test_i18n.py, wired into tests/verify.sh.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

import events as events_table  # i18n/events.py — the calendar and the box it lives in

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / "i18n" / "strings.json"
TEMPLATES = ROOT / "i18n" / "templates"
SRC = ROOT / "src"

LANGUAGES = ("es", "en")
DEFAULT = "es"
SITE = "https://multitecua.com"
# Kept in step with the /assets/vN/ segment in the templates by tests/verify.sh
# group 7 and by test_events.py, so a version bump cannot leave the cards behind.
ASSETS = "../assets/v7"

# The endonym is deliberately NOT a translated string: a language is offered in its own
# language, so an English reader on the Spanish page recognises the word without reading
# any Spanish. The <a> carries lang= to match, so a screen reader switches voice.
ENDONYM = {"es": "Español", "en": "English"}
CODE = {"es": "ES", "en": "EN"}
ARIA = {"es": "Ver en español", "en": "View in English"}
LANG_TAG = {"es": "es-ES", "en": "en"}
OG_LOCALE = {"es": "es_ES", "en": "en_GB"}

# url[lang] is where the page lives; switch[lang] is where its language switch points,
# which is the same thing everywhere except on 404: from a dead link the useful
# destination is the other language's homepage, not the other language's 404.
PAGES = {
    "index.html": {
        "url": {"es": "/", "en": "/en/"},
        "indexable": True,
    },
    "inscripcion.html": {
        "url": {"es": "/inscripcion.html", "en": "/en/inscripcion.html"},
        "indexable": True,
    },
    "enlaces.html": {
        # nginx serves /enlaces and /en/enlaces from these files; the .html URL is not
        # the canonical one and never appears in a link.
        "url": {"es": "/enlaces", "en": "/en/enlaces"},
        "indexable": False,
    },
    "404.html": {
        "url": {"es": "/404.html", "en": "/en/404.html"},
        "switch": {"es": "/", "en": "/en/"},
        "indexable": False,
    },
}

KEY = re.compile(r"\{\{(@?[a-z_0-9]+)\}\}")
FIELD = re.compile(r"\{(\w+)\}")


def load():
    return json.loads(TABLE.read_text(encoding="utf-8"))


def context(page: str, lang: str, table: dict) -> dict:
    """The computed values a template asks for as {{@name}}.

    They are prefixed @ so that they can never collide with a translated key, and so
    that reading a template tells you at a glance which holes are prose and which are
    machinery.
    """
    other = "en" if lang == "es" else "es"
    cfg = PAGES[page]
    switch = cfg.get("switch", cfg["url"])
    ctx = {
        "@lang": lang,
        "@lang_tag": LANG_TAG[lang],
        "@canonical": SITE + cfg["url"][lang],
        "@og_locale": OG_LOCALE[lang],
        "@og_locale_alt": OG_LOCALE[other],
        "@alt_lang": other,
        "@alt_href": switch[other],
        "@alt_code": CODE[other],
        "@alt_endonym": ENDONYM[other],
        "@alt_aria": ARIA[other],
        "@stripe_locale": lang,
        # Where "home" and "join" are in THIS language. The pages link to each other
        # relatively, which keeps a visitor inside the language tree for free, but the
        # three links that have to be root-absolute — the wordmark, and both links on
        # 404.html, which nginx serves from arbitrary URLs where a relative href would
        # resolve against the URL that was asked for — need to be told.
        "@home_href": PAGES["index.html"]["url"][lang],
        "@join_href": PAGES["inscripcion.html"]["url"][lang],
    }
    # The events wheel. Only index.html asks for it, and loading the calendar is what
    # validates it — see i18n/events.py — so an event that breaks the card shape fails
    # the build here rather than shipping a ragged row.
    if page == "index.html":
        def string(key, in_lang):
            row = table["strings"].get(key)
            if row is None:
                raise SystemExit("events: no such string: %s" % key)
            return row.get(in_lang) or row[DEFAULT]
        ctx["@events"] = events_table.render(lang, string, asset_prefix=ASSETS)
    if cfg["indexable"]:
        lines = ['    <link rel="alternate" hreflang="%s" href="%s%s">' % (l, SITE, cfg["url"][l])
                 for l in LANGUAGES]
        lines.append('    <link rel="alternate" hreflang="x-default" href="%s%s">'
                     % (SITE, cfg["url"][DEFAULT]))
        ctx["@alternates"] = "\n".join(lines)
    else:
        # noindex pages get no hreflang: it annotates what a crawler may index, and
        # these two are explicitly not that.
        ctx["@alternates"] = ""
    return ctx


def render(page: str, lang: str, table: dict) -> str:
    ctx = context(page, lang, table)
    strings = table["strings"]
    variables = table["vars"]
    missing = []

    def resolve(match):
        key = match.group(1)
        if key.startswith("@"):
            if key not in ctx:
                missing.append(key)
                return match.group(0)
            return ctx[key]
        row = strings.get(key)
        if row is None:
            missing.append(key)
            return match.group(0)
        # A key present in one language and blank in the other renders the other
        # language rather than a hole; test_i18n.py makes sure it never comes to that.
        value = row.get(lang) or row[DEFAULT]
        return FIELD.sub(lambda m: variables[m.group(1)], value)

    out = KEY.sub(resolve, (TEMPLATES / page).read_text(encoding="utf-8"))
    if missing:
        raise SystemExit("%s [%s]: no such string: %s" % (page, lang, ", ".join(sorted(set(missing)))))
    return out


def targets():
    for page in PAGES:
        for lang in LANGUAGES:
            path = SRC / page if lang == DEFAULT else SRC / lang / page
            yield page, lang, path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="do not write; exit 1 if any generated page is out of date")
    args = ap.parse_args()

    table = load()
    stale = []
    for page, lang, path in targets():
        text = render(page, lang, table)
        if args.check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                stale.append(str(path.relative_to(ROOT)))
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print("wrote %s" % path.relative_to(ROOT))
    if stale:
        print("out of date, run `python3 i18n/build.py`:\n  " + "\n  ".join(stale), file=sys.stderr)
        return 1
    if args.check:
        print("every generated page matches i18n/templates + i18n/strings.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
