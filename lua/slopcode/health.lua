local M = {}

local start = vim.health.start
local error = vim.health.error
local warn = vim.health.warn
local ok = vim.health.ok

--- Run a command and handle potential errors
---@param executable string
---@param command string
local function run_command(executable, command)
    local is_present = vim.fn.executable(executable)
    if is_present == 0 then
        return false
    else
        local success, result = pcall(vim.fn.system, { executable, command })
        if success then
            return vim.trim(result)
        else
            return false
        end
    end
end

--- Check if a Lua library is installed
---@param lib_name string
---@return boolean
local function lualib_installed(lib_name)
    local res, _ = pcall(require, lib_name)
    return res
end

function M.check()
    start('slopcode [core]')

    local vim_version = vim.trim(vim.api.nvim_exec2('version', { output = true }).output)
    if vim.fn.has('nvim-0.12.0') == 1 then
        ok('nvim: ' .. vim_version)
    else
        error('nvim: unsupported, please upgrade to 0.12.0 or later. See "https://neovim.io/".')
    end

    local testfile = os.tmpname()
    local f = io.open(testfile, 'w')
    local writable = false
    if f then
        f:write('test')
        f:close()
        writable = true
    end
    if writable then
        ok('temp dir: writable (' .. testfile .. ')')
        os.remove(testfile)
    else
        local stat = vim.loop.fs_stat(vim.fn.fnamemodify(testfile, ':h'))
        local perms = stat and string.format('%o', stat.mode % 512) or 'unknown'
        error(
            'temp dir: not writable. Permissions: ' .. perms .. ' (dir: ' .. vim.fn.fnamemodify(testfile, ':h') .. ')'
        )
    end

    start('slopcode [commands]')

    local curl_version = run_command('curl', '--version')
    if curl_version == false then
        error('curl: missing, required for API requests. See "https://curl.se/".')
    else
        ok('curl: ' .. curl_version)
    end

    local rg_version = run_command('rg', '--version')
    if rg_version == false then
        warn('rg: missing, required for search and skills. See "https://github.com/BurntSushi/ripgrep".')
    else
        ok('rg: ' .. rg_version)
    end

    local lynx_version = run_command('lynx', '-version')
    if lynx_version == false then
        warn('lynx: missing, required for fetching urls. See "https://lynx.invisible-island.net/".')
    else
        ok('lynx: ' .. lynx_version)
    end

    start('slopcode [dependencies]')

    if lualib_installed('async') then
        ok('async: installed')
    else
        error('async: missing, required for async jobs. Install "lewis6991/async.nvim" plugin.')
    end

    local select_source = debug.getinfo(vim.ui.select).source
    if select_source:match('vim/ui%.lua$') then
        warn('vim.ui.select: using default implementation, which may not provide the best user experience.')
    else
        ok('vim.ui.select: overridden by `' .. select_source .. '`')
    end
end

return M
