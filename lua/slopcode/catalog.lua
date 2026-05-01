-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local curl = require('slopcode.utils.curl')

local _cached_models = nil
local _cached_raw = nil

local NPM_TO_PARSER = {
    ['@ai-sdk/openai'] = 'openai_responses',
    ['@ai-sdk/openai-compatible'] = 'openai_completions',
}

--- Build a headers function that reads the first non-empty env key as a Bearer token.
--- @param env_keys string[]
--- @return fun()?: table
local function make_headers(env_keys)
    if not env_keys or #env_keys == 0 then
        return function()
            return {}
        end
    end

    local provider_has_key = false
    for _, e in ipairs(env_keys) do
        if (os.getenv(e) or '') ~= '' then
            provider_has_key = true
            break
        end
    end

    if not provider_has_key then
        return nil
    end

    return function()
        for _, e in ipairs(env_keys) do
            local val = os.getenv(e) or ''
            if val ~= '' then
                return { ['Authorization'] = 'Bearer ' .. val }
            end
        end
        return {}
    end
end

--- Resolve the API URL for a model using its parser's suffix.
--- @param model table
--- @param config table
--- @return string
local function resolve_url(model, config)
    local base = (model.baseUrl or ''):gsub('/+$', '')
    local parser = model.parser
    if type(parser) == 'string' then
        local mod = config.parsers[parser]
        if mod and mod.suffix then
            return base .. mod.suffix
        end
    end
    return base
end

--- Transform raw models.dev data into resolved model tables.
--- @param raw table
--- @return table[]
local function transform(raw)
    local models = {}
    for provider_id, pdata in pairs(raw) do
        if type(pdata) == 'table' and type(pdata.models) == 'table' then
            local parser = NPM_TO_PARSER[pdata.npm]
            local base_url = (pdata.api or ''):gsub('/+$', '')
            local env_keys = pdata.env or {}

            for model_id, mdata in pairs(pdata.models) do
                if type(mdata) == 'table' and mdata.status ~= 'deprecated' and mdata.tool_call == true then
                    local limits = mdata.limit or {}
                    local costs = mdata.cost or {}
                    local mods = mdata.modalities or {}

                    local m = {
                        id = model_id,
                        name = mdata.name or model_id,
                        provider = provider_id,
                        parser = parser,
                        baseUrl = base_url,
                        contextWindow = limits.context or 128000,
                        maxTokens = limits.output or 8192,
                        reasoning = mdata.reasoning == true,
                        tools = true,
                        input = mods.input or { 'text' },
                        cost = {
                            input = costs.input or 0,
                            output = costs.output or 0,
                            cacheRead = costs.cache_read or 0,
                            cacheWrite = costs.cache_write or 0,
                        },
                        env = env_keys,
                        headers = make_headers(env_keys),
                    }

                    models[#models + 1] = m
                end
            end
        end
    end
    return models
end

--- @async
--- @return table
local function fetch_raw()
    local body, err = curl.get('https://models.dev/api.json', { max_time = 30 })
    if err then
        error('Catalog: failed to fetch models.dev: ' .. err, 0)
    end
    local ok, raw = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok or type(raw) ~= 'table' then
        error('Catalog: invalid models.dev response', 0)
    end
    _cached_raw = raw
    return raw
end

--- @async
--- @return table
local function load_raw()
    if _cached_raw then
        return _cached_raw
    end
    return fetch_raw()
end

--- @async
--- Build resolved model list: fetch → transform → apply filters.
--- @return table[]
function M.build()
    if _cached_models then
        return _cached_models
    end

    local config = require('slopcode.config')
    local raw = load_raw()
    local models = transform(raw)

    for _, filter in pairs(config.filters) do
        local ok, filtered = pcall(filter, models)
        if ok and type(filtered) == 'table' then
            models = filtered
        end
    end

    for i, m in ipairs(models) do
        m.key = m.provider .. '/' .. m.id
        if not m.headers then
            m.headers = make_headers(m.env)
        end
        if not m.url or m.url == '' then
            m.url = resolve_url(m, config)
        end
        if not m.url or m.url == '' or not m.parser or not m.headers then
            table.remove(models, i)
        end
    end

    _cached_models = models
    return models
end

--- @async
--- @return table?, table?
function M.model()
    local config = require('slopcode.config')
    local models = M.build()
    for _, m in ipairs(models) do
        if m.key == config.model then
            local parser_name = m.parser
            if type(parser_name) == 'string' then
                return m, config.parsers[parser_name]
            end
            return m, nil
        end
    end
    return nil, nil
end

--- Invalidate cached models so next build() re-fetches.
function M.invalidate()
    _cached_models = nil
end

return M
