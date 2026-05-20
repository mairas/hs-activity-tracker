local denylist = require('lib.denylist')

local config = {
  bundle_ids = { 'com.1password.1password', 'com.apple.SecurityAgent' },
  patterns = { 'Private Browsing', 'Incognito' },
}

describe('denylist.scrub', function()
  it('passes nil through unchanged', function()
    assert.is_nil(denylist.scrub('com.apple.Safari', nil, config))
  end)

  it('passes empty string through unchanged', function()
    assert.are.equal('', denylist.scrub('com.apple.Safari', '', config))
  end)

  it('scrubs titles when bundle id matches exactly', function()
    assert.is_nil(denylist.scrub('com.1password.1password', 'Vault: Personal', config))
  end)

  it('does not match bundle id substrings', function()
    -- 'com.1password.1password' should not match 'com.1password.helper'.
    assert.are.equal('Title', denylist.scrub('com.1password.helper', 'Title', config))
  end)

  it('scrubs titles containing a forbidden pattern', function()
    assert.is_nil(denylist.scrub('com.apple.Safari', 'Private Browsing - Apple', config))
    assert.is_nil(denylist.scrub('com.google.Chrome', 'New Incognito Tab', config))
  end)

  it('passes titles through when neither rule matches', function()
    assert.are.equal(
      'Inbox - Gmail',
      denylist.scrub('com.apple.Safari', 'Inbox - Gmail', config)
    )
  end)

  it('tolerates missing config sections', function()
    assert.are.equal('Title', denylist.scrub('any.bundle', 'Title', {}))
    assert.are.equal('Title', denylist.scrub('any.bundle', 'Title', { patterns = {} }))
  end)
end)
