describe('Brave authentication', function()
  local overleaf = require('overleaf')
  local bridge = require('overleaf.bridge')
  local config = require('overleaf.config')
  local project = require('overleaf.project')
  local original_request, original_config, original_select, original_log
  local original_start, original_jobstart, original_has, original_project_select, original_projects, original_state
  local messages, opened, selected

  before_each(function()
    original_request = bridge.request
    original_config = vim.deepcopy(config._config)
    original_select = vim.ui.select
    original_log = config.log
    original_start, original_jobstart, original_has = bridge.start, vim.fn.jobstart, vim.fn.has
    original_project_select, original_projects = project.select_project, project._projects
    original_state = overleaf._state
    overleaf._state = { connected = false, documents = {} }
    config._config.cookie = nil
    config._config.base_url = 'https://www.overleaf.com'
    config._config.env_file = vim.fn.tempname()
    messages = {}
    config.log = function(_, message, ...) table.insert(messages, string.format(message, ...)) end
    opened, selected = {}, 0
    bridge.start = function(callback) callback(nil) end
    vim.fn.has = function(feature) return feature == 'mac' and 1 or original_has(feature) end
    vim.fn.jobstart = function(command, opts)
      assert.is_true(opts.detach)
      opened[#opened + 1] = command
      return 1
    end
    project.select_project = function() selected = selected + 1 end
  end)

  after_each(function()
    bridge.request = original_request
    config._config = original_config
    config.log = original_log
    vim.ui.select = original_select
    bridge.start, vim.fn.jobstart, vim.fn.has = original_start, original_jobstart, original_has
    project.select_project, project._projects = original_project_select, original_projects
    overleaf._state = original_state
  end)

  it('requests Brave profiles and extracts the selected cookie', function()
    local methods, result = {}, nil
    bridge.request = function(method, params, callback)
      table.insert(methods, method)
      if method == 'listBraveProfiles' then
        callback(nil, { profiles = { { dir = 'Default', name = 'Personal' } } })
      else
        assert.are.equal('getCookie', method)
        assert.are.equal('Default', params.profile)
        callback(nil, { cookie = 'overleaf_session2=fixture' })
      end
    end
    overleaf._get_cookie(function(cookie) result = cookie end)
    assert.are.same({ 'listBraveProfiles', 'getCookie' }, methods)
    assert.are.equal('overleaf_session2=fixture', result)
    assert.are.equal(result, config.get().cookie)
    assert.is_nil(table.concat(messages, '\n'):find('Chrome', 1, true))
  end)

  it('uses a Brave picker when multiple profiles are available', function()
    local selected, result
    vim.ui.select = function(profiles, opts, callback)
      assert.are.equal('Select Brave Profile:', opts.prompt)
      callback(profiles[2])
    end
    bridge.request = function(method, params, callback)
      if method == 'listBraveProfiles' then
        callback(nil, { profiles = { { dir = 'Default' }, { dir = 'Profile 1' } } })
      else
        selected = params.profile
        callback(nil, { cookie = 'selected-cookie' })
      end
    end
    overleaf._get_cookie(function(cookie) result = cookie end)
    assert.is_true(vim.wait(200, function() return result ~= nil end))
    assert.are.equal('Profile 1', selected)
    assert.are.equal('selected-cookie', result)
  end)

  it('keeps manual authentication when Brave is unavailable', function()
    config._config.cookie = 'manual-cookie'
    bridge.request = function(method, _, callback)
      assert.are.equal('listBraveProfiles', method)
      callback({ code = 'NOT_FOUND', message = 'Brave not installed' })
    end
    local result
    overleaf._get_cookie(function(cookie) result = cookie end)
    assert.are.equal('manual-cookie', result)
  end)

  it('falls back to manual authentication after extraction failure', function()
    config._config.cookie = 'manual-cookie'
    bridge.request = function(method, _, callback)
      if method == 'listBraveProfiles' then
        callback(nil, { profiles = { { dir = 'Default' } } })
      else
        callback({ code = 'KEYCHAIN_FAILED', message = 'Denied' })
      end
    end
    local result
    overleaf._get_cookie(function(cookie) result = cookie end)
    assert.are.equal('manual-cookie', result)
  end)

  it('opens Brave after missing profiles or cookie extraction fails with no manual fallback', function()
    for _, failure in ipairs({ 'NOT_FOUND', 'NO_COOKIE', 'KEYCHAIN_FAILED', 'DECRYPT_FAILED', 'TIMEOUT' }) do
      bridge.request = function(method, _, callback)
        if method == 'listBraveProfiles' and failure ~= 'NOT_FOUND' then
          callback(nil, { profiles = { { dir = 'Default' } } })
        else
          callback({ code = failure, message = 'Unavailable' })
        end
      end
      overleaf.connect()
    end
    assert.are.equal(5, #opened)
    for _, command in ipairs(opened) do
      assert.are.same({ 'open', '-a', 'Brave Browser', 'https://www.overleaf.com' }, command)
    end
    assert.are.equal(0, selected)
  end)

  it('opens Brave for expired sessions, parse errors, timeouts, and upstream errors', function()
    config._config.cookie = 'fixture-cookie'
    for _, code in ipairs({ 'AUTH_FAILED', 'PARSE_ERROR', 'TIMEOUT', 'HTTP_ERROR' }) do
      bridge.request = function(method, params, callback)
        if method == 'listBraveProfiles' then
          callback(nil, { profiles = {} })
        else
          assert.are.equal('auth', method)
          assert.are.equal('fixture-cookie', params.cookie)
          callback({ code = code, message = 'Authentication unavailable' })
        end
      end
      overleaf.connect()
    end
    assert.are.equal(4, #opened)
    assert.are.equal(0, selected)
  end)

  it('opens Brave when the bridge cannot start', function()
    bridge.start = function(callback) callback({ code = 'START_FAILED', message = 'No Node.js' }) end
    bridge.request = function() error('Must not request authentication without a bridge') end
    overleaf.connect()
    assert.are.equal(1, #opened)
  end)

  it('does not launch a browser for a successful manual fallback or profile picker cancellation', function()
    config._config.cookie = 'fixture-cookie'
    bridge.request = function(method, _, callback)
      if method == 'listBraveProfiles' then
        callback(nil, { profiles = {} })
      else
        callback(nil, { projects = {}, csrfToken = 'fixture-csrf', userId = 'fixture-user' })
      end
    end
    overleaf.connect()
    assert.are.equal(1, selected)
    assert.are.equal(0, #opened)
    bridge.request = function(method, _, callback)
      assert.are.equal('listBraveProfiles', method)
      callback(nil, { profiles = { { dir = 'Default' }, { dir = 'Profile 1' } } })
    end
    vim.ui.select = function(_, _, callback) callback(nil) end
    overleaf.connect()
    local done = false
    vim.schedule(function() done = true end)
    assert.is_true(vim.wait(200, function() return done end))
    assert.are.equal(0, #opened)
    assert.are.equal(1, selected)
  end)

  it('allows a successful retry after login without opening another browser', function()
    config._config.cookie = 'fixture-cookie'
    local attempts = 0
    bridge.request = function(method, _, callback)
      if method == 'listBraveProfiles' then
        callback(nil, { profiles = {} })
      else
        attempts = attempts + 1
        if attempts == 1 then
          callback({ code = 'AUTH_FAILED', message = 'Expired' })
        else
          callback(nil, { projects = {}, csrfToken = 'fixture-csrf', userId = 'fixture-user' })
        end
      end
    end
    overleaf.connect()
    overleaf.connect()
    assert.are.equal(1, #opened)
    assert.are.equal(1, selected)
  end)

  it('warns instead of crashing if Brave is unavailable', function()
    vim.fn.jobstart = function() return -1 end
    overleaf._open_login()
    assert.is_truthy(table.concat(messages, '\n'):find('Open https://www.overleaf.com manually', 1, true))
  end)

  it('opens the configured self-hosted site and handles asynchronous browser errors', function()
    config._config.base_url = 'https://latex.example.test'
    local exit
    vim.fn.jobstart = function(command, opts)
      assert.are.same({ 'open', '-a', 'Brave Browser', 'https://latex.example.test' }, command)
      exit = opts.on_exit
      return 1
    end
    overleaf._open_login()
    exit(1, 1)
    assert.is_true(
      vim.wait(
        200,
        function() return table.concat(messages, '\n'):find('Open https://latex.example.test manually', 1, true) ~= nil end
      )
    )
  end)
end)
