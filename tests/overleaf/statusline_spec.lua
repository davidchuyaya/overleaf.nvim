local overleaf = require('overleaf')
local bridge = require('overleaf.bridge')
local Document = require('overleaf.document')
local ot = require('overleaf.ot')
local cursors = require('overleaf.cursors')
local project = require('overleaf.project')
local status = require('overleaf.statusline')

describe('confirmed project sync status', function()
  local original_state, original_request, original_handlers, original_tree, sent, docs

  before_each(function()
    original_state, original_request = overleaf._state, bridge.request
    original_handlers, original_tree = bridge._event_handlers, project._project_tree
    overleaf._state = { connected = true, public_id = 'self', project_id = 'project', documents = {} }
    bridge._event_handlers = {}
    cursors.clear_all()
    project._project_tree = {}
    status.reset()
    sent, docs = {}, {}
    bridge.request = function(method, params, callback)
      table.insert(sent, { method = method, params = params, callback = callback })
    end
    overleaf._setup_event_handlers()
  end)

  after_each(function()
    for _, doc in ipairs(docs) do
      doc:_stop_ack_timer()
      if doc._flush_timer then vim.fn.timer_stop(doc._flush_timer) end
      if doc.bufnr and vim.api.nvim_buf_is_valid(doc.bufnr) then
        vim.api.nvim_buf_delete(doc.bufnr, { force = true })
      end
    end
    cursors.clear_all()
    status.reset()
    overleaf._state, bridge.request = original_state, original_request
    bridge._event_handlers, project._project_tree = original_handlers, original_tree
  end)

  local function document(id)
    local doc = Document.new(id or 'main', (id or 'main') .. '.tex')
    doc.joined, doc.version, doc.content, doc.server_content = true, 0, 'Hello', 'Hello'
    overleaf._state.documents[doc.doc_id] = doc
    table.insert(docs, doc)
    return doc
  end

  local function edit(doc, ops)
    doc.content = ot.apply(doc.content, ops)
    doc:submit_op(ops)
    doc:flush()
  end

  local function ack(doc, version) bridge._event_handlers.otUpdateApplied[1]({ doc = doc.doc_id, v = version }) end

  it('never invents a successful sync timestamp on connection or API queue success', function()
    local doc = document()
    assert.are.equal('idle', status.snapshot().kind)
    assert.is_nil(status.snapshot().last_ack_at)
    edit(doc, { { p = 5, i = '!' } })
    sent[1].callback(nil, {})
    assert.are.equal('syncing', status.snapshot().kind)
    assert.is_nil(status.snapshot().last_ack_at)
    assert.are.equal('Hello', doc.server_content)
    assert.are.equal(0, doc.version)
    ack(doc, 0)
    assert.are.equal('Hello!', doc.server_content)
    assert.are.equal(1, doc.version)
    assert.are.equal('synced', status.snapshot().kind)
    assert.is_number(status.snapshot().last_ack_at)
    assert.is_nil(doc._ack_timer)
  end)

  it('keeps the checkmark off until edits queued behind an in-flight edit are also applied', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    edit(doc, { { p = 6, i = '?' } })
    assert.are.equal(1, #sent)
    ack(doc, 0)
    assert.are.equal(2, #sent)
    assert.are.equal(1, sent[2].params.v)
    assert.are.equal('syncing', status.snapshot().kind)
    sent[2].callback(nil, {})
    assert.are.equal('syncing', status.snapshot().kind)
    ack(doc, 1)
    assert.are.equal('synced', status.snapshot().kind)
    assert.are.equal('Hello!?', doc.server_content)
    assert.are.equal(2, doc._confirmed_revision)
  end)

  it('ignores duplicate applied ACKs and late RPC failures for already confirmed edits', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    ack(doc, 0)
    edit(doc, { { p = 6, i = '?' } })
    ack(doc, 0)
    sent[1].callback({ message = 'late queue error' })
    assert.are.equal(1, doc.version)
    assert.is_nil(doc._rejoining)
    assert.are.equal('syncing', status.snapshot().kind)
    ack(doc, 1)
    assert.are.equal('synced', status.snapshot().kind)
  end)

  it('handles a collaborator edit before our applied ACK with correct versions and transforms', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 0, op = { { p = 0, i = 'Remote ' } } })
    assert.are.equal(1, doc.version)
    assert.are.equal('Remote Hello!', doc.content)
    assert.is_nil(status.snapshot().last_ack_at)
    ack(doc, 1)
    assert.are.equal('Remote Hello!', doc.server_content)
    assert.are.equal('synced', status.snapshot().kind)
  end)

  it('aggregates all documents, not only the current buffer', function()
    local a, b = document('a'), document('b')
    edit(a, { { p = 5, i = '!' } })
    edit(b, { { p = 5, i = '?' } })
    ack(a, 0)
    assert.are.equal('syncing', status.snapshot().kind)
    ack(b, 0)
    assert.are.equal('synced', status.snapshot().kind)
    b._sync_uncertain = true
    assert.are.equal('unconfirmed', status.snapshot().kind)
  end)

  it('does not move our last-sync time for remote edits or show success while offline', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    ack(doc, 0)
    status._last_ack_at = os.time() - 120
    local last_ack_at = status._last_ack_at
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 1, op = { { p = 6, i = ' remote' } } })
    assert.are.equal(last_ack_at, status.snapshot().last_ack_at)
    assert.are.equal(' ✓ ', status.sync_text(status.snapshot()))
    overleaf._state.connected = false
    assert.are.equal('offline', status.snapshot().kind)
    assert.are.same({}, status.snapshot().collaborators)
    overleaf._state.project_id = nil
    assert.is_false(status.snapshot().visible)
  end)

  it('detects buffer edits that could not be submitted without falsely counting modified-but-synced buffers', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    ack(doc, 0)
    doc.bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { 'Hello!' })
    assert.is_true(vim.bo[doc.bufnr].modified)
    assert.are.equal('synced', status.snapshot().kind)
    vim.api.nvim_buf_set_lines(doc.bufnr, 0, -1, false, { 'unsubmitted text' })
    assert.are.equal('syncing', status.snapshot().kind)
  end)

  it('does not confirm recovery snapshots that discarded unacknowledged changes', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    doc:rejoin()
    assert.is_true(doc._sync_uncertain)
    assert.is_nil(doc._ack_timer)
    assert.are.equal('unconfirmed', status.snapshot().kind)
    assert.is_nil(status.snapshot().last_ack_at)
    assert.is_false(doc:_on_ack({ v = 0 }))
  end)

  it('rejects missing and future versions rather than granting a false confirmation', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    assert.is_false(doc:_on_ack({}))
    assert.is_false(doc:_on_ack({ v = 3 }))
    assert.is_nil(status.snapshot().last_ack_at)
    assert.are.equal('unconfirmed', status.snapshot().kind)
  end)

  it('uses a fixed-width symbol for every sync state without showing elapsed time', function()
    local symbols = { synced = '✓', syncing = '⧖', idle = '○', unconfirmed = '!', offline = '×' }
    for kind, symbol in pairs(symbols) do
      local text = status.sync_text({ kind = kind, last_ack_at = os.time() - 120 })
      assert.are.equal(' ' .. symbol .. ' ', text)
      assert.are.equal(3, vim.fn.strdisplaywidth(text))
      assert.are.equal(text, status.sync_text({ kind = kind, last_ack_at = os.time() - 86400 }))
    end
  end)

  it('places collaborator presence before the final sync symbol', function()
    local component = status.component()
    assert.are.equal(20, component[1].flexible)
    assert.are.equal(' ✓ ', component[#component].provider({ overleaf_snapshot = { kind = 'synced' } }))
  end)

  it('waits for applied confirmation for externally changed mirrors with no buffer', function()
    local doc = document()
    doc.joined = false
    require('overleaf.sync')._sync_closed_doc(doc, 'External')
    assert.are.equal('joinDoc', sent[1].method)
    assert.are.equal('syncing', status.snapshot().kind)
    sent[1].callback(nil, { lines = { 'Hello' }, version = 0 })
    assert.are.equal('applyOtUpdate', sent[2].method)
    sent[2].callback(nil, {})
    assert.are.equal('Hello', doc.server_content)
    assert.are.equal('syncing', status.snapshot().kind)
    ack(doc, 0)
    assert.are.equal('External', doc.server_content)
    assert.are.equal('synced', status.snapshot().kind)
    assert.is_true(doc.joined)
  end)

  it('coalesces external changes during join and serializes later edits behind their applied ACK', function()
    local doc = document()
    doc.joined = false
    local sync = require('overleaf.sync')
    sync._sync_closed_doc(doc, 'First')
    sync._sync_closed_doc(doc, 'Second')
    assert.are.equal(1, #sent)
    sent[1].callback(nil, { lines = { 'Hello' }, version = 0 })
    assert.are.equal('Second', doc.content)
    sync._sync_closed_doc(doc, 'Third')
    assert.are.equal(2, #sent)
    ack(doc, 0)
    assert.are.equal('Second', doc.server_content)
    assert.are.equal(3, #sent)
    assert.are.equal('syncing', status.snapshot().kind)
    ack(doc, 1)
    assert.are.equal('Third', doc.server_content)
    assert.are.equal('synced', status.snapshot().kind)
  end)

  it('shares a pending mirror join with a user open instead of losing its in-flight edit', function()
    local doc = document()
    doc.joined = false
    require('overleaf.sync')._sync_closed_doc(doc, 'External')
    local callback = function() end
    overleaf.open_document('main', 'main.tex', callback, { display = false })
    assert.are.equal(doc, overleaf._state.documents.main)
    assert.are.equal(callback, doc._external_open_request.callback)
    -- Exercise the handoff without creating a real LSP-backed buffer here.
    local original_open = overleaf.open_document
    local handoff
    overleaf.open_document = function(id, path, on_open, opts)
      handoff = { id = id, path = path, callback = on_open, display = opts.display }
    end
    sent[1].callback(nil, { lines = { 'Hello' }, version = 0 })
    overleaf.open_document = original_open
    assert.are.same({ id = 'main', path = 'main.tex', callback = callback, display = false }, handoff)
    assert.is_not_nil(doc.inflight_op)
    ack(doc, 0)
    assert.are.equal('synced', status.snapshot().kind)
  end)

  it('waits for confirmation of a mirror edit on exit even when it has no buffer', function()
    local doc = document()
    edit(doc, { { p = 5, i = '!' } })
    assert.is_false(overleaf.flush_all(10))
    ack(doc, 0)
    assert.is_true(overleaf.flush_all(10))
  end)
end)
