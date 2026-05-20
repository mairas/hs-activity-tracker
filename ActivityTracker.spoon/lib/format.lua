-- Event line formatter. Produces a single JSONL line (with trailing newline)
-- from a timestamp, event type, and an ordered list of {key, value} pairs.

local json = require('lib.json')

local M = {}

local VALID_TYPES = {
  app_focus = true,
  window_focus = true,
  window_title = true,
  idle_start = true,
  active_resumed = true,
  heartbeat = true,
  system = true,
  tracker = true,
}

-- Format a Unix-epoch float (seconds, with optional fractional part) as
-- ISO 8601 UTC with millisecond precision, e.g. "2026-05-20T06:57:12.345Z".
function M.iso8601_utc_ms(ts)
  local whole = math.floor(ts)
  local ms = math.floor((ts - whole) * 1000 + 0.5)
  -- Carry rounding overflow into the seconds component.
  if ms >= 1000 then
    whole = whole + 1
    ms = ms - 1000
  end
  return string.format('%s.%03dZ', os.date('!%Y-%m-%dT%H:%M:%S', whole), ms)
end

-- Format one event as a JSONL line, including a trailing newline.
function M.line(ts, event_type, fields)
  if not VALID_TYPES[event_type] then
    error('invalid event type: ' .. tostring(event_type))
  end
  local items = {
    { 'ts', M.iso8601_utc_ms(ts) },
    { 'type', event_type },
  }
  if fields then
    for _, pair in ipairs(fields) do
      items[#items + 1] = pair
    end
  end
  return json.encode_object(items) .. '\n'
end

return M
