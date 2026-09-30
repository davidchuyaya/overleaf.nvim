local dependencies = require('overleaf.dependencies')

describe('dependencies', function()
  local original_registry

  before_each(function() original_registry = package.loaded['mason-registry'] end)

  after_each(function() package.loaded['mason-registry'] = original_registry end)

  it('installs a missing package through Mason', function()
    local installed = false
    local mason_package = {
      is_installed = function() return false end,
      is_installing = function() return false end,
      install = function(_, _, callback)
        installed = true
        callback(true)
      end,
    }
    package.loaded['mason-registry'] = {
      has_package = function() return true end,
      get_package = function() return mason_package end,
    }

    dependencies.ensure_mason_package('overleaf-test-package', 'overleaf-test-executable')

    assert.is_true(installed)
  end)

  it('does not reinstall an installed package', function()
    local installed = false
    local mason_package = {
      is_installed = function() return true end,
      is_installing = function() return false end,
      install = function() installed = true end,
    }
    package.loaded['mason-registry'] = {
      has_package = function() return true end,
      get_package = function() return mason_package end,
    }

    dependencies.ensure_mason_package('overleaf-test-package', 'overleaf-test-executable')

    assert.is_false(installed)
  end)
end)
