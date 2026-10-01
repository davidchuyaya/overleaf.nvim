local config = require('overleaf.config')
local sync = require('overleaf.sync')
local neo_tree = require('overleaf.neo_tree')

describe('Neo-tree live document handoff', function()
  local original_modules, original_config, original_sync_dir
  local editor_win, tree_win, tree_buf, state, subscriptions
  local opened, fallback_count

  before_each(function()
    original_modules = {}
    for _, name in ipairs({
      'neo-tree.events',
      'neo-tree.sources.manager',
      'neo-tree.sources.filesystem.commands',
      'overleaf',
    }) do
      original_modules[name] = package.loaded[name]
    end
    original_config = vim.deepcopy(config._config)
    original_sync_dir = sync._sync_dir
    sync._sync_dir = '/tmp/overleaf-neo-tree/project'
    config.setup({ explorer_key = '<leader>e' })
    editor_win = vim.api.nvim_get_current_win()
    vim.cmd('leftabove vsplit')
    tree_win = vim.api.nvim_get_current_win()
    tree_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(tree_win, tree_buf)
    vim.bo[tree_buf].filetype = 'neo-tree'
    state = {
      name = 'filesystem',
      path = sync._sync_dir,
      bufnr = tree_buf,
      winid = tree_win,
      tree = {
        get_node = function()
          return { type = 'file', get_id = function() return sync._sync_dir .. '/main.tex' end }
        end,
      },
    }
    opened, fallback_count = nil, 0
    package.loaded['neo-tree.sources.manager'] = {
      get_state_for_window = function(winid)
        if winid == tree_win then return state end
      end,
    }
    package.loaded['neo-tree.sources.filesystem.commands'] = {
      open = function() fallback_count = fallback_count + 1 end,
    }
    package.loaded['overleaf'] = {
      open_synced_file = function(path)
        opened = { path = path, win = vim.api.nvim_get_current_win() }
        return true
      end,
    }
    subscriptions = {}
    package.loaded['neo-tree.events'] = {
      AFTER_RENDER = 'after_render',
      FILE_OPEN_REQUESTED = 'file_open_requested',
      unsubscribe = function(event) subscriptions[event.event] = nil end,
      subscribe = function(event) subscriptions[event.event] = event end,
    }
  end)

  after_each(function()
    vim.api.nvim_create_augroup('OverleafNeoTree', { clear = true })
    if vim.api.nvim_win_is_valid(tree_win) then vim.api.nvim_win_close(tree_win, true) end
    if vim.api.nvim_buf_is_valid(tree_buf) then vim.api.nvim_buf_delete(tree_buf, { force = true }) end
    for _, name in ipairs({
      'neo-tree.events',
      'neo-tree.sources.manager',
      'neo-tree.sources.filesystem.commands',
      'overleaf',
    }) do
      package.loaded[name] = original_modules[name]
    end
    config._config = original_config
    sync._sync_dir = original_sync_dir
  end)

  local function enter()
    vim.api.nvim_set_current_win(tree_win)
    local mapping = vim.fn.maparg('<CR>', 'n', false, true)
    assert.is_function(mapping.callback)
    mapping.callback()
  end

  it('restores live Enter after an asynchronous render overwrites FileType mappings', function()
    neo_tree.setup()
    neo_tree.attach(tree_buf)
    -- Neo-tree acquires its window after FileType and resets the keymaps.
    vim.keymap.set('n', '<CR>', function() fallback_count = fallback_count + 1 end, { buffer = tree_buf })
    subscriptions.after_render.handler(state)
    enter()
    assert.are.same({ path = sync._sync_dir .. '/main.tex', win = editor_win }, opened)
    assert.are.equal(0, fallback_count)
  end)

  it('restores live Enter when a reused tree is reopened', function()
    neo_tree.setup()
    subscriptions.after_render.handler(state)
    vim.keymap.set('n', '<CR>', function() fallback_count = fallback_count + 1 end, { buffer = tree_buf })
    subscriptions.after_render.handler(state)
    enter()
    assert.is_not_nil(opened)
    assert.are.equal(0, fallback_count)
  end)

  it('does not override ordinary filesystem trees', function()
    state.path = '/tmp/unrelated-project'
    neo_tree.setup()
    vim.keymap.set('n', '<CR>', function() fallback_count = fallback_count + 1 end, { buffer = tree_buf })
    subscriptions.after_render.handler(state)
    enter()
    assert.is_nil(opened)
    assert.are.equal(1, fallback_count)
  end)

  it('keeps ordinary opening for non-document files', function()
    package.loaded['overleaf'].open_synced_file = function() return false end
    neo_tree.setup()
    subscriptions.after_render.handler(state)
    enter()
    assert.are.equal(1, fallback_count)
    assert.are.equal(tree_win, vim.api.nvim_get_current_win())
  end)

  it('intercepts the default file-open event even without our Enter mapping', function()
    neo_tree.setup()
    local result = subscriptions.file_open_requested.handler({
      state = state,
      path = sync._sync_dir .. '/main.tex',
      open_cmd = 'edit',
    })
    assert.are.same({ handled = true }, result)
    assert.are.same({ path = sync._sync_dir .. '/main.tex', win = editor_win }, opened)
  end)

  it('leaves unrelated files to Neo-tree', function()
    neo_tree.setup()
    local result = subscriptions.file_open_requested.handler({
      state = state,
      path = '/tmp/unrelated-project/main.tex',
      open_cmd = 'edit',
    })
    assert.is_nil(result)
    assert.is_nil(opened)
  end)
end)
