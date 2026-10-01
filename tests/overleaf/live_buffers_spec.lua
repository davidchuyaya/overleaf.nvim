local overleaf = require('overleaf')
local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local project = require('overleaf.project')
local sync = require('overleaf.sync')
local live = require('overleaf.live_buffers')

describe('opening mirror files through any editor UI', function()
  local original_state, original_config, original_request, original_tree, original_handlers
  local root, path, buffers, joins, reply

  before_each(function()
    original_state, original_config = overleaf._state, vim.deepcopy(config._config)
    original_request, original_tree = bridge.request, project._project_tree
    original_handlers = bridge._event_handlers
    bridge._event_handlers = {}
    root = vim.fn.tempname()
    config.setup({ sync_dir = root, log_level = 'error' })
    sync.start('project')
    path = sync.file_path('main.txt')
    vim.fn.writefile({ 'old text', 'second line' }, path)
    project._project_tree = {
      { id = 'main', path = 'main.txt', name = 'main.txt', type = 'doc' },
      { id = 'image', path = 'image.png', name = 'image.png', type = 'file' },
    }
    overleaf._state = { connected = true, documents = {} }
    buffers, joins, reply = {}, 0, nil
    bridge.request = function(method, _, callback)
      if method == 'joinDoc' then
        joins = joins + 1
        reply = callback
      elseif callback then
        callback(nil, {})
      end
    end
    live.setup()
    overleaf._setup_event_handlers()
  end)

  after_each(function()
    overleaf._state.connected = false
    vim.api.nvim_create_augroup('OverleafLiveBuffers', { clear = true })
    require('overleaf.cursors').clear_all()
    sync.stop()
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    overleaf._state, config._config = original_state, original_config
    bridge.request, project._project_tree = original_request, original_tree
    bridge._event_handlers = original_handlers
    vim.fn.delete(root, 'rf')
  end)

  local function open_mirror()
    vim.cmd.edit(path)
    local buf = vim.api.nvim_get_current_buf()
    table.insert(buffers, buf)
    assert.is_true(
      vim.wait(500, function() return joins == 1 end),
      vim.inspect({
        root = sync._sync_dir,
        name = vim.api.nvim_buf_get_name(buf),
        listed = vim.bo[buf].buflisted,
        buftype = vim.bo[buf].buftype,
        joins = joins,
      })
    )
    return buf
  end

  it('upgrades a normal edit in place and preserves the picker-selected cursor', function()
    local buf = open_mirror()
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    reply(nil, { lines = { 'server text', 'second line' }, version = 0 })
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.equal('acwrite', vim.bo[buf].buftype)
    assert.are.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
    assert.is_true(overleaf._state.documents.main.joined)
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 0, op = { { p = 11, i = ' remote' } } })
    assert.is_true(
      vim.wait(500, function() return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'server text remote' end)
    )
  end)

  it('does not steal focus if the join completes after switching buffers', function()
    local buf = open_mirror()
    local unrelated = vim.api.nvim_create_buf(true, false)
    table.insert(buffers, unrelated)
    vim.api.nvim_set_current_buf(unrelated)
    reply(nil, { lines = { 'server text' }, version = 0 })
    assert.are.equal(unrelated, vim.api.nvim_get_current_buf())
    assert.are.equal('acwrite', vim.bo[buf].buftype)
  end)

  it('does not start duplicate joins when a pending file is entered again', function()
    local buf = open_mirror()
    live.attach(buf)
    live.attach(buf)
    assert.are.equal(1, joins)
    reply(nil, { lines = { 'server text' }, version = 0 })
    live.attach(buf)
    assert.are.equal(1, joins)
  end)

  it('preserves local edits made while the server join is pending', function()
    local buf = open_mirror()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved local text' })
    reply(nil, { lines = { 'server text' }, version = 0 })
    assert.are.same({ 'unsaved local text' }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(vim.bo[buf].modified)
    assert.is_nil(overleaf._state.documents.main)
  end)

  it('ignores unlisted preview buffers and remote binary files', function()
    local buf = vim.api.nvim_create_buf(false, false)
    table.insert(buffers, buf)
    vim.api.nvim_buf_set_name(buf, path)
    assert.is_false(live.attach(buf))
    vim.bo[buf].buflisted = true
    vim.api.nvim_buf_set_name(buf, sync.file_path('image.png'))
    assert.is_false(live.attach(buf))
    assert.are.equal(0, joins)
  end)

  it('ignores similarly named sibling project directories and disconnected files', function()
    local buf = vim.api.nvim_create_buf(true, false)
    table.insert(buffers, buf)
    vim.api.nvim_buf_set_name(buf, sync._sync_dir .. '-other/main.txt')
    assert.is_false(live.attach(buf))
    vim.api.nvim_buf_set_name(buf, path)
    overleaf._state.connected = false
    assert.is_false(live.attach(buf))
    assert.are.equal(0, joins)
  end)

  it('does not reopen a file whose buffer was deleted during the join', function()
    local buf = open_mirror()
    vim.api.nvim_buf_delete(buf, { force = true })
    reply(nil, { lines = { 'server text' }, version = 0 })
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
    assert.is_nil(overleaf._state.documents.main)
  end)

  for _, close_command in ipairs({ 'bdelete', 'bunload', 'bwipeout' }) do
    it('restores live edits after ' .. close_command .. ' and reopen without losing pending ops', function()
      local buf = open_mirror()
      reply(nil, { lines = { 'server text' }, version = 0 })
      local doc = overleaf._state.documents.main
      doc.pending_ops = { { p = 11, i = ' pending' } }
      doc.content = 'server text pending'
      sync.write_doc(doc)
      doc.applying_remote = true
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { doc.content })
      doc.applying_remote = false
      local alternate = vim.api.nvim_create_buf(true, false)
      table.insert(buffers, alternate)
      vim.api.nvim_set_current_buf(alternate)
      vim.cmd(close_command .. '! ' .. buf)
      assert.is_false(doc._buffer_attached)
      vim.cmd.edit(path)
      local reopened = vim.api.nvim_get_current_buf()
      table.insert(buffers, reopened)
      assert.is_true(vim.wait(500, function() return doc._buffer_attached end))
      assert.are.equal(doc, overleaf._state.documents.main)
      assert.are.equal(1, joins)
      assert.are.same({ { p = 11, i = ' pending' } }, doc.pending_ops)
      assert.are.equal('server text pending', doc.content)
      vim.api.nvim_buf_set_text(reopened, 0, 19, 0, 19, { ' reopened' })
      assert.are.equal('server text pending reopened', doc.content)
      assert.are.equal(2, #doc.pending_ops)
    end)
  end

  it('keeps remote changes while unloaded without reopening the buffer', function()
    local buf = open_mirror()
    reply(nil, { lines = { 'server text' }, version = 0 })
    local doc = overleaf._state.documents.main
    local alternate = vim.api.nvim_create_buf(true, false)
    table.insert(buffers, alternate)
    vim.api.nvim_set_current_buf(alternate)
    vim.cmd('bunload! ' .. buf)
    assert.is_false(vim.api.nvim_buf_is_loaded(buf))
    assert.is_true(doc:check_content())
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 0, op = { { p = 11, i = ' remote' } } })
    assert.are.equal('server text remote', doc.content)
    assert.is_false(vim.api.nvim_buf_is_loaded(buf))
    overleaf.open_document('main', 'main.txt')
    assert.are.same({ 'server text remote' }, vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false))
    assert.is_true(doc._buffer_attached)
  end)

  it('does not apply a queued remote edit twice when closing and reopening immediately', function()
    local buf = open_mirror()
    reply(nil, { lines = { 'server text' }, version = 0 })
    local doc = overleaf._state.documents.main
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 0, op = { { p = 11, i = ' remote' } } })
    vim.cmd('bdelete! ' .. buf)
    overleaf.open_document('main', 'main.txt')
    vim.wait(30, function() return false end)
    assert.are.same({ 'server text remote' }, vim.api.nvim_buf_get_lines(doc.bufnr, 0, -1, false))
    local writes = vim.api.nvim_get_autocmds({ event = 'BufWriteCmd', buffer = doc.bufnr })
    assert.are.equal(1, #writes)
  end)
end)
