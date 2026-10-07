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
      assert.equals('sec:one', result[1].textEdit.newText)
    end
  end)

  it('replaces the full key including a suffix after the cursor, preserving other references', function()
    local result = items('\\Cref{sec:first, sec:wrong,sec:last}', nil, 21)
    assert.are.same({ line = 0, character = 17 }, result[1].textEdit.range.start)
    assert.are.same({ line = 0, character = 26 }, result[1].textEdit.range['end'])
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
end)
