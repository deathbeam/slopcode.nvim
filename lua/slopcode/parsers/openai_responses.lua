-- SPDX-License-Identifier: MIT

--- Convert chat/completions messages to /responses format.
--- @param messages table[]
--- @return string? instructions, table[] input
local function convert_messages(messages)
    local instructions = nil
    local input = {}
    for _, msg in ipairs(messages) do
        if msg.role == 'system' and not instructions then
            -- Use developer role for reasoning models, system for others
            instructions = msg.content
        elseif msg.role == 'system' then
            input[#input + 1] = { role = 'developer', content = msg.content }
        elseif msg.role == 'user' then
            input[#input + 1] = { role = 'user', content = msg.content }
        elseif msg.role == 'assistant' then
            if msg.content then
                input[#input + 1] = { role = 'assistant', content = msg.content }
            end
            if msg.tool_calls then
                for _, tc in ipairs(msg.tool_calls) do
                    local call_id = tc.call_id or tc.id
                    input[#input + 1] = {
                        type = 'function_call',
                        id = tc.id ~= '' and tc.id or nil,
                        call_id = call_id,
                        name = tc['function'].name,
                        arguments = tc['function'].arguments,
                    }
                end
            end
        elseif msg.role == 'tool' then
            input[#input + 1] = {
                type = 'function_call_output',
                call_id = msg.tool_call_id,
                output = msg.content,
            }
        end
    end
    return instructions, input
end

return {
    suffix = '/responses',

    --- @param model string
    --- @param messages table[]
    --- @param tool_defs table[]
    --- @param opts { temperature: number?, reasoning_effort: string?, max_tokens: integer?, stream: boolean? }
    --- @return table
    build_body = function(model, messages, tool_defs, opts)
        local instructions, input = convert_messages(messages)
        local body = {
            model = model,
        }

        if opts.temperature ~= nil then
            body.temperature = opts.temperature
        end

        if opts.reasoning_effort ~= nil then
            body.reasoning = {
                effort = opts.reasoning_effort,
                summary = 'auto',
            }
        end

        if opts.max_tokens ~= nil then
            body.max_output_tokens = opts.max_tokens
        end

        if opts.stream then
            body.stream = true
        else
            body.stream = false
        end

        if instructions then
            body.instructions = instructions
        end

        body.input = input
        if #tool_defs > 0 then
            body.tools = {}
            for _, def in ipairs(tool_defs) do
                body.tools[#body.tools + 1] = {
                    type = 'function',
                    name = def.name,
                    description = def.description,
                    parameters = def.parameters,
                }
            end
        end
        return body
    end,

    --- @param chunk table
    --- @param state table
    --- @return string? kind, string? payload
    process_chunk = function(chunk, state)
        local event_type = chunk.type

        if event_type == 'response.created' then
            if chunk.response and chunk.response.id then
                state.response_id = chunk.response.id
            end
            return nil
        end

        if event_type == 'response.failed' then
            local err = chunk.response and chunk.response.error
            local details = chunk.response and chunk.response.incomplete_details
            local msg = err and (err.code or 'unknown') .. ': ' .. (err.message or 'no message')
                or details and details.reason and ('incomplete: ' .. details.reason)
                or 'Response failed (no error details)'
            state.finish_reason = 'error: ' .. msg
            return 'done'
        end

        if event_type == 'error' then
            local msg = chunk.message or chunk.code or 'Unknown error'
            state.finish_reason = 'error: ' .. msg
            return 'done'
        end

        if event_type == 'response.output_item.added' and chunk.item then
            local item = chunk.item

            if item.type == 'function_call' then
                state.tool_calls = state.tool_calls or {}
                state._current_fc_idx = #state.tool_calls + 1
                state.tool_calls[state._current_fc_idx] = {
                    id = item.id or '',
                    call_id = item.call_id or item.id or '',
                    ['function'] = { name = item.name or '', arguments = item.arguments or '' },
                }
                return nil
            end

            -- Track reasoning and message items for finalization
            if item.type == 'reasoning' then
                state._current_item_type = 'reasoning'
                state._reasoning_parts = {}
                return nil
            end

            if item.type == 'message' then
                state._current_item_type = 'message'
                return nil
            end

            return nil
        end

        if event_type == 'response.reasoning_summary_part.added' then
            if state._reasoning_parts then
                state._reasoning_parts[#state._reasoning_parts + 1] = { text = '' }
            end
            return nil
        end

        if event_type == 'response.reasoning_summary_text.delta' then
            local text = chunk.delta or ''
            if text ~= '' then
                state.reasoning:put(text)
                -- Also track in parts if available
                if state._reasoning_parts and #state._reasoning_parts > 0 then
                    local last = state._reasoning_parts[#state._reasoning_parts]
                    last.text = (last.text or '') .. text
                end
                return 'reasoning', text
            end
            return nil
        end

        if event_type == 'response.reasoning_summary_part.done' then
            -- Insert paragraph separator between reasoning parts
            if state._reasoning_parts and #state._reasoning_parts > 0 then
                local last = state._reasoning_parts[#state._reasoning_parts]
                last.text = (last.text or '') .. '\n\n'
                state.reasoning:put('\n\n')
                return 'reasoning', '\n\n'
            end
            return nil
        end

        if event_type == 'response.output_text.delta' then
            local text = chunk.delta or ''
            if text ~= '' then
                state.content:put(text)
                return 'content', text
            end
            return nil
        end

        if event_type == 'response.refusal.delta' then
            local text = chunk.delta or ''
            if text ~= '' then
                state.content:put(text)
                return 'content', text
            end
            return nil
        end

        if event_type == 'response.function_call_arguments.delta' then
            if state.tool_calls and state._current_fc_idx then
                local tc = state.tool_calls[state._current_fc_idx]
                if tc then
                    tc['function'].arguments = tc['function'].arguments .. (chunk.delta or '')
                end
            end
            return nil
        end

        if event_type == 'response.function_call_arguments.done' then
            -- Finalize with the complete arguments from the event
            if state.tool_calls and state._current_fc_idx then
                local tc = state.tool_calls[state._current_fc_idx]
                if tc and chunk.arguments then
                    tc['function'].arguments = chunk.arguments
                end
            end
            state._current_fc_idx = nil
            return nil
        end

        if event_type == 'response.output_item.done' and chunk.item then
            local item = chunk.item

            if item.type == 'function_call' then
                -- Finalize tool call: set arguments from the completed item
                local call_id = item.call_id or item.id
                local item_id = item.id or ''
                local found = false
                if state.tool_calls then
                    for _, existing in ipairs(state.tool_calls) do
                        if existing.call_id == call_id then
                            existing.id = item_id
                            existing['function'].arguments = item.arguments or existing['function'].arguments
                            found = true
                            break
                        end
                    end
                end
                if not found then
                    state.tool_calls = state.tool_calls or {}
                    state.tool_calls[#state.tool_calls + 1] = {
                        id = item_id,
                        call_id = call_id,
                        ['function'] = { name = item.name or '', arguments = item.arguments or '' },
                    }
                end
                state._current_fc_idx = nil
                return nil
            end

            -- Reset current item tracking
            if item.type == 'reasoning' then
                state._current_item_type = nil
                state._reasoning_parts = nil
                -- Override reasoning with final summary text from the item
                if item.summary then
                    local summary = {}
                    for _, part in ipairs(item.summary) do
                        if part.text then
                            summary[#summary + 1] = part.text
                        end
                    end
                    state.reasoning:set(table.concat(summary, '\n\n'))
                end
                return nil
            end

            if item.type == 'message' then
                state._current_item_type = nil
                return nil
            end

            return nil
        end

        if event_type == 'response.completed' and chunk.response then
            local response = chunk.response

            -- Usage
            if response.usage then
                state.usage = response.usage
            end

            -- Capture response ID
            if response.id then
                state.response_id = response.id
            end

            -- Collect any function calls from the final output
            if response.output then
                state.tool_calls = state.tool_calls or {}
                for _, item in ipairs(response.output) do
                    if item.type == 'function_call' then
                        local call_id = item.call_id or item.id
                        local item_id = item.id or ''
                        local dup = false
                        for _, existing in ipairs(state.tool_calls) do
                            if existing.call_id == call_id then
                                -- Update item_id if we didn't have it from streaming
                                if existing.id == '' then
                                    existing.id = item_id
                                end
                                dup = true
                                break
                            end
                        end
                        if not dup then
                            state.tool_calls[#state.tool_calls + 1] = {
                                id = item_id,
                                call_id = call_id,
                                ['function'] = { name = item.name, arguments = item.arguments or '' },
                            }
                        end
                    end
                end
            end

            -- Map status to finish reason
            local status = response.status
            if status == 'completed' then
                state.finish_reason = 'done'
            elseif status == 'incomplete' then
                state.finish_reason = 'incomplete'
            else
                state.finish_reason = 'error: ' .. tostring(status)
            end

            return #state.tool_calls > 0 and 'tool_calls' or 'done'
        end

        return nil
    end,

    --- @param response table
    --- @return string
    extract_content = function(response)
        if response.output then
            local text = ''
            for _, item in ipairs(response.output) do
                if item.content then
                    for _, part in ipairs(item.content) do
                        if part.text then
                            text = text .. part.text
                        end
                    end
                end
            end
            return text
        end
        return ''
    end,
}
