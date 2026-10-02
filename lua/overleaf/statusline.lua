-- Project-wide sync and presence, with an optional Heirline integration.
-- No AstroNvim configuration changes or hard statusline dependency required.
local M = {}
local buffer_checks = setmetatable({}, { __mode = 'k' })

local function state() return require('overleaf')._state end

local function escape(text) return tostring(text):gsub('[%c]', ' '):gsub('%%', '%%%%') end

function M.relative_time(timestamp, now)
  local seconds = math.max(0, (now or os.time()) - timestamp)
  if seconds < 5 then return 'just now' end
  local amount, unit = seconds, 'second'
  if seconds >= 86400 then
    amount, unit = math.floor(seconds / 86400), 'day'
  elseif seconds >= 3600 then
    amount, unit = math.floor(seconds / 3600), 'hour'
  elseif seconds >= 60 then
    amount, unit = math.floor(seconds / 60), 'minute'
  end
  return string.format('%d %s%s ago', amount, unit, amount == 1 and '' or 's')
end

function M.changed()
  if not M._attached_root or M._redraw_pending then return end
  M._redraw_pending = true
  vim.schedule(function()
    M._redraw_pending = nil
    vim.cmd.redrawstatus()
  end)
end

function M.reset()
  M._last_ack_at = nil
  M.changed()
end

function M.acknowledged(timestamp)
  M._last_ack_at = timestamp
  M.changed()
end

function M.snapshot()
  local s = state()
  local result = { visible = s.connected or s.project_id ~= nil, collaborators = {}, last_ack_at = M._last_ack_at }
  local pending, uncertain, edited = false, false, false
  for _, doc in pairs(s.documents or {}) do
    edited = edited or (doc._local_revision or 0) > 0
    uncertain = uncertain or doc._sync_uncertain or doc._ack_stalled or false
    pending = pending
      or doc.inflight_op ~= nil
      or doc.pending_ops ~= nil
      or doc._rejoining
      or (doc._local_revision or 0) > (doc._confirmed_revision or 0)
      or doc.content ~= doc.server_content
    -- Catch edits made while disconnected, when on_bytes cannot submit OT.
    if doc.bufnr and vim.api.nvim_buf_is_loaded(doc.bufnr) and not doc.applying_remote and doc.content then
      local tick = vim.api.nvim_buf_get_changedtick(doc.bufnr)
      local check = buffer_checks[doc]
      if not check or check.bufnr ~= doc.bufnr or check.tick ~= tick or check.content ~= doc.content then
        check = {
          bufnr = doc.bufnr,
          tick = tick,
          content = doc.content,
          differs = table.concat(vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false), '\n') ~= doc.content,
        }
        buffer_checks[doc] = check
      end
      pending = pending or check.differs
    end
  end
  if not s.connected then
    result.kind = 'offline'
  elseif uncertain then
    result.kind = 'unconfirmed'
  elseif pending then
    result.kind = 'syncing'
  elseif result.last_ack_at then
    result.kind = 'synced'
  else
    result.kind = edited and 'unconfirmed' or 'idle'
  end
  if s.connected then result.collaborators = require('overleaf.cursors').list() end
  return result
end

function M.sync_text(snapshot)
  local labels = {
    synced = '✓ synced',
    syncing = '… syncing',
    unconfirmed = '! unconfirmed',
    offline = 'offline',
    idle = 'no edits yet',
  }
  local text = ' OL ' .. labels[snapshot.kind]
  if snapshot.last_ack_at then
    text = text .. (snapshot.kind == 'synced' and ' ' or ' · last sync ') .. M.relative_time(snapshot.last_ack_at)
  end
  return text .. ' '
end

-- Public factory for users who assemble their own Heirline statusline.
function M.component()
  return {
    static = { overleaf_status = true },
    condition = function() return state().connected or state().project_id ~= nil end,
    init = function(self) self.overleaf_snapshot = M.snapshot() end,
    {
      provider = function(self) return M.sync_text(self.overleaf_snapshot) end,
      hl = function(self)
        local kind = self.overleaf_snapshot.kind
        return { fg = kind == 'synced' and '#98c379' or kind == 'idle' and '#abb2bf' or '#e5c07b' }
      end,
    },
    {
      condition = function(self) return #self.overleaf_snapshot.collaborators > 0 end,
      flexible = 20,
      {
        init = function(self)
          for i = #self, 1, -1 do
            self[i] = nil
          end
          for i, person in ipairs(self.overleaf_snapshot.collaborators) do
            self[i] = self:new({
              provider = '│ ' .. escape(person.name) .. ' · ' .. escape(person.path or '(no file)') .. ' ',
              hl = { fg = person.color },
            }, i)
          end
        end,
      },
      {
        provider = function(self)
          return string.format('│ %d collaborator(s) ', #self.overleaf_snapshot.collaborators)
        end,
      },
    },
  }
end

function M.attach()
  -- Do not load Heirline just because Overleaf is enabled. Attach after its
  -- normal setup, whether it loads before or after this plugin.
  local heirline = package.loaded.heirline
  local root = heirline and heirline.statusline
  if not root then return end
  M._attached_root = root
  if root:find(function(child) return rawget(child, 'overleaf_status') end) then return end
  root[#root + 1] = root:new(M.component(), #root + 1)
  M.changed()
end

function M.setup()
  local group = vim.api.nvim_create_augroup('OverleafStatusline', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LazyLoad',
    callback = function(event)
      if event.data == 'heirline.nvim' then M.attach() end
    end,
  })
  -- Covers manually loaded Heirline too, and avoids duplicate components.
  vim.api.nvim_create_autocmd('BufEnter', { group = group, callback = function() vim.schedule(M.attach) end })
  if M._timer then vim.fn.timer_stop(M._timer) end
  M._timer = vim.fn.timer_start(1000, function()
    if state().connected or state().project_id then M.changed() end
    M._ticks = (M._ticks or 0) + 1
    -- Discover newly joined, stationary editors and reconcile missed departures.
    if M._ticks % 10 == 0 and state().connected then require('overleaf.cursors').load_collaborators() end
  end, { ['repeat'] = -1 })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function()
      if M._timer then vim.fn.timer_stop(M._timer) end
      M._timer = nil
    end,
  })
  M.attach()
end

return M
