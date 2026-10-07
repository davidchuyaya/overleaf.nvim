local labels = require('overleaf.labels')
local overleaf = require('overleaf')

describe('complete all live Overleaf labels', function()
  local saved, buf, client

  before_each(function()
    saved = overleaf._state
    buf = vim.api.nvim_create_buf(true, false)
    vim.bo[buf].filetype = 'tex'
    vim.bo[buf].buftype = 'acwrite'
    overleaf._state = { connected = true, documents = { main = { bufnr = buf } } }
    client = { name = 'texlab', offset_encoding = 'utf-16', settings = {} }
  end)

  after_each(function()
    vim.api.nvim_buf_delete(buf, { force = true })
    overleaf._state = saved
  end)

  local function items(line, declarations, character)
    local lines = { line }
    vim.list_extend(lines, declarations or { '\\label{sec:one}', '\\label{sec:two}' })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return labels.items(client, { position = { line = 0, character = character or #line } }, buf)
  end

  it('includes more than 50 unsaved current-file labels and keeps TexLab details without duplicate keys', function()
    local lines, original = {}, { isIncomplete = true, items = {} }
    for i = 1, 80 do
      local key = string.format('sec:label%03d', i)
      lines[#lines + 1] = '\\label{' .. key .. '}'
      if i <= 50 then original.items[#original.items + 1] = { label = key, detail = 'TexLab detail' } end
    end
    local result = labels.merge(original, items('\\Cref{', lines))
    assert.equals(80, #result.items)
    assert.equals('TexLab detail', result.items[1].detail)
    assert.equals('sec:label080', result.items[80].label)
    assert.is_true(result.isIncomplete)
    assert.is_true(vim.bo[buf].modified)
  end)

  it('supports common reference commands and comma-separated keys with exact edit bounds', function()
    for _, command in ipairs({ 'Cref', 'cref', 'ref', 'eqref', 'autoref', 'pageref', 'nameref' }) do
      local line = '\\' .. command .. '*{sec:first, sec:t'
      local result = items(line)
      assert.equals(2, #result)
      assert.equals(#line - 5, result[1].textEdit.range.start.character)
      assert.equals(#line, result[1].textEdit.range['end'].character)
      assert.equals('sec:one}', result[1].textEdit.newText)
    end
  end)

  it('replaces the full key including a suffix after the cursor, preserving other references', function()
    local result = items('\\Cref{sec:first, sec:wrong,sec:last}', nil, 21)
    assert.are.same({ line = 0, character = 17 }, result[1].textEdit.range.start)
    assert.are.same({ line = 0, character = 26 }, result[1].textEdit.range['end'])
    assert.equals('sec:one', result[1].textEdit.newText)
  end)

  it('uses UTF-16 positions after non-ASCII text', function()
    local line = 'α😀 \\Cref{sec:'
    local result = items(line, nil, 14)
    assert.equals(10, result[1].textEdit.range.start.character)
    assert.equals(14, result[1].textEdit.range['end'].character)
    client.offset_encoding = 'utf-8'
    result = items(line)
    assert.equals(#line - 4, result[1].textEdit.range.start.character)
  end)

  it(
    'recognizes multiline and optional label arguments, but skips comments, escaped commands and examples',
    function()
      assert.are.same(
        { 'sec:live', 'fig:optional', 'sec:multiline' },
        labels.scan({
          '\\label{sec:live} % \\label{sec:comment}',
          '% \\label{sec:hidden}',
          '\\\\label{sec:escaped}',
          '\\label[optional]{fig:optional}',
          '\\label',
          '{sec:multiline}',
          '\\verb|\\label{sec:example}|',
          '\\begin{verbatim}',
          '\\label{sec:verbatim}',
          '\\end{verbatim}',
          '\\newcommand{\\mylabel}[1]{\\label{#1}}',
          '\\label{sec:live}',
        })
      )
    end
  )

  it('updates immediately when a live label is added or removed', function()
    assert.equals('sec:new', items('\\Cref{', { '\\label{sec:new}' })[1].label)
    assert.equals(0, #items('\\Cref{', { 'Label removed' }))
  end)

  it('leaves citation, command, environment, comment and ordinary-buffer completion alone', function()
    for _, line in ipairs({ '\\cite{', '\\begin{', '\\emph', '% \\Cref{' }) do
      assert.equals(0, #items(line))
    end
    overleaf._state.documents = {}
    assert.equals(0, #items('\\Cref{'))
    overleaf._state.documents = { main = { bufnr = buf } }
    overleaf._state.connected = false
    assert.equals(0, #items('\\Cref{'))
  end)

  it('wraps only TexLab completion, preserves request IDs, and installs once', function()
    items('\\Cref{')
    local called = 0
    client.request = function(self, method, _, callback, target)
      assert.equals(client, self)
      assert.equals(buf, target)
      called = called + 1
      callback(
        nil,
        method == 'textDocument/completion' and { items = { { label = 'sec:one', detail = 'original' } } }
          or { hover = true },
        { bufnr = buf }
      )
      return true, 42
    end
    labels.attach(client)
    local wrapper = client.request
    labels.attach(client)
    assert.equals(wrapper, client.request)
    local result, ctx
    local ok, id = client:request(
      'textDocument/completion',
      { position = { line = 0, character = 6 } },
      function(_, value, context)
        result, ctx = value, context
      end,
      buf
    )
    assert.is_true(ok)
    assert.equals(42, id)
    assert.equals(2, #result.items)
    assert.equals('original', result.items[1].detail)
    assert.equals(buf, ctx.bufnr)
    client:request('textDocument/hover', {}, function(_, value) result = value end, buf)
    assert.are.same({ hover = true }, result)
    assert.equals(2, called)
  end)

  it('preserves server errors and supports TexLab custom reference command settings', function()
    client.settings = { texlab = { experimental = { labelReferenceCommands = { 'myref' } } } }
    assert.equals(2, #items('\\myref{'))
    local original_error = { message = 'LSP error' }
    client.request = function(_, _, _, callback) callback(original_error, nil) end
    labels.attach(client)
    client:request('textDocument/completion', { position = { line = 0, character = 7 } }, function(err, result)
      assert.equals(original_error, err)
      assert.is_nil(result)
    end, buf)
  end)

  local function accept_reference(line, column, key, kind)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
    local context = labels.context(client, { position = { line = 0, character = column } }, buf)
    assert.is_not_nil(context)
    local result = labels.normalize({
      items = {
        {
          label = key,
          kind = kind,
          detail = 'TexLab detail',
          documentation = { kind = 'markdown', value = 'Figure caption' },
          sortText = '04',
          textEdit = {
            newText = key,
            range = { start = { line = 0, character = 6 }, ['end'] = { line = 0, character = column } },
          },
        },
      },
    }, context)
    local item = result.items[1]
    vim.lsp.util.apply_text_edits({ item.textEdit }, buf, client.offset_encoding)
    return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1], item
  end

  it('accepts figure and section references with one closing brace and no function braces', function()
    for _, candidate in ipairs({ { 'fig:exhaustive-search', 2 }, { 'sec:exhaustive-search', 9 } }) do
      local line, item = accept_reference('\\Cref{' .. candidate[1]:sub(1, 5), 11, candidate[1], candidate[2])
      assert.equals('\\Cref{' .. candidate[1] .. '}', line)
      assert.equals(vim.lsp.protocol.CompletionItemKind.Reference, item.kind)
      assert.equals('TexLab detail', item.detail)
      assert.equals('Figure caption', item.documentation.value)
      assert.equals('04', item.sortText)
      assert.equals(vim.lsp.protocol.InsertTextFormat.PlainText, item.insertTextFormat)
    end
  end)

  it('reuses an existing closing brace without doubling it or swallowing surrounding text', function()
    local line, item = accept_reference('See \\Cref{fig:ex} next.', 16, 'fig:exhaustive-search', 2)
    assert.equals('See \\Cref{fig:exhaustive-search} next.', line)
    assert.equals('fig:exhaustive-search}', item.textEdit.newText)
    assert.equals(17, item.textEdit.range['end'].character)
    line = accept_reference('\\Cref{sec:ex  }.', 12, 'sec:example', 9)
    assert.equals('\\Cref{sec:example  }.', line)
  end)

  it('does not close comma-separated references early and closes the last reference', function()
    local line = accept_reference('\\Cref{fig:ex,sec:other}', 12, 'fig:exhaustive-search', 2)
    assert.equals('\\Cref{fig:exhaustive-search,sec:other}', line)
    line = accept_reference('\\Cref{sec:first, fig:ex', 22, 'fig:exhaustive-search', 2)
    assert.equals('\\Cref{sec:first, fig:exhaustive-search}', line)
  end)

  it('normalizes a server-only figure even when the current file defines no labels', function()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { '\\Cref{fig:' })
    client.request = function(_, _, _, callback)
      callback(nil, { items = { { label = 'fig:elsewhere', kind = 2, insertText = 'fig:elsewhere' } } })
    end
    labels.attach(client)
    client:request('textDocument/completion', { position = { line = 0, character = 10 } }, function(_, result)
      assert.equals(1, #result.items)
      assert.equals(vim.lsp.protocol.CompletionItemKind.Reference, result.items[1].kind)
      assert.equals('fig:elsewhere}', result.items[1].textEdit.newText)
    end, buf)
  end)

  it('never rewrites real command snippets as label keys', function()
    items('\\Cref{')
    local context = labels.context(client, { position = { line = 0, character = 6 } }, buf)
    local command = { label = 'command', kind = 2, textEdit = { newText = 'command{$1}$0' }, insertTextFormat = 2 }
    local result = labels.normalize({ items = { command } }, context)
    assert.equals(2, result.items[1].kind)
    assert.equals('command{$1}$0', result.items[1].textEdit.newText)
  end)

  it('registers colon after initialization, once, without removing existing triggers', function()
    client.request = function() end
    labels.attach(client)
    local wrapper = client.request
    local original = { '\\', '{', '}' }
    client.server_capabilities = { completionProvider = { triggerCharacters = original } }
    labels.attach(client)
    labels.attach(client)
    assert.equals(wrapper, client.request)
    assert.are.same({ '\\', '{', '}', ':' }, client.server_capabilities.completionProvider.triggerCharacters)
    assert.are.same({ '\\', '{', '}' }, original)
    client.name = 'other_lsp'
    client.server_capabilities.completionProvider.triggerCharacters = { '{' }
    labels.attach(client)
    assert.are.same({ '{' }, client.server_capabilities.completionProvider.triggerCharacters)
  end)
end)
