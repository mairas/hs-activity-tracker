--- === ActivityTracker ===
---
--- Records macOS desktop and application activity to a JSONL event log.
--- Capture only; see docs/design.md for the event schema.

local obj = {}
obj.__index = obj

obj.name = "ActivityTracker"
obj.version = "0.1.0"
obj.author = "Matti Airas <matti.airas@hatlabs.fi>"
obj.license = "MIT"
obj.homepage = "https://github.com/mairas/hs-activity-tracker"

function obj:start()
  error("not implemented")
end

function obj:stop()
  error("not implemented")
end

return obj
