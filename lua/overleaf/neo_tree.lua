local config = require('overleaf.config')

local M = {}

local protected_commands = {
  a = 'add',
  A = 'add_directory',
  d = 'delete',
  r = 'rename',
  x = 'cut_to_clipboard',
  p = 'paste_from_clipboard',
  c = 'copy',
  m = 'move',
}

local function state_for_window(winid)
  local ok, manager = pcall(require, 'neo-tree.sources.manager')
  if not ok then return nil end
  return manager.get_state_for_window(winid)
end

local function is_overleaf_path(path)
  local sync = require('overleaf.sync')
  if not sync._sync_dir or not path then return false end

  local root = vim.fs.normalize(sync._sync_dir)
  path = vim.fs.normalize(path)
  return path == root or path:sub(1, #root + 1) == root .. '/'
end

local function is_overleaf_state(state)
  if not state or state.name ~= 'filesystem' then return false end
  local node = state.tree and state.tree:get_node() or nil
  return is_overleaf_path(node and node:get_id() or state.path)
end

local function filesystem_command(winid, command)
  local state = state_for_window(winid)
  if not state then return end
  require('neo-tree.sources.filesystem.commands')[command](state)
end

local function find_editor_window(tree_win)
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if
      winid ~= tree_win
      and vim.bo[bufnr].filetype ~= 'neo-tree'
      and vim.api.nvim_win_get_config(winid).relative == ''
    then
      return winid
    end
  end
end

local function open(winid)
  local state = state_for_window(winid)
  local node = state and state.tree and state.tree:get_node() or nil
  if is_overleaf_state(state) and node and node.type == 'file' then
    local editor_win = find_editor_window(winid)
    if editor_win then
      vim.api.nvim_set_current_win(editor_win)
    else
      vim.cmd('rightbelow vsplit')
    end

    if require('overleaf').open_synced_file(node:get_id()) then return end
    if vim.api.nvim_win_is_valid(winid) then vim.api.nvim_set_current_win(winid) end
  end
  filesystem_command(winid, 'open')
end

local function protect(winid, command)
  local state = state_for_window(winid)
  if is_overleaf_state(state) then
    vim.notify(
      'The Overleaf tree is a local mirror. Use :Overleaf new, mkdir, delete, rename, or upload for remote changes.',
      vim.log.levels.WARN,
      { title = 'Overleaf' }
    )
    return
  end
  filesystem_command(winid, command)
end

--- Add Overleaf behavior to a Neo-tree buffer without changing Neo-tree's setup.
---@param bufnr integer
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].filetype ~= 'neo-tree' then return end

  local winid = vim.fn.bufwinid(bufnr)
  if winid == -1 or not is_overleaf_state(state_for_window(winid)) then return end

  local map_opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set('n', '<CR>', function() open(vim.fn.bufwinid(bufnr)) end, map_opts)
  for lhs, command in pairs(protected_commands) do
    vim.keymap.set('n', lhs, function() protect(vim.fn.bufwinid(bufnr), command) end, map_opts)
  end

  local explorer_key = config.get().explorer_key
  if explorer_key then
    vim.keymap.set('n', explorer_key, function() require('overleaf').toggle_explorer() end, {
      buffer = bufnr,
      desc = 'Toggle Explorer',
      silent = true,
    })
  end
end

function M.attach_open_trees()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].filetype == 'neo-tree' and is_overleaf_state(state_for_window(winid)) then M.attach(bufnr) end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup('OverleafNeoTree', { clear = true })
  vim.api.nvim_create_autocmd('FileType', {
    group = group,
    pattern = 'neo-tree',
    callback = function(args)
      vim.schedule(function() M.attach(args.buf) end)
    end,
  })
end

return M
