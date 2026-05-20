--- === ActivityTracker ===
---
--- Records macOS desktop and application activity to a JSONL event log.
--- Capture only; see docs/design.md for the event schema.

-- hs.loadSpoon does not add the Spoon's directory to package.path, so
-- require('lib.writer') would otherwise resolve only against the global
-- Lua paths. Prepend our directory before any requires fire.
local spoon_dir = debug.getinfo(1, 'S').source:sub(2):match('(.*)/[^/]+$')
package.path = spoon_dir .. '/?.lua;' .. spoon_dir .. '/?/init.lua;' .. package.path

local writer_mod = require('lib.writer')
local denylist_mod = require('lib.denylist')
local idle_mod = require('lib.idle')
local title_debounce_mod = require('lib.title_debounce')

local obj = {}
obj.__index = obj

obj.name = 'ActivityTracker'
obj.version = '0.1.0'
obj.author = 'Matti Airas <matti.airas@hatlabs.fi>'
obj.license = 'MIT'
obj.homepage = 'https://github.com/mairas/hs-activity-tracker'

-- Default configuration. Override via config.local.lua next to this file;
-- any keys present there shallow-merge over these defaults.
obj.defaults = {
  poll_interval_seconds = 15,
  heartbeat_interval_seconds = 300,
  idle_min_threshold_seconds = 15,
  idle_timestamp_tolerance_seconds = 2,
  -- Coalesce rapid `window_title` changes (spinner glyphs, progress counters)
  -- into a single emit per window per debounce window. Set to 0 to disable.
  window_title_debounce_seconds = 2,
  log_dir = '~/.local/share/hs-activity-tracker/events',
  diagnostic_log = '~/.local/share/hs-activity-tracker/tracker.log',
  title_denylist_bundle_ids = {
    'com.apple.SecurityAgent',
  },
  title_denylist_patterns = {
    'Private Browsing',
    'Incognito',
  },
  window_filter_options = { visible = true },
}

local SYSTEM_EVENT_NAMES = nil  -- populated lazily once hs.caffeinate is available

local function build_system_event_names()
  return {
    [hs.caffeinate.watcher.screensDidLock] = 'screen_locked',
    [hs.caffeinate.watcher.screensDidUnlock] = 'screen_unlocked',
    [hs.caffeinate.watcher.systemWillSleep] = 'will_sleep',
    [hs.caffeinate.watcher.systemDidWake] = 'did_wake',
    [hs.caffeinate.watcher.screensDidWake] = 'screen_on',
    [hs.caffeinate.watcher.screensDidSleep] = 'screen_off',
  }
end

local function now() return hs.timer.secondsSinceEpoch() end

local function load_local_overrides(spoon_dir)
  local path = spoon_dir .. '/config.local.lua'
  local f = io.open(path, 'r')
  if not f then return nil end
  f:close()
  local ok, result = pcall(dofile, path)
  if ok and type(result) == 'table' then return result end
  hs.printf('[ActivityTracker] failed to load %s', path)
  return nil
end

local function merge_config(defaults, overrides)
  local config = {}
  for k, v in pairs(defaults) do config[k] = v end
  if overrides then
    for k, v in pairs(overrides) do config[k] = v end
  end
  return config
end

function obj:_validate_config()
  local errs = {}
  local function check_positive(k)
    if type(self.config[k]) ~= 'number' or self.config[k] <= 0 then
      errs[#errs + 1] = k .. ' must be a positive number'
    end
  end
  check_positive('poll_interval_seconds')
  check_positive('heartbeat_interval_seconds')
  check_positive('idle_min_threshold_seconds')
  check_positive('idle_timestamp_tolerance_seconds')
  if type(self.config.window_title_debounce_seconds) ~= 'number'
      or self.config.window_title_debounce_seconds < 0 then
    errs[#errs + 1] = 'window_title_debounce_seconds must be a non-negative number'
  end
  for _, k in ipairs({ 'log_dir', 'diagnostic_log' }) do
    if type(self.config[k]) ~= 'string' or self.config[k] == '' then
      errs[#errs + 1] = k .. ' must be a non-empty string'
    end
  end
  if #errs > 0 then
    hs.printf('[ActivityTracker] config invalid: %s', table.concat(errs, '; '))
    return false
  end
  return true
end

function obj:_scrub_title(bundle_id, title)
  return denylist_mod.scrub(bundle_id, title, {
    bundle_ids = self.config.title_denylist_bundle_ids,
    patterns = self.config.title_denylist_patterns,
  })
end

function obj:_app_fields(app)
  return {
    { 'app', app:name() },
    { 'bundle_id', app:bundleID() },
    { 'pid', app:pid() },
  }
end

function obj:_window_fields(win)
  local app = win:application()
  local bid = app and app:bundleID() or nil
  return {
    { 'app', app and app:name() or nil },
    { 'bundle_id', bid },
    { 'window_id', win:id() },
    { 'title', self:_scrub_title(bid, win:title()) },
  }
end

function obj:_state_replay(ts)
  local app = hs.application.frontmostApplication()
  if app then
    self.writer:write(ts, 'app_focus', self:_app_fields(app))
    local win = app:focusedWindow()
    if win then
      self.writer:write(ts, 'window_focus', self:_window_fields(win))
      local wid = win:id()
      if wid then
        self.title_debounce_state = title_debounce_mod.mark(self.title_debounce_state, wid, ts)
      end
    end
  end
  local idle_time = hs.host.idleTime()
  if idle_time >= self.config.idle_min_threshold_seconds then
    local idle_started = ts - idle_time
    self.writer:write(idle_started, 'idle_start',
      { { 'idle_started_at', idle_started } })
    self.idle_state = { last_logged_idle_start = idle_started }
  end
end

function obj:_emit_app_focus(app)
  self.writer:write(now(), 'app_focus', self:_app_fields(app))
end

function obj:_emit_window_focus(win)
  local ts = now()
  self.writer:write(ts, 'window_focus', self:_window_fields(win))
  local wid = win:id()
  if wid then
    self.title_debounce_state = title_debounce_mod.mark(self.title_debounce_state, wid, ts)
  end
end

function obj:_emit_window_title(win)
  local ts = now()
  local wid = win:id()
  if wid then
    local new_state, emit = title_debounce_mod.should_emit(
      self.title_debounce_state, wid, ts, self.config.window_title_debounce_seconds)
    self.title_debounce_state = new_state
    if not emit then return end
  end
  self.writer:write(ts, 'window_title', self:_window_fields(win))
end

function obj:_emit_system(name)
  self.writer:write(now(), 'system', { { 'event', name } })
end

function obj:_start_app_watcher()
  self.app_watcher = hs.application.watcher.new(function(_, event_type, app)
    if event_type ~= hs.application.watcher.activated then return end
    if not app then return end
    pcall(function() self:_emit_app_focus(app) end)
  end)
  self.app_watcher:start()
end

function obj:_start_window_filter()
  -- Default filter (visible standard windows of non-system apps) is the
  -- right starting point; setDefaultFilter only when an override is given.
  self.window_filter = hs.window.filter.new()
  if self.config.window_filter_options then
    self.window_filter:setDefaultFilter(self.config.window_filter_options)
  end
  self.window_filter:subscribe(hs.window.filter.windowFocused, function(win)
    pcall(function() self:_emit_window_focus(win) end)
  end)
  self.window_filter:subscribe(hs.window.filter.windowTitleChanged, function(win)
    pcall(function() self:_emit_window_title(win) end)
  end)
end

function obj:_start_system_watcher()
  SYSTEM_EVENT_NAMES = SYSTEM_EVENT_NAMES or build_system_event_names()
  self.caffeinate_watcher = hs.caffeinate.watcher.new(function(event)
    local name = SYSTEM_EVENT_NAMES[event]
    if not name then return end
    pcall(function() self:_emit_system(name) end)
  end)
  self.caffeinate_watcher:start()
end

function obj:_idle_tick()
  local current = now()
  local idle_time = hs.host.idleTime()
  local new_state, events = idle_mod.step(self.idle_state, current, idle_time, self.config)
  self.idle_state = new_state
  for _, ev in ipairs(events) do
    if ev.type == 'idle_start' then
      self.writer:write(ev.ts, 'idle_start', { { 'idle_started_at', ev.ts } })
    else
      self.writer:write(ev.ts, 'active_resumed', { { 'resumed_at', ev.ts } })
    end
  end
end

function obj:_heartbeat()
  local app = hs.application.frontmostApplication()
  local win = app and app:focusedWindow() or nil
  local bid = app and app:bundleID() or nil
  local title = win and win:title() or nil
  self.writer:write(now(), 'heartbeat', {
    { 'idle_seconds', hs.host.idleTime() },
    { 'focused_app', app and app:name() or nil },
    { 'focused_title', self:_scrub_title(bid, title) },
  })
end

function obj:_start_timers()
  -- _state_replay may have already populated self.idle_state if we entered
  -- start while the user was idle; only initialize when missing.
  self.idle_state = self.idle_state or idle_mod.initial_state()
  self.idle_timer = hs.timer.doEvery(self.config.poll_interval_seconds, function()
    pcall(function() self:_idle_tick() end)
  end)
  self.heartbeat_timer = hs.timer.doEvery(self.config.heartbeat_interval_seconds, function()
    pcall(function() self:_heartbeat() end)
  end)
end

function obj:_on_shutdown()
  -- hs.shutdownCallback fires on both Hammerspoon quit and reload; we cannot
  -- distinguish them, so :stop() emits `stopped` uniformly. A subsequent
  -- `started` in the next session signals that it was a reload.
  self:stop()
end

function obj:start()
  if self._running then return self end

  self.config = merge_config(self.defaults, load_local_overrides(self.spoonPath or '.'))
  if not self:_validate_config() then return self end

  self.title_debounce_state = title_debounce_mod.initial_state()

  self.writer = writer_mod.new({
    log_dir = self.config.log_dir,
    diagnostic_log = self.config.diagnostic_log,
    on_rotation = function() self:_state_replay(now()) end,
  })

  local ts = now()
  self.writer:write(ts, 'tracker', { { 'event', 'started' } })
  self:_state_replay(ts)

  self:_start_app_watcher()
  self:_start_window_filter()
  self:_start_system_watcher()
  self:_start_timers()

  hs.shutdownCallback = function() self:_on_shutdown() end

  self._running = true
  hs.printf('[ActivityTracker] started; log_dir=%s', self.config.log_dir)
  return self
end

function obj:stop()
  if not self._running then return self end

  if self.writer then
    pcall(function()
      self.writer:write(now(), 'tracker', { { 'event', 'stopped' } })
    end)
  end

  if self.app_watcher then self.app_watcher:stop(); self.app_watcher = nil end
  if self.window_filter then
    self.window_filter:unsubscribeAll()
    self.window_filter = nil
  end
  if self.caffeinate_watcher then
    self.caffeinate_watcher:stop()
    self.caffeinate_watcher = nil
  end
  if self.idle_timer then self.idle_timer:stop(); self.idle_timer = nil end
  if self.heartbeat_timer then self.heartbeat_timer:stop(); self.heartbeat_timer = nil end
  if self.writer then self.writer:close(); self.writer = nil end

  self._running = false
  return self
end

return obj
