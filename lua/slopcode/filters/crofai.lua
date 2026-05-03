-- SPDX-License-Identifier: GPL-2.0-only

local BASE_URL = 'https://crof.ai/v1'

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    local key = os.getenv('CROFAI_API_KEY') or ''
    if key == '' then
        return models
    end

    local curl = require('slopcode.utils.curl')
    local data, err = curl.get(BASE_URL .. '/models', { json = true, max_time = 10 })
    if err or type(data) ~= 'table' or type(data.data) ~= 'table' then
        return models
    end

    for _, m in ipairs(data.data) do
        local reasoning = m.reasoning_effort == true or m.custom_reasoning == true
        models[#models + 1] = {
            id = m.id,
            name = m.name or m.id,
            provider = 'crofai',
            parser = 'openai_completions',
            baseUrl = BASE_URL,
            contextWindow = m.context_length or 128000,
            maxTokens = m.max_completion_tokens or 8192,
            reasoning = reasoning,
            temperature = true,
            tools = true,
            input = { 'text' },
            env = { 'CROFAI_API_KEY' },
        }
    end

    return models
end
