local json = require('lib.json')

describe('json.encode_value', function()
  it('encodes nil as null', function()
    assert.are.equal('null', json.encode_value(nil))
  end)

  it('encodes booleans', function()
    assert.are.equal('true', json.encode_value(true))
    assert.are.equal('false', json.encode_value(false))
  end)

  it('encodes integers without decimal point', function()
    assert.are.equal('0', json.encode_value(0))
    assert.are.equal('42', json.encode_value(42))
    assert.are.equal('-7', json.encode_value(-7))
  end)

  it('encodes floats', function()
    assert.are.equal('1.5', json.encode_value(1.5))
  end)

  it('encodes plain strings with surrounding quotes', function()
    assert.are.equal('"hello"', json.encode_value('hello'))
  end)

  it('escapes quotes, backslashes, newlines, and tabs', function()
    assert.are.equal('"a\\"b"', json.encode_value('a"b'))
    assert.are.equal('"a\\\\b"', json.encode_value('a\\b'))
    assert.are.equal('"a\\nb"', json.encode_value('a\nb'))
    assert.are.equal('"a\\tb"', json.encode_value('a\tb'))
  end)

  it('escapes other control characters as \\uXXXX', function()
    assert.are.equal('"\\u0001"', json.encode_value('\1'))
  end)

  it('rejects NaN and infinity', function()
    assert.has_error(function() json.encode_value(0 / 0) end)
    assert.has_error(function() json.encode_value(math.huge) end)
  end)
end)

describe('json.encode_object', function()
  it('encodes empty object', function()
    assert.are.equal('{}', json.encode_object({}))
  end)

  it('preserves key order from the input list', function()
    local out = json.encode_object({
      { 'b', 1 },
      { 'a', 2 },
      { 'c', 3 },
    })
    assert.are.equal('{"b":1,"a":2,"c":3}', out)
  end)

  it('encodes nil values as null', function()
    local out = json.encode_object({ { 'title', nil } })
    assert.are.equal('{"title":null}', out)
  end)

  it('escapes keys', function()
    local out = json.encode_object({ { 'a"b', 1 } })
    assert.are.equal('{"a\\"b":1}', out)
  end)
end)
