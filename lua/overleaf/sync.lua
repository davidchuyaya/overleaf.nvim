--- Local file sync for external tool integration (e.g., Claude Code)
--- Mirrors Overleaf documents to disk and watches for external changes.
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')

local M = {}

M._sync_dir = nil
M._watchers = {} -- path -> {handle, doc_id}
M._write_timers = {} -- doc_id -> timer
M._self_writes = {} -- path -> {content, token}, catches delayed filesystem events
M._disk_content = {} -- last observed contents, protects edits awaiting watcher delivery

--- Start sync for a project. Creates the sync directory.
---@param project_name string
function M.start(project_name)
  local sync_dir = config.get().sync_dir
  if not sync_dir then return end

  -- Expand ~ and resolve
  sync_dir = vim.fn.expand(sync_dir)

  -- Use project subdirectory
  M._sync_dir = sync_dir .. '/' .. project_name:gsub('[^%w%-_%.%s]', '_')
  vim.fn.mkdir(M._sync_dir, 'p')
  -- Neovim resolves symlinks in buffer names (e.g. /var -> /private/var on
  -- macOS), so use the same canonical root when recognizing mirror buffers.
  M._sync_dir = (vim.uv or vim.loop).fs_realpath(M._sync_dir) or vim.fs.normalize(M._sync_dir)

  config.log('info', 'File sync: %s', M._sync_dir)
end

--- Stop all watchers and timers
function M.stop()
  for _, w in pairs(M._watchers) do
    if w.handle and not w.handle:is_closing() then
      w.handle:stop()
      w.handle:close()
    end
  end
  M._watchers = {}

  for _, timer in pairs(M._write_timers) do
    vim.fn.timer_stop(timer)
  end
  M._write_timers = {}
  M._self_writes = {}
  M._disk_content = {}

  M._sync_dir = nil
end

--- Get the local file path for a document
---@param doc_path string Overleaf document path
---@return string|nil
function M.file_path(doc_path)
  if not M._sync_dir then return nil end
  return M._sync_dir .. '/' .. doc_path
end

--- Create a path in the local mirror after a successful remote create.
---@param doc_path string
---@param directory? boolean
function M.create_path(doc_path, directory)
  local path = M.file_path(doc_path)
  if not path then return end
  if directory then
    vim.fn.mkdir(path, 'p')
    return
  end
  if vim.fn.filereadable(path) == 1 then return end
  vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
  local file = io.open(path, 'w')
  if file then file:close() end
end

local function stop_path_watchers(path)
  for watched_path, watcher in pairs(M._watchers) do
    if watched_path == path or watched_path:sub(1, #path + 1) == path .. '/' then
      if watcher.handle and not watcher.handle:is_closing() then
        watcher.handle:stop()
        watcher.handle:close()
      end
      if watcher.doc_id and M._write_timers[watcher.doc_id] then
        vim.fn.timer_stop(M._write_timers[watcher.doc_id])
        M._write_timers[watcher.doc_id] = nil
      end
      M._watchers[watched_path] = nil
      M._self_writes[watched_path] = nil
      M._disk_content[watched_path] = nil
    end
  end
end

--- Remove a remote-deleted path from the local mirror.
---@param doc_path string
function M.remove_path(doc_path)
  local path = M.file_path(doc_path:gsub('/$', ''))
  if not path then return end
  stop_path_watchers(path)
  vim.fn.delete(path, 'rf')
end

--- Rename a path in the local mirror after the remote rename succeeds.
---@param old_doc_path string
---@param new_doc_path string
function M.rename_path(old_doc_path, new_doc_path)
  local old_path = M.file_path(old_doc_path:gsub('/$', ''))
  local new_path = M.file_path(new_doc_path:gsub('/$', ''))
  if not old_path or not new_path or old_path == new_path then return end
  stop_path_watchers(old_path)
  vim.fn.mkdir(vim.fn.fnamemodify(new_path, ':h'), 'p')
  local ok, err = os.rename(old_path, new_path)
  if not ok then config.log('warn', 'Could not rename mirror path %s: %s', old_doc_path, tostring(err)) end
end

--- Get the buffer name for a document.
--- Returns the real file path when sync_dir is enabled, otherwise overleaf:// URI.
---@param doc_path string Overleaf document path
---@return string
function M.buf_name(doc_path)
  if M._sync_dir then return M._sync_dir .. '/' .. doc_path end
  return 'overleaf://' .. doc_path
end

--- Check if a buffer name belongs to an Overleaf buffer (either URI or sync path)
---@param bufname string
---@return string|nil doc_path the document path if it's an Overleaf buffer
function M.parse_buf_name(bufname)
  if bufname:match('^overleaf://') then return bufname:gsub('^overleaf://', '') end
  if M._sync_dir and bufname:sub(1, #M._sync_dir + 1) == M._sync_dir .. '/' then
    return bufname:sub(#M._sync_dir + 2) -- +2 for the trailing /
  end
  return nil
end

--- Write a document's content to disk immediately
---@param doc table Document instance (needs .path, .content)
function M.write_doc(doc)
  if not M._sync_dir then return end
  if not doc.content then return end

  local path = M._sync_dir .. '/' .. doc.path

  -- An agent may have written since our last read, before its watcher event
  -- arrives. Import that edit rather than overwriting it with a mirror flush.
  local known = M._disk_content[path]
  if known ~= nil then
    local existing = io.open(path, 'r')
    if existing then
      local disk = existing:read('*a')
      existing:close()
      if disk ~= known then
        M._on_file_changed(path, doc)
        return
      end
    end
  end

  -- Ensure parent directory exists
  local dir = vim.fn.fnamemodify(path, ':h')
  vim.fn.mkdir(dir, 'p')

  -- Identify our own events by content, not a timed window that could suppress
  -- another writer's edits too.
  local token = {}
  local content = doc.content

  local f = io.open(path, 'w')
  if f then
    f:write(content)
    f:close()
    M._disk_content[path] = content
    M._self_writes[path] = { content = content, token = token }
    vim.defer_fn(function()
      local own = M._self_writes[path]
      if own and own.token == token then M._self_writes[path] = nil end
    end, 5000)
  end
end

--- Schedule a debounced write to disk (call after content changes)
---@param doc table Document instance
function M.schedule_write(doc)
  if not M._sync_dir then return end

  if M._write_timers[doc.doc_id] then vim.fn.timer_stop(M._write_timers[doc.doc_id]) end

  M._write_timers[doc.doc_id] = vim.fn.timer_start(500, function()
    M._write_timers[doc.doc_id] = nil
    M.write_doc(doc)
  end)
end

--- Start watching a file for external changes
---@param doc table Document instance
function M.watch(doc)
  if not M._sync_dir then return end

  local path = M._sync_dir .. '/' .. doc.path

  -- Stop existing watcher for this path
  if M._watchers[path] then
    local old = M._watchers[path]
    if old.handle and not old.handle:is_closing() then
      old.handle:stop()
      old.handle:close()
    end
  end

  local handle = vim.uv.new_fs_event()
  if not handle then return end

  local watcher = { handle = handle, doc_id = doc.doc_id }
  M._watchers[path] = watcher

  handle:start(path, {}, function(err, _, _)
    if err then return end
    if M._watchers[path] ~= watcher then return end
    -- Do not suppress every edit during a timed writing window: an agent
    -- can write then too. _on_file_changed compares actual contents instead.

    vim.schedule(function()
      if M._watchers[path] == watcher then M._on_file_changed(path, doc) end
    end)
  end)
end

--- Stop watching a specific document's file
---@param doc table Document instance
function M.unwatch(doc)
  if not M._sync_dir then return end

  local path = M._sync_dir .. '/' .. doc.path
  local w = M._watchers[path]
  if w then
    if w.handle and not w.handle:is_closing() then
      w.handle:stop()
      w.handle:close()
    end
    M._watchers[path] = nil
  end
end

--- Handle external file change
---@param path string local file path
---@param doc table Document instance
function M._on_file_changed(path, doc)
  local f = io.open(path, 'r')
  if not f then return end
  local new_content = f:read('*a')
  f:close()

  -- A filesystem notification can arrive well after write_doc() completed.
  -- Compare contents so our own older mirror write is never mistaken for an
  -- external edit and synced back over newer in-memory text.
  local own = M._self_writes[path]
  if own then
    if new_content == own.content then return end
    M._self_writes[path] = nil
  end
  -- Repeated/delayed notifications for an already observed disk snapshot
  -- must not roll back newer buffer edits, even after the own-write marker
  -- expires.
  if new_content == M._disk_content[path] then return end

  if (doc._remote_apply_pending or 0) > 0 then
    vim.schedule(function() M._on_file_changed(path, doc) end)
    return
  end
  M._disk_content[path] = new_content

  -- No change
  if new_content == doc.content then return end

  config.log('debug', 'External change: %s', doc.path)

  if doc.joined and doc.bufnr and vim.api.nvim_buf_is_loaded(doc.bufnr) then
    -- Doc is open in Neovim: replace buffer content (triggers on_bytes → OT)
    local lines = vim.split(new_content, '\n', { plain = true })
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, lines)
  else
    -- Doc is NOT open: join, send OT ops directly, leave
    M._sync_closed_doc(doc, new_content)
  end
end

--- Sync a changed mirror through the same confirmed OT path as live buffers.
---@param doc table Document instance
---@param new_content string new file content
function M._sync_closed_doc(doc, new_content)
  doc._external_target = new_content
  require('overleaf.statusline').changed()
  local function submit()
    local target = doc._external_target
    doc._external_target = nil
    if target == doc.content then return end
    -- Compose with any unconfirmed local edit instead of issuing a second,
    -- independent applyOtUpdate request that could consume its ACK.
    local ops = {}
    if #doc.content > 0 then table.insert(ops, { p = 0, d = doc.content }) end
    if #target > 0 then table.insert(ops, { p = 0, i = target }) end
    doc.content = target
    doc:submit_op(ops)
    doc:flush()
  end
  if doc.joined and not doc._rejoining then
    submit()
  elseif not doc._external_joining and not doc._rejoining then
    doc._external_joining = true
    doc:join(function(err)
      doc._external_joining = nil
      if err then
        doc._sync_uncertain = true
        require('overleaf.statusline').changed()
      else
        -- Keep the document joined: its applied ACK and subsequent remote edits
        -- must be observed even though no Neovim buffer is currently displayed.
        submit()
      end
      local open = doc._external_open_request
      doc._external_open_request = nil
      local overleaf = require('overleaf')
      if open and overleaf._state.connected and overleaf._state.documents[doc.doc_id] == doc then
        overleaf.open_document(doc.doc_id, doc.path, open.callback, open.opts)
      end
    end)
  end
end

--- Download a binary file (image, etc.) to the sync directory
---@param entry table project tree entry {id, name, path, type='file'}
---@param project_id string
function M._download_file(entry, project_id)
  if not M._sync_dir then return end

  local dest = M._sync_dir .. '/' .. entry.path

  -- Skip if file already exists on disk (binary files don't change often)
  if vim.fn.filereadable(dest) == 1 then return end

  local dir = vim.fn.fnamemodify(dest, ':h')
  vim.fn.mkdir(dir, 'p')

  bridge.request('downloadFile', {
    cookie = config.get().cookie,
    projectId = project_id,
    fileId = entry.id,
    fileName = entry.name,
  }, function(err, result)
    if err then
      config.log('debug', 'Download skip %s: %s', entry.path, err.message)
      return
    end

    -- Copy from temp to sync dir
    local src = result.path
    local ok, copy_err = pcall(function()
      local src_f = io.open(src, 'rb')
      if not src_f then error('Cannot read ' .. src) end
      local data = src_f:read('*a')
      src_f:close()

      local dest_f = io.open(dest, 'wb')
      if not dest_f then error('Cannot write ' .. dest) end
      dest_f:write(data)
      dest_f:close()
    end)

    if ok then
      config.log('debug', 'Downloaded: %s', entry.path)
    else
      config.log('debug', 'Copy failed %s: %s', entry.path, tostring(copy_err))
    end
  end)
end

--- Sync all project documents and files to disk
---@param state table M._state from init.lua
---@param project_tree table[] project._project_tree
---@param callback function|nil called when done
function M.sync_all(state, project_tree, callback)
  if not M._sync_dir then
    if callback then callback() end
    return
  end

  local docs = {}
  local files = {}
  for _, entry in ipairs(project_tree) do
    if entry.type == 'doc' then
      table.insert(docs, entry)
    elseif entry.type == 'file' then
      table.insert(files, entry)
    elseif entry.type == 'folder' then
      -- Ensure folder exists on disk
      vim.fn.mkdir(M._sync_dir .. '/' .. entry.path, 'p')
    end
  end

  -- Download binary files (async, fire-and-forget)
  local project_id = state.project_id
  if project_id and #files > 0 then
    config.log('info', 'Downloading %d binary file(s)...', #files)
    for _, entry in ipairs(files) do
      M._download_file(entry, project_id)
    end
  end

  -- Sync text documents
  if #docs == 0 then
    if callback then callback() end
    return
  end

  config.log('info', 'Syncing %d document(s) to disk...', #docs)

  local remaining = #docs
  local function on_done()
    remaining = remaining - 1
    if remaining <= 0 then
      config.log('info', 'Sync complete: %s', M._sync_dir)
      if callback then callback() end
    end
  end

  for _, entry in ipairs(docs) do
    local doc_id = entry.id
    local doc_path = entry.path

    -- Check if already open
    local existing = state.documents[doc_id]
    if existing and existing.content then
      -- Already joined, just write
      M.write_doc(existing)
      M.watch(existing)
      on_done()
    else
      -- Need to join, write, leave
      bridge.request('joinDoc', { docId = doc_id }, function(err, result)
        if err then
          config.log('debug', 'Sync skip %s: %s', doc_path, err.message)
          on_done()
          return
        end

        local content = table.concat(result.lines, '\n')

        -- Create a lightweight doc object for writing and watching
        local doc = state.documents[doc_id]
        if not doc then
          local Document = require('overleaf.document')
          doc = Document.new(doc_id, doc_path)
          doc.content = content
          doc.server_content = content
          doc.version = result.version
          -- Store it so watchers can find it
          state.documents[doc_id] = doc
        end

        M.write_doc(doc)
        M.watch(doc)

        -- Leave if no buffer (not opened by user)
        if not doc.bufnr then
          doc.joined = false
          bridge.request('leaveDoc', { docId = doc_id }, function() on_done() end)
        else
          on_done()
        end
      end)
    end
  end
end

--- Re-sync: read all disk files and push changes to Overleaf
---@param state table M._state from init.lua
function M.import_all(state)
  if not M._sync_dir then
    config.log('warn', 'File sync not enabled (set sync_dir in config)')
    return
  end

  local changed = 0
  for _, doc in pairs(state.documents) do
    local path = M._sync_dir .. '/' .. doc.path
    local f = io.open(path, 'r')
    if f then
      local disk_content = f:read('*a')
      f:close()

      if disk_content ~= doc.content then
        changed = changed + 1
        if doc.joined and doc.bufnr and vim.api.nvim_buf_is_loaded(doc.bufnr) then
          local lines = vim.split(disk_content, '\n', { plain = true })
          vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, lines)
        else
          M._sync_closed_doc(doc, disk_content)
        end
      end
    end
  end

  if changed == 0 then
    config.log('info', 'No external changes detected')
  else
    config.log('info', 'Importing %d changed file(s)', changed)
  end
end

--- Export: write all open documents to disk
---@param state table M._state from init.lua
function M.export_all(state)
  if not M._sync_dir then
    config.log('warn', 'File sync not enabled (set sync_dir in config)')
    return
  end

  local count = 0
  for _, doc in pairs(state.documents) do
    if doc.content then
      M.write_doc(doc)
      count = count + 1
    end
  end

  config.log('info', 'Exported %d document(s) to %s', count, M._sync_dir)
end

return M
