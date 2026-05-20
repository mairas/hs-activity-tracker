-- Title denylist: scrubs window titles for privacy-sensitive apps and
-- substrings before they reach the event log.
--
-- Bundle IDs match exactly; patterns use Lua pattern semantics
-- (so '%-' to match a literal dash, etc.).

local M = {}

-- Returns the title to log, or nil if the title should be scrubbed.
--
-- An incoming nil or empty title is passed through unchanged so the caller
-- can rely on whatever the source provided.
function M.scrub(bundle_id, title, config)
  if title == nil or title == '' then
    return title
  end
  if config.bundle_ids then
    for _, bid in ipairs(config.bundle_ids) do
      if bid == bundle_id then
        return nil
      end
    end
  end
  if config.patterns then
    for _, pat in ipairs(config.patterns) do
      if string.find(title, pat) then
        return nil
      end
    end
  end
  return title
end

return M
