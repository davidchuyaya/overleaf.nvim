describe('PDF viewer commands', function()
  local overleaf = require('overleaf')
  local config = require('overleaf.config')
  local bridge = require('overleaf.bridge')
  local saved_config, saved_has, saved_request, saved_jobstart, saved_pdf_state, saved_readable

  local function download_pdf(path)
    bridge.request = function(method, _, callback)
      assert.are.equal('downloadUrl', method)
      callback(nil, { path = path })
    end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.com/output.pdf' } })
    local done = false
    vim.schedule(function() done = true end)
    assert.is_true(vim.wait(1000, function() return done end))
  end

  before_each(function()
    saved_config = vim.deepcopy(config._config)
    saved_has = vim.fn.has
    saved_request = bridge.request
    saved_jobstart = vim.fn.jobstart
    saved_pdf_state = overleaf._pdf_state
    saved_readable = vim.fn.filereadable
    overleaf._pdf_state = {}
  end)

  after_each(function()
    config._config = saved_config
    vim.fn.has = saved_has
    bridge.request = saved_request
    vim.fn.jobstart = saved_jobstart
    overleaf._pdf_state = saved_pdf_state
    vim.fn.filereadable = saved_readable
  end)

  it('launches the macOS Sioyek executable without clearing its render cache', function()
    vim.fn.has = function(feature) return feature == 'mac' and 1 or saved_has(feature) end
    config.setup({ pdf_viewer = 'sioyek' })
    assert.are.same({
      '/Applications/sioyek.app/Contents/MacOS/sioyek',
      '--reuse-window',
      '/tmp/project with spaces.pdf',
    }, overleaf._viewer_command('/tmp/project with spaces.pdf'))
  end)

  it('uses the PATH executable outside macOS', function()
    vim.fn.has = function(feature) return feature == 'mac' and 0 or saved_has(feature) end
    config.setup({ pdf_viewer = 'Sioyek' })
    assert.are.same({ 'sioyek', '--reuse-window', '/tmp/project.pdf' }, overleaf._viewer_command('/tmp/project.pdf'))
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

  it('builds an explicit reload command only when requested', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local executable = vim.fn.has('mac') == 1 and '/Applications/sioyek.app/Contents/MacOS/sioyek' or 'sioyek'
    assert.are.same(
      { executable, '--reuse-window', '--execute-command', 'reload', '/tmp/project.pdf' },
      overleaf._viewer_command('/tmp/project.pdf', true)
    )
  end)

  it('downloads every compile but only opens the same PDF once', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return 1
    end
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    assert.are.equal(1, #commands)
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf'), commands[1])
    assert.are.equal('/tmp/project.pdf', overleaf._pdf_state.last_path)
  end)

  it('opens another PDF and reopens the first when switching back', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return 1
    end
    download_pdf('/tmp/first.pdf')
    download_pdf('/tmp/second.pdf')
    download_pdf('/tmp/first.pdf')
    assert.are.equal(3, #commands)
    assert.are.same(overleaf._viewer_command('/tmp/second.pdf'), commands[2])
  end)

  it('keeps opening other viewers and custom command tables on every compile', function()
    local commands = {}
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return 1
    end
    config.setup({ pdf_viewer = 'skim' })
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    assert.are.equal(2, #commands)
    config.setup({ pdf_viewer = { '/custom/sioyek', '--execute-command', 'reload' } })
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    assert.are.equal(4, #commands)
  end)

  it('allows manually reopening and reloading without another download', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return 1
    end
    vim.fn.filereadable = function(path) return path == '/tmp/project.pdf' and 1 or 0 end
    download_pdf('/tmp/project.pdf')
    bridge.request = function() error('Manual PDF commands must not download') end
    overleaf.view_pdf()
    overleaf.view_pdf('reload')
    assert.are.equal(3, #commands)
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf'), commands[2])
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true), commands[3])
    download_pdf('/tmp/project.pdf')
    assert.are.equal(3, #commands)
  end)

  it('retries a failed launch on the next compile', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local attempts = 0
    vim.fn.jobstart = function()
      attempts = attempts + 1
      return attempts == 1 and -1 or 1
    end
    download_pdf('/tmp/project.pdf')
    assert.is_nil(overleaf._pdf_state.sioyek_path)
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    assert.are.equal(2, attempts)
  end)

  it('retries a viewer process that exits with an error', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local attempts, exit = 0, nil
    vim.fn.jobstart = function(_, opts)
      attempts = attempts + 1
      exit = opts.on_exit
      return 1
    end
    download_pdf('/tmp/project.pdf')
    exit(1, 1)
    assert.is_true(vim.wait(1000, function() return overleaf._pdf_state.sioyek_path == nil end))
    download_pdf('/tmp/project.pdf')
    assert.are.equal(2, attempts)
  end)

  it('does not let an older failed process reset a newer PDF launch', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local exits = {}
    vim.fn.jobstart = function(_, opts)
      table.insert(exits, opts.on_exit)
      return #exits
    end
    download_pdf('/tmp/first.pdf')
    download_pdf('/tmp/second.pdf')
    exits[1](1, 1)
    vim.wait(20, function() return false end)
    assert.are.equal('/tmp/second.pdf', overleaf._pdf_state.sioyek_path)
    download_pdf('/tmp/second.pdf')
    assert.are.equal(2, #exits)
  end)

  it('does not launch a missing PDF or an unsupported manual action', function()
    vim.fn.jobstart = function() error('No viewer should be launched') end
    vim.fn.filereadable = function() return 0 end
    overleaf.view_pdf()
    overleaf._pdf_state.last_path = '/tmp/missing.pdf'
    overleaf.view_pdf('reload')
    overleaf.view_pdf('invalid')
  end)
end)
