local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')

local M = {}

function M.enabled()
  local opts = config.get()
  return opts.sioyek_inverse_search ~= false
    and type(opts.pdf_viewer) == 'string'
    and opts.pdf_viewer:lower() == 'sioyek'
end

local function context(pdf)
  local overleaf = require('overleaf')
  return {
    project = overleaf._state.project_id,
    instance = config.get().base_url,
    connection = overleaf._pdf_state.connection or 0,
    pdf = pdf,
  }
end

local function current(value)
  local overleaf = require('overleaf')
  return M.enabled() and overleaf._state.connected and vim.deep_equal(value, context(value.pdf))
end

--- Download the exact compile's map before enabling jumps or launching Sioyek.
function M.prepare(pdf, outputs, pdf_url, callback)
  if not M.enabled() or not require('overleaf')._state.connected then
    callback()
    return
  end
  local state = require('overleaf')._pdf_state
  local mapping = { context = context(pdf), ready = false }
  state.inverse = mapping
  local url
  for _, output in ipairs(outputs) do
    if output.path == 'output.synctex.gz' or output.path == 'output.synctex' then
      url = output.url
      if output.path == 'output.synctex.gz' then break end
    end
  end
  if url and not url:match('^https?://') then url = config.get().base_url .. url end
  bridge.request('downloadSynctex', {
    cookie = config.get().cookie,
    pdfPath = pdf,
    pdfUrl = pdf_url,
    url = url,
  }, function(err, result)
    if state ~= require('overleaf')._pdf_state or state.inverse ~= mapping or not current(mapping.context) then
      return
    end
    if err then
      config.log('warn', 'PDF opened without inverse search: SyncTeX download failed (%s)', err.message)
    else
      mapping.inputs = {}
      for _, file in ipairs(result.inputs or {}) do
        mapping.inputs[file] = true
      end
      mapping.ready = true
    end
    callback()
  end)
end

-- Sioyek 2.x uses Qt's command tokenizer, NOT a shell. Single-quote shell
-- escaping does not work; Qt represents an embedded quote with three quotes.
local function quote(value) return '"' .. value:gsub('"', '"""') .. '"' end

function M.command(pdf)
  local mapping = require('overleaf')._pdf_state.inverse
  if
    not M.enabled()
    or not mapping
    or not mapping.ready
    or mapping.context.pdf ~= pdf
    or not current(mapping.context)
  then
    return nil
  end
  local server = vim.v.servername
  if server == '' then
    local ok, address = pcall(vim.fn.serverstart)
    if not ok or not address or address == '' then
      config.log('warn', 'Cannot enable inverse search: Neovim could not start its RPC server')
      return nil
    end
    server = address
  end
  local node = vim.fn.exepath(config.get().node_path)
  if node == '' then
    config.log('warn', 'Cannot enable inverse search: Node executable not found')
    return nil
  end
  local encoded = vim.json
    .encode(mapping.context)
    :gsub('.', function(char) return string.format('%02x', char:byte()) end)
  local args = {
    node,
    config.plugin_root() .. '/node/inverse-search.js',
    vim.v.progpath,
    server,
    encoded,
    '%1',
    '%2',
    '%3',
  }
  return table.concat(vim.tbl_map(quote, args), ' ')
end

local function source(file)
  -- Overleaf builds under /compile. Keep directory components: matching only
  -- basenames can jump into the wrong chapter. Never open arbitrary disk files.
  local path = file:gsub('\\', '/')
  if path:sub(1, 9) == '/compile/' then path = path:sub(10) end
  local root = require('overleaf.sync')._sync_dir
  if root and path:sub(1, #root + 1) == root .. '/' then path = path:sub(#root + 2) end
  path = path:gsub('^%./', ''):gsub('/%./', '/')
  if path:sub(1, 1) == '/' or path:match('^%a:') or path:match('^%.%./') or path:find('/../', 1, true) then
    return nil
  end
  local entry = project.get_doc_by_path(path)
  return entry and entry.type == 'doc' and entry or nil
end

local function editor_window(buf)
  local current_win = vim.api.nvim_get_current_win()
  local candidates = { current_win }
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= current_win then candidates[#candidates + 1] = win end
  end
  local fallback
  for _, win in ipairs(candidates) do
    local winbuf = vim.api.nvim_win_get_buf(win)
    local kind = vim.bo[winbuf].buftype
    if
      vim.api.nvim_win_get_config(win).relative == ''
      and not vim.wo[win].winfixbuf
      and (kind == '' or kind == 'acwrite')
    then
      if winbuf == buf then return win end
      fallback = fallback or win
    end
  end
  if fallback then return fallback end
  -- No editor pane exists: create one without replacing a terminal or tree.
  vim.cmd('botright vsplit')
  vim.wo.winfixbuf = false
  return vim.api.nvim_get_current_win()
end

local function focus_terminal()
  if vim.fn.has('mac') ~= 1 then return end
  local apps = {
    iTerm = 'com.googlecode.iterm2',
    ['iTerm.app'] = 'com.googlecode.iterm2',
    ['Apple_Terminal'] = 'com.apple.Terminal',
    WezTerm = 'com.github.wez.wezterm',
    ghostty = 'com.mitchellh.ghostty',
    kitty = 'net.kovidgoyal.kitty',
    vscode = 'com.microsoft.VSCode',
  }
  local app = apps[vim.env.TERM_PROGRAM] or (vim.env.KITTY_WINDOW_ID and apps.kitty)
  if app then
    vim.fn.jobstart({ 'osascript', '-e', 'tell application id "' .. app .. '" to activate' }, { detach = true })
  end
end

--- RPC entry point. Accept data only from this connected PDF and project.
function M.receive(request)
  local mapping = require('overleaf')._pdf_state.inverse
  if
    type(request) ~= 'table'
    or type(request.context) ~= 'table'
    or type(request.file) ~= 'string'
    or type(request.line) ~= 'number'
    or request.line < 1
    or request.line ~= math.floor(request.line)
    or type(request.column) ~= 'number'
    or request.column < 0
    or request.column ~= math.floor(request.column)
    or not mapping
    or not mapping.ready
    or not current(request.context)
    or not vim.deep_equal(request.context, mapping.context)
    or not mapping.inputs[request.file]
  then
    return 0
  end
  local entry = source(request.file)
  if not entry then return 0 end
  local token = {}
  M._click = token
  local function valid() return M._click == token and current(request.context) end
  vim.schedule(function()
    if not valid() then return end
    require('overleaf').open_document(entry.id, entry.path, nil, {
      display = false,
      on_complete = function(doc, err)
        if not valid() then return end
        if err then
          config.log('warn', 'Inverse search could not open %s: %s', entry.path, err.message)
          return
        end
        if not doc or not doc.bufnr or not vim.api.nvim_buf_is_valid(doc.bufnr) then return end
        local win = editor_window(doc.bufnr)
        vim.cmd('stopinsert')
        vim.api.nvim_set_current_win(win)
        vim.api.nvim_win_set_buf(win, doc.bufnr)
        local row = math.min(request.line, vim.api.nvim_buf_line_count(doc.bufnr))
        local line = vim.api.nvim_buf_get_lines(doc.bufnr, row - 1, row, false)[1] or ''
        local column = math.min(math.max(0, request.column - 1), #line)
        -- SyncTeX can omit the column; do not land inside a UTF-8 codepoint.
        while column > 0 and line:byte(column + 1) and line:byte(column + 1) >= 128 and line:byte(column + 1) < 192 do
          column = column - 1
        end
        vim.api.nvim_win_set_cursor(win, { row, column })
        vim.cmd('normal! zvzz')
        require('overleaf.cursors').publish_position(true)
        focus_terminal()
      end,
    })
  end)
  return 1
end

return M
