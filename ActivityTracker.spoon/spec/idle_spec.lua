local idle = require('lib.idle')

local config = {
  idle_min_threshold_seconds = 15,
  idle_timestamp_tolerance_seconds = 2,
}

describe('idle.step', function()
  it('emits nothing while user is active and no period is in progress', function()
    local state = idle.initial_state()
    local new_state, events = idle.step(state, 1000, 0, config)
    assert.is_nil(new_state.last_logged_idle_start)
    assert.are.equal(0, #events)
  end)

  it('emits idle_start when threshold is crossed from active state', function()
    local state = idle.initial_state()
    local new_state, events = idle.step(state, 1000, 30, config)
    assert.are.equal(1, #events)
    assert.are.equal('idle_start', events[1].type)
    -- ts is the moment of last input, not the polling moment.
    assert.are.equal(970, events[1].ts)
    assert.are.equal(970, new_state.last_logged_idle_start)
  end)

  it('does not re-emit while the idle stretch continues', function()
    local state = { last_logged_idle_start = 970 }
    -- 30 seconds later, idle_time has grown by 30s; idle_start is unchanged.
    local new_state, events = idle.step(state, 1030, 60, config)
    assert.are.equal(0, #events)
    assert.are.equal(970, new_state.last_logged_idle_start)
  end)

  it('tolerates small jitter in computed idle_start', function()
    local state = { last_logged_idle_start = 970 }
    -- Same idle period, but idle_start drifts by 1s (within tolerance).
    local new_state, events = idle.step(state, 1030, 59, config)
    assert.are.equal(0, #events)
    assert.are.equal(970, new_state.last_logged_idle_start)
  end)

  it('emits active_resumed when the user returns', function()
    local state = { last_logged_idle_start = 970 }
    -- now=1100, idle_time=5: input happened at 1095.
    local new_state, events = idle.step(state, 1100, 5, config)
    assert.are.equal(1, #events)
    assert.are.equal('active_resumed', events[1].type)
    assert.are.equal(1095, events[1].ts)
    assert.is_nil(new_state.last_logged_idle_start)
  end)

  it('emits active_resumed then idle_start on bounce-through-active', function()
    local state = { last_logged_idle_start = 970 }
    -- now=1100, idle_time=20: input happened at 1080, then idle again.
    local new_state, events = idle.step(state, 1100, 20, config)
    assert.are.equal(2, #events)
    assert.are.equal('active_resumed', events[1].type)
    assert.are.equal(1080, events[1].ts)
    assert.are.equal('idle_start', events[2].type)
    assert.are.equal(1080, events[2].ts)
    assert.are.equal(1080, new_state.last_logged_idle_start)
  end)

  it('does not mutate the input state table', function()
    local state = { last_logged_idle_start = 970 }
    idle.step(state, 1100, 5, config)
    assert.are.equal(970, state.last_logged_idle_start)
  end)
end)
