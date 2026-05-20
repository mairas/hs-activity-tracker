# hs-activity-tracker

A Hammerspoon Spoon that records macOS desktop and application activity to a local JSONL event log for personal history and analysis.

Capture only. Reporting and aggregation are intentionally out of scope and may live in a separate project later.

See [docs/design.md](docs/design.md) for the design and event schema.

## Install

Symlink the Spoon into your Hammerspoon directory and load it from `init.lua`:

```sh
ln -s "$(pwd)/ActivityTracker.spoon" ~/.hammerspoon/Spoons/ActivityTracker.spoon
```

Then add to `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("ActivityTracker")
spoon.ActivityTracker:start()
```

Reload Hammerspoon (menu bar → Reload Config, or `hs.reload()` in the console).

Events stream to `~/.local/share/hs-activity-tracker/events/<YYYY-MM-DD>.jsonl`. Tracker diagnostics (errors, drops) land in `~/.local/share/hs-activity-tracker/tracker.log`.

## Configuration

Defaults are at the top of `ActivityTracker.spoon/init.lua`. To override, create `ActivityTracker.spoon/config.local.lua` (gitignored) that returns a table:

```lua
return {
  poll_interval_seconds = 30,
  title_denylist_patterns = { "Private Browsing", "Incognito", "Banking" },
}
```

Keys you don't set fall back to defaults. Reload Hammerspoon to apply changes.

## Manual verification checklist

After install, run through this once to confirm the tracker is wired up correctly. Open a terminal:

```sh
tail -f ~/.local/share/hs-activity-tracker/events/$(date -u +%Y-%m-%d).jsonl | python3 -m json.tool --json-lines
```

Then trigger each scenario and confirm the expected event appears:

- [ ] **Reload Hammerspoon.** Expect: `tracker started`, then `app_focus` and `window_focus` replaying current state.
- [ ] **Switch to a different app** (Cmd-Tab). Expect: `app_focus` followed by `window_focus`.
- [ ] **Switch windows within an app** (Cmd-`). Expect: `window_focus` only, no `app_focus`.
- [ ] **Change browser tab or document title.** Expect: `window_title` with the new title string.
- [ ] **Leave the machine idle for ~30 seconds.** Expect: `idle_start` with `ts` matching the last input moment (not the polling moment).
- [ ] **Wiggle the mouse.** Expect: `active_resumed` with `ts` matching the input moment.
- [ ] **Wait 5 minutes with no activity.** Expect: exactly one `heartbeat` event, no spurious `idle_start`s.
- [ ] **Lock the screen** (Ctrl-Cmd-Q). Expect: `system screen_locked`.
- [ ] **Put the machine to sleep, then wake it.** Expect: `system will_sleep` then `system did_wake`.
- [ ] **Open 1Password and view a vault.** Expect: `window_focus` with `title: null` (denylist scrub).
- [ ] **Quit Hammerspoon cleanly.** Expect: `tracker stopped` as the last line.

## Development

All development commands live in `./run`:

```sh
./run deps    # install Lua 5.4 + luarocks (Homebrew) and busted (into .luarocks/)
./run test    # run busted tests
./run help    # list commands
```

Unit tests cover the pure-Lua libraries under `ActivityTracker.spoon/lib/`. Hammerspoon-integrated code (the top-level Spoon `init.lua`) is verified manually via the checklist above.

## Status

v1 (capture only). Active development.
