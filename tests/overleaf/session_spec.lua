local overleaf = require('overleaf')
local session = require('overleaf.session')
local buffer = require('overleaf.buffer')
local Document = require('overleaf.document')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')
local config = require('overleaf.config')
local sync = require('overleaf.sync')

describe('remembering Overleaf document tabs', function()
  local root, original_state, original_config, original_request, original_tree, original_tabs, original_storage
  local original_handlers, original_unexpected, original_toggle
  local buffers, joins, windows

  before_each(function()
    original_state, original_config = overleaf._state, vim.deepcopy(config._config)
    original_request, original_tree = bridge.request, project._project_tree
    original_handlers, original_unexpected = bridge._event_handlers, bridge._on_unexpected_exit
    original_toggle = overleaf.toggle_tree
    bridge._event_handlers = {}
    original_tabs, original_storage = vim.t.bufs, session._storage_dir
    root = vim.fn.tempname()
    session._storage_dir = root
    config.setup({ sync_dir = false, log_level = 'error', restore_session = true })
    overleaf._state = { connected = true, project_id = 'project-a', documents = {} }
    project._project_tree = {
      { id = 'a', path = 'a.txt', type = 'doc' },
      { id = 'b', path = 'b.txt', type = 'doc' },
    }
    buffers, joins, windows = {}, {}, {}
    vim.t.bufs = {}
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' then
        joins[#joins + 1] = params.docId
        callback(nil, { lines = { 'Fresh Overleaf content', 'Second server line' }, version = 5 })
      elseif callback then
        callback(nil, {})
      end
    end
  end)

  after_each(function()
    session.cancel()
    sync.stop()
    for _, doc in pairs(overleaf._state.documents) do
      if doc.bufnr then buffers[#buffers + 1] = doc.bufnr end
    end
    overleaf._state.connected = false
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    overleaf._state, config._config = original_state, original_config
    bridge.request, project._project_tree = original_request, original_tree
    bridge._event_handlers, bridge._on_unexpected_exit = original_handlers, original_unexpected
    overleaf.toggle_tree = original_toggle
    vim.t.bufs, session._storage_dir = original_tabs, original_storage
    vim.fn.delete(root, 'rf')
  end)

  local function doc(id)
    local d = Document.new(id, id .. '.txt')
    d.joined, d.version = true, 0
    d.content, d.server_content = 'Old local text\nAnother old line', 'Old local text\nAnother old line'
    buffer.create(d, vim.split(d.content, '\n', { plain = true }), { display = false })
    overleaf._state.documents[id] = d
    buffers[#buffers + 1] = d.bufnr
    return d
  end

  local function save_and_close()
    local a, b = doc('a'), doc('b')
    vim.api.nvim_set_current_buf(a.bufnr)
    vim.api.nvim_win_set_cursor(0, { 2, 4 })
    vim.api.nvim_set_current_buf(b.bufnr)
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.t.bufs = { b.bufnr, a.bufnr }
    assert.is_true(session.save(overleaf._state))
    buffer.cleanup_all(overleaf._state.documents)
    assert.is_false(vim.api.nvim_buf_is_valid(a.bufnr or -1))
    overleaf._state.documents = {}
    vim.t.bufs = {}
  end

  it('remembers tab order, active document and cursors without saving document contents', function()
    local a, b = doc('a'), doc('b')
    vim.api.nvim_set_current_buf(b.bufnr)
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.t.bufs = { b.bufnr, a.bufnr }
    assert.is_true(session.save(overleaf._state))
    local saved = session.load(overleaf._state)
    assert.are.equal('b', saved.active)
    assert.are.equal('b', saved.files[1].id)
    assert.are.equal('a', saved.files[2].id)
    assert.are.same({ 2, 3 }, saved.files[1].cursor)
    assert.is_nil(saved.files[1].content)
    assert.is_nil(saved.files[1].bufnr)
    assert.is_nil(saved.base_url)
    assert.are.equal(384, vim.uv.fs_stat(root .. '/' .. vim.fn.readdir(root)[1]).mode % 512)
  end)

  it('reopens fresh live documents after cleanup and selects the previously active tab', function()
    save_and_close()
    session.restore(overleaf)
    assert.is_true(vim.wait(1000, function()
      local b = overleaf._state.documents.b
      return b and b.bufnr and vim.api.nvim_get_current_buf() == b.bufnr
    end))
    local a, b = overleaf._state.documents.a, overleaf._state.documents.b
    assert.are.same({ 'b', 'a' }, joins)
    assert.are.same({ b.bufnr, a.bufnr }, vim.t.bufs)
    assert.are.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
    assert.are.same({ 2, 4 }, vim.api.nvim_buf_get_mark(a.bufnr, '"'))
    assert.are.equal('acwrite', vim.bo[b.bufnr].buftype)
    assert.are.equal('Fresh Overleaf content\nSecond server line', b.content)
    assert.is_true(b.joined)
    assert.is_true(b._buffer_attached)
    vim.api.nvim_set_current_buf(a.bufnr)
    assert.are.same({ 2, 4 }, vim.api.nvim_win_get_cursor(0))
    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    vim.api.nvim_set_current_buf(b.bufnr)
    vim.api.nvim_set_current_buf(a.bufnr)
    assert.are.same({ 1, 2 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('restores automatically only after a successful project connection', function()
    save_and_close()
    overleaf._state.connected = false
    local original = bridge.request
    bridge.request = function(method, params, callback)
      if method == 'connect' then
        callback(nil, {
          project = {
            rootFolder = {
              docs = {
                { _id = 'a', name = 'a.txt' },
                { _id = 'b', name = 'b.txt' },
              },
            },
          },
        })
      else
        original(method, params, callback)
      end
    end
    overleaf.toggle_tree = function() end
    overleaf._connect_project('test-cookie', 'project-a', 'Project A')
    assert.is_true(vim.wait(1000, function()
      local b = overleaf._state.documents.b
      return b and b.bufnr and vim.api.nvim_get_current_buf() == b.bufnr
    end))
    assert.are.same({ 'b', 'a' }, joins)
  end)

  it('cancels pending restoration when disconnecting from the project', function()
    save_and_close()
    local reply
    bridge.request = function(method, _, callback)
      if method == 'joinDoc' then reply = callback end
    end
    session.restore(overleaf)
    assert.is_function(reply)
    session.cancel()
    overleaf._state.documents = {}
    reply(nil, { lines = { 'Other connection' }, version = 2 })
    vim.wait(30, function() return false end)
    assert.are.same({}, overleaf._state.documents)
  end)

  it('restores saved tabs before a slow unrelated mirror join, including explorer focus changes', function()
    save_and_close()
    config.setup({ sync_dir = root .. '/mirror' })
    overleaf._state.connected = false
    local original = bridge.request
    local slow_reply
    bridge.request = function(method, params, callback)
      if method == 'connect' then
        callback(nil, {
          project = {
            rootFolder = {
              docs = {
                { _id = 'a', name = 'a.txt' },
                { _id = 'b', name = 'b.txt' },
                { _id = 'slow', name = 'unrelated.txt' },
              },
            },
          },
        })
      elseif method == 'joinDoc' and params.docId == 'slow' then
        joins[#joins + 1] = params.docId
        slow_reply = callback
      else
        original(method, params, callback)
      end
    end
    overleaf.toggle_tree = function()
      vim.cmd('vsplit')
      windows[#windows + 1] = vim.api.nvim_get_current_win()
      local tree = vim.api.nvim_create_buf(false, true)
      buffers[#buffers + 1] = tree
      vim.api.nvim_set_current_buf(tree)
    end
    overleaf._connect_project('test-cookie', 'project-a', 'Project A')
    assert.is_true(vim.wait(1000, function() return slow_reply ~= nil end))
    local a, b = overleaf._state.documents.a, overleaf._state.documents.b
    assert.is_true(a.joined)
    assert.is_true(b.joined)
    assert.are.equal(b.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same({ b.bufnr, a.bufnr }, vim.t.bufs)
    assert.are.same({ 'b', 'a', 'slow' }, joins)
  end)

  it('completes initialization when restoration is disabled or no history exists', function()
    local calls = 0
    session.restore(overleaf, function() calls = calls + 1 end)
    assert.are.equal(1, calls)
    config.setup({ restore_session = false })
    session.restore(overleaf, function() calls = calls + 1 end)
    assert.are.equal(2, calls)
  end)

  it('continues mirror initialization if focus changes during restoration', function()
    save_and_close()
    local reply
    local original = bridge.request
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' and not reply then
        reply = function() original(method, params, callback) end
      else
        original(method, params, callback)
      end
    end
    local done = false
    session.restore(overleaf, function() done = true end)
    local other = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = other
    vim.api.nvim_set_current_buf(other)
    reply()
    assert.is_true(vim.wait(1000, function() return done end))
    assert.are.equal(other, vim.api.nvim_get_current_buf())
  end)

  it('keeps projects and Overleaf instances separate', function()
    save_and_close()
    overleaf._state.project_id = 'project-b'
    session.restore(overleaf)
    assert.are.same({}, joins)
    assert.is_nil(session.load(overleaf._state))
    overleaf._state.project_id = 'project-a'
    config.setup({ base_url = 'https://another-overleaf.example' })
    assert.is_nil(session.load(overleaf._state))
  end)

  it('resolves renamed documents by ID and skips deleted files', function()
    save_and_close()
    project._project_tree = { { id = 'a', path = 'renamed.txt', type = 'doc' } }
    session.restore(overleaf)
    assert.is_true(vim.wait(1000, function() return #joins == 1 and overleaf._state.documents.a.bufnr ~= nil end))
    assert.are.same({ 'a' }, joins)
    assert.are.equal('renamed.txt', overleaf._state.documents.a.path)
  end)

  it('continues restoring when a document join fails', function()
    save_and_close()
    local original = bridge.request
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' and params.docId == 'b' then
        callback({ message = 'No access' })
      else
        original(method, params, callback)
      end
    end
    session.restore(overleaf)
    assert.is_true(vim.wait(1000, function()
      local a = overleaf._state.documents.a
      return a and a.bufnr and vim.api.nvim_get_current_buf() == a.bufnr
    end))
    assert.is_nil(overleaf._state.documents.b)
  end)

  it('waits for a mirror already joining instead of starting a duplicate join', function()
    save_and_close()
    local reply
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' then
        joins[#joins + 1] = params.docId
        reply = callback
      end
    end
    overleaf.open_document('b', 'b.txt', nil, { display = false })
    session.restore(overleaf)
    assert.are.same({ 'b' }, joins)
    reply(nil, { lines = { 'Newest content' }, version = 7 })
    assert.is_true(vim.wait(1000, function() return #joins == 2 end))
    reply(nil, { lines = { 'Short' }, version = 8 })
    assert.is_true(
      vim.wait(1000, function() return vim.api.nvim_get_current_buf() == overleaf._state.documents.b.bufnr end)
    )
    assert.are.same({ 1, 3 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('does not overwrite a modified local mirror or stall other tabs', function()
    save_and_close()
    local mirror = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = mirror
    vim.api.nvim_buf_set_name(mirror, 'overleaf://b.txt')
    vim.api.nvim_buf_set_lines(mirror, 0, -1, false, { 'Unsaved local text' })
    session.restore(overleaf)
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.a ~= nil end))
    assert.are.same({ 'Unsaved local text' }, vim.api.nvim_buf_get_lines(mirror, 0, -1, false))
    assert.is_nil(overleaf._state.documents.b)
  end)

  it('can be disabled and does nothing before reconnecting', function()
    save_and_close()
    overleaf._state.connected = false
    session.restore(overleaf)
    assert.are.same({}, joins)
    overleaf._state.connected = true
    config.setup({ restore_session = false })
    session.restore(overleaf)
    assert.are.same({}, joins)
    assert.is_nil(session.save(overleaf._state))
  end)

  it('restores into the editor and leaves an open Sidekick terminal untouched', function()
    save_and_close()
    local editor = vim.api.nvim_get_current_win()
    vim.cmd('rightbelow vsplit')
    local sidekick = vim.api.nvim_get_current_win()
    windows[#windows + 1] = sidekick
    local terminal = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = terminal
    vim.api.nvim_open_term(terminal, {})
    vim.api.nvim_win_set_buf(sidekick, terminal)
    session.restore(overleaf)
    assert.is_true(vim.wait(1000, function()
      local b = overleaf._state.documents.b
      return b and b.bufnr and vim.api.nvim_get_current_win() == editor and vim.api.nvim_win_get_buf(editor) == b.bufnr
    end))
    assert.are.equal(terminal, vim.api.nvim_win_get_buf(sidekick))
  end)

  it('does not replace a different file selected while restoration was joining', function()
    save_and_close()
    local replies = {}
    bridge.request = function(method, _, callback)
      if method == 'joinDoc' then replies[#replies + 1] = callback end
    end
    session.restore(overleaf)
    local unrelated = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = unrelated
    vim.api.nvim_set_current_buf(unrelated)
    replies[1](nil, { lines = { 'Fresh content' }, version = 1 })
    assert.is_true(vim.wait(1000, function() return #replies == 2 end))
    replies[2](nil, { lines = { 'Fresh content' }, version = 1 })
    vim.wait(30, function() return false end)
    assert.are.equal(unrelated, vim.api.nvim_get_current_buf())
    assert.is_number(overleaf._state.documents.a.bufnr)
    assert.is_number(overleaf._state.documents.b.bufnr)
  end)

  it('ignores corrupt metadata', function()
    save_and_close()
    local path = root .. '/' .. vim.fn.readdir(root)[1]
    vim.fn.writefile({ 'not json' }, path)
    assert.is_nil(session.load(overleaf._state))
    session.restore(overleaf)
    assert.are.same({}, joins)
  end)

  it('replaces the remembered set when tabs have been closed', function()
    doc('a')
    assert.is_true(session.save(overleaf._state))
    buffer.cleanup_all(overleaf._state.documents)
    assert.is_true(session.save(overleaf._state))
    assert.are.same({}, session.load(overleaf._state).files)
  end)
end)
