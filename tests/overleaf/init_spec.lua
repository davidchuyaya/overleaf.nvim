describe('overleaf shutdown', function()
  it('flushes pending edits and removes buffers in resession pre-save', function()
    local hooks = {}
    package.loaded.resession = {
      add_hook = function(name, callback) hooks[name] = callback end,
    }
    package.loaded.overleaf = nil

    local overleaf = require('overleaf')
    local sync = require('overleaf.sync')
    local sync_root = vim.fn.tempname()
    overleaf.setup({ keys = false, sync_dir = sync_root })
    sync.start('project')

    require('overleaf.config').setup({ pdf_viewer = 'skim' })
    assert.are.same({ 'open', '-a', 'Skim', '/tmp/output.pdf' }, overleaf._viewer_command('/tmp/output.pdf'))

    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, sync._sync_dir .. '/main.tex')
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'new content' })
    vim.bo[bufnr].modified = true

    local doc = {
      doc_id = 'doc_shutdown',
      path = 'main.tex',
      bufnr = bufnr,
      joined = true,
      content = 'new content',
      server_content = 'old content',
      pending_ops = { { p = 0, i = 'new content' } },
      inflight_op = nil,
      _rejoining = false,
      _flush_timer = nil,
      flush = function(self)
        self.inflight_op = self.pending_ops
        self.pending_ops = nil
        vim.defer_fn(function()
          self.server_content = self.content
          self.inflight_op = nil
        end, 10)
      end,
    }

    overleaf._state.connected = true
    overleaf._state.documents = { [doc.doc_id] = doc }

    assert.is_true(overleaf.flush_all(500))
    assert.are.equal('new content', table.concat(vim.fn.readfile(sync._sync_dir .. '/main.tex'), '\n'))
    assert.is_false(vim.bo[bufnr].modified)

    overleaf._prepare_exit()
    assert.is_true(overleaf._exit_cleanup_pending)
    assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
    assert.is_function(hooks.pre_save)

    hooks.pre_save()
    assert.is_false(overleaf._exit_cleanup_pending)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))

    overleaf._state.connected = false
    overleaf._state.documents = {}
    sync.stop()
    vim.fn.delete(sync_root, 'rf')
    package.loaded.resession = nil
  end)
end)

describe('overleaf compile modes', function()
  local overleaf = require('overleaf')
  local bridge = require('overleaf.bridge')
  local config = require('overleaf.config')
  local original_config
  local original_request
  local original_state

  before_each(function()
    original_config = vim.deepcopy(config._config)
    original_request = bridge.request
    original_state = vim.deepcopy(overleaf._state)
    overleaf._state.connected = true
    overleaf._state.project_id = 'project-id'
    overleaf._state.csrf_token = 'csrf-token'
  end)

  after_each(function()
    config._config = original_config
    bridge.request = original_request
    overleaf._state = original_state
  end)

  it('passes fast draft mode to the bridge', function()
    local request
    config.setup({ compile_mode = 'fast' })
    bridge.request = function(method, params) request = { method = method, params = params } end

    overleaf.compile()

    assert.are.equal('compile', request.method)
    assert.is_true(request.params.draft)
  end)

  it('can override fast mode with a normal compile', function()
    local request
    config.setup({ compile_mode = 'fast' })
    bridge.request = function(method, params) request = { method = method, params = params } end

    overleaf.compile('normal')

    assert.are.equal('compile', request.method)
    assert.is_false(request.params.draft)
  end)
end)
