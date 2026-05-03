-- SPDX-License-Identifier: MIT

local VERSION = vim.version()
local HEADERS = {
    ['Editor-Version'] = 'Neovim/' .. VERSION.major .. '.' .. VERSION.minor .. '.' .. VERSION.patch,
    ['Editor-Plugin-Version'] = 'slopcode/*',
    ['Copilot-Integration-Id'] = 'vscode-chat',
    ['x-github-api-version'] = '2025-10-01',
}

local _cache = { token = nil, expires_at = nil, base_url = nil }

--- Find the XDG or platform config directory.
--- @return string?
local function config_dir()
    local dir = os.getenv('XDG_CONFIG_HOME')
    if dir and vim.uv.fs_stat(dir) then
        return dir
    end
    if vim.fn.has('win32') > 0 then
        dir = os.getenv('LOCALAPPDATA')
        if not dir or not vim.uv.fs_stat(dir) then
            dir = (os.getenv('HOME') or '') .. '\\AppData\\Local'
        end
    else
        dir = (os.getenv('HOME') or '') .. '/.config'
    end
    return dir
end

--- Read and decode a JSON file.
--- @param path string
--- @return table?
local function read_json_file(path)
    local f = io.open(path, 'r')
    if not f then
        return nil
    end
    local content = f:read('*a')
    f:close()
    local ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if not ok or type(data) ~= 'table' then
        return nil
    end
    return data
end

--- Read the Copilot OAuth token from disk.
--- @return string?
local function get_oauth_token()
    local dir = config_dir()
    if not dir then
        return nil
    end
    for _, name in ipairs({ 'github-copilot/hosts.json', 'github-copilot/apps.json' }) do
        local data = read_json_file(dir .. '/' .. name)
        if data then
            for key, value in pairs(data) do
                if
                    type(key) == 'string'
                    and key:find('github.com')
                    and type(value) == 'table'
                    and value.oauth_token
                then
                    return value.oauth_token
                end
            end
        end
    end
    return nil
end

--- Fetch a fresh Copilot API token and base URL from GitHub.
--- @async
--- @return string? token, string? base_url
local function fetch_copilot_token()
    local oauth = get_oauth_token()
    if not oauth then
        return nil
    end
    local curl = require('slopcode.utils.curl')
    local body, err = curl.get('https://api.github.com/copilot_internal/v2/token', {
        headers = { ['Authorization'] = 'Token ' .. oauth },
    })
    if err then
        return nil
    end
    local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok or type(data) ~= 'table' or data.error then
        return nil
    end
    local base_url = 'https://api.githubcopilot.com'
    if data.endpoints and data.endpoints.api then
        base_url = data.endpoints.api:gsub('/$', '')
    end
    _cache.token = data.token
    _cache.expires_at = data.expires_at or (os.time() + 1800)
    _cache.base_url = base_url
    return data.token, base_url
end

--- Get a cached or fresh Copilot API token.
--- @async
--- @return string? token, string? base_url
local function get_copilot_token()
    if _cache.token and _cache.expires_at and os.time() < _cache.expires_at - 60 then
        return _cache.token, _cache.base_url
    end
    return fetch_copilot_token()
end

--- Fetch the live model list from the Copilot API.
--- @async
--- @param token string
--- @param base_url string
--- @return table<string, { responses: boolean }>
local function fetch_copilot_models(token, base_url)
    local curl = require('slopcode.utils.curl')

    local data, err = curl.get(base_url .. '/models', {
        json = true,
        headers = vim.tbl_extend('force', HEADERS, {
            ['Authorization'] = 'Bearer ' .. token,
        }),
        max_time = 10,
    })
    local models = {}
    if not err and type(data) == 'table' and type(data.data) == 'table' then
        for _, m in ipairs(data.data) do
            if type(m.capabilities) == 'table' and m.capabilities.type == 'chat' and m.model_picker_enabled then
                local has_responses = false
                if type(m.supported_endpoints) == 'table' then
                    for _, ep in ipairs(m.supported_endpoints) do
                        if ep == '/responses' then
                            has_responses = true
                            break
                        end
                    end
                end
                models[m.id or m.name] = { responses = has_responses }
            end
        end
    end
    return models
end

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    local token, base_url = get_copilot_token()
    if not token then
        for i = #models, 1, -1 do
            if models[i].provider == 'github-copilot' then
                table.remove(models, i)
            end
        end
        return models
    end

    local copilot_models = fetch_copilot_models(token, base_url)
    for i = #models, 1, -1 do
        local m = models[i]
        if m.provider == 'github-copilot' then
            local live = copilot_models[m.id]
            if not live then
                table.remove(models, i)
            else
                m.baseUrl = base_url
                m.parser = live.responses and 'openai_responses' or 'openai_completions'
                m.headers = function(messages)
                    local last = messages[#messages]
                    local initiator = (last and last.role ~= 'user') and 'agent' or 'user'
                    local token = get_copilot_token() or ''

                    return vim.tbl_extend('force', HEADERS, {
                        ['Authorization'] = 'Bearer ' .. token,
                        ['X-Initiator'] = initiator,
                    })
                end
            end
        end
    end

    return models
end
