-- Per-window debounce for `window_title` events.
--
-- `windowTitleChanged` fires on every title mutation, so animated titles
-- (spinner glyphs, progress counters) produce a flood of near-identical
-- events. This module suppresses repeated emissions for the same window_id
-- within `debounce_seconds` of the previously-emitted title — keeping the
-- first frame of each burst, which is the meaningful transition.
--
-- Pure data; state is a plain { [window_id] = last_emit_ts } map so it can
-- be tested without Hammerspoon.

local M = {}

function M.initial_state()
  return {}
end

local function copy(state)
  local out = {}
  for k, v in pairs(state) do out[k] = v end
  return out
end

-- Predicate for `windowTitleChanged`: returns (new_state, emit_bool).
-- A `debounce_seconds` of 0 disables suppression.
function M.should_emit(state, window_id, ts, debounce_seconds)
  local last = state[window_id]
  if last == nil or debounce_seconds <= 0 or ts - last >= debounce_seconds then
    local new_state = copy(state)
    new_state[window_id] = ts
    return new_state, true
  end
  return copy(state), false
end

-- Seed the last-emit timestamp without consulting the predicate. Called
-- when a `window_focus` event is emitted so the post-focus animation burst
-- is suppressed correctly.
function M.mark(state, window_id, ts)
  local new_state = copy(state)
  new_state[window_id] = ts
  return new_state
end

return M
