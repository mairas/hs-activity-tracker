# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

- `./run deps` — install Lua 5.4, luarocks, and busted into `.luarocks/` (Homebrew).
- `./run test` — run the full busted suite (`.luarocks/bin/busted`).
- `.luarocks/bin/busted ActivityTracker.spoon/spec/idle_spec.lua` — run a single spec file.
- `.luarocks/bin/busted --filter "pattern"` — run only tests whose description matches.

There is no lint step and no CI; correctness rests on busted plus manual scenarios from `docs/design.md`.

- `python3 analysis/app_usage.py <App> --since YYYY-MM-DD` — per-app active-use periods from the event log. Stdlib only; methodology and data gotchas in `docs/analysis.md`.

## Architecture

This is a Hammerspoon Spoon. The only file that touches `hs.*` APIs is `ActivityTracker.spoon/init.lua`. Everything under `ActivityTracker.spoon/lib/` is **pure Lua** and unit-tested by `busted` — that boundary is load-bearing, not stylistic. When adding behavior, push the testable logic (state machines, formatters, matchers, path math) into `lib/` and keep `init.lua` as the thin glue layer that wires watchers and timers to writer calls.

Concretely:

- `init.lua` owns lifecycle (`:start`/`:stop`), watcher wiring (`hs.application.watcher`, `hs.window.filter`, `hs.caffeinate.watcher`), the idle/heartbeat timers, and state replay. All watcher callbacks are wrapped in `pcall` so Hammerspoon never crashes from this Spoon.
- `lib/writer.lua` owns the single open JSONL handle, lazy open, UTC daily rotation (emits bracketing `tracker day_rotated` markers and calls `on_rotation` so the lifecycle layer can replay state), and `0700`/`0600` perms. It is the only place that talks to the filesystem for the event stream.
- `lib/format.lua`, `lib/json.lua` — line formatting. `format.line(ts, type, fields)` takes ordered `{key, value}` pairs so JSON field order is stable across runs.
- `lib/idle.lua` — pure idle state machine. `step(state, now, idleTime, config)` returns `(new_state, events[])`. Both `idle_start` and `active_resumed` carry precise (non-poll-quantized) timestamps derived from `now - idleTime`.
- `lib/title_debounce.lua` — leading-edge per-window-id debounce for `window_title` bursts. `should_emit` extends the suppression window on every *observation* (emitted or suppressed), so sustained sub-debounce streams stay silent indefinitely after their first frame. `window_focus` events seed the same map via `mark` so the post-focus title burst is correctly suppressed.
- `lib/denylist.lua`, `lib/paths.lua` — title scrubbing and tilde-expansion / UTC date-string helpers.

`docs/design.md` is the authoritative spec for the event schema, switch-event ordering, idle state machine, file self-containment rules, and out-of-scope items. Treat it as the source of truth when behavior is ambiguous; update it when behavior changes.

### Event schema invariants worth preserving

- One JSON object per line, UTF-8, `\n`-terminated, no pretty printing. `io.write` + `flush` on every event (crash safety > throughput).
- All timestamps are UTC ISO-8601 with `Z` and millisecond precision. Local-time rendering is an analysis-stage concern.
- Denylisted titles are set to `null`, never omitted — absent fields would be ambiguous.
- Every JSONL file must be analyzable in isolation: it opens with a `tracker` lifecycle line followed by state replay (`app_focus`, `window_focus`, `idle_start` if applicable), and ideally closes with a matching `tracker stopped`/`reloaded`/`day_rotated`.

## Configuration

Defaults live at the top of `ActivityTracker.spoon/init.lua` in `obj.defaults`. Users override them by creating `ActivityTracker.spoon/config.local.lua` (gitignored) that returns a table; `merge_config` is a shallow merge, so nested tables (e.g. `title_denylist_patterns`) are replaced wholesale, not merged. `_validate_config` runs at `:start()` and refuses to wire watchers if anything is wrong.

## Conventions

- `.luarc.json` declares Lua-LS globals (`hs`, `spoon`, busted's `describe`/`it`/etc.).
- Tests live in `ActivityTracker.spoon/spec/`, named `<module>_spec.lua`. `.busted` configures `lpath` so specs can `require('lib.foo')` directly.
- The `./run` script is the convention used across hatlabs/mairas repos: bash dispatcher, `#@ Description` / `#@ Category:` docstrings, awk-based help auto-generation. Match this style when adding commands.
