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

Stdlib only. Run with `python3 analysis/app_usage.py KiCad --since 2026-05-25`
(or via `uv run`).
"""

import argparse
import datetime
import glob
import json
import os
import sys

DEFAULT_EVENTS_DIR = "~/.local/share/hs-activity-tracker/events"


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


def engaged_intervals(events, app, threshold):
    """Intervals where `app` is frontmost and the user is not (long-)idle."""
    away = away_intervals(events, threshold)
    out = []
    for s, e, fg_app in frontmost_intervals(events):
        if fg_app != app or e <= s:
            continue
        out.extend(subtract(s, e, away))
    return sorted((s, e) for s, e in out if e > s)


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
    ap.add_argument("app", help="Application name as it appears in app_focus 'app' field (e.g. KiCad)")
    ap.add_argument("--since", help="First UTC date to include, YYYY-MM-DD")
    ap.add_argument("--until", help="Last UTC date to include, YYYY-MM-DD")
    ap.add_argument("--break-mins", type=float, default=10.0,
                    help="A no-engagement gap >= this many minutes ends a session (default 10)")
    ap.add_argument("--min-secs", type=float, default=30.0,
                    help="Drop sessions shorter than this many seconds (default 30)")
    ap.add_argument("--utc-offset", type=float, default=None,
                    help="Hours to offset from UTC for display (default: system local time)")
    ap.add_argument("--events-dir", default=DEFAULT_EVENTS_DIR,
                    help=f"Event log directory (default {DEFAULT_EVENTS_DIR})")
    args = ap.parse_args(argv)

    threshold = args.break_mins * 60
    tz = make_tz(args.utc_offset)

    events = load_events(args.events_dir, args.since, args.until)
    if not events:
        print("No events found for the given range.", file=sys.stderr)
        return 1

    engaged = engaged_intervals(events, args.app, threshold)
    periods = sessions(engaged, threshold, args.min_secs)
    if not periods:
        print(f"No {args.app} activity found for the given range.", file=sys.stderr)
        return 1

    by_day = {}
    for s, e, eng in periods:
        by_day.setdefault(local_date(s, tz), []).append((s, e, eng))

    tzlabel = "system local" if tz is None else f"UTC{args.utc_offset:+g}"
    print(f"Active {args.app} sessions  |  break >= {args.break_mins:g} min  |  times in {tzlabel}\n")

    grand_span = grand_eng = 0.0
    for day in sorted(by_day):
        rows = by_day[day]
        dspan = sum(e - s for s, e, _ in rows)
        deng = sum(eng for *_, eng in rows)
        grand_span += dspan
        grand_eng += deng
        pct = round(100 * deng / dspan) if dspan else 0
        print(f"{day}   span {fmt_dur(dspan)} | engaged {fmt_dur(deng)} ({pct}%) | {len(rows)} session(s)")
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
