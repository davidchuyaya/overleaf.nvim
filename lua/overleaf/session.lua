--- Remember document tabs without persisting live buffers in editor sessions.
local config = require('overleaf.config')
local project = require('overleaf.project')
local M = {}
local serial = 0

local function identity(state)
  if not state.project_id then return end
  local base = config.get().base_url:gsub('/+$', '')
  local root = M._storage_dir or (vim.fn.stdpath('data') .. '/overleaf.nvim/sessions')
  return root .. '/' .. vim.fn.sha256(vim.json.encode({ base, state.project_id })) .. '.json', vim.fn.sha256(base)
end

local function position(bufnr)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return vim.api.nvim_win_get_cursor(win) end
  end
  local mark = vim.api.nvim_buf_get_mark(bufnr, '"')
  return { math.max(1, mark[1]), mark[2] }
end

function M.save(state)
  if config.get().restore_session == false then return end
  local path, instance = identity(state)
  if not path then return end
  local owned, files, seen = {}, {}, {}
  for _, doc in pairs(state.documents) do
    local buf = doc.bufnr
    if buf and vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buflisted then
      owned[buf] = doc
    end
  end
  local function add(buf)
    if not owned[buf] or seen[buf] then return end
    seen[buf] = true
    local doc = owned[buf]
    files[#files + 1] = { id = doc.doc_id, path = doc.path, cursor = position(buf) }
  end
  -- Preserve the editor's buffer-tab order when available, without requiring
  -- AstroNvim. Other tracked, listed files follow in native buffer order.
  for _, buf in ipairs(vim.t.bufs or {}) do
    add(buf)
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    add(buf)
  end
  local current = owned[vim.api.nvim_get_current_buf()]
  if not current then
    local previous = vim.fn.win_getid(vim.fn.winnr('#'))
    if previous ~= 0 then current = owned[vim.api.nvim_win_get_buf(previous)] end
  end
  if not current then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      current = owned[vim.api.nvim_win_get_buf(win)]
      if current then break end
    end
  end
  local payload = vim.json.encode({
    version = 1,
    instance = instance,
    project_id = state.project_id,
    files = files,
    active = current and current.doc_id or nil,
  })
  local made, mkdir_error = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ':h'), 'p', 448)
  if not made then
    config.log('warn', 'Could not remember Overleaf tabs: %s', tostring(mkdir_error))
    return false
  end
  serial = serial + 1
  local temp = path .. '.tmp-' .. vim.fn.getpid() .. '-' .. serial
  local fd, err = vim.uv.fs_open(temp, 'w', 384)
  if fd then
    local written
    written, err = vim.uv.fs_write(fd, payload, 0)
    vim.uv.fs_close(fd)
    if written == #payload then
      local ok
      ok, err = vim.uv.fs_rename(temp, path)
      if ok then return true end
    end
    vim.uv.fs_unlink(temp)
  end
  config.log('warn', 'Could not remember Overleaf tabs: %s', tostring(err))
  return false
end

function M.load(state)
  local path, instance = identity(state)
  if not path then return end
  local file = io.open(path, 'r')
  if not file then return end
  local data = file:read('*a')
  file:close()
  local ok, saved = pcall(vim.json.decode, data)
  if
    not ok
    or type(saved) ~= 'table'
    or saved.version ~= 1
    or saved.instance ~= instance
    or saved.project_id ~= state.project_id
    or type(saved.files) ~= 'table'
  then
    return
  end
  return saved
end

local function editor_window()
  local current = vim.api.nvim_get_current_win()
  local wins = { current }
  vim.list_extend(wins, vim.api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    local kind = vim.bo[buf].buftype
    if
      vim.api.nvim_win_get_config(win).relative == ''
      and (kind == '' or kind == 'acwrite')
      and not vim.wo[win].winfixbuf
    then
      return win
    end
  end
end

function M.restore(overleaf, on_complete)
  if config.get().restore_session == false or not overleaf._state.connected then
    if on_complete then on_complete() end
    return
  end
  local state = overleaf._state
  local saved = M.load(state)
  if not saved then
    if on_complete then on_complete() end
    return
  end
  local documents, project_id = state.documents, state.project_id
  local token = {}
  M._restore_token = token
  local function valid()
    return M._restore_token == token
      and overleaf._state == state
      and state.connected
      and state.project_id == project_id
      and state.documents == documents
  end
  local target = editor_window()
  local tabpage = vim.api.nvim_get_current_tabpage()
  local start_win = vim.api.nvim_get_current_win()
  local start_buf = target and vim.api.nvim_win_get_buf(target)
  local restored, active, seen = {}, nil, {}
  local function display_restored()
    if not valid() then return end
    if vim.api.nvim_tabpage_is_valid(tabpage) and vim.t[tabpage].bufs then
      local order = {}
      for _, buf in ipairs(vim.t[tabpage].bufs) do
        if vim.api.nvim_buf_is_valid(buf) and not seen[buf] then order[#order + 1] = buf end
      end
      vim.list_extend(order, restored)
      vim.t[tabpage].bufs = order
    end
    local buf = active or restored[1]
    if not buf or vim.api.nvim_get_current_win() ~= start_win then return end
    if target and vim.api.nvim_win_is_valid(target) then
      -- Loading tabs must not overwrite a file the user switched to or edited
      -- while the asynchronous joins were in progress.
      if vim.api.nvim_win_get_buf(target) ~= start_buf or vim.bo[start_buf].modified then return end
    else
      -- No editor split exists (e.g. only the explorer is open).
      vim.cmd('rightbelow vsplit')
      target = vim.api.nvim_get_current_win()
    end
    vim.api.nvim_win_set_buf(target, buf)
    vim.api.nvim_set_current_win(target)
    vim.api.nvim_win_set_cursor(target, vim.api.nvim_buf_get_mark(buf, '"'))
  end
  local function finish()
    if not valid() then return end
    display_restored()
    -- Mirror initialization must continue even if there are no remembered files
    -- or the user changed focus while the joins were in progress.
    if on_complete then on_complete() end
  end
  local index = 0
  local function next_file()
    if not valid() then return end
    index = index + 1
    local item = saved.files[index]
    if not item then
      finish()
      return
    end
    local entry = type(item) == 'table' and (project.get_doc_by_id(item.id) or project.get_doc_by_path(item.path))
    if not entry or entry.type ~= 'doc' then
      vim.schedule(next_file)
      return
    end
    overleaf.open_document(entry.id, entry.path, nil, {
      display = false,
      on_complete = function(doc)
        if not valid() then return end
        if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) and not seen[doc.bufnr] then
          local buf = doc.bufnr
          seen[buf] = true
          restored[#restored + 1] = buf
          local cursor = type(item.cursor) == 'table' and item.cursor or {}
          local row = math.max(1, math.min(math.floor(tonumber(cursor[1]) or 1), vim.api.nvim_buf_line_count(buf)))
          local text = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ''
          local col = math.max(0, math.min(math.floor(tonumber(cursor[2]) or 0), #text))
          vim.api.nvim_buf_set_mark(buf, '"', row, col, {})
          -- Hidden buffers have no editor-window cursor to restore yet. Apply
          -- their saved mark once when they are actually displayed; subsequent
          -- entries retain the user's normal, newer cursor position.
          local group = vim.api.nvim_create_augroup('OverleafSessionBuffer' .. buf, { clear = true })
          vim.api.nvim_create_autocmd('BufWinEnter', {
            buffer = buf,
            group = group,
            once = true,
            callback = function()
              local mark = vim.api.nvim_buf_get_mark(buf, '"')
              local line = math.max(1, math.min(mark[1], vim.api.nvim_buf_line_count(buf)))
              local current = vim.api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ''
              for _, win in ipairs(vim.fn.win_findbuf(buf)) do
                vim.api.nvim_win_set_cursor(win, { line, math.min(mark[2], #current) })
              end
            end,
          })
          if item.id == saved.active then active = buf end
        end
        -- Avoid recursion for already-open files and synchronous test bridges.
        vim.schedule(next_file)
      end,
    })
  end
  next_file()
end

function M.cancel() M._restore_token = nil end

return M
