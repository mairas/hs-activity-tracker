local title_debounce = require('lib.title_debounce')

describe('title_debounce.should_emit', function()
  it('emits on first observation for a window_id', function()
    local state = title_debounce.initial_state()
    local new_state, emit = title_debounce.should_emit(state, 42, 1000, 2)
    assert.is_true(emit)
    assert.are.equal(1000, new_state[42])
  end)

  it('suppresses changes inside the debounce window', function()
    local state = { [42] = 1000 }
    local new_state, emit = title_debounce.should_emit(state, 42, 1001, 2)
    assert.is_false(emit)
    assert.are.equal(1000, new_state[42])
  end)

  it('emits again once the debounce window has elapsed', function()
    local state = { [42] = 1000 }
    local new_state, emit = title_debounce.should_emit(state, 42, 1002, 2)
    assert.is_true(emit)
    assert.are.equal(1002, new_state[42])
  end)

  it('tracks window_ids independently', function()
    local state = { [42] = 1000 }
    local new_state, emit = title_debounce.should_emit(state, 99, 1000, 2)
    assert.is_true(emit)
    assert.are.equal(1000, new_state[42])
    assert.are.equal(1000, new_state[99])
  end)

  it('always emits when debounce_seconds is zero', function()
    local state = { [42] = 1000 }
    local new_state, emit = title_debounce.should_emit(state, 42, 1000, 0)
    assert.is_true(emit)
    assert.are.equal(1000, new_state[42])
  end)

  it('does not mutate the input state table', function()
    local state = { [42] = 1000 }
    title_debounce.should_emit(state, 42, 1001, 2)
    assert.are.equal(1000, state[42])
    assert.is_nil(state[99])
  end)
end)

describe('title_debounce.mark', function()
  it('seeds last-emit timestamp without consulting the window', function()
    local state = title_debounce.initial_state()
    local new_state = title_debounce.mark(state, 42, 1000)
    assert.are.equal(1000, new_state[42])
  end)

  it('overwrites an earlier timestamp', function()
    local state = { [42] = 900 }
    local new_state = title_debounce.mark(state, 42, 1000)
    assert.are.equal(1000, new_state[42])
  end)

  it('does not mutate the input state table', function()
    local state = { [42] = 900 }
    title_debounce.mark(state, 42, 1000)
    assert.are.equal(900, state[42])
  end)
end)

