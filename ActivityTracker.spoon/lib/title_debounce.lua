-- Per-window debounce for `window_title` events.
--
-- `windowTitleChanged` fires on every title mutation, so animated titles
-- (spinner glyphs, progress counters) produce a flood of near-identical
-- events. This module suppresses an emission whenever any other observation
-- (emitted or not) landed within `debounce_seconds`. A sustained stream
-- therefore extends the suppression indefinitely; isolated changes followed
-- by silence pass through immediately.
--
-- Tradeoff: when a noisy stream stops, the final settled title arrives as
-- part of the same burst and is suppressed. That's the cost of leading-edge
-- debounce; the alternative (timer-based trailing flush) is more code for
-- a marginal-signal payoff.
--
-- Pure data; state is a plain { [window_id] = last_observed_ts } map so it
-- can be tested without Hammerspoon. Entries accumulate over the life of a
-- Hammerspoon session — practical leak is negligible (each entry is a
-- number) and a sweep can be added if it ever matters.

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
--
-- Emits when no prior observation has been recorded for this window_id, or
-- when `debounce_seconds` have elapsed since the last observation. The
-- observation timestamp is updated on every call regardless of the emit
-- decision, so an ongoing burst keeps the suppression alive. A
-- `debounce_seconds` of 0 disables suppression.
function M.should_emit(state, window_id, ts, debounce_seconds)
  local last = state[window_id]
  local emit = last == nil or debounce_seconds <= 0 or ts - last >= debounce_seconds
  local new_state = copy(state)
  new_state[window_id] = ts
  return new_state, emit
end

-- Seed the last-observed timestamp without going through the predicate.
-- Called from `window_focus` emissions so the post-focus animation burst is
-- suppressed correctly.
function M.mark(state, window_id, ts)
  local new_state = copy(state)
  new_state[window_id] = ts
  return new_state
end

return M
