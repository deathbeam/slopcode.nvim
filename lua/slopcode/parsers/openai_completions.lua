-- SPDX-License-Identifier: GPL-2.0-only

--- Extract the first non-empty reasoning field from a delta object.
--- @param delta table
--- @return string?
local function first_nonempty_reasoning(delta)
    local fields = { 'reasoning_content', 'reasoning', 'reasoning_text' }
    for _, field in ipairs(fields) do
        local val = delta[field]
        if type(val) == 'string' and val ~= '' then
            return val
        end
    end
    return nil
end

return {
    suffix = '/chat/completions',

    --- @param model string
    --- @param messages table[]
    --- @param tool_defs table[]
    --- @param opts { temperature: number?, max_tokens: integer?, stream: boolean? }
    --- @return table
    build_body = function(model, messages, tool_defs, opts)
        -- Ensure assistant messages with tool_calls have content (some providers require it)
        for _, msg in ipairs(messages) do
            if msg.role == 'assistant' and msg.tool_calls and msg.content == nil then
                msg.content = ''
            end
        end

        local body = {
            model = model,
            messages = messages,
            store = false,
        }

        if opts.temperature ~= nil then
            body.temperature = opts.temperature
        end

        if opts.max_tokens ~= nil then
            body.max_tokens = opts.max_tokens
        end

        if opts.stream then
            body.stream = true
            body.stream_options = { include_usage = true }
        else
            body.stream = false
        end

        if #tool_defs > 0 then
            body.tools = {}
            body.tool_choice = 'auto'
            for _, def in ipairs(tool_defs) do
                body.tools[#body.tools + 1] = {
                    type = 'function',
                    ['function'] = {
                        name = def.name,
                        description = def.description,
                        parameters = def.parameters,
                    },
                }
            end
        end
        return body
    end,

    --- @param chunk table
    --- @param state table
    --- @return string? kind, string? payload
    process_chunk = function(chunk, state)
        -- Usage can arrive in chunk.usage or choice.usage (some providers)
        if chunk.usage then
            state.usage = chunk.usage
        end

        if not chunk.choices or #chunk.choices == 0 then
            return nil
        end
        local choice = chunk.choices[1]

        -- Fallback: some providers (e.g. Moonshot) put usage in choice.usage
        if not chunk.usage and choice.usage then
            state.usage = choice.usage
        end

        local delta = choice.delta

        -- Reasoning / thinking tokens (multiple field name variants)
        local reasoning_delta = delta and first_nonempty_reasoning(delta)
        if reasoning_delta then
            state.reasoning = (state.reasoning or '') .. reasoning_delta
            return 'reasoning', reasoning_delta
        end

        -- Regular content
        if delta and delta.content and delta.content ~= '' then
            state.content = (state.content or '') .. delta.content
            return 'content', delta.content
        end

        -- Tool calls
        if delta and delta.tool_calls then
            state.tool_calls = state.tool_calls or {}
            for _, tc in ipairs(delta.tool_calls) do
                local idx = (tc.index or 0) + 1
                state.tool_calls[idx] = state.tool_calls[idx]
                    or { id = '', type = 'function', ['function'] = { name = '', arguments = '' } }
                if tc.id then
                    state.tool_calls[idx].id = tc.id
                end
                if tc['function'] then
                    if tc['function'].name then
                        state.tool_calls[idx]['function'].name = state.tool_calls[idx]['function'].name
                            .. tc['function'].name
                    end
                    if tc['function'].arguments then
                        state.tool_calls[idx]['function'].arguments = state.tool_calls[idx]['function'].arguments
                            .. tc['function'].arguments
                    end
                end
            end
            return 'tool_calls'
        end

        -- Finish reason mapping
        if choice.finish_reason then
            local r = choice.finish_reason
            if r == 'stop' or r == 'end' or r == 'tool_calls' or r == 'function_call' then
                state.finish_reason = 'done'
            elseif r == 'length' then
                state.finish_reason = 'incomplete'
            else
                state.finish_reason = 'error: ' .. tostring(r)
            end
            return 'done'
        end
    end,

    --- @param response table
    --- @return string
    extract_content = function(response)
        if response.choices and response.choices[1] then
            return response.choices[1].message and response.choices[1].message.content or ''
        end
        return ''
    end,
}
