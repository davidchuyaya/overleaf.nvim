describe('Brave authentication', function()
  local overleaf = require('overleaf')
  local bridge = require('overleaf.bridge')
  local config = require('overleaf.config')
  local original_request, original_config, original_select, original_log
  local messages

  before_each(function()
    original_request = bridge.request
    original_config = vim.deepcopy(config._config)
    original_select = vim.ui.select
    original_log = config.log
    config._config.cookie = nil
    config._config.env_file = vim.fn.tempname()
    messages = {}
    config.log = function(_, message, ...) table.insert(messages, string.format(message, ...)) end
  end)

  after_each(function()
    bridge.request = original_request
    config._config = original_config
    config.log = original_log
    vim.ui.select = original_select
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
end)
