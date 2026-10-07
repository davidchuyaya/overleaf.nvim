-- TexLab limits each response to 50 entries. Fill in missing current-buffer
-- labels before completion reaches the editor, without adding a second source.
local M = {}

local references = {}
for _, name in ipairs({
  'ref',
  'Ref',
  'eqref',
  'pageref',
  'Pageref',
  'autoref',
  'Autoref',
  'nameref',
  'cref',
  'Cref',
  'cpageref',
  'Cpageref',
  'labelcref',
  'labelcpageref',
  'namecref',
  'Namecref',
  'nameCref',
  'lcnamecref',
  'vref',
  'Vref',
  'vpageref',
}) do
  references[name] = true
end

local function escaped(text, pos)
  local count = 0
  pos = pos - 1
  while pos > 0 and text:sub(pos, pos) == '\\' do
    count, pos = count + 1, pos - 1
  end
  return count % 2 == 1
end

local function without_comments(line)
  for pos = 1, #line do
    if line:sub(pos, pos) == '%' and not escaped(line, pos) then return line:sub(1, pos - 1) end
  end
  return line
end

function M.scan(lines)
  local clean, blocked = {}, nil
  for _, line in ipairs(lines) do
    line = without_comments(line)
    if blocked then
      if line:find('\\end{' .. blocked .. '}', 1, true) then blocked = nil end
      line = ''
    else
      local env = line:match('\\begin%s*{([^}]+)}')
      if env and ({ verbatim = true, ['verbatim*'] = true, lstlisting = true, minted = true, comment = true })[env] then
        if not line:find('\\end{' .. env .. '}', 1, true) then blocked = env end
        line = line:sub(1, (line:find('\\begin', 1, true) or 1) - 1)
      end
      -- Inline verbatim examples are not label definitions.
      line = line:gsub('\\verb%*?([^%a%s])(.-)%1', '')
    end
    clean[#clean + 1] = line
  end
  local text, labels, seen = table.concat(clean, '\n'), {}, {}
  local cursor = 1
  while true do
    local start, finish = text:find('\\label', cursor, true)
    if not start then break end
    cursor = finish + 1
    if not escaped(text, start) and not text:sub(cursor, cursor):match('[%a@]') then
      local tail = text:sub(cursor):gsub('^%s+', '')
      if tail:sub(1, 1) == '[' then tail = tail:gsub('^%b[]%s*', '') end
      local key = tail:match('^{([^{}]+)}')
      key = key and vim.trim(key)
      if key and key ~= '' and not key:find('[\\#%s]') and not seen[key] then
        labels[#labels + 1], seen[key] = key, true
      end
    end
  end
  return labels
end

local function byte_index(line, character, encoding)
  if encoding == 'utf-8' then return character end
  if vim.fn.has('nvim-0.11') == 1 then return vim.str_byteindex(line, encoding, character, false) end
  return vim.str_byteindex(line, character, encoding == 'utf-16')
end

local function character_index(line, byte, encoding)
  if encoding == 'utf-8' then return byte end
  local utf32, utf16 = vim.str_utfindex(line:sub(1, byte))
  return encoding == 'utf-16' and utf16 or utf32
end

local function live_buffer(buf)
  local overleaf = package.loaded.overleaf
  if not overleaf or not overleaf._state.connected or not vim.api.nvim_buf_is_valid(buf) then return false end
  for _, doc in pairs(overleaf._state.documents or {}) do
    if doc.bufnr == buf then return vim.bo[buf].filetype == 'tex' end
  end
  return false
end

function M.context(client, params, buf)
  if not live_buffer(buf) or not params or not params.position then return nil end
  local row = params.position.line
  local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
  if not line then return nil end
  local encoding = client.offset_encoding or 'utf-16'
  local ok, byte = pcall(byte_index, line, params.position.character, encoding)
  if not ok then return nil end
  local prefix = line:sub(1, byte)
  if without_comments(prefix) ~= prefix then return nil end
  local command, argument = prefix:match('\\([%a]+)%*?%s*{([^{}]*)$')
  local allowed = references[command]
  local extra = client.settings and client.settings.texlab and client.settings.texlab.experimental
  for _, name in ipairs(extra and extra.labelReferenceCommands or {}) do
    if name == command then allowed = true end
  end
  if not allowed then return nil end
  -- Replace the entire current comma-separated key, including text after the
  -- cursor. Blink's generic word bounds split labels at ':' and '-'.
  local fragment = argument:match('([^,]*)$')
  local leading = fragment:match('^%s*')
  local start = byte - #fragment + #leading
  local suffix = line:sub(byte + 1):match('^[^,{}%s]*') or ''
  local range = {
    start = { line = row, character = character_index(line, start, encoding) },
    ['end'] = { line = row, character = character_index(line, byte + #suffix, encoding) },
  }
  local remainder = line:sub(byte + #suffix + 1)
  -- Consume and reinsert an existing closing brace so accepting lands after
  -- it. Do not close the argument early when more comma-separated keys follow.
  local closing = remainder:match('^(%s*})')
  if closing then
    range['end'].character = character_index(line, byte + #suffix + #closing, encoding)
  elseif remainder:match('^%s*,') or remainder:match('^%s*{') then
    closing = ''
  else
    closing = '}'
  end
  return { range = range, closing = closing }
end

function M.items(client, params, buf, context)
  context = context or M.context(client, params, buf)
  if not context then return {} end
  local result = {}
  for _, key in ipairs(M.scan(vim.api.nvim_buf_get_lines(buf, 0, -1, false))) do
    result[#result + 1] = {
      label = key,
      kind = vim.lsp.protocol.CompletionItemKind.Reference,
      detail = 'Label in current Overleaf buffer',
      filterText = key,
      textEdit = { newText = key .. context.closing, range = vim.deepcopy(context.range) },
      insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
    }
  end
  return result
end

function M.normalize(result, context)
  if not result or not context then return result end
  for _, item in ipairs(result.items or result) do
    local key = item.textEdit and item.textEdit.newText or item.insertText or item.label
    -- Reference completion contains literal keys, not command snippets. Keep
    -- TexLab's descriptions, captions and ranking, but never treat a figure's
    -- Method kind as a function that needs another pair of braces.
    if type(key) == 'string' and key ~= '' and not key:find('[\\{}%s$#]') then
      item.kind = vim.lsp.protocol.CompletionItemKind.Reference
      item.insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText
      item.textEdit = { newText = key .. context.closing, range = vim.deepcopy(context.range) }
    end
  end
  return result
end

function M.merge(result, items)
  if #items == 0 then return result end
  result = result or { items = {}, isIncomplete = false }
  local entries = result.items or result
  local seen = {}
  for _, item in ipairs(entries) do
    seen[item.label] = true
  end
  for _, item in ipairs(items) do
    if not seen[item.label] then
      entries[#entries + 1], seen[item.label] = item, true
    end
  end
  return result
end

function M.attach(client)
  if not client or client.name ~= 'texlab' or type(client.request) ~= 'function' then return end
  -- Blink reads this standard LSP capability when deciding whether to hide on
  -- punctuation. Configure it again on LspAttach: a new client may not have
  -- finished initialization when we first install the request wrapper.
  local provider = client.server_capabilities and client.server_capabilities.completionProvider
  if type(provider) == 'table' then
    local characters = provider.triggerCharacters or {}
    if not vim.tbl_contains(characters, ':') then
      provider.triggerCharacters = vim.list_extend(vim.deepcopy(characters), { ':' })
    end
  end
  if client._overleaf_labels then return end
  client._overleaf_labels = true
  local original = client.request
  local function handler(method, params, callback, buf)
    if method ~= 'textDocument/completion' or type(callback) ~= 'function' then return callback end
    buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
    local context = M.context(client, params, buf)
    if not context then return callback end
    local items = M.items(client, params, buf, context)
    return function(err, result, ...)
      if not err then result = M.merge(M.normalize(result, context), items) end
      return callback(err, result, ...)
    end
  end
  if vim.fn.has('nvim-0.11') == 1 then
    client.request = function(self, method, params, callback, buf)
      return original(self, method, params, handler(method, params, callback, buf), buf)
    end
  else
    client.request = function(method, params, callback, buf)
      return original(method, params, handler(method, params, callback, buf), buf)
    end
  end
end

return M
