#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""The events calendar is in its box, and the box is the same box the build enforces.

`i18n/events.py` already refuses to load a row that is out of range, so a bad event
cannot be rendered at all — this file exists so that the failure is *readable* (one
PASS/FAIL line per rule, the way tests/verify.sh counts them) and so that the handful of
rules that are about the file as a whole, rather than about one row, get checked too:
ordering, the countdown placeholder, whether the wheel's markup and its script still
agree about the class names they pass between each other.

Run it directly — no pytest, no dependencies, this repo has neither:

    python3 tests/test_events.py
"""
from __future__ import annotations

import datetime as dt
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "i18n"))

import build   # noqa: E402  (i18n/build.py)
import events  # noqa: E402  (i18n/events.py)

FAILED = []
CHECKS = []


def check(ok, description, detail=""):
    CHECKS.append(ok)
    if ok:
        print("PASS %s" % description)
    else:
        FAILED.append(description)
        print("FAIL %s%s" % (description, ("\n     " + detail) if detail else ""))


def main() -> int:
    table = build.load()
    strings = table["strings"]
    raw = json.loads(events.TABLE.read_text(encoding="utf-8"))

    # -- 1. the box ---------------------------------------------------------------
    # events.load() raises on the first violation. Catching it here turns "the build
    # exploded" into "this row, this field, this language, this count".
    try:
        rows = events.load()
        check(True, "every event is inside the box (%d events, %s)"
              % (len(rows), ", ".join("%s %d-%d" % (f, lo, hi)
                                      for f, (lo, hi) in sorted(events.BOUNDS.items()))))
    except events.EventError as exc:
        check(False, "every event is inside the box", str(exc))
        rows = []

    # -- 2. the box is worth having ------------------------------------------------
    # A range nothing is near is a range nobody is obeying. This is the check that
    # notices the day somebody widens BOUNDS instead of rewriting a sentence.
    if rows:
        for field, (lo, hi) in sorted(events.BOUNDS.items()):
            # `location` may be absent -- see OPTIONAL in events.py. Absent is not a
            # length, so it is not measured; what IS measured is that the ones present
            # still sit inside the box.
            lengths = [len(ev[field][lang]) for ev in rows for lang in events.LANGUAGES
                       if ev.get(field) is not None]
            if not lengths:
                check(field in events.OPTIONAL, "%s is absent everywhere" % field)
                continue
            check(max(lengths) <= hi and min(lengths) >= lo,
                  "%s: %d-%d characters used of the %d-%d allowed%s"
                  % (field, min(lengths), max(lengths), lo, hi,
                     "" if field not in events.OPTIONAL
                     else " (%d of %d events record one)" % (len(lengths) // 2, len(rows))))
        # the point of the whole exercise: the two summaries on any pair of cards are
        # close enough in length that the cards are the same height
        summaries = [len(ev["summary"][lang]) for ev in rows for lang in events.LANGUAGES]
        spread = max(summaries) - min(summaries)
        check(spread <= events.BOUNDS["summary"][1] - events.BOUNDS["summary"][0],
              "no two summaries differ by more than the box allows (%d characters apart)" % spread)

    # -- 3. chronological, and that is decided in code ------------------------------
    check([e["start"] for e in rows] == sorted(e["start"] for e in rows),
          "load() returns the calendar oldest-first whatever order the file is in")

    # -- 4. the countdown placeholder -----------------------------------------------
    # %d and not {days}: i18n/build.py resolves {word} against the vars table and would
    # raise on a placeholder that is not one. So the parity check test_i18n.py runs on
    # {fields} does not see these, and this is its counterpart.
    for key in ("events_cd_days",):
        counts = {l: strings[key][l].count("%d") for l in build.LANGUAGES}
        check(counts["es"] == counts["en"] == 1,
              "%s carries exactly one %%d in both languages" % key, repr(counts))
    for key, row in strings.items():
        if key.startswith("events_cd_") and key != "events_cd_days":
            check("%d" not in row["es"] + row["en"],
                  "%s has no placeholder to substitute" % key)

    # -- 4b. role and audience: closed vocabularies, and every value has a label ------
    # These two carry judgement, not fact -- "we organised it" vs "we turned up" -- so a
    # typo that silently falls back to a default would put a claim on the association's
    # own homepage that is not true.
    for field, vocab in (("role", events.ROLES), ("audience", events.AUDIENCES)):
        used = {e[field] for e in rows}
        check(used <= set(vocab), "every %s is in the vocabulary" % field,
              ", ".join(sorted(used - set(vocab))))
        prefix = "events_role_" if field == "role" else "events_aud_"
        for value in vocab:
            check(prefix + value in strings, "%s%s has a label in both languages" % (prefix, value))
    check(any(e["role"] == "organiza" for e in rows),
          "at least one card says the association organised it")
    check(all(e["audience"] != "socios" or not e.get("link") for e in rows),
          "no members-only event carries a public sign-up link",
          ", ".join(e["id"] for e in rows if e["audience"] == "socios" and e.get("link")))

    # -- 4c. an unknown start time is 00:00 and is NOT printed -------------------------
    # The alternative was inventing a time to fill the slot on a 2020 event nobody wrote
    # one down for. Check the renderer actually honours the convention.
    midnight = [e for e in rows if e["start"].endswith("T00:00")]
    if midnight:
        out = events.render("es", lambda k, l: strings[k][l], events=midnight)
        check('class="ev-time"' not in out,
              "%d event(s) with an unrecorded start time print no visible clock" % len(midnight))

    # -- 4d. approximate dates, and the logos that go with them ----------------------
    # Sergio, 2026-08-31: a future event often has neither a fixed day nor a poster yet, so
    # it may carry a month and the event's logo. Both of those are honesty features and
    # each has a way of going quietly wrong, so each gets a check.
    approx = [e for e in rows if events.precision(e["start"]) == "month"]
    tentative = [e for e in rows if e.get("tentative")]
    logos = [e for e in rows if e.get("image_kind") == "logo"]
    print("     (%d month-precision, %d tentative, %d drawn with a logo)"
          % (len(approx), len(tentative), len(logos)))

    if approx:
        out = events.render("es", lambda k, l: strings[k][l], events=approx)
        # a month-precision date must print a month NAME, never a day number
        check("OCTUBRE" in out or "ENERO" in out or "SEPTIEMBRE" in out or "NOVIEMBRE" in out,
              "month-precision dates print the month spelled out")
    if tentative:
        out = events.render("es", lambda k, l: strings[k][l], events=tentative)
        check(out.count('class="ev-approx"') == len(tentative),
              "every tentative event prints the aprox. marker")
        check(out.count('data-tentative="1"') == len(tentative),
              "every tentative event tells the script not to count days to it")
        check("events_cd_tbc" in strings or "Fecha por confirmar" == strings["events_cd_tbc"]["es"],
              "there is a label for a date that is not confirmed yet")
    # A LOGO stands in for a picture that does not exist. Using a photograph of a previous
    # edition instead would claim something that has not happened, which is the specific
    # thing Sergio asked this to avoid.
    for e in logos:
        check(e["image"].startswith("events/logo-"),
              "%s draws a logo and its file is named like one" % e["id"], e["image"])
        check(bool(e.get("tentative")) or e["start"] >= "2026-09",
              "%s only falls back to a logo because it is still to come" % e["id"])
    if logos:
        out = events.render("es", lambda k, l: strings[k][l], events=logos)
        check(out.count("ev-img-logo") == len(logos),
              "every logo card is marked so the CSS contains it instead of cropping it")
        sheet = (ROOT / "assets" / "css" / "style.css").read_text(encoding="utf-8")
        check("ev-img-logo" in sheet and "object-fit: contain" in sheet,
              "the stylesheet contains logos rather than cropping them")

    # -- 5. every category has a label, and every label a category -------------------
    declared = set(raw["categories"])
    labelled = {k[len("events_cat_"):] for k in strings if k.startswith("events_cat_")}
    check(declared == labelled, "every category has a label and every label a category",
          "only in events.json: %s / only in strings.json: %s"
          % (sorted(declared - labelled), sorted(labelled - declared)))
    used = {e["category"] for e in rows}
    check(used <= declared, "no event uses a category outside the vocabulary",
          ", ".join(sorted(used - declared)))

    # -- 6. the markup and the script agree -----------------------------------------
    # The section passes seven labels and three class names across a boundary no compiler
    # checks. Both halves have been edited independently at least once already.
    tpl = (build.TEMPLATES / "index.html").read_text(encoding="utf-8")
    js = (ROOT / "assets" / "js" / "script.js").read_text(encoding="utf-8")
    css = (ROOT / "assets" / "css" / "style.css").read_text(encoding="utf-8")

    declared_attrs = set(re.findall(r'data-(pill-\w+|cd-\w+)="\{\{', tpl))
    wanted_attrs = set(re.findall(r"getAttribute\('data-(pill-\w+|cd-\w+)'\)", js))
    check(declared_attrs == wanted_attrs,
          "the script reads exactly the %d labels the markup carries" % len(wanted_attrs),
          "markup only: %s / script only: %s"
          % (sorted(declared_attrs - wanted_attrs), sorted(wanted_attrs - declared_attrs)))

    for key in sorted({"events_" + a.replace("-", "_") for a in declared_attrs}):
        check(key in strings, "%s is in the string table" % key)

    for cls in ("is-past", "is-next", "is-running"):
        check(("'" + cls + "'") in js or ('"' + cls + '"') in js,
              "the script sets .%s" % cls)
        check((".ev-card." + cls) in css, "the stylesheet styles .ev-card.%s" % cls)

    # -- 7. the wheel degrades ------------------------------------------------------
    # With scripting off --t and --a are never written, so their declared defaults are
    # the whole no-JS experience. If they are not 0 the flat fallback is a heap.
    block = re.search(r"\n\.ev-card \{(.*?)\n\}", css, re.S)
    check(bool(block) and re.search(r"--t:\s*0\s*;", block.group(1))
          and re.search(r"--a:\s*0\s*;", block.group(1)),
          "with no JavaScript the wheel flattens (--t and --a default to 0)")
    check("prefers-reduced-motion" in css and "perspective: none" in css,
          "prefers-reduced-motion switches the perspective off, not merely down")

    # -- 8. the images the cards draw are the ones on disk ---------------------------
    # events.py already proved they exist; this proves the rendered <img> points at them
    # through the versioned URL, which is what group 7 of verify.sh caches for a year.
    version = sorted(set(re.findall(r"assets/(v\d+)/", tpl)))
    check(len(version) == 1, "the template uses one asset version", ", ".join(version))
    if version:
        rendered = events.render("es", lambda k, l: strings[k][l],
                                 asset_prefix="../assets/%s" % version[0], events=rows)
        srcs = re.findall(r'src="\.\./assets/v\d+/images/([^"]+)"', rendered)
        check(len(srcs) == len(rows), "every card renders an image", "%d of %d" % (len(srcs), len(rows)))
        missing = [s for s in srcs if not (ROOT / "assets" / "images" / s).exists()]
        check(not missing, "every rendered image exists on disk", ", ".join(missing))
        check(("../assets/%s" % version[0]) == build.ASSETS,
              "i18n/build.py renders cards at the same asset version the template uses",
              "%s vs %s" % (build.ASSETS, version[0]))

    # -- 9. the wheel has not been left to rot ---------------------------------------
    # The first version of this check failed when nothing was upcoming. That was the wrong
    # rule: "the association has no confirmed future event this week" is a true state of
    # the world, not a defect, and a test that goes red for it trains people to ignore it.
    #
    # What IS a defect is a section nobody has touched in a year, quietly showing a wall of
    # grey to every visitor. So: report the split, and fail only when the newest event has
    # gone stale.
    if rows:
        today = dt.date.today()
        def endof(e):
            # events._parse understands all three date shapes; strptime with one hard
            # format does not, and crashed the moment a month-precision event appeared.
            return events._parse(e["end"] or e["start"]).date()
        past = [e for e in rows if endof(e) < today]
        future = [e for e in rows if e not in past]
        newest = max(endof(e) for e in rows)
        months = (today - newest).days / 30.4
        print("     (%d past, %d upcoming; newest event %s, %.1f months ago)"
              % (len(past), len(future), newest, max(0.0, months)))
        check(months <= 12,
              "the newest event on the wheel is less than a year old (%s)" % newest,
              "everything on the page has already happened and the freshest of it is "
              "%.1f months old — the section reads as a museum" % months)
        if not future:
            print("     NOTE no upcoming event is confirmed yet. The wheel opens on the most "
                  "recent past one, which is correct behaviour but worth Sergio knowing.")

    print("\n%d checks, %d failed" % (len(CHECKS), len(FAILED)))
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
