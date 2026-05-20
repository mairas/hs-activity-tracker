local paths = require('lib.paths')

describe('paths.expand_home', function()
  it('expands a leading tilde', function()
    local home = os.getenv('HOME')
    assert.are.equal(home .. '/foo', paths.expand_home('~/foo'))
  end)

  it('leaves non-tilde paths alone', function()
    assert.are.equal('/tmp/foo', paths.expand_home('/tmp/foo'))
    assert.are.equal('foo/bar', paths.expand_home('foo/bar'))
  end)
end)

describe('paths.date_string', function()
  it('returns the UTC date for a timestamp', function()
    -- 2026-05-20T23:59:59Z
    assert.are.equal('2026-05-20', paths.date_string(1779321599))
  end)

  it('crosses to the next UTC date at midnight', function()
    -- 2026-05-21T00:00:01Z
    assert.are.equal('2026-05-21', paths.date_string(1779321601))
  end)
end)

describe('paths.event_file', function()
  it('joins base_dir and the UTC date filename', function()
    -- 2026-05-20T06:57:12Z
    assert.are.equal('/tmp/events/2026-05-20.jsonl',
      paths.event_file('/tmp/events', 1779260232))
  end)

  it('expands ~ in base_dir', function()
    local home = os.getenv('HOME')
    assert.are.equal(home .. '/events/2026-05-20.jsonl',
      paths.event_file('~/events', 1779260232))
  end)
end)
