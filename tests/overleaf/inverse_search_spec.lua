local overleaf = require('overleaf')
local inverse = require('overleaf.inverse_search')
local config = require('overleaf.config')
local bridge = require('overleaf.bridge')
local project = require('overleaf.project')
local buffer = require('overleaf.buffer')
local sync = require('overleaf.sync')

describe('Sioyek inverse search', function()
  local saved, windows, buffers, joins

  before_each(function()
    saved = {
      state = overleaf._state,
      pdf = overleaf._pdf_state,
      config = vim.deepcopy(config._config),
      tree = project._project_tree,
      request = bridge.request,
      serverstart = vim.fn.serverstart,
      jobstart = vim.fn.jobstart,
      show = overleaf._show_pdf,
      system = vim.system,
    }
    config.setup({ pdf_viewer = 'sioyek', sioyek_inverse_search = true, sync_dir = false, log_level = 'error' })
    overleaf._state = { connected = true, project_id = 'project-a', documents = {} }
    overleaf._pdf_state = { connection = 3 }
    project._project_tree = {
      { id = 'main', path = 'main.tex', type = 'doc' },
      { id = 'intro', path = 'chapters/intro.tex', type = 'doc' },
      { id = 'other', path = 'other/intro.tex', type = 'doc' },
    }
    windows, buffers, joins = {}, {}, {}
    vim.fn.serverstart = function() return '/tmp/overleaf test socket' end
    vim.fn.jobstart = function() return 1 end
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' then
        joins[#joins + 1] = params.docId
        callback(nil, { lines = { 'First line', 'Second line', 'Third line' }, version = 0 })
      elseif callback then
        callback(nil, {
          inputs = {
            '/compile/./main.tex',
            '/compile/chapters/intro.tex',
            './other/intro.tex',
            '/usr/local/texlive/article.cls',
          },
        })
      end
    end
  end)

  after_each(function()
    inverse._click = nil
    sync.stop()
    overleaf._state.connected = false
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    end
    buffer.cleanup_all(overleaf._state.documents)
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
    end
    overleaf._state, overleaf._pdf_state = saved.state, saved.pdf
    config._config, project._project_tree = saved.config, saved.tree
    bridge.request, vim.fn.serverstart, vim.fn.jobstart = saved.request, saved.serverstart, saved.jobstart
    overleaf._show_pdf = saved.show
    vim.system = saved.system
  end)

  local function prepare()
    local done = false
    inverse.prepare('/tmp/My project.pdf', {}, 'https://worker.test/output.pdf?build=abc', function() done = true end)
    assert.is_true(done)
  end

  local function request(file, line, col)
    return {
      context = vim.deepcopy(overleaf._pdf_state.inverse.context),
      file = file or '/compile/chapters/intro.tex',
      line = line or 2,
      column = col or 4,
    }
  end

  it('passes the exact map artifact URL and local PDF path to the bridge', function()
    local params, done
    bridge.request = function(method, value, callback)
      assert.equals('downloadSynctex', method)
      params = value
      callback(nil, { inputs = { './main.tex' } })
    end
    inverse.prepare(
      '/tmp/p.pdf',
      { { path = 'output.synctex.gz', url = '/build/abc/output.synctex.gz?clsiserverid=worker' } },
      'https://worker.test/output.pdf?build=abc',
      function() done = true end
    )
    assert.equals(config.get().base_url .. '/build/abc/output.synctex.gz?clsiserverid=worker', params.url)
    assert.equals('/tmp/p.pdf', params.pdfPath)
    assert.equals('https://worker.test/output.pdf?build=abc', params.pdfUrl)
    assert.is_true(done)
    assert.is_true(overleaf._pdf_state.inverse.ready)
  end)

  it('sets a Qt-quoted callback with the correct RPC server and placeholders', function()
    prepare()
    local command = overleaf._viewer_command('/tmp/My project.pdf')
    assert.equals('--inverse-search', command[3])
    assert.is_truthy(command[4]:find('"' .. config.plugin_root() .. '/node/inverse-search.js"', 1, true))
    assert.is_truthy(
      command[4]:find(
        '"' .. (vim.v.servername ~= '' and vim.v.servername or '/tmp/overleaf test socket') .. '"',
        1,
        true
      )
    )
    assert.is_truthy(command[4]:find('"%1" "%2" "%3"', 1, true))
    assert.equals('/tmp/My project.pdf', command[5])
  end)

  it('opens a fresh live buffer in the main editor without replacing Sidekick', function()
    prepare()
    local main = vim.api.nvim_get_current_win()
    local blank = vim.api.nvim_create_buf(true, false)
    buffers[#buffers + 1] = blank
    vim.api.nvim_win_set_buf(main, blank)
    vim.cmd('vsplit')
    local terminal = vim.api.nvim_get_current_win()
    windows[#windows + 1] = terminal
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = terminal_buf
    vim.api.nvim_win_set_buf(terminal, terminal_buf)
    vim.api.nvim_open_term(terminal_buf, {})
    assert.equals(1, inverse.receive(request()))
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.intro ~= nil end))
    local doc = overleaf._state.documents.intro
    assert.is_true(doc.joined)
    assert.equals('acwrite', vim.bo[doc.bufnr].buftype)
    assert.equals(main, vim.api.nvim_get_current_win())
    assert.equals(terminal_buf, vim.api.nvim_win_get_buf(terminal))
    assert.equals(doc.bufnr, vim.api.nvim_win_get_buf(main))
    assert.are.same({ 2, 3 }, vim.api.nvim_win_get_cursor(main))
    assert.are.same({ 'intro' }, joins)
  end)

  it('reuses a joined live buffer and clamps absent/out-of-range source positions', function()
    prepare()
    assert.equals(1, inverse.receive(request('/compile/./main.tex', 300, 0)))
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.main ~= nil end))
    assert.are.same({ 3, 0 }, vim.api.nvim_win_get_cursor(0))
    assert.equals(1, inverse.receive(request('/compile/./main.tex', 1, 300)))
    assert.is_true(vim.wait(1000, function() return vim.api.nvim_win_get_cursor(0)[1] == 1 end))
    assert.are.same({ 1, 9 }, vim.api.nvim_win_get_cursor(0))
    assert.are.same({ 'main' }, joins)
  end)

  it('never uses basename matching or opens system/package/unlisted files', function()
    prepare()
    for _, file in ipairs({ '/usr/local/texlive/article.cls', 'intro.tex', '/compile/../main.tex', '/tmp/main.tex' }) do
      assert.equals(0, inverse.receive(request(file)))
    end
    assert.equals(1, inverse.receive(request('./other/intro.tex')))
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.other ~= nil end))
    assert.is_nil(overleaf._state.documents.intro)
  end)

  it('rejects disconnected, reconnected, wrong-project and wrong-instance callbacks', function()
    prepare()
    local original = request()
    for _, field in ipairs({ 'project', 'instance', 'pdf', 'connection' }) do
      local bad = vim.deepcopy(original)
      bad.context[field] = field == 'connection' and 99 or 'wrong'
      assert.equals(0, inverse.receive(bad))
    end
    overleaf._state.connected = false
    assert.equals(0, inverse.receive(original))
    overleaf._state.connected = true
    overleaf._reset_pdf_connection()
    assert.equals(0, inverse.receive(original))
    assert.is_nil(inverse.command('/tmp/My project.pdf'))
  end)

  it('ignores a slow earlier click when a newer click completes first', function()
    prepare()
    local pending = {}
    bridge.request = function(method, params, callback)
      if method == 'joinDoc' then pending[params.docId] = callback end
    end
    assert.equals(1, inverse.receive(request()))
    assert.is_true(vim.wait(1000, function() return pending.intro ~= nil end))
    assert.equals(1, inverse.receive(request('./other/intro.tex', 1, 1)))
    assert.is_true(vim.wait(1000, function() return pending.other ~= nil end))
    pending.other(nil, { lines = { 'other' }, version = 0 })
    local buf = overleaf._state.documents.other.bufnr
    assert.equals(buf, vim.api.nvim_get_current_buf())
    pending.intro(nil, { lines = { 'intro' }, version = 0 })
    assert.equals(buf, vim.api.nvim_get_current_buf())
  end)

  it('still opens a PDF when SyncTeX is missing and disables stale mapping', function()
    prepare()
    local old = request()
    local shown
    bridge.request = function(method, _, callback)
      if method == 'downloadUrl' then
        callback(nil, { path = '/tmp/My project.pdf' })
      elseif method == 'downloadSynctex' then
        callback({ message = '404' })
      end
    end
    overleaf._show_pdf = function(path) shown = path end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://worker.test/output.pdf' } })
    assert.is_true(vim.wait(1000, function() return shown ~= nil end))
    assert.equals('/tmp/My project.pdf', shown)
    assert.equals(0, inverse.receive(old))
    assert.is_nil(inverse.command('/tmp/My project.pdf'))
  end)

  it('does not launch a stale PDF if the connection changes while fetching its map', function()
    local complete, shown
    bridge.request = function(method, _, callback)
      if method == 'downloadUrl' then
        callback(nil, { path = '/tmp/My project.pdf' })
      elseif method == 'downloadSynctex' then
        complete = callback
      end
    end
    overleaf._show_pdf = function() shown = true end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://worker.test/output.pdf' } })
    overleaf._reset_pdf_connection()
    complete(nil, { inputs = { './main.tex' } })
    vim.wait(20, function() return false end)
    assert.is_nil(shown)
    assert.is_nil(overleaf._pdf_state.inverse)
  end)

  it('can be disabled without downloading a map or adding viewer arguments', function()
    config.setup({ sioyek_inverse_search = false })
    bridge.request = function() error('must not request a map') end
    local done = false
    inverse.prepare('/tmp/p.pdf', {}, 'https://worker.test/output.pdf', function() done = true end)
    assert.is_true(done)
    assert.equals(3, #overleaf._viewer_command('/tmp/p.pdf'))
  end)

  it('opens a new editor pane when only a terminal pane is available', function()
    prepare()
    local terminal = vim.api.nvim_get_current_win()
    local terminal_buf = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = terminal_buf
    vim.api.nvim_win_set_buf(terminal, terminal_buf)
    vim.api.nvim_open_term(terminal_buf, {})
    assert.equals(1, inverse.receive(request()))
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.intro ~= nil end))
    local editor = vim.api.nvim_get_current_win()
    windows[#windows + 1] = editor
    assert.is_not.equal(terminal, editor)
    assert.equals(terminal_buf, vim.api.nvim_win_get_buf(terminal))
    assert.equals(overleaf._state.documents.intro.bufnr, vim.api.nvim_win_get_buf(editor))
  end)

  it('waits for an already-joining document without issuing a second join', function()
    prepare()
    local complete, count = nil, 0
    bridge.request = function(method, _, callback)
      if method == 'joinDoc' then
        count = count + 1
        complete = callback
      end
    end
    overleaf.open_document('intro', 'chapters/intro.tex', nil, { display = false })
    assert.equals(1, inverse.receive(request()))
    assert.is_true(vim.wait(1000, function() return overleaf._state.documents.intro._open_waiters ~= nil end))
    assert.equals(1, count)
    complete(nil, { lines = { 'First line', 'Second line' }, version = 0 })
    assert.equals(overleaf._state.documents.intro.bufnr, vim.api.nvim_get_current_buf())
    assert.are.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
  end)

  it('leaves ordinary PDF viewing available when the RPC server cannot start', function()
    prepare()
    if vim.v.servername ~= '' then return end
    vim.fn.serverstart = function() error('operation not permitted') end
    assert.is_nil(inverse.command('/tmp/My project.pdf'))
    assert.equals(3, #overleaf._viewer_command('/tmp/My project.pdf'))
  end)

  it('enables inverse search after an earlier map failure without forcing a PDF reload', function()
    local commands, downloads = {}, 0
    vim.system = function(_, _, callback) callback({ code = 0, stdout = 'true\n' }) end
    vim.fn.jobstart = function(command)
      commands[#commands + 1] = command
      return 1
    end
    bridge.request = function(method, _, callback)
      if method == 'downloadUrl' then
        callback(nil, { path = '/tmp/My project.pdf' })
      elseif method == 'downloadSynctex' then
        downloads = downloads + 1
        if downloads == 1 then
          callback({ message = '404' })
        else
          callback(nil, { inputs = { './main.tex' } })
        end
      end
    end
    local outputs = { { path = 'output.pdf', url = 'https://worker.test/output.pdf' } }
    overleaf._open_pdf(outputs)
    assert.is_true(vim.wait(1000, function() return #commands == 1 end))
    assert.is_false(vim.tbl_contains(commands[1], '--inverse-search'))
    overleaf._open_pdf(outputs)
    assert.is_true(vim.wait(1000, function() return #commands == 2 end))
    assert.is_true(vim.tbl_contains(commands[2], '--inverse-search'))
    assert.is_false(vim.tbl_contains(commands[2], '--execute-command'))
    overleaf._open_pdf(outputs)
    local done = false
    vim.schedule(function()
      vim.schedule(function() done = true end)
    end)
    assert.is_true(vim.wait(1000, function() return done end))
    assert.equals(2, #commands)
  end)
end)
