-- Path helpers. UTC date computation and ~-expansion. No I/O.

local M = {}

function M.expand_home(path)
  if path:sub(1, 1) == '~' then
    return (os.getenv('HOME') or '') .. path:sub(2)
  end
  return path
end

-- UTC date string for a Unix-epoch timestamp, e.g. '2026-05-20'.
function M.date_string(ts)
  return os.date('!%Y-%m-%d', math.floor(ts))
end

-- Full JSONL path for a given timestamp, under base_dir.
function M.event_file(base_dir, ts)
  return M.expand_home(base_dir) .. '/' .. M.date_string(ts) .. '.jsonl'
end

return M
