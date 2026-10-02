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
    bridge._event_handlers.otUpdateApplied[1]({ doc = 'main', v = 1, op = { { p = 6, i = ' remote' } } })
    assert.matches('2 minutes ago', status.sync_text(status.snapshot()))
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

  it('formats relative time with singular units and larger intervals', function()
    assert.are.equal('just now', status.relative_time(100, 103))
    assert.are.equal('10 seconds ago', status.relative_time(100, 110))
    assert.are.equal('1 minute ago', status.relative_time(100, 160))
    assert.are.equal('2 minutes ago', status.relative_time(100, 220))
    assert.are.equal('1 hour ago', status.relative_time(100, 3700))
    assert.are.equal('2 days ago', status.relative_time(100, 172900))
    assert.are.equal('just now', status.relative_time(200, 100))
  end)
end)
