-- SPDX-License-Identifier: MIT

local BASE_URL = 'https://api.anthropic.com/v1'

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    for _, m in ipairs(models) do
        if m.provider == 'anthropic' then
            m.parser = 'openai_completions'
            m.baseUrl = BASE_URL
        end
    end

    return models
end
