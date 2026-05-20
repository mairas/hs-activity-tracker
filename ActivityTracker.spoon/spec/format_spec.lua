local format = require('lib.format')

describe('format.iso8601_utc_ms', function()
  it('formats a known UTC timestamp', function()
    local ts = 1779260232 + 0.345  -- 2026-05-20T06:57:12.345Z
    assert.are.equal('2026-05-20T06:57:12.345Z', format.iso8601_utc_ms(ts))
  end)

  it('pads sub-second to three digits', function()
    local ts = 1779260232 + 0.001
    assert.are.equal('2026-05-20T06:57:12.001Z', format.iso8601_utc_ms(ts))
  end)

  it('rounds millisecond fractions correctly', function()
    -- 0.3456 -> 346 ms
    assert.are.equal('2026-05-20T06:57:12.346Z', format.iso8601_utc_ms(1779260232 + 0.3456))
  end)

  it('carries ms overflow into seconds', function()
    -- 0.9999 rounds up to 1000ms, which should bump the second.
    assert.are.equal('2026-05-20T06:57:13.000Z', format.iso8601_utc_ms(1779260232 + 0.9999))
  end)
end)

describe('format.line', function()
  local ts = 1779260232 + 0.345

  it('produces a JSONL line ending in a newline', function()
    local line = format.line(ts, 'tracker', { { 'event', 'started' } })
    assert.are.equal('\n', line:sub(-1))
  end)

  it('places ts and type first in the object', function()
    local line = format.line(ts, 'tracker', { { 'event', 'started' } })
    assert.are.equal(
      '{"ts":"2026-05-20T06:57:12.345Z","type":"tracker","event":"started"}\n',
      line
    )
  end)

  it('emits fields in the order provided', function()
    local line = format.line(ts, 'app_focus', {
      { 'app', 'Ghostty' },
      { 'bundle_id', 'com.mitchellh.ghostty' },
      { 'pid', 12345 },
    })
    assert.are.equal(
      '{"ts":"2026-05-20T06:57:12.345Z","type":"app_focus","app":"Ghostty","bundle_id":"com.mitchellh.ghostty","pid":12345}\n',
      line
    )
  end)

  it('encodes nil title field as null (denylist scrub case)', function()
    local line = format.line(ts, 'window_title', {
      { 'app', 'Safari' },
      { 'bundle_id', 'com.apple.Safari' },
      { 'window_id', 42 },
      { 'title', nil },
    })
    -- nil values must round-trip through the field list intact.
    assert.is_not_nil(line:find('"title":null', 1, true))
  end)

  it('escapes problematic characters in title strings', function()
    local line = format.line(ts, 'window_title', {
      { 'title', 'A "quoted"\ntitle' },
    })
    assert.is_not_nil(line:find([["title":"A \"quoted\"\ntitle"]], 1, true))
  end)

  it('rejects unknown event types', function()
    assert.has_error(function()
      format.line(ts, 'nonsense', {})
    end)
  end)
end)
