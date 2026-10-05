local Document = require('overleaf.document')
local buffer = require('overleaf.buffer')
local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local sync = require('overleaf.sync')
local ot = require('overleaf.ot')

describe('live external edits', function()
  local root, doc, original_request, original_config, sent

  before_each(function()
    root = vim.fn.tempname()
    original_request, original_config = bridge.request, vim.deepcopy(config._config)
    sent = {}
    bridge.request = function(method, params, callback)
      sent[#sent + 1] = { method = method, params = vim.deepcopy(params) }
      if callback then callback(nil, {}) end
    end
    config.setup({ sync_dir = root })
    sync.start('project')
    doc = Document.new('external', 'main.txt')
    doc.joined, doc.version, doc.content, doc.server_content = true, 0, 'Original text', 'Original text'
    sync.write_doc(doc)
    doc.bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(doc.bufnr, sync.file_path(doc.path))
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { doc.content })
    vim.bo[doc.bufnr].buftype = 'acwrite'
    vim.bo[doc.bufnr].modified = false
    buffer.attach(doc.bufnr, doc)
  end)

  after_each(function()
    doc:_stop_ack_timer()
    if doc._flush_timer then vim.fn.timer_stop(doc._flush_timer) end
    if vim.api.nvim_buf_is_valid(doc.bufnr) then vim.api.nvim_buf_delete(doc.bufnr, { force = true }) end
    sync.stop()
    bridge.request, config._config = original_request, original_config
    vim.fn.delete(root, 'rf')
  end)

  local function write_agent(text)
    local f = assert(io.open(sync.file_path(doc.path), 'w'))
    f:write(text)
    f:close()
  end

  local function assert_confirmed(text)
    assert.are.equal(text, doc.content)
    assert.are.equal(text, table.concat(vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false), '\n'))
    assert.is_true(doc:check_content())
    assert.is_nil(doc._rejoining)
    doc:flush()
    assert.are.equal('applyOtUpdate', sent[#sent].method)
    assert.are.equal(text, ot.apply(doc.server_content, sent[#sent].params.op))
    assert.is_true(doc:_on_ack({ v = doc.version }))
    assert.are.equal(text, doc.server_content)
  end

  it('imports full multiline replacements, including trailing newlines, and waits for applied ACK', function()
    local target = 'Agent replacement\nMore text 日本語\n'
    write_agent(target)
    sync._on_file_changed(sync.file_path(doc.path), doc)
    assert_confirmed(target)
  end)

  it('handles replacements that shorten a document or remove all its text', function()
    for _, target in ipairs({ 'a\nb\nc', 'short', '' }) do
      write_agent(target)
      sync._on_file_changed(sync.file_path(doc.path), doc)
      assert_confirmed(target)
    end
  end)

  it('imports a disk edit before a queued mirror write can overwrite it', function()
    local target = 'Agent edit before watcher delivery'
    write_agent(target)
    sync.write_doc(doc)
    assert.are.same({ target }, vim.fn.readfile(sync.file_path(doc.path)))
    assert_confirmed(target)
  end)

  it('ignores an unchanged disk snapshot even after its own-write marker expires', function()
    vim.api.nvim_buf_set_text(doc.bufnr, 0, 13, 0, 13, { '!' })
    sync._self_writes[sync.file_path(doc.path)] = nil
    sync._on_file_changed(sync.file_path(doc.path), doc)
    assert_confirmed('Original text!')
  end)

  it('detects an agent edit immediately after our own write through the real watcher', function()
    sync.watch(doc)
    vim.wait(150) -- allow macOS to arm its asynchronous filesystem stream
    sync.write_doc(doc)
    write_agent('Immediate external edit')
    assert.is_true(vim.wait(2000, function() return doc.content == 'Immediate external edit' end))
    assert_confirmed('Immediate external edit')
  end)

  it('continues watching after an agent atomically replaces the file', function()
    sync.watch(doc)
    vim.wait(150)
    local path = sync.file_path(doc.path)
    local replacement = assert(io.open(path .. '.tmp', 'w'))
    replacement:write('Atomic external edit')
    replacement:close()
    assert(os.rename(path .. '.tmp', path))
    assert.is_true(vim.wait(2000, function() return doc.content == 'Atomic external edit' end))
    assert_confirmed('Atomic external edit')
    write_agent('Second external edit')
    assert.is_true(vim.wait(2000, function() return doc.content == 'Second external edit' end))
    assert_confirmed('Second external edit')
  end)

  it('retains the listener and imports a whole-buffer reload', function()
    write_agent('Reloaded by Sidekick')
    -- :edit! unloads/reloads the buffer; a listener must survive that too.
    vim.api.nvim_buf_call(doc.bufnr, function() vim.cmd('edit!') end)
    vim.wait(50, function() return doc._buffer_attached and doc.content == 'Reloaded by Sidekick' end)
    assert_confirmed('Reloaded by Sidekick')
    assert.is_true(doc._buffer_attached)
    vim.api.nvim_buf_set_text(doc.bufnr, 0, 20, 0, 20, { '!' })
    assert_confirmed('Reloaded by Sidekick!')
  end)

  it('imports on_reload notifications without detaching the listener', function()
    -- Populate Neovim's file timestamps first. Ordinary mirror buffers can
    -- be reloaded by :checktime before/while they are promoted to acwrite.
    vim.api.nvim_buf_call(doc.bufnr, function() vim.cmd('edit!') end)
    assert.is_true(vim.wait(50, function() return doc._buffer_attached end))
    vim.bo[doc.bufnr].buftype = ''
    vim.bo[doc.bufnr].autoread = true
    write_agent('Reload callback edit')
    vim.api.nvim_buf_call(doc.bufnr, function() vim.cmd('checktime') end)
    vim.bo[doc.bufnr].buftype = 'acwrite'
    assert_confirmed('Reload callback edit')
    assert.is_true(doc._buffer_attached)
  end)

  it('reconciles missed edits behind an in-flight update without dropping either', function()
    vim.api.nvim_buf_set_text(doc.bufnr, 0, 13, 0, 13, { '!' })
    doc:flush()
    -- Simulate a missed notification while a previous edit awaits its ACK.
    doc.applying_remote = true
    vim.api.nvim_buf_set_text(doc.bufnr, 0, 0, 0, 0, { 'Agent ' })
    doc.applying_remote = false
    assert.is_true(doc:check_content())
    assert.are.equal('Agent Original text!', doc.content)
    assert.is_nil(doc._rejoining)
    assert.is_true(doc:_on_ack({ v = 0 }))
    assert_confirmed('Agent Original text!')
  end)

  it('does not sync a stale buffer while a remote update is queued', function()
    vim.api.nvim_buf_set_text(doc.bufnr, 0, 13, 0, 13, { '!' })
    doc:on_remote_op(
      { v = 0, op = { { p = 0, i = 'Collaborator ' } } },
      function(ops) buffer.apply_remote(doc, ops) end
    )
    assert.is_false(doc:check_content())
    doc:flush()
    assert.are.equal(0, #sent)
    vim.wait(50, function() return doc._remote_apply_pending == 0 end)
    assert_confirmed('Collaborator Original text!')
  end)

  it('never publishes only the delete half when inserted-text extraction fails', function()
    local original = vim.api.nvim_buf_get_text
    vim.api.nvim_buf_get_text = function() error('simulated extraction failure') end
    local ok, err = pcall(vim.api.nvim_buf_set_text, doc.bufnr, 0, 0, 0, 8, { 'Agent' })
    vim.api.nvim_buf_get_text = original
    assert.is_true(ok, err)
    assert.is_nil(doc.pending_ops)
    assert.are.equal('Original text', doc.content)
    vim.wait(50, function() return doc.content == 'Agent text' end)
    assert_confirmed('Agent text')
  end)
end)
