local buffer = require('overleaf.buffer')

describe('Overleaf LSP attachment', function()
  local original_clients, original_start, original_detach, original_lookup, original_executable
  local buf, clients, started, detached

  before_each(function()
    original_clients, original_start = vim.lsp.get_clients, vim.lsp.start
    original_detach, original_lookup = vim.lsp.buf_detach_client, vim.lsp.get_client_by_id
    original_executable = vim.fn.executable
    buf = vim.api.nvim_create_buf(true, false)
    clients, started, detached = {}, {}, {}
    vim.lsp.get_clients = function(filter)
      assert.is_true(filter._uninitialized)
      local result = {}
      for _, client in ipairs(clients) do
        if client.name == filter.name and client.attached_buffers[filter.bufnr] then table.insert(result, client) end
      end
      return result
    end
    vim.lsp.get_client_by_id = function(id)
      for _, client in ipairs(clients) do
        if client.id == id then return client end
      end
    end
    vim.lsp.start = function(config, opts) table.insert(started, { config = config, opts = opts }) end
    vim.lsp.buf_detach_client = function(bufnr, id)
      table.insert(detached, { bufnr = bufnr, id = id })
      vim.lsp.get_client_by_id(id).attached_buffers[bufnr] = nil
    end
    vim.fn.executable = function() return 1 end
  end)

  after_each(function()
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.wait(10, function() return false end)
    vim.lsp.get_clients, vim.lsp.start = original_clients, original_start
    vim.lsp.buf_detach_client, vim.lsp.get_client_by_id = original_detach, original_lookup
    vim.fn.executable = original_executable
  end)

  local function client(id, name, initialized)
    return { id = id, name = name, initialized = initialized, attached_buffers = { [buf] = true } }
  end

  it('reuses editor-attached servers instead of launching fallback duplicates with different roots', function()
    clients = { client(1, 'texlab', true), client(2, 'ltex', true), client(3, 'harper_ls', true) }
    buffer._attach_lsp(buf, 'tex')
    assert.are.same({}, started)
    assert.are.same({}, detached)
  end)

  it('also reuses a server that is still initializing', function()
    clients = { client(1, 'texlab', false) }
    buffer._attach_lsp(buf, 'tex')
    assert.are.equal(2, #started)
    for _, item in ipairs(started) do
      assert.are_not.equal('texlab', item.config.name)
    end
  end)

  it('starts fallback servers normally when none are attached', function()
    buffer._attach_lsp(buf, 'tex')
    assert.are.equal(3, #started)
    assert.are.equal('texlab', started[3].config.name)
    assert.are.equal(buf, started[3].opts.bufnr)
  end)

  it('detaches duplicate clients from this buffer without stopping shared clients or other servers', function()
    clients = { client(8, 'texlab', true), client(2, 'texlab', true), client(3, 'ltex', true) }
    clients[1].attached_buffers[9876] = true
    assert.are.equal(2, buffer._dedupe_lsp(buf, 'texlab').id)
    assert.are.same({ { bufnr = buf, id = 8 } }, detached)
    assert.is_true(clients[1].attached_buffers[9876])
    assert.is_true(clients[3].attached_buffers[buf])
  end)

  it('guards against a second editor client attaching after the Overleaf buffer was created', function()
    local doc = {
      path = 'lsp-race.txt',
      content = 'text',
      joined = true,
      check_content = function() return true end,
      submit_op = function() end,
    }
    buffer.create(doc, { 'text' }, { bufnr = buf, display = false })
    clients = { client(1, 'texlab', true), client(2, 'texlab', true) }
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = buf, data = { client_id = 2 } })
    assert.is_true(vim.wait(500, function() return #detached == 1 end))
    assert.are.equal(2, detached[1].id)
  end)

  it('does not touch ordinary buffers outside Overleaf', function()
    clients = { client(1, 'texlab', true), client(2, 'texlab', true) }
    vim.api.nvim_exec_autocmds('LspAttach', { buffer = buf, data = { client_id = 2 } })
    vim.wait(10, function() return false end)
    assert.are.same({}, detached)
  end)
end)
