describe('PDF viewer commands', function()
  local overleaf = require('overleaf')
  local config = require('overleaf.config')
  local bridge = require('overleaf.bridge')
  local saved_config, saved_has, saved_request, saved_jobstart, saved_pdf_state, saved_readable
  local saved_system, saved_state

  local function download_pdf(path)
    bridge.request = function(method, _, callback)
      assert.are.equal('downloadUrl', method)
      callback(nil, { path = path })
    end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.com/output.pdf' } })
    local done = false
    vim.schedule(function()
      vim.schedule(function() done = true end)
    end)
    assert.is_true(vim.wait(1000, function() return done end))
  end

  before_each(function()
    saved_config = vim.deepcopy(config._config)
    saved_has = vim.fn.has
    saved_request = bridge.request
    saved_jobstart = vim.fn.jobstart
    saved_pdf_state = overleaf._pdf_state
    saved_readable = vim.fn.filereadable
    saved_system = vim.system
    saved_state = overleaf._state
    overleaf._state = vim.deepcopy(saved_state)
    -- Default to a living viewer; tests never query or launch a real GUI app.
    vim.system = function(command, _, callback)
      callback({ code = 0, stdout = command[1] == 'tasklist' and 'sioyek.exe 123 Console' or 'true\n' })
    end
    overleaf._pdf_state = {}
  end)

  after_each(function()
    config._config = saved_config
    vim.fn.has = saved_has
    bridge.request = saved_request
    vim.fn.jobstart = saved_jobstart
    overleaf._pdf_state = saved_pdf_state
    vim.fn.filereadable = saved_readable
    vim.system = saved_system
    overleaf._state = saved_state
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

  it('opens a new Sioyek window without replacing another project', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local executable = vim.fn.has('mac') == 1 and '/Applications/sioyek.app/Contents/MacOS/sioyek' or 'sioyek'
    assert.are.same(
      { executable, '--new-window', '/tmp/project with spaces.pdf' },
      overleaf._viewer_command('/tmp/project with spaces.pdf', false, true)
    )
    assert.are.same({
      executable,
      '--new-window',
      '--execute-command',
      'open_document;reload',
      '--execute-command-data',
      '/tmp/project with spaces.pdf',
      '/tmp/project with spaces.pdf',
    }, overleaf._viewer_command('/tmp/project with spaces.pdf', true, true))
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
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true, true), commands[1])

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

  it('downloads every compile but only opens the same PDF once while Sioyek is running', function()
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
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true, true), commands[1])
    assert.are.equal('/tmp/project.pdf', overleaf._pdf_state.last_path)
  end)

  it('reopens on the next compile after a normal Sioyek quit', function()
    config.setup({ pdf_viewer = 'sioyek' })
    vim.fn.has = function(feature) return feature == 'mac' and 1 or saved_has(feature) end
    local commands, exit = {}, nil
    vim.fn.jobstart = function(command, opts)
      table.insert(commands, command)
      exit = opts.on_exit
      return #commands
    end
    download_pdf('/tmp/project.pdf')
    exit(1, 0)
    vim.system = function(command, _, callback)
      assert.are.same({ 'osascript', '-e', 'application "/Applications/sioyek.app" is running' }, command)
      callback({ code = 0, stdout = 'false\n' })
    end
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return #commands == 2 end))
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf'), commands[2])
  end)

  it('does not reopen when a reuse-window launcher exits normally but the GUI is still running', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands, exit = {}, nil
    vim.fn.jobstart = function(command, opts)
      table.insert(commands, command)
      exit = opts.on_exit
      return #commands
    end
    download_pdf('/tmp/project.pdf')
    exit(1, 0)
    download_pdf('/tmp/project.pdf')
    vim.wait(20, function() return false end)
    assert.are.equal(1, #commands)
  end)

  it('reopens when the running-app check fails or cannot start', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local attempts = 0
    vim.fn.jobstart = function()
      attempts = attempts + 1
      return attempts
    end
    download_pdf('/tmp/project.pdf')
    vim.system = function(_, _, callback) callback({ code = 124, stdout = '' }) end
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return attempts == 2 end))
    vim.system = function() error('probe unavailable') end
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return attempts == 3 end))
  end)

  it('coalesces pending checks and ignores stale results after switching PDFs', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands, probes, complete = {}, 0, nil
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return #commands
    end
    download_pdf('/tmp/first.pdf')
    vim.system = function(_, _, callback)
      probes = probes + 1
      complete = callback
    end
    download_pdf('/tmp/first.pdf')
    download_pdf('/tmp/first.pdf')
    assert.are.equal(1, probes)
    download_pdf('/tmp/second.pdf')
    complete({ code = 0, stdout = 'false\n' })
    vim.wait(20, function() return false end)
    assert.are.equal(2, #commands)
    assert.are.equal('/tmp/second.pdf', overleaf._pdf_state.sioyek_path)
  end)

  it('uses pgrep on Unix and distinguishes absent apps from probe errors', function()
    config.setup({ pdf_viewer = 'sioyek' })
    vim.fn.has = function(feature)
      if feature == 'mac' or feature == 'win32' then return 0 end
      return saved_has(feature)
    end
    local commands, code = {}, 0
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return #commands
    end
    vim.system = function(command, _, callback)
      assert.are.same({ 'pgrep', '-x', 'sioyek' }, command)
      callback({ code = code })
    end
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    vim.wait(20, function() return false end)
    assert.are.equal(1, #commands)
    code = 1
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return #commands == 2 end))
    code = 3
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return #commands == 3 end))
  end)

  it('checks sioyek.exe on Windows', function()
    config.setup({ pdf_viewer = 'sioyek' })
    vim.fn.has = function(feature)
      if feature == 'mac' then return 0 end
      if feature == 'win32' then return 1 end
      return saved_has(feature)
    end
    local commands, output = {}, 'sioyek.exe 123 Console'
    vim.fn.jobstart = function(command)
      table.insert(commands, command)
      return #commands
    end
    vim.system = function(command, _, callback)
      assert.are.same({ 'tasklist', '/FI', 'IMAGENAME eq sioyek.exe', '/NH' }, command)
      callback({ code = 0, stdout = output })
    end
    download_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    vim.wait(20, function() return false end)
    assert.are.equal(1, #commands)
    output = 'INFO: No tasks are running which match the specified criteria.'
    download_pdf('/tmp/project.pdf')
    assert.is_true(vim.wait(1000, function() return #commands == 2 end))
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
    assert.are.same(overleaf._viewer_command('/tmp/second.pdf', false, true), commands[2])
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

  it('refreshes a PDF left open from another Neovim once, then relies on automatic reload', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      commands[#commands + 1] = command
      return #commands
    end
    download_pdf('/tmp/project.pdf')
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true, true), commands[1])
    download_pdf('/tmp/project.pdf')
    assert.are.equal(1, #commands)
  end)

  it('refreshes once after reconnecting to the same project without quitting Sioyek', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      commands[#commands + 1] = command
      return #commands
    end
    download_pdf('/tmp/project.pdf')
    overleaf._reset_pdf_connection()
    download_pdf('/tmp/project.pdf')
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true), commands[2])
    download_pdf('/tmp/project.pdf')
    assert.are.equal(2, #commands)
  end)

  it('does not force a reload when starting a fresh Sioyek instance', function()
    config.setup({ pdf_viewer = 'sioyek' })
    vim.system = function(_, _, callback) callback({ code = 0, stdout = 'false\n' }) end
    local command
    vim.fn.jobstart = function(cmd)
      command = cmd
      return 1
    end
    download_pdf('/tmp/project.pdf')
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', false, true), command)
  end)

  it('refreshes once even if running-app detection is unavailable', function()
    config.setup({ pdf_viewer = 'sioyek' })
    vim.system = function(_, _, callback) callback({ code = 124, stdout = '' }) end
    local command
    vim.fn.jobstart = function(cmd)
      command = cmd
      return 1
    end
    download_pdf('/tmp/project.pdf')
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true, true), command)
  end)

  it('still refreshes the first compile after manually reopening an older connection PDF', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      commands[#commands + 1] = command
      return #commands
    end
    download_pdf('/tmp/project.pdf')
    overleaf._reset_pdf_connection()
    overleaf._show_pdf('/tmp/project.pdf')
    download_pdf('/tmp/project.pdf')
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true), commands[3])
    download_pdf('/tmp/project.pdf')
    assert.are.equal(3, #commands)
  end)

  it('ignores a PDF download from a previous connection', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local reply
    bridge.request = function(_, _, callback) reply = callback end
    vim.fn.jobstart = function() error('Old connection PDF must not launch a viewer') end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.test/output.pdf' } })
    overleaf._reset_pdf_connection()
    reply(nil, { path = '/tmp/old.pdf' })
    assert.is_nil(overleaf._pdf_state.last_path)
  end)

  it('ignores an old running-app probe after reconnecting', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local probes, commands = {}, {}
    vim.system = function(_, _, callback) probes[#probes + 1] = callback end
    vim.fn.jobstart = function(cmd)
      commands[#commands + 1] = cmd
      return 1
    end
    download_pdf('/tmp/project.pdf')
    overleaf._reset_pdf_connection()
    download_pdf('/tmp/project.pdf')
    assert.are.equal(2, #probes)
    probes[1]({ code = 0, stdout = 'true\n' })
    local done = false
    vim.schedule(function() done = true end)
    assert.is_true(vim.wait(1000, function() return done end))
    assert.are.equal(0, #commands)
    probes[2]({ code = 0, stdout = 'true\n' })
    assert.is_true(vim.wait(1000, function() return #commands == 1 end))
    assert.are.same(overleaf._viewer_command('/tmp/project.pdf', true, true), commands[1])
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

  it('keeps independently connected projects in separate windows without reopening on each compile', function()
    config.setup({ pdf_viewer = 'sioyek' })
    local commands = {}
    vim.fn.jobstart = function(command)
      commands[#commands + 1] = command
      return #commands
    end
    local first, second = {}, {}
    overleaf._pdf_state = first
    download_pdf('/tmp/first.pdf')
    overleaf._pdf_state = second
    download_pdf('/tmp/second.pdf')
    overleaf._pdf_state = first
    download_pdf('/tmp/first.pdf')
    overleaf._pdf_state = second
    download_pdf('/tmp/second.pdf')
    assert.equals(2, #commands)
    assert.equals('--new-window', commands[1][2])
    assert.equals('--new-window', commands[2][2])
    assert.equals('/tmp/first.pdf', commands[1][#commands[1]])
    assert.equals('/tmp/second.pdf', commands[2][#commands[2]])
  end)

  it('gives identically named projects distinct stable PDF filenames', function()
    overleaf._state.project_name = 'Same project'
    overleaf._state.project_id = 'first-id'
    local first = overleaf._pdf_filename()
    assert.equals(first, overleaf._pdf_filename())
    overleaf._state.project_id = 'second-id'
    local second = overleaf._pdf_filename()
    assert.is_not.equal(first, second)
    overleaf._state.project_id = 'first-id'
    config.setup({ base_url = config.get().base_url .. '/' })
    assert.equals(first, overleaf._pdf_filename())
    config.setup({ base_url = 'https://other-overleaf.example' })
    assert.is_not.equal(first, overleaf._pdf_filename())
  end)

  it('sanitizes PDF names and passes the project-specific name to downloads', function()
    overleaf._state.project_name = '../A/B\\C\n project'
    overleaf._state.project_id = 'project-id'
    local filename = overleaf._pdf_filename()
    assert.is_nil(filename:find('[/\\%c]'))
    assert.equals('.pdf', filename:sub(-4))
    config.setup({ pdf_dir = '/tmp/custom PDFs' })
    local params
    bridge.request = function(method, value)
      assert.equals('downloadUrl', method)
      params = value
    end
    overleaf._open_pdf({ { path = 'output.pdf', url = 'https://example.com/output.pdf' } })
    assert.equals(filename, params.fileName)
    assert.equals('/tmp/custom PDFs', params.outputDir)
  end)
end)
