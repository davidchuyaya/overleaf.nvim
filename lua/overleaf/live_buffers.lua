local M = {}
local scheduled = {}

--- Upgrade ordinary mirror opens from any UI, without replacing its window.
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return false end
  -- Ignore picker preview buffers and other temporary/special-purpose buffers.
  if not vim.bo[bufnr].buflisted then return false end
  if vim.bo[bufnr].buftype ~= '' and vim.bo[bufnr].buftype ~= 'acwrite' then return false end
  local overleaf = require('overleaf')
  local sync = require('overleaf.sync')
  if not overleaf._state.connected or not sync._sync_dir then return false end
  local path = vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr))
  local root = vim.fs.normalize(sync._sync_dir)
  if path:sub(1, #root + 1) ~= root .. '/' then return false end
  local entry = require('overleaf.project').get_doc_by_path(path:sub(#root + 2))
  if not entry or entry.type ~= 'doc' then return false end
  local doc = overleaf._state.documents[entry.id]
  if doc and doc._opening then return true end
  if doc and doc.bufnr == bufnr and doc._buffer_attached then
    vim.bo[bufnr].buftype = 'acwrite'
    return true
  end
  overleaf.open_document(entry.id, entry.path, nil, { bufnr = bufnr, display = false })
  return true
end

function M.attach_open_buffers()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    M.attach(vim.api.nvim_win_get_buf(win))
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('OverleafLiveBuffers', { clear = true })
  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufEnter' }, {
    group = group,
    callback = function(args)
      if scheduled[args.buf] then return end
      scheduled[args.buf] = true
      -- Let file pickers finish placing the buffer and its selected position.
      vim.schedule(function()
        scheduled[args.buf] = nil
        M.attach(args.buf)
      end)
    end,
  })
end

return M
