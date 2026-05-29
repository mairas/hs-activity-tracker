# hs-activity-tracker — Analysis

How to turn the raw event log into per-app active-use periods, and the reasoning
behind the metrics. The reference implementation is `analysis/app_usage.py`.

> Scope note: `design.md` originally deferred all reporting to a separate project.
> `analysis/app_usage.py` is the first reporting tool to land in-repo, written
> against real captured data. It stays deliberately small (stdlib only, one file)
> so the capture layer remains the focus.

## Usage

```
python3 analysis/app_usage.py KiCad --since 2026-05-25
```

Common flags:

| Flag | Default | Meaning |
|---|---|---|
| `app` (positional) | — | Value of the `app` field in `app_focus` events (e.g. `KiCad`, `Ghostty`). |
| `--since` / `--until` | all | UTC date bounds (`YYYY-MM-DD`), matched against the file name. |
| `--break-mins` | `10` | A no-engagement gap at least this long ends a session. |
| `--min-secs` | `30` | Drop sessions shorter than this (momentary focus blips). |
| `--utc-offset` | system local | Hours from UTC for display only. |
| `--events-dir` | `~/.local/share/hs-activity-tracker/events` | Where the JSONL lives. |

## Metrics

Two numbers are reported per session, because they answer different questions:

- **engaged** — time the target app was frontmost *and* the user was not idle.
  This is "fingers on the app". Idle stretches and time in other apps are excluded.
- **span** — wall-clock from the first to the last engaged moment of a session,
  *including* short diversions (a quick browser/datasheet lookup, a sub-break
  thinking pause). This is "time inside a work session on the app".

`engaged / span` (the percentage) is a useful focus signal: a 98% session was
heads-down; a 33% session means the app was open but you were mostly elsewhere
within the break window.

## The single break threshold

There is exactly one tunable that defines a "break": `--break-mins`. A gap with no
engagement that lasts at least that long ends the current session — and it does so
regardless of *why* there was no engagement:

- you switched to another app for the whole gap, **or**
- you were idle at the keyboard for the whole gap, **or**
- any mix of the two.

Gaps shorter than the threshold are bridged into the surrounding session. This is
the property that makes the output match intuition: a 34-second glance at Discord
mid-layout does not split a session, but leaving for 15 minutes does — even if the
app never lost focus while you were gone.

10 minutes is a sensible default. On the data this was first validated against,
moving the threshold between 3 and 10 minutes barely changed engaged totals (~9
minutes across five days): real idle gaps were bimodal — either short pauses or
genuine departures — with little in between.

## Pipeline

`app_usage.py` computes, in order:

1. **Load + sort.** Read every daily file in range into one list and sort by
   timestamp. Required because the on-disk stream is *not* time-ordered and a
   session can straddle the UTC-midnight file rotation (see gotchas).
2. **Frontmost intervals.** Each `app_focus` event makes its app frontmost until
   the next `app_focus`. Yields `[(start, end, app)]`.
3. **Away intervals.** Pair each `idle_start` with the next `active_resumed`; keep
   only stretches `>= break`. These are the periods the user was genuinely away.
4. **Engaged intervals.** For each frontmost interval of the target app, subtract
   the away intervals. What remains is engaged time.
5. **Sessions.** Merge engaged intervals, bridging any gap `< break` into one
   session. `span = end - start`; `engaged = sum of the engaged pieces inside`.
   Drop sessions shorter than `--min-secs`.

## Data gotchas (learned the hard way)

These tripped up the first analysis pass; respect them or the numbers lie.

- **The file is not time-ordered.** `idle_start` / `active_resumed` carry precise
  HID-derived timestamps (`now - idleTime()`), which can be *earlier* than lines
  written just before them. Always sort by `ts` before reasoning about order.
- **Idle events "flap".** During sparse input the detector emits rapid
  `idle_start`/`active_resumed` pairs seconds apart. Do not treat each pair as a
  real break. The away-interval step ignores any stretch shorter than the
  threshold, which absorbs the flapping; real departures show up as a single long
  gap between an `idle_start` and the next `active_resumed`.
- **`idle_seconds` in heartbeats is the ground truth idle clock.** Heartbeats fire
  every 5 minutes carrying the true `idleTime()` and the focused app — useful as an
  independent cross-check on the idle-event reconstruction, and to tell "tracker
  quiet" from "tracker dead".
- **Files rotate at UTC midnight, but you'll want local-time days.** Sessions are
  grouped by the *local* date of their start. A late-night session can therefore
  live in one UTC file but read as the previous local day, or vice versa. Loading
  the whole range into one sorted stream (step 1) makes this a non-issue.
- **"Frontmost" is coarse.** `app_focus` says nothing about whether you were
  looking at the screen — only that the app was in front. Idle subtraction
  (engaged) is what turns "in front" into "in use".
- **Raw frontmost slices break on every focus change**, including a 1-second
  alt-tab. They are not the right unit to show a human; sessions (step 5) are.

## Extending

The `app` argument matches `app_focus.app` exactly. To split by sub-tool or
project (e.g. KiCad Schematic Editor vs PCB Editor, or per-board), join on the
`window_focus` / `window_title` stream by `window_id` and bucket on the title —
the titles distinguish editor type and document. Not implemented here; left as the
obvious next step when per-project breakdowns are needed.
