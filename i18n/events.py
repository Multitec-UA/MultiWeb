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

ID_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
WHEN_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$")

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


class EventError(ValueError):
    """A row that is not in the box. The message names the row, the field and the fix."""


def _fail(event_id, message):
    raise EventError("events.json [%s]: %s" % (event_id, message))


def _parse(when):
    return _dt.datetime.strptime(when, "%Y-%m-%dT%H:%M")


def _image_size(path: pathlib.Path):
    """Width and height of a WebP file, without Pillow — this repo has no dependencies.

    Handles the three WebP flavours (lossy VP8, lossless VP8L, extended VP8X). Returns
    None for anything it does not recognise rather than guessing, and the caller treats
    that as "cannot check", not as "fine".
    """
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
                _fail(eid, "%s must be YYYY-MM-DDTHH:MM local time (Europe/Madrid), got %r"
                      % (key, value))
        if ev.get("end") and _parse(ev["end"]) < _parse(ev["start"]):
            _fail(eid, "end is before start")

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
            _fail(eid, "image %s is not a WebP this can measure — convert it" % image)
        w, h = size
        if w < MIN_IMAGE_WIDTH:
            _fail(eid, "image %s is %dpx wide, the card needs at least %d"
                  % (image, w, MIN_IMAGE_WIDTH))
        if w / h < MIN_ASPECT:
            _fail(eid, "image %s is %dx%d (%.2f:1); the card crops to 16:10, so anything "
                       "under %.1f:1 loses most of the picture" % (image, w, h, w / h, MIN_ASPECT))
        ev["_image_size"] = size

        link = ev.get("link")
        if link is not None and not str(link).startswith("https://"):
            _fail(eid, "link must be https:// or null, got %r" % link)

    return sorted(events, key=lambda e: e["start"])


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
            | {"events_aud_" + a for a in AUDIENCES})


def when_label(ev, lang):
    """The date as the card prints it: '14-16 NOV 2025', '22 MAY 2025', '30 DIC - 2 ENE'.

    Deliberately not locale-dependent: strftime would need a locale installed in the
    build environment, and a missing es_ES.UTF-8 would silently produce English months
    on a Spanish page.
    """
    m = MONTHS[lang]
    a = _parse(ev["start"])
    b = _parse(ev["end"]) if ev.get("end") else a
    dash = "–"  # en dash, the correct mark for a range
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


def render(lang, strings, asset_prefix="../assets/v7", events=None):
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
        clock = ev["start"][11:]
        time_span = "" if clock == "00:00" else '<span class="ev-time">%s</span>' % _e(clock)
        link = ev.get("link")
        category = strings("events_cat_" + ev["category"], lang)

        # The heading is the link when there is one, so the accessible name of the link
        # is the event's name rather than "more information" repeated eight times.
        heading = ('<a href="%s" target="_blank" rel="noopener noreferrer">%s</a>'
                   % (_e(link), title)) if link else title

        out.append(
            '                            <li class="ev-card" style="--i:%d"'
            ' data-start="%s"%s>\n'
            '                                <article class="ev-inner">\n'
            '                                    <div class="ev-media">\n'
            '                                        <img src="%s/images/%s" alt="%s"'
            ' width="%d" height="%d" loading="lazy" decoding="async">\n'
            '                                        <p class="ev-cat">%s</p>\n'
            '                                        <p class="ev-role ev-role-%s">%s</p>\n'
            '                                    </div>\n'
            '                                    <div class="ev-body">\n'
            '                                        <p class="ev-when">'
            '<time datetime="%s">%s</time>%s</p>\n'
            '                                        <h3 class="ev-title">%s</h3>\n'
            '                                        <p class="ev-summary">%s</p>\n'
            '                                        <p class="ev-where">%s</p>\n'
            '                                        <p class="ev-state" hidden></p>\n'
            '                                    </div>\n'
            '                                </article>\n'
            '                            </li>'
            % (
                index,
                _e(ev["start"]),
                (' data-end="%s"' % _e(ev["end"])) if ev.get("end") else "",
                asset_prefix, _e(ev["image"]), _e(ev["image_alt"][lang]), w, h,
                _e(category), _e(ev["role"]), _e(role),
                _e(ev["start"]), _e(when_label(ev, lang)), time_span,
                heading,
                _e(ev["summary"][lang]),
                _e(where),
            )
        )
    return "\n".join(out)
