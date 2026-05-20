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

## Development

All development commands live in `./run`:

```sh
./run deps    # install Lua 5.4 + luarocks (Homebrew) and busted (into .luarocks/)
./run test    # run busted tests
./run help    # list commands
```

Unit tests cover the pure-Lua libraries under `ActivityTracker.spoon/lib/`. Hammerspoon-integrated code (the top-level Spoon `init.lua`) is verified by running through the event scenarios documented in [docs/design.md](docs/design.md) (see *Event schema* and *Testing*).

## Status

v1 (capture only). Active development.
