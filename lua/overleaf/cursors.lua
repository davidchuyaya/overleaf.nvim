local _ = require('overleaf.config')

local M = {}

M._collaborators = {} -- user_id -> { name, doc_id, row, col, color_idx }
M._ns = vim.api.nvim_create_namespace('overleaf_cursors')

-- Color palette for collaborator cursors
local COLORS = {
  { fg = '#ffffff', bg = '#e06c75' }, -- red
  { fg = '#ffffff', bg = '#61afef' }, -- blue
  { fg = '#ffffff', bg = '#98c379' }, -- green
  { fg = '#ffffff', bg = '#e5c07b' }, -- yellow
  { fg = '#ffffff', bg = '#c678dd' }, -- purple
}

local _hl_created = false
local _color_counter = 0

-- Browser cursor columns count UTF-16 code units; Neovim columns count bytes.
function M.byte_to_utf16(text, col)
  local units = 0
  for i = 1, math.min(col, #text) do
    local b = text:byte(i)
    if b < 128 or b >= 192 then units = units + (b >= 240 and 2 or 1) end
  end
  return units
end

local function utf16_to_byte(text, col)
  local byte, units = 0, 0
  while byte < #text do
    local b = text:byte(byte + 1)
    local size = b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4
    local width = size == 4 and 2 or 1
    if units + width > col then break end
    byte, units = byte + size, units + width
  end
  return byte
end

function M.load_collaborators()
  local state = require('overleaf')._state
  if not state.connected then return end
  local public_id = state.public_id
  require('overleaf.bridge').request('getConnectedUsers', {}, function(err, result)
    if not state.connected or state.public_id ~= public_id then return end
    if err then
      require('overleaf.config').log('debug', 'Collaborator lookup failed: %s', err.message or '?')
      return
    end
    for _, user in ipairs(result.users or {}) do
      local id = user.client_id or user.id
      -- A live event received during this request is newer than the snapshot.
      if id and not M._collaborators[id] then
        local position = user.cursorData or {}
        local name = vim.trim((user.first_name or '') .. ' ' .. (user.last_name or ''))
        M.on_client_updated({
          id = id,
          name = name ~= '' and name or user.name,
          email = user.email,
          doc_id = position.doc_id,
          row = position.row,
          column = position.column,
        })
      end
    end
  end)
end

function M.render_document(doc_id)
  for id, collab in pairs(M._collaborators) do
    if collab.doc_id == doc_id then M._render_cursor(id, collab) end
  end
end

function M.publish_position(force)
  local state = require('overleaf')._state
  if not state.connected then return end
  local bufnr = vim.api.nvim_get_current_buf()
  local position = { doc_id = vim.NIL }
  for _, doc in pairs(state.documents) do
    if doc.bufnr == bufnr and doc.joined then
      local cursor = vim.api.nvim_win_get_cursor(0)
      local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
      position = { doc_id = doc.doc_id, row = cursor[1] - 1, column = M.byte_to_utf16(line, cursor[2]) }
      break
    end
  end
  if not force and vim.deep_equal(position, M._last_position) then return end
  M._last_position = position
  require('overleaf.bridge').request('updatePosition', position, function(err)
    if err then
      M._last_position = nil
      require('overleaf.config').log('debug', 'Cursor update failed: %s', err.message or '?')
    end
  end)
end

function M.setup()
  local group = vim.api.nvim_create_augroup('OverleafCursorTracking', { clear = true })
  vim.api.nvim_create_autocmd(
    { 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinEnter', 'TextChanged', 'TextChangedI' },
    {
      group = group,
      callback = function()
        if M._publish_timer or not require('overleaf')._state.connected then return end
        -- Throttle, rather than postpone indefinitely while the cursor moves.
        M._publish_timer = vim.fn.timer_start(100, function()
          M._publish_timer = nil
          M.publish_position()
        end)
      end,
    }
  )
end

local function ensure_highlights()
  if _hl_created then return end
  _hl_created = true
  for i, color in ipairs(COLORS) do
    vim.api.nvim_set_hl(0, 'OverleafCursor' .. i, { fg = color.fg, bg = color.bg, bold = true })
    vim.api.nvim_set_hl(0, 'OverleafCursorName' .. i, { fg = color.bg, italic = true })
  end
end

local function assign_color()
  _color_counter = _color_counter + 1
  return ((_color_counter - 1) % #COLORS) + 1
end

--- Find bufnr for a doc_id from the overleaf state
local function find_bufnr(doc_id)
  local state = require('overleaf')._state
  local doc = state.documents[doc_id]
  if doc and doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then return doc.bufnr end
  return nil
end

--- Handle clientTracking.clientUpdated event
function M.on_client_updated(data)
  if not data or not data.id then return end
  if data.id == require('overleaf')._state.public_id then return end

  ensure_highlights()

  local user_id = data.id
  local collab = M._collaborators[user_id]

  if not collab then
    collab = {
      name = data.name and data.name ~= '' and data.name or data.email or 'User',
      color_idx = assign_color(),
    }
    M._collaborators[user_id] = collab
  end

  if collab.doc_id and collab.doc_id ~= data.doc_id then
    local old_buf = find_bufnr(collab.doc_id)
    if old_buf then pcall(vim.api.nvim_buf_del_extmark, old_buf, M._ns, M._get_mark_id(user_id)) end
  end

  -- Update position
  if data.name and data.name ~= '' then collab.name = data.name end
  collab.doc_id = data.doc_id ~= vim.NIL and data.doc_id or nil
  collab.row = data.row or 0
  collab.col = data.column or 0

  -- Render cursor
  M._render_cursor(user_id, collab)
end

--- Handle clientTracking.clientDisconnected event
function M.on_client_disconnected(data)
  if not data or not data.id then return end

  local user_id = data.id
  local collab = M._collaborators[user_id]
  if not collab then return end

  -- Clear extmark
  if collab.doc_id then
    local bufnr = find_bufnr(collab.doc_id)
    if bufnr then
      vim.api.nvim_buf_clear_namespace(bufnr, M._ns, 0, -1)
      -- Re-render remaining cursors on this buffer
      for uid, c in pairs(M._collaborators) do
        if uid ~= user_id and c.doc_id == collab.doc_id then M._render_cursor(uid, c) end
      end
    end
  end

  M._collaborators[user_id] = nil
end

--- Render a single collaborator cursor as extmark
function M._render_cursor(user_id, collab)
  if not collab.doc_id then return end

  local bufnr = find_bufnr(collab.doc_id)
  if not bufnr or not vim.api.nvim_buf_is_loaded(bufnr) then return end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.max(0, math.min(collab.row, line_count - 1))

  -- Clamp column to line length
  local line_text = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
  local col = utf16_to_byte(line_text, math.max(0, collab.col))

  local hl_cursor = 'OverleafCursor' .. collab.color_idx
  local hl_name = 'OverleafCursorName' .. collab.color_idx

  local mark_id = M._get_mark_id(user_id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, M._ns, mark_id)

  -- Place extmark at exact row:col with a highlighted cursor character
  local end_col = col
  if col < #line_text then
    local b = line_text:byte(col + 1)
    end_col = math.min(col + (b < 128 and 1 or b < 224 and 2 or b < 240 and 3 or 4), #line_text)
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M._ns, row, col, {
    id = mark_id,
    end_col = end_col,
    hl_group = hl_cursor,
    virt_text = { { ' ' .. collab.name .. ' ', hl_name } },
    virt_text_pos = 'eol',
    priority = 100,
  })
end

--- Generate a stable numeric mark ID from user_id string
function M._get_mark_id(user_id)
  local hash = 0
  for i = 1, #user_id do
    hash = (hash * 31 + string.byte(user_id, i)) % 2147483647
  end
  return math.max(1, hash)
end

--- Clear all collaborator cursors
function M.clear_all()
  if M._publish_timer then vim.fn.timer_stop(M._publish_timer) end
  M._publish_timer = nil
  M._last_position = nil
  for _, doc in pairs(require('overleaf')._state.documents) do
    if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
      vim.api.nvim_buf_clear_namespace(doc.bufnr, M._ns, 0, -1)
    end
  end
  M._collaborators = {}
end

return M
