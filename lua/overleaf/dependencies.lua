local config = require('overleaf.config')

local M = {}

--- Ensure an optional Mason package is installed when Mason is available.
---@param name string
---@param executable string
function M.ensure_mason_package(name, executable)
  if vim.fn.executable(executable) == 1 then return end

  local ok, registry = pcall(require, 'mason-registry')
  if not ok then
    config.log('debug', 'Mason is unavailable; install %s manually to enable its integration', name)
    return
  end

  local function install()
    local package_ok, package = pcall(registry.get_package, name)
    if not package_ok then
      config.log('warn', 'Mason package %s is unavailable', name)
      return
    end
    if package:is_installed() or package:is_installing() then return end

    config.log('info', 'Installing %s with Mason...', name)
    package:install({}, function(success, err)
      vim.schedule(function()
        if success then
          config.log('info', 'Installed %s with Mason', name)
        else
          config.log('error', 'Failed to install %s with Mason: %s', name, tostring(err))
        end
      end)
    end)
  end

  if registry.has_package(name) then
    install()
  else
    registry.refresh(function(success)
      vim.schedule(function()
        if success then
          install()
        else
          config.log('warn', 'Could not refresh Mason registry to install %s', name)
        end
      end)
    end)
  end
end

function M.setup()
  if config.get().ensure_texlab then M.ensure_mason_package('texlab', 'texlab') end
end

return M
