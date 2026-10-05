-- Sidekick treats only ordinary/help buffers as file context. Overleaf mirrors
-- use acwrite so :write goes through BufWriteCmd rather than bypassing OT.
local M = {}

function M.attach()
  -- Optional integration: no dependency installation or Sidekick source edits.
  -- Load its lightweight location helper now, so even the first send works.
  local ok, location = pcall(require, 'sidekick.cli.context.location')
  if not ok or type(location) ~= 'table' or type(location.is_file) ~= 'function' then return false end
  if location.is_file == location._overleaf_is_file then return true end

  local original = location.is_file
  location.is_file = function(buf)
    if original(buf) then return true end
    buf = buf == 0 and vim.api.nvim_get_current_buf() or buf
    if not vim.api.nvim_buf_is_valid(buf) or not vim.bo[buf].buflisted or vim.bo[buf].buftype ~= 'acwrite' then
      return false
    end
    local overleaf = package.loaded.overleaf
    local state = overleaf and overleaf._state
    if not state then return false end
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.fn.filereadable(name) ~= 1 then return false end
    for _, doc in pairs(state.documents or {}) do
      if doc.bufnr == buf then
        local path = require('overleaf.sync').file_path(doc.path)
        return path ~= nil and vim.fs.normalize(path) == vim.fs.normalize(name)
      end
    end
    return false
  end
  location._overleaf_is_file = location.is_file
  return true
end

function M.setup()
  local group = vim.api.nvim_create_augroup('OverleafSidekick', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'LazyLoad',
    callback = function(event)
      if event.data == 'sidekick.nvim' then M.attach() end
    end,
  })
  M.attach()
end

return M
