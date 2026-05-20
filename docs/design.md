# hs-activity-tracker — Design

**Status:** Approved 2026-05-20
**Scope:** Capture only. Reporting/aggregation deferred.

## Purpose

Record macOS desktop and application activity to a local append-only event log so historical activity can be reviewed ("what was I doing on Tuesday afternoon?") and aggregated later ("how much time in app X this week?"). The capture layer is intentionally dumb: it produces a clean event stream and nothing else. Reporting will live in a separate project once there is real data to design against.

## Architecture

A single Hammerspoon Spoon loaded from `~/.hammerspoon/init.lua`:

- **Location:** `~/.hammerspoon/Spoons/ActivityTracker.spoon/`, symlinked from this repo so edits are live.
- **Components (internal):**
  - **Watchers** — thin wrappers around `hs.application.watcher`, `hs.window.filter`, and `hs.caffeinate.watcher`. Each translates OS callbacks into normalized event records and hands them to the writer.
  - **Idle detector** — single `hs.timer` ticking every 15s. Implements the idle-state machine (see *Idle handling* below) and emits a liveness heartbeat every 5 minutes.
  - **Writer** — owns the open JSONL file handle. Formats events, flushes on every write, rotates by UTC date, enforces the title denylist.
- **Pure-Lua boundary:** all formatting, denylist matching, idle-state-machine logic, and file-path computation live in `lib/` modules that import nothing from `hs.*` and can be unit-tested with `busted`. Only the top-level Spoon `init.lua` touches Hammerspoon APIs.

## Event schema

Each event is one JSON object on its own line. Common envelope:

```
{"ts": "2026-05-20T06:57:12.345Z", "type": "...", ...type-specific fields...}
```

All timestamps are **UTC**, ISO 8601 with `Z` suffix, millisecond precision. Raw data is not consumed by humans; rendering to local time is an analysis-stage concern.

| Type | Fields | When emitted |
|---|---|---|
| `app_focus` | `app`, `bundle_id`, `pid` | Frontmost application changes (different bundle ID becomes frontmost). |
| `window_focus` | `app`, `bundle_id`, `window_id`, `title` | A different window gains keyboard focus (within or across apps). Includes the current title for self-contained context. |
| `window_title` | `app`, `bundle_id`, `window_id`, `title` | The currently focused window's title text changes (browser tab switch, save indicator, terminal command change). |
| `idle_start` | `idle_started_at` (= `ts`) | User input ceased; `ts` is the precise timestamp of the last HID input (`now - hs.host.idleTime()`). |
| `active_resumed` | `resumed_at` (= `ts`) | User input resumed after an idle period; `ts` is the precise timestamp of that input. |
| `heartbeat` | `idle_seconds`, `focused_app`, `focused_title` | Liveness signal every 5 minutes regardless of activity. |
| `system` | `event` ∈ {`screen_locked`, `screen_unlocked`, `will_sleep`, `did_wake`, `screen_on`, `screen_off`} | From `hs.caffeinate.watcher`. |
| `tracker` | `event` ∈ {`started`, `stopped`, `reloaded`, `day_rotated`} | Lifecycle bookends. See *File self-containment*. |

### Title denylist

`window_focus` and `window_title` events for apps on the denylist set `title` to `null` (do not omit; absent fields are ambiguous). Default denylist: 1Password, system password prompts, and titles containing `"Private Browsing"` or `"Incognito"`. Tunable via config.

### Switch-event semantics

| Scenario | Events emitted, in order |
|---|---|
| App A → App B | `app_focus` (B), then `window_focus` (B's focused window) |
| Window switch within app A | `window_focus` |
| Title change in current window | `window_title` |
| App with no windows becomes frontmost | `app_focus` only |

`app_focus` and `window_focus`/`window_title` are independent observation streams; each event is self-contained (`window_focus`/`window_title` carry `app` and `bundle_id`) so analysis does not need to walk back to find context.

## Idle handling

Polled by a single 15s timer.

**State variable:** `last_logged_idle_start` (timestamp or `nil`).

**Constants:**
- `poll_interval = 15s`
- `idle_min_threshold = 15s` (avoid logging trivial sub-tick blips)
- `tolerance = 2s` (timestamp jitter on the same idle stretch)

**Each tick:**
1. Compute `current_idle_start = now - hs.host.idleTime()`. This is the precise timestamp of the last HID input.
2. If `last_logged_idle_start` is `nil`:
   - If `hs.host.idleTime() >= idle_min_threshold`: emit `idle_start` with `ts = current_idle_start`. Set `last_logged_idle_start = current_idle_start`.
   - Else: do nothing.
3. If `last_logged_idle_start` is set:
   - If `|current_idle_start - last_logged_idle_start| <= tolerance`: still in the same idle stretch. Do nothing.
   - Else (input happened since the last tick):
     - Emit `active_resumed` with `ts = current_idle_start`.
     - If `hs.host.idleTime() >= idle_min_threshold` (user went idle again between ticks): emit a new `idle_start` with `ts = current_idle_start` and set `last_logged_idle_start = current_idle_start`.
     - Else: clear `last_logged_idle_start`.

**Properties:**
- Both `idle_start.ts` and `active_resumed.ts` are precise (derived from `idleTime()`), not poll-quantized. Detection latency is at most one poll interval but stored timestamps are accurate.
- One pair of events per idle period regardless of how long it lasts.
- Analysis can apply any idle threshold post-hoc.

**Liveness heartbeat:** independent of the idle state machine. Every 5 minutes, emit `heartbeat` with the current `idle_seconds` and focused app/title. Distinguishes "tracker quiet because nothing happened" from "tracker dead".

## Storage

**Location:** `~/.local/share/hs-activity-tracker/`

```
events/
  2026-05-20.jsonl
  2026-05-19.jsonl
  ...
tracker.log    # diagnostic log (errors, rotation events) — not the event stream
```

**Permissions:** directory `0700`, files `0600`. Personal log.

**Rotation:** one file per UTC date. On every write, check if the date component of `now` differs from the open file's date; if so, close the old handle and open the new one. No race conditions because writes are serialized through the single writer.

**Write discipline:**
- `\n`-terminated JSON, no pretty printing.
- `io.write` + `f:flush()` on every event. Crash safety beats throughput at this volume.
- Append mode (`"a"`); safe across reloads.

**Retention:** none in v1. ~1–5 MB/day uncompressed; ~1–2 GB/year worst case. Compression of old files can be added later.

**Backup:** `~/.local/share/` is covered by the existing Borg backup of the home directory. No extra configuration.

## File self-containment

Every JSONL file is analyzable in isolation, without reading earlier files.

**File start:** the first lines of every file are, in order:

1. `tracker` with `event` ∈ {`started`, `reloaded`, `day_rotated`} — explains why the file started.
2. Replayed current state, using the normal event types:
   - `app_focus` for the current frontmost app
   - `window_focus` for the currently focused window (if any)
   - `idle_start` if `hs.host.idleTime() >= idle_min_threshold` at start time

The `tracker` event preceding the replayed state lines signals to consumers that what follows is state replay, not a real transition. Consumers that count transitions should suppress events immediately following a lifecycle marker, or dedup adjacent identical events.

**File end:** when the tracker stops or Hammerspoon reloads cleanly, the last line is `tracker` with `event ∈ {stopped, reloaded, day_rotated}`. A file lacking a closing lifecycle marker indicates an unclean shutdown (crash, kill, power loss).

## Configuration & lifecycle

**Config table** at the top of the Spoon (defaults), overridable by a gitignored `config.local.lua`:

| Key | Default |
|---|---|
| `poll_interval_seconds` | `15` |
| `heartbeat_interval_seconds` | `300` |
| `idle_min_threshold_seconds` | `15` |
| `idle_timestamp_tolerance_seconds` | `2` |
| `log_dir` | `~/.local/share/hs-activity-tracker/events` |
| `diagnostic_log` | `~/.local/share/hs-activity-tracker/tracker.log` |
| `title_denylist_bundle_ids` | 1Password bundles, system password agent, etc. |
| `title_denylist_patterns` | `{"Private Browsing", "Incognito"}` |
| `window_filter_options` | `{visible = true}` |

**Lifecycle:**

- Loaded from `~/.hammerspoon/init.lua`:
  ```
  hs.loadSpoon("ActivityTracker")
  spoon.ActivityTracker:start()
  ```
- `:start()` — verifies/creates the log directory with `0700`, opens today's file, emits the `tracker started` lifecycle event followed by state replay, wires watchers, starts timers. Idempotent.
- `:stop()` — emits `tracker stopped`, tears down watchers/timers, closes the file. Idempotent.
- `hs.shutdownCallback` — registered on `:start()`. Fires on Hammerspoon reload and quit. Emits `tracker reloaded` (on reload) or `tracker stopped` (on quit), then closes the handle.

**Error handling:**
- All watcher callbacks wrapped in `pcall`. Errors logged to the diagnostic log; Hammerspoon never crashes due to this Spoon.
- If the event file cannot be opened, log the error to the diagnostic log and retry on the next event. Do not drop events silently except as a last resort.

## Testing

**Unit-testable (pure Lua, runnable via `busted`):**

- Event record formatting (`lib/format.lua`)
- Idle state machine, given a synthetic sequence of `(now, idleTime)` samples (`lib/idle.lua`)
- Title denylist matching (`lib/denylist.lua`)
- File path / rotation date computation (`lib/paths.lua`)

These modules import nothing from `hs.*`. The Spoon's `init.lua` is the only file with Hammerspoon dependencies.

**Integration testing (manual):** a checklist in the repo README walks through switching apps/windows, going idle, locking the screen, and reloading Hammerspoon, with the expected events to observe via `tail -f` on the current JSONL file.

**CI:** none in v1. Add GitHub Actions running `busted` if the pure-Lua surface grows.

## Out of scope (v1)

- Reporting, aggregation, or visualization
- Browser tab URL capture beyond what window titles already expose
- Per-display tracking, mouse/keystroke counts, network/SSID, calendar correlation
- Compression or retention pruning
- Detection of deep terminal state (foreground process via PTY introspection) — relies on shell-set window titles instead
