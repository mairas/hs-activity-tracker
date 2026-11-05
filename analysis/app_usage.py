#!/usr/bin/env python3
"""Aggregate hs-activity-tracker event logs into per-app active-use periods.

Reads the JSONL event stream produced by the ActivityTracker Spoon and reports,
per day, the continuous periods during which a given application was actively
used, plus how much of each period was genuinely "engaged".

Two metrics are reported per session (see docs/analysis.md for the full rationale):

  span    - wall-clock from the first to the last engaged moment in the session,
            including short (<break) diversions to other apps or short idle gaps.
  engaged - time the target app was frontmost AND the user was not idle.

A "break" is a single tunable threshold (--break-mins, default 10): any gap with
no engagement that lasts at least that long ends the current session, whether the
gap is time in another app or time idle at the keyboard. Shorter gaps (reading a
datasheet, thinking) stay inside the session.

Pass --title-contains, --title-matches or --title-excludes to further restrict
engaged time to moments when the frontmost app's own window title passed the
filter (e.g. one KiCad project among several). Each app's title is taken only from
its own window_title events, so another app's title changes (an animated browser
tab in the background) never end a match. With a title filter the app argument may
be omitted: every app counts, and each day gets a per-app breakdown.

Stdlib only. Run with `python3 analysis/app_usage.py KiCad --since 2026-05-25`
(or via `uv run`).
"""

import argparse
import datetime
import glob
import json
import os
import re
import sys

DEFAULT_EVENTS_DIR = "~/.local/share/hs-activity-tracker/events"
# Per-app lines below this round to "0s" and only add noise.
MIN_BREAKDOWN_SECS = 1


def parse_ts(ts):
    """ISO-8601 'Z' timestamp -> POSIX seconds (float)."""
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()


def load_events(events_dir, since, until):
    """Load and time-sort events from all daily files in [since, until].

    The on-disk stream is NOT guaranteed to be time-ordered (idle events derive
    their ts from `now - idleTime()`, so they can precede earlier-written lines),
    and a session can straddle the UTC midnight file rotation. We therefore read
    every relevant file into one list and sort by timestamp.
    """
    events = []
    for path in sorted(glob.glob(os.path.join(os.path.expanduser(events_dir), "*.jsonl"))):
        day = os.path.basename(path)[:10]  # YYYY-MM-DD (file is named by UTC date)
        if since and day < since:
            continue
        if until and day > until:
            continue
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue
                e["_t"] = parse_ts(e["ts"])
                events.append(e)
    events.sort(key=lambda e: e["_t"])
    return events


def frontmost_intervals(events):
    """[(start, end, app)] from app_focus events; each app stays frontmost
    until the next app_focus."""
    focus = [e for e in events if e["type"] == "app_focus"]
    out = []
    for i, e in enumerate(focus):
        end = focus[i + 1]["_t"] if i + 1 < len(focus) else e["_t"]
        out.append((e["_t"], end, e["app"]))
    return out


def away_intervals(events, threshold):
    """[(start, end)] of idle stretches lasting >= threshold seconds.

    Each idle period is one idle_start -> next active_resumed pair. The tracker's
    idle detector can "flap" (rapid idle_start/active_resumed pairs) during sparse
    input; only stretches >= threshold count as the user being away, so flapping
    is ignored and short thinking pauses are not penalised.
    """
    out = []
    pending = None
    for e in events:
        if e["type"] == "idle_start":
            if pending is None:
                pending = e["_t"]
        elif e["type"] == "active_resumed":
            if pending is not None:
                if e["_t"] - pending >= threshold:
                    out.append((pending, e["_t"]))
                pending = None
    return out


def subtract(s, e, cuts):
    """Yield sub-intervals of [s, e) with each [a, b) in `cuts` removed."""
    cur = s
    for a, b in sorted((max(s, a), min(e, b)) for a, b in cuts if min(e, b) > max(s, a)):
        if a > cur:
            yield (cur, a)
        cur = max(cur, b)
    if cur < e:
        yield (cur, e)


def title_predicate(contains=None, matches=None, excludes=None):
    """Combine the title filters into one test on a title string, or None when
    no filter is given. All given filters must hold; all are case-insensitive."""
    if contains is None and matches is None and excludes is None:
        return None
    match_re = re.compile(matches, re.I) if matches is not None else None
    exclude_re = re.compile(excludes, re.I) if excludes is not None else None

    def pred(title):
        if contains is not None and contains.lower() not in title.lower():
            return False
        if match_re is not None and not match_re.search(title):
            return False
        return not (exclude_re is not None and exclude_re.search(title))
    return pred


def title_spans(events, app, pred):
    """Spans during which the title of `app`'s focused window passes `pred`.

    Titles are kept per window_id from the app's own `window_focus` and
    `window_title` events, and `window_focus` names the focused window. Both
    halves matter: switching to an existing window can carry its title only in
    `window_focus`, and an app emits `window_title` for its unfocused windows too
    (a background browser tab whose title animates). Other apps' events are
    ignored for the same reason. Until the app's first `window_focus`, a
    `window_title` event is taken as coming from the focused window.

    A non-matching title ends the current span, and so does a null (denylisted)
    one, which is tested as the empty string; the next matching title reopens one.
    """
    out = []
    start = None
    titles = {}
    focused = None
    seen_focus = False
    for e in events:
        if e["type"] not in ("window_focus", "window_title") or e.get("app") != app:
            continue
        wid = e.get("window_id")
        titles[wid] = e.get("title") or ""
        if e["type"] == "window_focus":
            focused, seen_focus = wid, True
        elif not seen_focus:
            focused = wid
        if pred(titles[focused]):
            if start is None:
                start = e["_t"]
        elif start is not None:
            out.append((start, e["_t"]))
            start = None
    if start is not None:
        out.append((start, events[-1]["_t"]))
    return out


def clip(s, e, spans):
    """Yield the parts of [s, e) that fall within any interval in `spans`."""
    for a, b in spans:
        lo, hi = max(s, a), min(e, b)
        if hi > lo:
            yield (lo, hi)


def engaged_pieces(events, app, threshold, title_pred=None):
    """[(start, end, app)] where an app is frontmost and the user is not
    (long-)idle. `app=None` counts every app.

    With `title_pred`, additionally restrict to moments when the frontmost app's
    own window title passed it (see title_spans)."""
    away = away_intervals(events, threshold)
    keep = {}
    out = []
    for s, e, fg_app in frontmost_intervals(events):
        if (app is not None and fg_app != app) or e <= s:
            continue
        if title_pred is None:
            segments = [(s, e)]
        else:
            if fg_app not in keep:
                keep[fg_app] = title_spans(events, fg_app, title_pred)
            segments = clip(s, e, keep[fg_app])
        for a, b in segments:
            out.extend((x, y, fg_app) for x, y in subtract(a, b, away))
    return sorted(p for p in out if p[1] > p[0])


def engaged_intervals(events, app, threshold, title_pred=None):
    """engaged_pieces without the app name."""
    return [(s, e) for s, e, _ in engaged_pieces(events, app, threshold, title_pred)]


def sessions(engaged, threshold, min_secs):
    """Merge engaged intervals into sessions, bridging gaps < threshold.

    Returns [(start, end, engaged_seconds)]. Sessions shorter than min_secs
    (momentary focus blips) are dropped.
    """
    out = []
    for s, e in engaged:
        if out and s - out[-1][1] < threshold:
            out[-1][1] = max(out[-1][1], e)
            out[-1][2] += e - s
        else:
            out.append([s, e, e - s])
    return [p for p in out if p[1] - p[0] >= min_secs]


def app_breakdown(pieces, periods):
    """[(app, engaged_seconds)] for the pieces inside `periods`, largest first."""
    totals = {}
    for s, e, app in pieces:
        if any(ps <= s < pe for ps, pe, _ in periods):
            totals[app] = totals.get(app, 0) + e - s
    return sorted(totals.items(), key=lambda kv: -kv[1])


def make_tz(utc_offset):
    if utc_offset is None:
        return None  # system local time
    return datetime.timezone(datetime.timedelta(hours=utc_offset))


def fmt_clock(t, tz):
    return datetime.datetime.fromtimestamp(t, tz).strftime("%H:%M")


def fmt_dur(secs):
    m = int(round(secs / 60))
    if m >= 60:
        return f"{m // 60}h{m % 60:02d}m"
    return f"{m}m" if m else f"{int(round(secs))}s"


def local_date(t, tz):
    return datetime.datetime.fromtimestamp(t, tz).strftime("%Y-%m-%d (%a)")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("app", nargs="?",
                    help="Application name as it appears in app_focus 'app' field (e.g. KiCad). "
                         "Omit to count every app; a title filter is then required")
    ap.add_argument("--since", help="First UTC date to include, YYYY-MM-DD")
    ap.add_argument("--until", help="Last UTC date to include, YYYY-MM-DD")
    ap.add_argument("--break-mins", type=float, default=10.0,
                    help="A no-engagement gap >= this many minutes ends a session (default 10)")
    ap.add_argument("--min-secs", type=float, default=30.0,
                    help="Drop sessions shorter than this many seconds (default 30)")
    ap.add_argument("--title-contains",
                    help="Only count time when the app's own window title contains this "
                         "substring, case-insensitive (e.g. a KiCad project name)")
    ap.add_argument("--title-matches", metavar="REGEX",
                    help="Only count time when the window title matches this regex, case-insensitive")
    ap.add_argument("--title-excludes", metavar="REGEX",
                    help="Do not count time when the window title matches this regex, case-insensitive")
    ap.add_argument("--utc-offset", type=float, default=None,
                    help="Hours to offset from UTC for display (default: system local time)")
    ap.add_argument("--events-dir", default=DEFAULT_EVENTS_DIR,
                    help=f"Event log directory (default {DEFAULT_EVENTS_DIR})")
    args = ap.parse_args(argv)
    try:
        title_pred = title_predicate(args.title_contains, args.title_matches, args.title_excludes)
    except re.error as err:
        ap.error(f"invalid regex: {err}")
    if args.app is None and title_pred is None:
        ap.error("give an app, a title filter, or both")

    threshold = args.break_mins * 60
    tz = make_tz(args.utc_offset)

    events = load_events(args.events_dir, args.since, args.until)
    if not events:
        print("No events found for the given range.", file=sys.stderr)
        return 1

    pieces = engaged_pieces(events, args.app, threshold, title_pred)
    periods = sessions([(s, e) for s, e, _ in pieces], threshold, args.min_secs)
    subject = args.app or "matching"
    if not periods:
        print(f"No {subject} activity found for the given range.", file=sys.stderr)
        return 1

    by_day = {}
    for s, e, eng in periods:
        by_day.setdefault(local_date(s, tz), []).append((s, e, eng))

    tzlabel = "system local" if tz is None else f"UTC{args.utc_offset:+g}"
    notes = [f"title {label} {value!r}" for label, value in (
        ("contains", args.title_contains), ("matches", args.title_matches),
        ("excludes", args.title_excludes)) if value is not None]
    title_note = "".join(f"  |  {n}" for n in notes)
    print(f"Active {subject} sessions{title_note}  |  break >= {args.break_mins:g} min  |  times in {tzlabel}\n")

    grand_span = grand_eng = 0.0
    for day in sorted(by_day):
        rows = by_day[day]
        dspan = sum(e - s for s, e, _ in rows)
        deng = sum(eng for *_, eng in rows)
        grand_span += dspan
        grand_eng += deng
        pct = round(100 * deng / dspan) if dspan else 0
        print(f"{day}   span {fmt_dur(dspan)} | engaged {fmt_dur(deng)} ({pct}%) | {len(rows)} session(s)")
        if args.app is None:
            print("   by app: " + ", ".join(
                f"{name} {fmt_dur(secs)}" for name, secs in app_breakdown(pieces, rows)
                if secs >= MIN_BREAKDOWN_SECS))
        for s, e, eng in rows:
            sp = e - s
            ppct = round(100 * eng / sp) if sp else 0
            print(f"   {fmt_clock(s, tz)}-{fmt_clock(e, tz):<6}{fmt_dur(sp):>8} span, {fmt_dur(eng):>7} engaged ({ppct}%)")
        print()

    gpct = round(100 * grand_eng / grand_span) if grand_span else 0
    print(f"TOTAL  span {fmt_dur(grand_span)} | engaged {fmt_dur(grand_eng)} ({gpct}%)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
