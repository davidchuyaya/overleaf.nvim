local cursors = require('overleaf.cursors')
local bridge = require('overleaf.bridge')

describe('cursor publishing', function()
  local original_overleaf, original_request, buf, state, sent

  before_each(function()
    original_overleaf, original_request = package.loaded.overleaf, bridge.request
    state = { connected = true, public_id = 'self', documents = {} }
    package.loaded.overleaf = { _state = state }
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'line one', 'aé中😀z' })
    vim.api.nvim_set_current_buf(buf)
    state.documents.main = { doc_id = 'main', bufnr = buf, joined = true }
    sent = {}
    bridge.request = function(method, params, callback)
      table.insert(sent, { method = method, params = vim.deepcopy(params) })
      if callback then callback(nil, {}) end
    end
    cursors.clear_all()
    cursors.setup()
  end)

  after_each(function()
    cursors.clear_all()
    vim.api.nvim_create_augroup('OverleafCursorTracking', { clear = true })
    vim.api.nvim_buf_delete(buf, { force = true })
    bridge.request, package.loaded.overleaf = original_request, original_overleaf
  end)

  it('sends zero-based rows and UTF-16 columns for the current live document', function()
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    cursors.publish_position()
    assert.are.same({ method = 'updatePosition', params = { doc_id = 'main', row = 1, column = 5 } }, sent[1])
  end)

  it('suppresses duplicates but allows a forced refresh', function()
    cursors.publish_position()
    cursors.publish_position()
    assert.are.equal(1, #sent)
    cursors.publish_position(true)
    assert.are.equal(2, #sent)
  end)

  it('throttles normal and insert-mode cursor events and uses the latest position', function()
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = buf })
    assert.is_true(vim.wait(500, function() return #sent == 1 end))
    assert.are.same({ doc_id = 'main', row = 1, column = 2 }, sent[1].params)
  end)

  it('clears the advertised document when leaving a live buffer', function()
    state.documents.main.joined = false
    cursors.publish_position()
    assert.are.same({ doc_id = vim.NIL }, sent[1].params)
  end)

  it('does not publish while disconnected and cancels queued updates', function()
    vim.api.nvim_exec_autocmds('CursorMoved', { buffer = buf })
    cursors.clear_all()
    state.connected = false
    cursors.publish_position(true)
    assert.is_nil(cursors._publish_timer)
    assert.are.equal(0, #sent)
  end)

  it('does not render the server echo of our own cursor', function()
    cursors.on_client_updated({ id = 'self', name = 'Me', doc_id = 'main', row = 0, column = 0 })
    assert.is_nil(cursors._collaborators.self)
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {}))
  end)

  it('renders stationary collaborators from the initial server snapshot', function()
    bridge.request = function(method, _, callback)
      assert.are.equal('getConnectedUsers', method)
      callback(nil, {
        users = {
          { client_id = 'self', first_name = 'Me', cursorData = { doc_id = 'main', row = 0, column = 0 } },
          {
            client_id = 'other',
            first_name = 'Alice',
            last_name = 'Example',
            cursorData = { doc_id = 'main', row = 1, column = 5 },
          },
        },
      })
    end
    cursors.load_collaborators()
    assert.is_nil(cursors._collaborators.self)
    assert.are.equal('Alice Example', cursors._collaborators.other.name)
    local marks = vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, { details = true })
    assert.are.equal(1, #marks)
    assert.are.equal(1, marks[1][2])
    assert.are.equal(10, marks[1][3]) -- UTF-16 column 5 after a non-BMP character.
    assert.are.equal(' Alice Example ', marks[1][4].virt_text[1][1])
  end)

  it('stores snapshot cursors until their document is opened', function()
    state.documents.main.bufnr = nil
    bridge.request = function(_, _, callback)
      callback(nil, {
        users = {
          { client_id = 'other', first_name = 'Alice', cursorData = { doc_id = 'main', row = 0, column = 2 } },
        },
      })
    end
    cursors.load_collaborators()
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {}))
    state.documents.main.bufnr = buf
    cursors.render_document('main')
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {}))
  end)

  it('does not replace a newer movement event with a pending snapshot', function()
    local reply
    bridge.request = function(_, _, callback) reply = callback end
    cursors.load_collaborators()
    cursors.on_client_updated({ id = 'other', name = 'Alice', doc_id = 'main', row = 1, column = 3 })
    reply(nil, {
      users = { { client_id = 'other', first_name = 'Alice', cursorData = { doc_id = 'main', row = 0, column = 0 } } },
    })
    assert.are.equal(1, cursors._collaborators.other.row)
    assert.are.equal(3, cursors._collaborators.other.col)
  end)

  it('discards a snapshot from a previous connection', function()
    local reply
    bridge.request = function(_, _, callback) reply = callback end
    cursors.load_collaborators()
    state.public_id = 'reconnected'
    reply(nil, { users = { { client_id = 'other', first_name = 'Alice' } } })
    assert.is_nil(cursors._collaborators.other)
  end)

  it('clears a collaborator mark when they leave the document', function()
    cursors.on_client_updated({ id = 'other', name = 'Alice', doc_id = 'main', row = 0, column = 2 })
    assert.are.equal(1, #vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {}))
    cursors.on_client_updated({ id = 'other', name = 'Alice', doc_id = vim.NIL })
    assert.are.same({}, vim.api.nvim_buf_get_extmarks(buf, cursors._ns, 0, -1, {}))
  end)

  it('does not resurrect an editor who left during a pending snapshot', function()
    local reply
    bridge.request = function(_, _, callback) reply = callback end
    cursors.load_collaborators()
    cursors.on_client_disconnected({ id = 'other' })
    reply(nil, { users = { { client_id = 'other', first_name = 'Alice' } } })
    assert.is_nil(cursors._collaborators.other)
  end)

  it('refreshes stationary editors and removes sessions missing from a later snapshot', function()
    cursors.on_client_updated({ id = 'old', name = 'Old', doc_id = 'main', row = 0, column = 0 })
    bridge.request = function(_, _, callback)
      callback(nil, { users = { { client_id = 'new', first_name = 'New', cursorData = vim.NIL } } })
    end
    cursors.load_collaborators()
    assert.is_nil(cursors._collaborators.old)
    assert.are.equal('New', cursors._collaborators.new.name)
    assert.is_nil(cursors._collaborators.new.doc_id)
  end)
end)

describe('collaborator navigation', function()
  local original_overleaf, original_tree, original_select, state, buf, selection
  local project = require('overleaf.project')

  before_each(function()
    original_overleaf, original_tree, original_select = package.loaded.overleaf, project._project_tree, vim.ui.select
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'first', 'aé中😀z' })
    state = { connected = true, public_id = 'self', project_id = 'project', documents = {} }
    package.loaded.overleaf = {
      _state = state,
      open_document = function(id, path, callback, opts)
        assert.are.equal('main', id)
        assert.are.equal('chapters/main.tex', path)
        assert.is_false(opts.display)
        callback({ bufnr = buf })
      end,
    }
    project._project_tree = { { id = 'main', path = 'chapters/main.tex', type = 'doc' } }
    selection = nil
    vim.ui.select = function(items, opts, callback) selection = { items = items, opts = opts, callback = callback } end
    cursors.clear_all()
  end)

  after_each(function()
    cursors.clear_all()
    vim.api.nvim_buf_delete(buf, { force = true })
    package.loaded.overleaf, project._project_tree, vim.ui.select = original_overleaf, original_tree, original_select
  end)

  it('jumps directly to the sole editor, translating their UTF-16 column to Neovim bytes', function()
    cursors.on_client_updated({ id = 'alice', name = 'Alice', doc_id = 'main', row = 1, column = 5 })
    cursors.jump()
    assert.is_nil(selection)
    assert.are.equal(buf, vim.api.nvim_get_current_buf())
    assert.are.same({ 2, 10 }, vim.api.nvim_win_get_cursor(0))
    assert.are.equal('chapters/main.tex', cursors.list()[1].path)
    assert.matches('^#%x%x%x%x%x%x$', cursors.list()[1].color)
  end)

  it('offers sorted names and files for multiple editors and uses the chosen editor latest cursor', function()
    cursors.on_client_updated({ id = 'bob', name = 'Bob', doc_id = 'main', row = 0, column = 0 })
    cursors.on_client_updated({ id = 'alice', name = 'Alice', doc_id = 'main', row = 0, column = 0 })
    cursors.jump()
    assert.are.equal('Alice', selection.items[1].name)
    assert.are.equal('Alice — chapters/main.tex', selection.opts.format_item(selection.items[1]))
    cursors.on_client_updated({ id = 'alice', doc_id = 'main', row = 1, column = 5 })
    selection.callback(selection.items[1])
    assert.are.same({ 2, 10 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('handles cancellation, departure, no open file, and project changes without jumping', function()
    local opened = false
    package.loaded.overleaf.open_document = function() opened = true end
    cursors.on_client_updated({ id = 'alice', name = 'Alice' })
    cursors.jump()
    assert.is_false(opened)
    cursors.on_client_updated({ id = 'bob', name = 'Bob', doc_id = 'main', row = 0, column = 0 })
    cursors.jump()
    selection.callback(nil)
    cursors.on_client_disconnected({ id = 'bob' })
    selection.callback(selection.items[2])
    state.project_id = 'different'
    selection.callback(selection.items[1])
    assert.is_false(opened)
  end)

  it('clamps cursors to the current document bounds', function()
    cursors.on_client_updated({ id = 'alice', name = 'Alice', doc_id = 'main', row = 100, column = 100 })
    cursors.jump()
    assert.are.same({ 2, 10 }, vim.api.nvim_win_get_cursor(0)) -- normal-mode end-of-line clamp
  end)

  it('does not steal focus when a connection changes while joining the document', function()
    local reply
    package.loaded.overleaf.open_document = function(_, _, callback) reply = callback end
    cursors.on_client_updated({ id = 'alice', name = 'Alice', doc_id = 'main', row = 0, column = 0 })
    cursors.jump()
    state.public_id = 'new connection'
    local oldbuf = vim.api.nvim_get_current_buf()
    reply({ bufnr = buf })
    assert.are.equal(oldbuf, vim.api.nvim_get_current_buf())
  end)
end)
