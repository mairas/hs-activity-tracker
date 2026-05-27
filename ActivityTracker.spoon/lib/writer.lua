-- Event writer. Owns one event-file handle and one diagnostic-log handle,
-- handles UTC daily rotation, enforces 0700 / 0600 permissions, and falls
-- back to the diagnostic log when the event file cannot be opened.
--
-- The writer is intentionally dumb about lifecycle: it emits its own
-- `tracker {event: "day_rotated"}` markers when the date rolls over, and
-- calls an optional `on_rotation` callback so the caller (the lifecycle
-- layer) can emit state-replay events on the newly opened file before the
-- triggering event is written.

local format = require('lib.format')
local paths = require('lib.paths')

local M = {}
local Writer = {}
Writer.__index = Writer

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function ensure_dir(dir, mode)
  os.execute('mkdir -p ' .. shell_quote(dir))
  os.execute('chmod ' .. mode .. ' ' .. shell_quote(dir))
end

local function dir_of(path)
  return path:match('(.*)/[^/]+$') or '.'
end

function M.new(opts)
  return setmetatable({
    log_dir = paths.expand_home(opts.log_dir),
    diagnostic_log = paths.expand_home(opts.diagnostic_log),
    on_rotation = opts.on_rotation,
    handle = nil,
    handle_date = nil,
    diag_handle = nil,
  }, Writer)
end

function Writer:_diag(msg)
  if not self.diag_handle then
    ensure_dir(dir_of(self.diagnostic_log), '700')
    self.diag_handle = io.open(self.diagnostic_log, 'a')
    if self.diag_handle then
      self.diag_handle:setvbuf('line')
    end
  end
  if self.diag_handle then
    self.diag_handle:write(os.date('!%Y-%m-%dT%H:%M:%SZ ') .. msg .. '\n')
  end
end

function Writer:_open_for_date(date_str)
  ensure_dir(self.log_dir, '700')
  local path = self.log_dir .. '/' .. date_str .. '.jsonl'
  local f, err = io.open(path, 'a')
  if not f then
    self:_diag('cannot open ' .. path .. ': ' .. tostring(err))
    return false
  end
  os.execute('chmod 600 ' .. shell_quote(path))
  self.handle = f
  self.handle_date = date_str
  return true
end

function Writer:_write_raw(ts, event_type, fields)
  if not self.handle then return false end
  local ok, err = pcall(function()
    self.handle:write(format.line(ts, event_type, fields))
    self.handle:flush()
  end)
  if not ok then
    self:_diag('write failed (' .. event_type .. '): ' .. tostring(err))
    return false
  end
  return true
end

local DAY_ROTATED = { { 'event', 'day_rotated' } }

-- Write one event. Opens the file lazily; on UTC date rollover, brackets
-- the rotation with `tracker day_rotated` markers on both the old and new
-- files and calls on_rotation if provided.
function Writer:write(ts, event_type, fields)
  local desired_date = paths.date_string(ts)

  if self.handle == nil then
    if not self:_open_for_date(desired_date) then
      self:_diag('dropping event ' .. event_type)
      return false
    end
    return self:_write_raw(ts, event_type, fields)
  end

  -- Forward-only: a backward "rotation" would re-enter on_rotation → state
  -- replay → another past-dated write, recursing until the stack overflows.
  if desired_date > self.handle_date then
    self:_write_raw(ts, 'tracker', DAY_ROTATED)
    self.handle:close()
    self.handle = nil
    if not self:_open_for_date(desired_date) then
      self:_diag('dropping event ' .. event_type)
      return false
    end
    self:_write_raw(ts, 'tracker', DAY_ROTATED)
    if self.on_rotation then self.on_rotation(self) end
  end

  return self:_write_raw(ts, event_type, fields)
end

function Writer:close()
  if self.handle then
    self.handle:close()
    self.handle = nil
  end
  if self.diag_handle then
    self.diag_handle:close()
    self.diag_handle = nil
  end
end

return M
