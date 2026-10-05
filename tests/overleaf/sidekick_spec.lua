local sidekick = require('overleaf.sidekick')
local sync = require('overleaf.sync')

describe('Sidekick mirror context', function()
  local original_location, original_overleaf, original_sync_dir
  local root, file, buf, location, calls

  before_each(function()
    original_location = package.loaded['sidekick.cli.context.location']
    original_overleaf, original_sync_dir = package.loaded.overleaf, sync._sync_dir
    root = vim.fn.tempname()
    vim.fn.mkdir(root, 'p')
    root = vim.uv.fs_realpath(root)
    file = root .. '/main.txt'
    vim.fn.writefile({ 'hello' }, file)
    buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, file)
    vim.bo[buf].buftype = 'acwrite'
    sync._sync_dir = root
    package.loaded.overleaf = { _state = { documents = { main = { path = 'main.txt', bufnr = buf } } } }
    calls = 0
    location = {
      is_file = function(b)
        calls = calls + 1
        return vim.bo[b].buflisted
          and vim.tbl_contains({ '', 'help' }, vim.bo[b].buftype)
          and vim.fn.filereadable(vim.api.nvim_buf_get_name(b)) == 1
      end,
    }
    package.loaded['sidekick.cli.context.location'] = location
  end)

  after_each(function()
    vim.api.nvim_create_augroup('OverleafSidekick', { clear = true })
    vim.api.nvim_buf_delete(buf, { force = true })
    vim.fn.delete(root, 'rf')
    package.loaded['sidekick.cli.context.location'] = original_location
    package.loaded.overleaf, sync._sync_dir = original_overleaf, original_sync_dir
  end)

  it('accepts tracked mirrors without changing their buffer type or invoking saves', function()
    assert.is_false(location.is_file(buf))
    assert.is_true(sidekick.attach())
    assert.is_true(location.is_file(buf))
    assert.are.equal('acwrite', vim.bo[buf].buftype)
    assert.are.same({ 'hello' }, vim.fn.readfile(file))
  end)

  it('keeps ordinary and help file context unchanged', function()
    sidekick.attach()
    package.loaded.overleaf._state.documents = {}
    for _, buftype in ipairs({ '', 'help' }) do
      vim.bo[buf].buftype = buftype
      assert.is_true(location.is_file(buf))
    end
  end)

  it('does not accept unrelated acwrite, nofile, or unlisted buffers', function()
    sidekick.attach()
    package.loaded.overleaf._state.documents = {}
    assert.is_false(location.is_file(buf))
    package.loaded.overleaf._state.documents.main = { path = 'main.txt', bufnr = buf }
    vim.bo[buf].buftype = 'nofile'
    assert.is_false(location.is_file(buf))
    vim.bo[buf].buftype = 'acwrite'
    vim.bo[buf].buflisted = false
    assert.is_false(location.is_file(buf))
  end)

  it('requires a readable mirror at the tracked document path', function()
    sidekick.attach()
    sync._sync_dir = root .. '/another-project'
    assert.is_false(location.is_file(buf))
    sync._sync_dir = root
    vim.fn.delete(file)
    assert.is_false(location.is_file(buf))
    vim.api.nvim_buf_set_name(buf, 'overleaf://main.txt')
    assert.is_false(location.is_file(buf))
  end)

  it('does not recognize stale buffers after disconnect or module removal', function()
    sidekick.attach()
    package.loaded.overleaf._state.documents = {}
    assert.is_false(location.is_file(buf))
    package.loaded.overleaf = nil
    assert.is_false(location.is_file(buf))
  end)

  it('is idempotent across repeated setup and supports the current-buffer handle', function()
    sidekick.setup()
    local wrapped = location.is_file
    sidekick.setup()
    assert.are.equal(wrapped, location.is_file)
    vim.api.nvim_set_current_buf(buf)
    calls = 0
    assert.is_true(location.is_file(0))
    assert.are.equal(1, calls)
  end)

  it('reattaches if Sidekick is loaded or replaces its location module later', function()
    sidekick.setup()
    local replacement = { is_file = function() return false end }
    package.loaded['sidekick.cli.context.location'] = replacement
    vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'sidekick.nvim' })
    assert.is_true(replacement.is_file(buf))
  end)
end)
