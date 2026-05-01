-- SPDX-License-Identifier: GPL-2.0-only

local BASE_URL = 'https://generativelanguage.googleapis.com/v1beta/openai'

--- @async
--- @param models table[]
--- @return table[]
return function(models)
    for _, m in ipairs(models) do
        if m.provider == 'google' then
            m.parser = 'openai_completions'
            m.baseUrl = BASE_URL
        end
    end

    return models
end
