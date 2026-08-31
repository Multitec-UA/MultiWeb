#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The event standard: load i18n/events.json, refuse it if it is out of the box, render it.

Why this file exists
--------------------
The events strip on the homepage is a row of cards that all have to be the SAME card.
A summary of 60 characters beside one of 240 does not make a wheel, it makes a ragged
fence — and no amount of CSS fixes it, because the text really is that different. So the
shape is enforced where the text is written, not where it is drawn:

  * every field has a hard minimum and maximum length, in BOTH languages;
  * `load()` raises on the first violation, and `i18n/build.py` calls `load()`;
  * therefore a card that would break the row cannot be rendered at all — the build
    fails, with the field, the language, the count and the allowed range.

That is the same trick tests/test_i18n.py plays on the string table, for the same reason.
`tests/test_events.py` runs the identical checks as a readable PASS/FAIL list; this module
is what makes them unskippable.

What is deliberately NOT in here
--------------------------------
Anything that depends on today's date. `src/*.html` is generated and committed, and
`build.py --check` fails when regenerating would change a byte — so a page that baked in
"faltan 24 días" would be stale tomorrow morning and red in CI by lunchtime. Past/next
state and the countdown are therefore decided in the browser, from the `data-start` and
`data-end` attributes rendered here. See the events block in assets/js/script.js.
"""
from __future__ import annotations

import datetime as _dt
import html
import json
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
TABLE = ROOT / "i18n" / "events.json"
IMAGES = ROOT / "assets" / "images"

LANGUAGES = ("es", "en")

# ── the box ────────────────────────────────────────────────────────────────────
# Each entry is (min, max) inclusive, counted in characters, per language.
#
# The two that matter are `summary` and `title`: they are what the card is sized by.
# 110-150 is roughly two full lines at the card width on a phone and two on a desktop,
# which is why the range is narrow — 90 would leave a visible hole under one card and
# 170 would clip. The others are ranges rather than maxima so an empty-ish field cannot
# pass by being merely short.
BOUNDS = {
    "title":     (8, 28),
    "summary":   (110, 150),
    "location":  (6, 34),
    "image_alt": (30, 110),
}
# `location` is the one field allowed to be absent. Several real events -- a members'
# party, a co-hosted meetup -- have no venue recorded anywhere, and the choice was between
# inventing one and leaving the line out. The card does not go ragged: the same line
# always renders, carrying the audience when there is no venue to carry.
OPTIONAL = {"location"}

# What the association actually did here. Sergio, 2026-08-31: the card has to say whether
# "es una colaboración, es una organización o si simplemente hemos asistido", because
# claiming to have run somebody else's event is the one thing this section must not do.
ROLES = ("organiza", "colabora", "asiste")

# Who could come. `socios` exists because a members' event has no registration link and
# never will -- that is not a hole in the data, it is a different kind of event.
AUDIENCES = ("publico", "socios")

# How the picture should be drawn, which is not a style choice — it is about honesty.
# Sergio, 2026-08-31, on an event whose poster does not exist yet: "usa, a lo mejor, solo
# el logotipo, no pongas una foto que no es". A photograph of last year's edition on this
# year's card claims something that did not happen. So:
#   photo   a real photograph OF THIS EDITION      -> cropped to fill the card window
#   poster  this edition's own poster              -> letterboxed, never cropped
#   logo    the event's or its organiser's mark, when there is neither -> contained, on
#           the section ground, and visibly not a photograph
#   illustration  a drawing made for the card, for an event nobody photographed. Sergio,
#           2026-08-31, about the camping weekend: "a lo mejor no encuentras una foto, coge
#           y crea una imagen SVG de un pequeño campamento, así con colores planos".
#           Contained like a logo, and an SVG so it costs 1.3 KB instead of 30.
IMAGE_KINDS = ("photo", "poster", "logo", "illustration")

# Every event belongs to a SERIES, and every series has a mark. Sergio, 2026-08-31: a
# recurring event has to be identifiable as part of its family at a glance -- "aunque sea
# en chiquitín, en translúcido… a lo mejor en la propia tarjeta abajo, no encima de la foto
# porque ya tiene demasiada sobrecarga". So the mark lives in a slim dark strip at the foot
# of the card, beside the countdown, and never over the photograph.
#
# The map is here rather than per-event on purpose: every Game Jam card gets the same mark
# without anybody having to remember, and a series cannot end up with two different ones.
# The files are white-on-transparent, which is why the strip is dark -- these are the
# institutions' own light variants, not recoloured versions of their marks.
SERIES_EMBLEM = {
    "gamejam-alicante":     "gamejam.webp",
    "cienciathon":          "pca.webp",
    "nasa-space-apps":      "nasa-space-apps.webp",
    "gdg-alicante":         "gdg.webp",
    "uagames-devcon":       "eps.webp",
    "quiero-ser-ingeniera": "eps.webp",
    "mes-cultural":         "eps.webp",
    "bienvenida":           "ua.webp",
    "multifiesta":          "multitec.webp",
    "multi-acampada":       "multitec.webp",
    "fempa":                "multitec.webp",
    "cursos-multitec":      "multitec.webp",
    "lan-party":            "multitec.webp",
    "hackathons-externos":  "multitec.webp",
    "jornadas":             "multitec.webp",
    "ferias":               "multitec.webp",
    "opensourcejam":        "multitec.webp",
    "gymkana-tecnologica":  "multitec.webp",
    "doeactua":             "ua.webp",
}

ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

# Three shapes, and which one is used says how well the date is known. Sergio, 2026-08-31:
# "para los futuros eventos, muchas veces no se confirma la fecha hasta que queda poco…
# te puedes permitir poner un rango de fechas o poner un mes". So a future event is not
# forced to invent a day it does not have.
#
#   2026-01-30T17:00   the day and the hour       -> "30 ENE 2026 · 17:00"
#   2026-01-30         the day, no hour recorded  -> "30 ENE 2026"
#   2026-10            only the month             -> "OCTUBRE 2026"
#
# `tentative: true` is orthogonal and means "this is our best information, not a promise" —
# it prints an `aprox.` next to the date and replaces the day countdown with "fecha por
# confirmar", because counting down to a day nobody has committed to is a lie with a number
# attached.
WHEN_RE = re.compile(r"^\d{4}(-\d{2}(-\d{2}(T\d{2}:\d{2})?)?)?$")

def precision(when: str) -> str:
    """`month`, `day` or `exact`, from the shape of the string itself."""
    return {4: "year", 7: "month", 10: "day", 16: "exact"}[len(when)]


def sort_key(ev) -> str:
    """A month sorts as if it were its first day, so the wheel stays chronological."""
    w = ev["start"]
    return w + "-01" * ((10 - len(w)) // 3) if len(w) < 10 else w

# The image every card draws is cropped to a fixed 16:10 window by CSS, so the source
# only has to be at least this big and at least this shape. A portrait poster would be
# cropped to a letterbox of somebody's chin, which is why the ratio has a floor too.
MIN_IMAGE_WIDTH = 600
MIN_ASPECT = 1.2          # width / height

MONTHS = {
    "es": ["ENE", "FEB", "MAR", "ABR", "MAY", "JUN",
           "JUL", "AGO", "SEP", "OCT", "NOV", "DIC"],
    "en": ["JAN", "FEB", "MAR", "APR", "MAY", "JUN",
           "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"],
}
# A month-precision date reads better spelled out: "OCTUBRE 2026" says "sometime in
# October" in a way "OCT 2026" does not.
MONTHS_LONG = {
    "es": ["ENERO", "FEBRERO", "MARZO", "ABRIL", "MAYO", "JUNIO",
           "JULIO", "AGOSTO", "SEPTIEMBRE", "OCTUBRE", "NOVIEMBRE", "DICIEMBRE"],
    "en": ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
           "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"],
}


class EventError(ValueError):
    """A row that is not in the box. The message names the row, the field and the fix."""


def _fail(event_id, message):
    raise EventError("events.json [%s]: %s" % (event_id, message))


def _parse(when):
    for fmt in ("%Y-%m-%dT%H:%M", "%Y-%m-%d", "%Y-%m", "%Y"):
        try:
            return _dt.datetime.strptime(when, fmt)
        except ValueError:
            continue
    raise ValueError("not a date this understands: %r" % when)


def _svg_size(path: pathlib.Path):
    """Width and height off an SVG root element.

    SVG is allowed for ILLUSTRATIONS — Sergio, 2026-08-31, on an event with no photograph
    and no poster: "coge y crea una imagen SVG de un pequeño campamento, así con colores
    planos". A drawing that stands in for a missing photograph should not pretend to be a
    photograph, and vector is the honest and much cheaper way to say so: the camping
    illustration is 1.3 KB against ~30 KB for the same thing rasterised.
    """
    head = path.read_text(encoding="utf-8")[:600]
    w = re.search(r'\bwidth="(\d+)', head)
    h = re.search(r'\bheight="(\d+)', head)
    if w and h:
        return int(w.group(1)), int(h.group(1))
    vb = re.search(r'viewBox="[\d.]+ [\d.]+ ([\d.]+) ([\d.]+)"', head)
    if vb:
        return round(float(vb.group(1))), round(float(vb.group(2)))
    return None


def _image_size(path: pathlib.Path):
    """Width and height of a WebP file, without Pillow — this repo has no dependencies.

    Handles the three WebP flavours (lossy VP8, lossless VP8L, extended VP8X). Returns
    None for anything it does not recognise rather than guessing, and the caller treats
    that as "cannot check", not as "fine".
    """
    if path.suffix.lower() == ".svg":
        return _svg_size(path)
    data = path.read_bytes()[:40]
    if len(data) < 30 or data[:4] != b"RIFF" or data[8:12] != b"WEBP":
        return None
    chunk = data[12:16]
    if chunk == b"VP8X":
        w = int.from_bytes(data[24:27], "little") + 1
        h = int.from_bytes(data[27:30], "little") + 1
        return w, h
    if chunk == b"VP8L":
        bits = int.from_bytes(data[21:25], "little")
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if chunk == b"VP8 ":
        return (int.from_bytes(data[26:28], "little") & 0x3FFF,
                int.from_bytes(data[28:30], "little") & 0x3FFF)
    return None


def load(table_path: pathlib.Path = TABLE):
    """Read events.json, validate every row, return them sorted oldest first.

    Raises EventError on the first problem. Chronological order is decided here and not
    in the JSON, so a row appended at the bottom of the file lands in the right place on
    the page without anybody having to re-sort by hand.
    """
    raw = json.loads(table_path.read_text(encoding="utf-8"))
    categories = set(raw["categories"])
    events = raw["events"]
    seen = set()

    for ev in events:
        eid = ev.get("id", "<no id>")
        if not ID_RE.match(str(eid)):
            _fail(eid, "id must be lowercase-kebab-case")
        if eid in seen:
            _fail(eid, "duplicate id")
        seen.add(eid)

        if ev.get("category") not in categories:
            _fail(eid, "category %r is not one of %s"
                  % (ev.get("category"), ", ".join(sorted(categories))))

        for key in ("start", "end"):
            value = ev.get(key)
            if key == "end" and value is None:
                continue
            if not isinstance(value, str) or not WHEN_RE.match(value):
                _fail(eid, "%s must be YYYY-MM, YYYY-MM-DD or YYYY-MM-DDTHH:MM local time "
                           "(Europe/Madrid), got %r" % (key, value))
        if ev.get("end") and precision(ev["end"]) != precision(ev["start"]):
            _fail(eid, "start and end must be equally precise (%s vs %s)"
                  % (precision(ev["start"]), precision(ev["end"])))
        if ev.get("end") and _parse(ev["end"]) < _parse(ev["start"]):
            _fail(eid, "end is before start")
        if not isinstance(ev.get("tentative", False), bool):
            _fail(eid, "tentative must be true or false")
        if ev.get("series") not in SERIES_EMBLEM:
            _fail(eid, "series %r has no emblem. Add it to SERIES_EMBLEM in i18n/events.py "
                       "-- a card without its family mark is the thing the strip exists for"
                  % ev.get("series"))
        if ev.get("image_kind", "photo") not in IMAGE_KINDS:
            _fail(eid, "image_kind %r is not one of %s"
                  % (ev.get("image_kind"), ", ".join(IMAGE_KINDS)))

        if ev.get("role") not in ROLES:
            _fail(eid, "role %r is not one of %s" % (ev.get("role"), ", ".join(ROLES)))
        if ev.get("audience") not in AUDIENCES:
            _fail(eid, "audience %r is not one of %s" % (ev.get("audience"), ", ".join(AUDIENCES)))

        for field, (lo, hi) in BOUNDS.items():
            row = ev.get(field)
            if row is None and field in OPTIONAL:
                continue
            if not isinstance(row, dict):
                _fail(eid, "%s must be an object with an es and an en" % field)
            for lang in LANGUAGES:
                text = row.get(lang)
                if not isinstance(text, str) or not text.strip():
                    _fail(eid, "%s.%s is missing — both languages are mandatory, always"
                          % (field, lang))
                n = len(text)
                if not (lo <= n <= hi):
                    _fail(eid, "%s.%s is %d characters, the box is %d-%d. Rewrite it, do "
                               "not widen the box: every card is the same card."
                          % (field, lang, n, lo, hi))

        image = ev.get("image")
        if (not isinstance(image, str) or image.startswith("/") or ".." in image
                or image.count("/") > 1):
            _fail(eid, "image must be a filename inside assets/images/, at most one "
                       "folder deep (e.g. events/gamejam-2026.webp)")
        path = IMAGES / image
        if not path.exists():
            _fail(eid, "image %s does not exist in assets/images/" % image)
        size = _image_size(path)
        if size is None:
            _fail(eid, "image %s is not a WebP or an SVG this can measure" % image)
        w, h = size
        if ev.get("image_kind") in ("logo", "illustration"):
            # A logo is contained, not cropped, so the 16:10 rule that protects
            # photographs from being cut to a letterbox of somebody's chin does not
            # apply — but it still has to be big enough not to be fuzzy.
            if w < 320:
                _fail(eid, "logo %s is only %dpx wide; the card draws it at 300" % (image, w))
        else:
            if w < MIN_IMAGE_WIDTH:
                _fail(eid, "image %s is %dpx wide, the card needs at least %d"
                      % (image, w, MIN_IMAGE_WIDTH))
            if w / h < MIN_ASPECT:
                _fail(eid, "image %s is %dx%d (%.2f:1); the card crops to 16:10, so anything "
                           "under %.1f:1 loses most of the picture"
                      % (image, w, h, w / h, MIN_ASPECT))
        ev["_image_size"] = size

        link = ev.get("link")
        if link is not None and not str(link).startswith("https://"):
            _fail(eid, "link must be https:// or null, got %r" % link)

    return sorted(events, key=sort_key)


def strings_used(table_path: pathlib.Path = TABLE):
    """Every i18n key render() will look up.

    tests/test_i18n.py fails on a string in the table that no template names, which is a
    good check and would be wrong here: these are chosen from the event's `category` at
    render time, so they appear in no template. Declaring them keeps the dead-string
    check honest instead of loosening it.
    """
    raw = json.loads(table_path.read_text(encoding="utf-8"))
    return ({"events_cat_" + c for c in raw["categories"]}
            | {"events_role_" + r for r in ROLES}
            | {"events_aud_" + a for a in AUDIENCES}
            | {"events_approx"})


def when_label(ev, lang):
    """The date as the card prints it.

    '24-26 OCT 2025', '22 MAY 2025', '30 DIC - 2 ENE', and — for a future event whose day
    nobody has fixed yet — 'OCTUBRE 2026' or 'ENE - FEB 2027'.

    Deliberately not locale-dependent: strftime would need a locale installed in the build
    environment, and a missing es_ES.UTF-8 would silently produce English months on a
    Spanish page.
    """
    m, ml = MONTHS[lang], MONTHS_LONG[lang]
    dash = "\u2013"  # en dash, the correct mark for a range
    a = _parse(ev["start"])
    b = _parse(ev["end"]) if ev.get("end") else a

    if precision(ev["start"]) == "year":
        return "%d" % a.year if a.year == b.year else "%d %s %d" % (a.year, dash, b.year)

    if precision(ev["start"]) == "month":
        if (a.year, a.month) == (b.year, b.month):
            return "%s %d" % (ml[a.month - 1], a.year)
        if a.year == b.year:
            return "%s %s %s %d" % (m[a.month - 1], dash, m[b.month - 1], a.year)
        return "%s %d %s %s %d" % (m[a.month - 1], a.year, dash, m[b.month - 1], b.year)

    if a.date() == b.date():
        return "%d %s %d" % (a.day, m[a.month - 1], a.year)
    if (a.year, a.month) == (b.year, b.month):
        return "%d%s%d %s %d" % (a.day, dash, b.day, m[a.month - 1], a.year)
    if a.year == b.year:
        return "%d %s %s %d %s %d" % (a.day, m[a.month - 1], dash, b.day, m[b.month - 1], a.year)
    return "%d %s %d %s %d %s %d" % (a.day, m[a.month - 1], a.year, dash,
                                     b.day, m[b.month - 1], b.year)


def _e(text):
    return html.escape(text, quote=True)


def render(lang, strings, asset_prefix="../assets/v8", events=None):
    """The <li> list for the events wheel, in one language.

    `strings` is the resolved i18n table (build.py hands over a lookup so the labels the
    card needs — the category name, the 'more information' link — come out of the same
    single table as every other sentence on the site, not out of this file).
    """
    if events is None:
        events = load()
    out = []
    for index, ev in enumerate(events):
        w, h = ev["_image_size"]
        title = _e(ev["title"][lang])
        role = strings("events_role_" + ev["role"], lang)
        audience = strings("events_aud_" + ev["audience"], lang)
        # The venue and the audience share one line, so the line is never empty and every
        # card keeps the same number of rows whether or not the venue is known.
        where = ev["location"][lang] + " · " + audience if ev.get("location") else audience
        # 00:00 is the convention for "the time is not recorded anywhere". Printing
        # "· 00:00" on a 2020 event nobody wrote a start time for would be inventing a
        # fact to fill a slot, so the span is simply left out and the row still lines up.
        kind = ev.get("image_kind", "photo")
        emblem = SERIES_EMBLEM[ev["series"]]
        tentative = bool(ev.get("tentative"))
        clock = ev["start"][11:] if precision(ev["start"]) == "exact" else ""
        time_span = "" if clock in ("", "00:00") else '<span class="ev-time">%s</span>' % _e(clock)
        # `aprox.` sits next to the date rather than replacing it, so the card still says
        # what we know while being honest that it is not fixed yet.
        if tentative:
            time_span += '<span class="ev-approx">%s</span>' % _e(strings("events_approx", lang))
        link = ev.get("link")
        category = strings("events_cat_" + ev["category"], lang)

        # The heading is the link when there is one, so the accessible name of the link
        # is the event's name rather than "more information" repeated eight times.
        heading = ('<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>'
                   % (_e(link), title)) if link else title

        out.append(
            '                            <li class="ev-card" style="--i:%d"'
            ' data-start="%s"%s%s>\n'
            '                                <article class="ev-inner">\n'
            '                                    <div class="ev-media">\n'
            '                                        <img class="ev-img ev-img-%s" src="%s/images/%s"'
            ' alt="%s" width="%d" height="%d" loading="lazy" decoding="async">\n'
            '                                        <p class="ev-cat">%s</p>\n'
            '                                        <p class="ev-role ev-role-%s">%s</p>\n'
            '                                    </div>\n'
            '                                    <div class="ev-body">\n'
            '                                        <p class="ev-when">'
            '<time datetime="%s">%s</time>%s</p>\n'
            '                                        <h3 class="ev-title">%s</h3>\n'
            '                                        <p class="ev-summary">%s</p>\n'
            '                                        <p class="ev-where">%s</p>\n'
            '                                    </div>\n'
            '                                    <div class="ev-foot">\n'
            '                                        <p class="ev-state"></p>\n'
            '                                        <img class="ev-emblem" src="%s/images/emblems/%s"'
            ' alt="" width="120" height="24" loading="lazy" decoding="async" aria-hidden="true">\n'
            '                                    </div>\n'
            '                                </article>\n'
            '                            </li>'
            % (
                index,
                _e(ev["start"]),
                (' data-end="%s"' % _e(ev["end"])) if ev.get("end") else "",
                ' data-tentative="1"' if tentative else "",
                _e(kind), asset_prefix, _e(ev["image"]), _e(ev["image_alt"][lang]), w, h,
                _e(category), _e(ev["role"]), _e(role),
                _e(ev["start"]), _e(when_label(ev, lang)), time_span,
                heading,
                _e(ev["summary"][lang]),
                _e(where),
                asset_prefix, _e(emblem),
            )
        )
    return "\n".join(out)
