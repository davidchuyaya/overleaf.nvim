local config = require('overleaf.config')

local M = {}

local protected_commands = {
  x = 'cut_to_clipboard',
  p = 'paste_from_clipboard',
  c = 'copy',
  m = 'move',
}

local function state_for_window(winid)
  if type(winid) ~= 'number' or not vim.api.nvim_win_is_valid(winid) then return nil end
  local ok, manager = pcall(require, 'neo-tree.sources.manager')
  if not ok then return nil end
  local state_ok, state = pcall(manager.get_state_for_window, winid)
  return state_ok and state or nil
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
  return is_overleaf_path(state.path)
end

local function selected_node(state)
  if not state or not state.tree then return nil end
  local ok, node = pcall(state.tree.get_node, state.tree)
  return ok and node or nil
end

local function entry_for_node(node)
  if not node then return nil end
  local relative = require('overleaf.sync').parse_buf_name(vim.fs.normalize(node:get_id()))
  if not relative or relative == '' then return nil end
  local project = require('overleaf.project')
  local folder_path = relative:sub(-1) == '/' and relative or relative .. '/'
  return project.get_doc_by_path(relative) or project.get_doc_by_path(folder_path)
end

local function parent_folder_id(node)
  if not node then return nil end
  local relative = require('overleaf.sync').parse_buf_name(vim.fs.normalize(node:get_id()))
  if not relative or relative == '' then return nil end

  local folder_path
  if node.type == 'directory' then
    folder_path = relative:sub(-1) == '/' and relative or relative .. '/'
  else
    folder_path = relative:match('^(.*/)')
  end
  if not folder_path then return nil end

  local entry = require('overleaf.project').get_doc_by_path(folder_path)
  return entry and entry.id or nil
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

local function open_path(winid, path)
  if not is_overleaf_path(path) then return false end
  local editor_win = find_editor_window(winid)
  if editor_win then
    vim.api.nvim_set_current_win(editor_win)
  else
    vim.cmd('rightbelow vsplit')
  end

  if require('overleaf').open_synced_file(path) then return true end
  if type(winid) == 'number' and vim.api.nvim_win_is_valid(winid) then vim.api.nvim_set_current_win(winid) end
  return false
end

local function open(winid)
  local state = state_for_window(winid)
  local node = selected_node(state)
  if is_overleaf_state(state) and node and node.type == 'file' and open_path(winid, node:get_id()) then return end
  filesystem_command(winid, 'open')
end

local function create(winid, directory)
  local state = state_for_window(winid)
  if not is_overleaf_state(state) then
    filesystem_command(winid, directory and 'add_directory' or 'add')
    return
  end

  local parent_id = parent_folder_id(selected_node(state))
  if directory then
    require('overleaf').create_folder(nil, parent_id)
  else
    require('overleaf').create_doc(nil, parent_id)
  end
end

local function mutate(winid, action)
  local state = state_for_window(winid)
  if not is_overleaf_state(state) then
    filesystem_command(winid, action)
    return
  end

  local entry = entry_for_node(selected_node(state))
  if not entry then
    config.log('warn', 'The Overleaf project root cannot be renamed or deleted')
    return
  end
  require('overleaf')[action == 'delete' and 'delete_entity' or 'rename_entity'](entry)
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
  vim.keymap.set('n', 'a', function() create(vim.fn.bufwinid(bufnr), false) end, map_opts)
  vim.keymap.set('n', 'A', function() create(vim.fn.bufwinid(bufnr), true) end, map_opts)
  vim.keymap.set('n', 'd', function() mutate(vim.fn.bufwinid(bufnr), 'delete') end, map_opts)
  vim.keymap.set('n', 'r', function() mutate(vim.fn.bufwinid(bufnr), 'rename') end, map_opts)
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

function M.refresh()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local state = state_for_window(winid)
    if is_overleaf_state(state) then pcall(require('neo-tree.sources.filesystem.commands').refresh, state) end
  end
end

function M.attach_open_trees()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if vim.bo[bufnr].filetype == 'neo-tree' and is_overleaf_state(state_for_window(winid)) then M.attach(bufnr) end
  end
end

function M.setup()
  -- FileType runs before Neo-tree acquires its window and installs mappings.
  -- Filesystem scans are asynchronous, so even a scheduled FileType handler
  -- (or a callback after command.execute) can be overwritten by the renderer.
  -- AFTER_RENDER also runs for reused buffers when the explorer is reopened.
  local ok, events = pcall(require, 'neo-tree.events')
  if ok then
    local subscription = {
      event = events.AFTER_RENDER,
      id = 'overleaf.neo_tree.attach',
      handler = function(state)
        if state and state.bufnr and is_overleaf_state(state) then M.attach(state.bufnr) end
      end,
    }
    events.unsubscribe(subscription)
    events.subscribe(subscription)

    -- Also intercept Neo-tree's default edit command. This prevents a local
    -- mirror from being opened even if another plugin replaces our Enter map.
    local open_subscription = {
      event = events.FILE_OPEN_REQUESTED,
      id = 'overleaf.neo_tree.open',
      handler = function(data)
        if not data or (data.open_cmd ~= 'edit' and data.open_cmd ~= 'b') then return end
        if not data.state or data.state.name ~= 'filesystem' then return end
        if open_path(data.state.winid, data.path) then return { handled = true } end
      end,
    }
    events.unsubscribe(open_subscription)
    events.subscribe(open_subscription)
  end

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
