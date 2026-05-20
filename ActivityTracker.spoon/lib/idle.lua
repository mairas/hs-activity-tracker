-- Idle-state machine. Pure function over (state, now, idle_time, config).
--
-- Emits at most two events per call: `active_resumed` if the user returned
-- since the last tick, optionally followed by a fresh `idle_start` if the
-- user has gone idle again since.
--
-- See docs/design.md → "Idle handling" for the rationale.

local M = {}

local function near(a, b, tol)
  return math.abs(a - b) <= tol
end

-- Returns the initial state (no idle period in progress).
function M.initial_state()
  return { last_logged_idle_start = nil }
end

-- One tick of the state machine.
--
-- state            : { last_logged_idle_start = number | nil }
-- now              : current wall-clock time, seconds (UTC float)
-- idle_time        : seconds since last HID input
-- config           : { idle_min_threshold_seconds, idle_timestamp_tolerance_seconds }
--
-- Returns (new_state, events) where events is an ordered array of
-- { type = 'idle_start'|'active_resumed', ts = number } records.
function M.step(state, now, idle_time, config)
  local threshold = config.idle_min_threshold_seconds
  local tolerance = config.idle_timestamp_tolerance_seconds
  local current_idle_start = now - idle_time
  local new_state = { last_logged_idle_start = state.last_logged_idle_start }
  local events = {}

  if state.last_logged_idle_start == nil then
    if idle_time >= threshold then
      events[#events + 1] = { type = 'idle_start', ts = current_idle_start }
      new_state.last_logged_idle_start = current_idle_start
    end
    return new_state, events
  end

  if near(current_idle_start, state.last_logged_idle_start, tolerance) then
    -- Same idle stretch continuing; nothing to emit.
    return new_state, events
  end

  -- The user provided input since our last tick.
  events[#events + 1] = { type = 'active_resumed', ts = current_idle_start }
  if idle_time >= threshold then
    -- They also went idle again before we noticed; open a new idle period.
    events[#events + 1] = { type = 'idle_start', ts = current_idle_start }
    new_state.last_logged_idle_start = current_idle_start
  else
    new_state.last_logged_idle_start = nil
  end
  return new_state, events
end

return M
