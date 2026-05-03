-- SPDX-License-Identifier: MIT

local BASE_URL = 'http://localhost:11434'

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

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    for i = #models, 1, -1 do
        if models[i].provider == 'ollama' then
            table.remove(models, i)
        end
    end

    local curl = require('slopcode.utils.curl')
    local data, err = curl.get(BASE_URL .. '/api/tags', { json = true, max_time = 10 })
    if err or type(data) ~= 'table' or type(data.models) ~= 'table' then
        return models
    end

    for _, m in ipairs(data.models) do
        local name = m.name or m.model or ''
        if name ~= '' then
            name = name:gsub(':latest$', '')
            local ctx = ctx_from_param_size(m.details and m.details.parameter_size)
            models[#models + 1] = {
                id = name,
                name = name,
                provider = 'ollama',
                parser = 'openai_completions',
                baseUrl = BASE_URL .. '/v1',
                contextWindow = ctx,
                maxTokens = 8192,
                reasoning = false,
                tools = true,
                input = { 'text' },
            }
        end
    end

    return models
end
