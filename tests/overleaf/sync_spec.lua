local bridge = require('overleaf.bridge')
local config = require('overleaf.config')
local sync = require('overleaf.sync')

describe('sync file watcher', function()
  it('ignores a delayed event from its own older mirror write', function()
    local sync_root = vim.fn.tempname()
    local original_config = vim.deepcopy(config._config)
    local original_request = bridge.request
    local requests = 0

    config.setup({ sync_dir = sync_root })
    sync.start('project')

    local doc = {
      doc_id = 'doc_self_write',
      path = 'main.tex',
      content = 'first edit',
      joined = false,
    }
    sync.write_doc(doc)

    -- The next edit reaches memory before the filesystem event for the prior
    -- write is delivered. It must not be reverted as an "external" change.
    doc.content = 'second edit'
    bridge.request = function() requests = requests + 1 end
    sync._on_file_changed(sync._sync_dir .. '/main.tex', doc)

    assert.are.equal(0, requests)
    assert.are.equal('second edit', doc.content)

    bridge.request = original_request
    sync.stop()
    config._config = original_config
    vim.fn.delete(sync_root, 'rf')
  end)
end)
