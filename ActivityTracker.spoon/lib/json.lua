-- Minimal JSON encoder for hs-activity-tracker event lines.
--
-- Supports strings, numbers, booleans, nil, and ordered objects built from a
-- list of {key, value} pairs. Arrays and nested objects are intentionally not
-- supported; the event schema is flat.

local M = {}

local ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escape_string(s)
  return (s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end))
end

M.escape_string = escape_string

local function encode_value(v)
  local t = type(v)
  if v == nil then return 'null' end
  if t == 'boolean' then return v and 'true' or 'false' end
  if t == 'number' then
    if v ~= v then error('cannot encode NaN') end
    if v == math.huge or v == -math.huge then error('cannot encode infinity') end
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format('%d', v)
    end
    return string.format('%.14g', v)
  end
  if t == 'string' then
    return '"' .. escape_string(v) .. '"'
  end
  error('cannot encode value of type ' .. t)
end

M.encode_value = encode_value

-- Encode an object from a list of {key, value} pairs. Key order is preserved.
function M.encode_object(items)
  local parts = {}
  for i, pair in ipairs(items) do
    parts[i] = '"' .. escape_string(pair[1]) .. '":' .. encode_value(pair[2])
  end
  return '{' .. table.concat(parts, ',') .. '}'
end

return M
