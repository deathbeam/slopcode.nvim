-- SPDX-License-Identifier: GPL-2.0-only

local LOCAL_URL = 'http://localhost:11434'

--- Estimate context window size from Ollama's parameter_size string.
--- @param ps string?
--- @return integer?
local function ctx_from_param_size(ps)
    if not ps or ps == '' then
        return nil
    end
    local num = tonumber(ps:match('(%d+%.?%d*)[Bb]'))
    if not num then
        return nil
    end
    if num >= 600 then
        return 262144
    end
    if num >= 100 then
        return 128000
    end
    if num >= 70 then
        return 32768
    end
    if num >= 30 then
        return 16384
    end
    if num >= 13 then
        return 8192
    end
    return 4096
end

--- Fetch locally running Ollama models from the daemon API.
--- @async
--- @return table[]?
local function fetch_local_models()
    local curl = require('slopcode.utils.curl')
    local body, err = curl.get(LOCAL_URL .. '/api/tags', { max_time = 5 })
    if err then
        return nil
    end
    local ok, parsed = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok or type(parsed) ~= 'table' or type(parsed.models) ~= 'table' then
        return nil
    end
    local models = {}
    for _, m in ipairs(parsed.models) do
        local name = m.name or m.model or ''
        if name ~= '' then
            name = name:gsub(':latest$', '')
            local ctx = ctx_from_param_size(m.details and m.details.parameter_size) or 128000
            models[#models + 1] = {
                id = name,
                name = name,
                provider = 'ollama',
                parser = 'openai_completions',
                baseUrl = LOCAL_URL .. '/v1',
                contextWindow = ctx,
                maxTokens = 8192,
                reasoning = false,
                tools = true,
                input = { 'text' },
                env = { 'OLLAMA_API_KEY' },
            }
        end
    end
    return models
end

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    -- Remove stale ollama entries from a previous invocation
    for i = #models, 1, -1 do
        if models[i].provider == 'ollama' then
            table.remove(models, i)
        end
    end

    local local_models = fetch_local_models()
    if not local_models then
        return models
    end

    for _, m in ipairs(local_models) do
        models[#models + 1] = m
    end

    return models
end
