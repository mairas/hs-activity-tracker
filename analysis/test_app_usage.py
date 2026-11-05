#!/usr/bin/env python3
"""Scenario checks for app_usage.py interval logic. Stdlib only, no pytest.

Run directly: `python3 analysis/test_app_usage.py`. Builds synthetic event
streams and asserts engaged-time math, the --title-contains filter, and the
load-bearing invariant that the default (no-filter) path is unchanged.
"""

import contextlib
import importlib.util
import io
import os

_spec = importlib.util.spec_from_file_location(
    "app_usage", os.path.join(os.path.dirname(__file__), "app_usage.py"))
au = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(au)


def ev(clock, typ, app=None, title="__none__"):
    e = {"ts": f"2026-06-01T{clock}.000Z", "type": typ}
    if app is not None:
        e["app"] = app
    if title != "__none__":
        e["title"] = title  # may be None (denylisted)
    e["_t"] = au.parse_ts(e["ts"])
    return e


def total(intervals):
    return sum(e - s for s, e in intervals)


def engaged_secs(events, app, break_secs, title=None, matches=None, excludes=None):
    pred = au.title_predicate(contains=title, matches=matches, excludes=excludes)
    return total(au.engaged_intervals(events, app, break_secs, pred))


BREAK = 600  # 10 min


def test_no_flag_path_unchanged():
    # KiCad frontmost 10:00-10:10, one title, no idle.
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "projA — PCB Editor"),
        ev("10:10:00", "app_focus", "Browser"),
    ]
    # The default path must equal the raw frontmost-minus-idle span.
    assert engaged_secs(events, "KiCad", BREAK) == 600
    assert engaged_secs(events, "KiCad", BREAK, None) == 600


def test_background_title_spam_does_not_end_match():
    # A background browser whose title animates must not end the KiCad match.
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "projA — PCB Editor"),
        ev("10:02:00", "window_title", "Browser", "spam 1"),
        ev("10:05:00", "window_title", "Browser", "spam 2"),
        ev("10:07:00", "window_title", "KiCad", "Footprint Properties"),  # dialog, no match
        ev("10:10:00", "app_focus", "Browser"),
        ev("10:20:00", "app_focus", "KiCad"),  # bounds last frontmost interval
    ]
    # Match runs 10:00-10:07 (ends at the dialog title), not 10:00-10:02.
    assert engaged_secs(events, "KiCad", BREAK, "projA") == 420
    # Background spam ending it would have yielded 120.


def test_dialog_and_null_title_end_a_span():
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "projA"),
        ev("10:03:00", "window_title", "KiCad", None),  # denylisted -> ends span
        ev("10:10:00", "app_focus", "Browser"),
    ]
    assert engaged_secs(events, "KiCad", BREAK, "projA") == 180


def test_case_insensitive():
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "PULSE — PCB Editor"),
        ev("10:05:00", "app_focus", "Browser"),
    ]
    assert engaged_secs(events, "KiCad", BREAK, "pulse") == 300


def test_non_matching_needle_yields_nothing():
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "projA"),
        ev("10:05:00", "app_focus", "Browser"),
    ]
    assert engaged_secs(events, "KiCad", BREAK, "projB") == 0


def test_title_filter_then_idle_subtraction():
    # break 5 min; a 6-min idle gap is removed; title span ends at the dialog.
    br = 300
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "projA"),
        ev("10:02:00", "idle_start"),
        ev("10:08:00", "active_resumed"),
        ev("10:09:00", "window_title", "KiCad", "Symbol Fields Table"),  # no match
        ev("10:12:00", "app_focus", "Browser"),
    ]
    # filtered: clip 10:00-10:12 to title 10:00-10:09, minus idle 10:02-10:08
    #           = [10:00,10:02] + [10:08,10:09] = 180
    assert engaged_secs(events, "KiCad", br, "projA") == 180
    # no-flag: [10:00,10:12] minus idle = [10:00,10:02] + [10:08,10:12] = 360
    assert engaged_secs(events, "KiCad", br) == 360


def test_empty_needle_applies_filter_not_silent_passthrough():
    # KiCad frontmost from 10:00 but the first title only fires at 10:03.
    events = [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:03:00", "window_title", "KiCad", "projA"),
        ev("10:10:00", "app_focus", "Browser"),
    ]
    # None -> whole frontmost interval (600). "" -> a real (match-all) filter
    # that only opens at the first title event (10:03), so 420. The two must
    # differ: an empty needle must not silently behave like no flag.
    assert engaged_secs(events, "KiCad", BREAK, None) == 600
    assert engaged_secs(events, "KiCad", BREAK, "") == 420


def test_title_spans_on_empty_events():
    assert au.title_spans([], "KiCad", au.title_predicate(contains="projA")) == []


def test_clip_partial_overlap():
    # interval [10, 50] clipped to spans [0,20] and [40,100] -> [10,20]+[40,50]
    got = sorted(au.clip(10, 50, [(0, 20), (40, 100)]))
    assert got == [(10, 20), (40, 50)], got


def cross_app_events():
    # KiCad on proj, then a terminal tab on proj, then a browser on something else
    # while the terminal's matching title is still its latest one.
    return [
        ev("10:00:00", "app_focus", "KiCad"),
        ev("10:00:00", "window_title", "KiCad", "pulse — PCB Editor"),
        ev("10:05:00", "app_focus", "Ghostty"),
        ev("10:05:00", "window_title", "Ghostty", "[velamari-logger-hardware] RFQ"),
        ev("10:08:00", "app_focus", "Browser"),
        ev("10:08:00", "window_title", "Browser", "Inbox"),
        ev("10:12:00", "app_focus", "Ghostty"),
        ev("10:12:00", "window_title", "Ghostty", "[HALMET] Pulse sensor tuning"),
        ev("10:15:00", "app_focus", "Browser"),
    ]


def test_regex_across_apps_sums_matching_frontmost_time():
    # KiCad 10:00-10:05 + Ghostty 10:05-10:08 + Ghostty 10:12-10:15 (HALMET pulse)
    assert engaged_secs(cross_app_events(), None, BREAK, matches="velamari|pulse") == 660


def test_excludes_removes_a_match():
    assert engaged_secs(cross_app_events(), None, BREAK,
                        matches="velamari|pulse", excludes="halmet") == 480


def test_background_matching_title_does_not_count():
    # Ghostty's matching title stays its latest while the browser is frontmost
    # 10:08-10:12; that time must not count.
    events = cross_app_events()
    t0 = events[0]["_t"]
    pieces = au.engaged_pieces(events, None, BREAK, au.title_predicate(matches="velamari"))
    assert [(a - t0, b - t0, app) for a, b, app in pieces] == [
        (300, 480, "Ghostty")], pieces


def test_pieces_carry_app_for_breakdown():
    pieces = au.engaged_pieces(cross_app_events(), None, BREAK,
                               au.title_predicate(matches="pulse|velamari", excludes="halmet"))
    by_app = {}
    for a, b, app in pieces:
        by_app[app] = by_app.get(app, 0) + b - a
    assert by_app == {"KiCad": 300, "Ghostty": 180}, by_app


def test_app_and_regex_combine():
    assert engaged_secs(cross_app_events(), "Ghostty", BREAK, matches="velamari|pulse") == 360


def test_no_filters_gives_no_predicate():
    assert au.title_predicate() is None


def test_no_app_and_no_title_filter_is_usage_error():
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            au.main(["--since", "2026-06-01", "--events-dir", "/nonexistent"])
    except SystemExit as e:
        assert e.code == 2, e.code
    else:
        raise AssertionError("expected a usage error")


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print(f"ok  {t.__name__}")
    print(f"\n{len(tests)} checks passed")


if __name__ == "__main__":
    main()
