describe('PDF viewer commands', function()
  local overleaf = require('overleaf')
  local config = require('overleaf.config')
  local bridge = require('overleaf.bridge')
  local saved_config, saved_has, saved_request, saved_jobstart

  before_each(function()
    saved_config = vim.deepcopy(config._config)
    saved_has = vim.fn.has
    saved_request = bridge.request
    saved_jobstart = vim.fn.jobstart
  end)

  after_each(function()
    config._config = saved_config
    vim.fn.has = saved_has
    bridge.request = saved_request
    vim.fn.jobstart = saved_jobstart
  end)

  it('launches the macOS Sioyek executable with an explicit reload', function()
    vim.fn.has = function(feature) return feature == 'mac' and 1 or saved_has(feature) end
    config.setup({ pdf_viewer = 'sioyek' })
    assert.are.same({
      '/Applications/sioyek.app/Contents/MacOS/sioyek',
      '--reuse-window',
      '--execute-command',
      'reload',
      '/tmp/project with spaces.pdf',
    }, overleaf._viewer_command('/tmp/project with spaces.pdf'))
  end)

  it('uses the PATH executable outside macOS', function()
    vim.fn.has = function(feature) return feature == 'mac' and 0 or saved_has(feature) end
    config.setup({ pdf_viewer = 'Sioyek' })
    assert.are.same(
      { 'sioyek', '--reuse-window', '--execute-command', 'reload', '/tmp/project.pdf' },
      overleaf._viewer_command('/tmp/project.pdf')
    )
  end)

  it('preserves custom viewer arguments without mutating the configuration', function()
    local command = { '/custom/sioyek', '--reuse-window', '--execute-command', 'reload' }
    config.setup({ pdf_viewer = vim.deepcopy(command) })
    local expected = vim.deepcopy(command)
    table.insert(expected, '/tmp/project.pdf')
    assert.are.same(expected, overleaf._viewer_command('/tmp/project.pdf'))
    assert.are.same(command, config.get().pdf_viewer)
  end)

  it('only sends the PDF to the viewer after a successful download', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local complete, commands = nil, {}
    bridge.request = function(method, _, callback)
      assert.are.equal('downloadUrl', method)
      complete = callback
    end
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return 1
    end

    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.com/output.pdf' } })
    assert.are.equal(0, #commands)
    complete(nil, { path = '/tmp/project.pdf' })
    assert.is_true(vim.wait(1000, function() return #commands == 1 end))
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf'), commands[1])

    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.com/output.pdf' } })
    complete({ message = 'download failed' })
    vim.wait(20, function() return false end)
    assert.are.equal(1, #commands)
  end)
end)
