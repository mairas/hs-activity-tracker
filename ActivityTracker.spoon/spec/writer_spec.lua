local writer = require('lib.writer')

local function mktempdir()
  local f = io.popen('mktemp -d')
  local dir = f:read('*l')
  f:close()
  return dir
end

local function rmtree(dir)
  os.execute('rm -rf ' .. "'" .. dir .. "'")
end

local function read_file(path)
  local f = io.open(path, 'r')
  if not f then return nil end
  local content = f:read('*a')
  f:close()
  return content
end

local function lines(content)
  local out = {}
  for line in (content or ''):gmatch('([^\n]+)') do
    out[#out + 1] = line
  end
  return out
end

local function file_mode_octal(path)
  local f = io.popen('stat -f %p ' .. "'" .. path .. "'")
  local raw = f:read('*l')
  f:close()
  -- Last three digits are the permission bits.
  return raw:sub(-3)
end

local TS_2026_05_20 = 1779260232      -- 2026-05-20T06:57:12Z
local TS_2026_05_21 = TS_2026_05_20 + 86400  -- 2026-05-21T06:57:12Z

describe('writer', function()
  local tmp
  local w

  before_each(function()
    tmp = mktempdir()
    w = writer.new({
      log_dir = tmp .. '/events',
      diagnostic_log = tmp .. '/tracker.log',
    })
  end)

  after_each(function()
    if w then w:close() end
    rmtree(tmp)
  end)

  it('writes one event as one JSONL line', function()
    w:write(TS_2026_05_20, 'tracker', { { 'event', 'started' } })
    local content = read_file(tmp .. '/events/2026-05-20.jsonl')
    assert.is_not_nil(content)
    assert.are.equal(1, #lines(content))
    assert.is_not_nil(content:find('"type":"tracker"', 1, true))
    assert.is_not_nil(content:find('"event":"started"', 1, true))
  end)

  it('appends subsequent same-day events to the same file', function()
    w:write(TS_2026_05_20, 'tracker', { { 'event', 'started' } })
    w:write(TS_2026_05_20 + 60, 'heartbeat', { { 'idle_seconds', 5 } })
    local content = read_file(tmp .. '/events/2026-05-20.jsonl')
    assert.are.equal(2, #lines(content))
  end)

  it('creates the events directory with 0700 permissions', function()
    w:write(TS_2026_05_20, 'tracker', { { 'event', 'started' } })
    assert.are.equal('700', file_mode_octal(tmp .. '/events'))
  end)

  it('creates event files with 0600 permissions', function()
    w:write(TS_2026_05_20, 'tracker', { { 'event', 'started' } })
    assert.are.equal('600', file_mode_octal(tmp .. '/events/2026-05-20.jsonl'))
  end)

  it('rotates on UTC date rollover, bracketing both files with day_rotated', function()
    w:write(TS_2026_05_20, 'app_focus',
      { { 'app', 'X' }, { 'bundle_id', 'x' }, { 'pid', 1 } })
    w:write(TS_2026_05_21, 'app_focus',
      { { 'app', 'Y' }, { 'bundle_id', 'y' }, { 'pid', 2 } })

    local old = lines(read_file(tmp .. '/events/2026-05-20.jsonl'))
    local new = lines(read_file(tmp .. '/events/2026-05-21.jsonl'))

    assert.are.equal(2, #old)
    assert.is_not_nil(old[1]:find('"type":"app_focus"', 1, true))
    assert.is_not_nil(old[2]:find('"event":"day_rotated"', 1, true))

    assert.are.equal(2, #new)
    assert.is_not_nil(new[1]:find('"event":"day_rotated"', 1, true))
    assert.is_not_nil(new[2]:find('"app":"Y"', 1, true))
  end)

  it('does not rotate when a past-dated event is written into an open file', function()
    local replay_calls = 0
    w = writer.new({
      log_dir = tmp .. '/events',
      diagnostic_log = tmp .. '/tracker.log',
      on_rotation = function() replay_calls = replay_calls + 1 end,
    })

    -- Open today's file with a fresh event, then write a past-dated event
    -- (mirrors state-replay emitting idle_start with ts = now - idle_time
    -- when the user has been idle across midnight).
    w:write(TS_2026_05_21, 'tracker', { { 'event', 'started' } })
    w:write(TS_2026_05_20, 'idle_start', { { 'idle_started_at', TS_2026_05_20 } })

    assert.are.equal(0, replay_calls)
    -- Yesterday's file must not be (re-)opened by a backward "rotation".
    assert.is_nil(read_file(tmp .. '/events/2026-05-20.jsonl'))

    local today = lines(read_file(tmp .. '/events/2026-05-21.jsonl'))
    assert.are.equal(2, #today)
    assert.is_not_nil(today[1]:find('"event":"started"', 1, true))
    assert.is_not_nil(today[2]:find('"type":"idle_start"', 1, true))
  end)

  it('does not recurse when on_rotation writes a past-dated event', function()
    -- Reproduces the day_rotated spam: at midnight rollover the writer
    -- rotates forward, on_rotation runs state replay, and state replay
    -- emits an idle_start with a yesterday timestamp. That past-dated
    -- write must not re-trigger on_rotation.
    local replay_calls = 0
    w = writer.new({
      log_dir = tmp .. '/events',
      diagnostic_log = tmp .. '/tracker.log',
      on_rotation = function(writer_instance)
        replay_calls = replay_calls + 1
        writer_instance:write(TS_2026_05_20, 'idle_start',
          { { 'idle_started_at', TS_2026_05_20 } })
      end,
    })

    w:write(TS_2026_05_20, 'tracker', { { 'event', 'started' } })
    w:write(TS_2026_05_21, 'app_focus',
      { { 'app', 'X' }, { 'bundle_id', 'x' }, { 'pid', 1 } })

    assert.are.equal(1, replay_calls)
  end)

  it('invokes on_rotation between the new file marker and the triggering event', function()
    local replay_called = false
    w = writer.new({
      log_dir = tmp .. '/events',
      diagnostic_log = tmp .. '/tracker.log',
      on_rotation = function(writer_instance)
        replay_called = true
        writer_instance:write(TS_2026_05_21, 'app_focus',
          { { 'app', 'Replay' }, { 'bundle_id', 'r' }, { 'pid', 99 } })
      end,
    })

    w:write(TS_2026_05_20, 'app_focus',
      { { 'app', 'X' }, { 'bundle_id', 'x' }, { 'pid', 1 } })
    w:write(TS_2026_05_21, 'app_focus',
      { { 'app', 'Triggering' }, { 'bundle_id', 't' }, { 'pid', 2 } })

    assert.is_true(replay_called)
    local new = lines(read_file(tmp .. '/events/2026-05-21.jsonl'))
    -- day_rotated, replay (app_focus Replay), triggering (app_focus Triggering)
    assert.are.equal(3, #new)
    assert.is_not_nil(new[1]:find('"event":"day_rotated"', 1, true))
    assert.is_not_nil(new[2]:find('"app":"Replay"', 1, true))
    assert.is_not_nil(new[3]:find('"app":"Triggering"', 1, true))
  end)
end)
