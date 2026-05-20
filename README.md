# hs-activity-tracker

A Hammerspoon Spoon that records macOS desktop and application activity to a local JSONL event log for personal history and analysis.

Capture only. Reporting and aggregation are intentionally out of scope and may live in a separate project later.

See [docs/design.md](docs/design.md) for the design and event schema.

## Status

Pre-implementation. Design approved 2026-05-20.

## Development

All development commands live in `./run`:

```sh
./run deps    # install Lua 5.4 + luarocks (Homebrew) and busted (into .luarocks/)
./run test    # run busted tests
./run help    # list commands
```
