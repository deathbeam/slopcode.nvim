-- SPDX-License-Identifier: MIT

local M = {}

local buf = require('vim._core.stringbuffer')

--- Parse SSE event data into a list of JSON objects.
--- @param data string
--- @return table[]
local function parse_sse(data)
    local events = {}
    for line in data:gmatch('[^\r\n]+') do
        local json_str = line:match('^data:%s*(.+)$')
        if json_str and json_str ~= '[DONE]' then
            local ok, parsed = pcall(vim.json.decode, json_str, { luanil = { object = true, array = true } })
            if ok then
                events[#events + 1] = parsed
            end
        end
    end
    return events
end

--- Dispatch a parsed SSE chunk to the appropriate callback.
--- @param event table  parsed JSON event
--- @param state table  mutable parser state
--- @param opts table  callback options (on_content, on_reasoning)
local function dispatch_chunk(event, state, opts)
    local kind, payload = state.parser.process_chunk(event, state)
    if kind == 'content' then
        opts.on_content(payload)
    elseif kind == 'reasoning' then
        opts.on_reasoning(payload)
    end
end

--- Stream a completion request via SSE
--- @param messages table[]
--- @param tools table tool definitions
--- @param opts table { session_id, temperature, reasoning_effort, model, parser, on_content, on_reasoning, on_done, on_abort, on_error }
--- @return function  cancel_fn
function M.stream(messages, tools, opts)
    local model, parser = opts.model, opts.parser
    if not model or not parser then
        opts.on_error('No model/parser provided')
        error('No model/parser provided')
    end

    local req = {
        stream = true,
        max_tokens = model.maxTokens,
    }

    if opts.temperature ~= nil and model.temperature then
        req.temperature = opts.temperature
    end

    if opts.reasoning_effort ~= nil and model.reasoning then
        req.reasoning_effort = opts.reasoning_effort
    end

    local body = parser.build_body(model.id, messages, tools, req)
    local url = model.url
    local headers = type(model.headers) == 'function' and model:headers(messages) or model.headers or {}
    headers['Content-Type'] = 'application/json'
    headers['Accept'] = 'text/event-stream'

    if opts.session_id then
        headers['session_id'] = opts.session_id
        headers['x-client-request-id'] = opts.session_id
        headers['x-session-affinity'] = opts.session_id
    end

    local curl = require('slopcode.utils.curl')
    local c = curl.cmd('POST', url, { headers = headers, body = body, stream = true })

    local state = { content = buf.new(), reasoning = buf.new(), tool_calls = {}, parser = parser }
    local sse_buffer = ''
    local completed = false
    local aborted = false

    local job = vim.system(c.args, {
        text = true,
        stdout = function(err, data)
            if err or not data or aborted then
                return
            end
            sse_buffer = sse_buffer .. data
            while true do
                local event_end = sse_buffer:find('\n\n')
                if not event_end then
                    break
                end
                local event_text = sse_buffer:sub(1, event_end - 1)
                sse_buffer = sse_buffer:sub(event_end + 2)
                for _, event in ipairs(parse_sse(event_text)) do
                    dispatch_chunk(event, state, opts)
                end
            end
        end,
    }, function(result)
        c:cleanup()
        if sse_buffer ~= '' then
            for _, event in ipairs(parse_sse(sse_buffer)) do
                dispatch_chunk(event, state, opts)
            end
        end

        if aborted then
            opts.on_abort()
            return
        end

        if completed then
            return
        end

        completed = true
        if result.code ~= 0 then
            local err_msg = vim.trim(result.stderr or '')
            if err_msg == '' then
                err_msg = 'curl exited with code ' .. result.code
            end
            opts.on_error(err_msg)
        elseif state.finish_reason and state.finish_reason:find('^error') then
            opts.on_error(state.finish_reason)
        elseif
            state.finish_reason == nil
            and buf.len(state.content) == 0
            and (not state.tool_calls or not next(state.tool_calls))
        then
            local err_msg = vim.trim(sse_buffer or '')
            if err_msg == '' then
                err_msg = 'curl response ended without content or finish reason'
            end
            opts.on_error(err_msg)
        else
            -- Normalize sparse tool_calls to contiguous array
            local tool_calls = {}
            if state.tool_calls then
                local keys = {}
                for k in pairs(state.tool_calls) do
                    if type(k) == 'number' then
                        keys[#keys + 1] = k
                    end
                end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    tool_calls[#tool_calls + 1] = state.tool_calls[k]
                end
            end

            opts.on_done({
                content = state.content:tostring(),
                reasoning = state.reasoning:tostring(),
                tool_calls = tool_calls,
                finish_reason = state.finish_reason,
                usage = state.usage,
                response_id = state.response_id,
            })
        end
    end)

    return function()
        aborted = true
        pcall(job.kill, job)
    end
end

--- Non-streaming completion request.
--- @async
--- @param messages table[]
--- @param opts table { model, parser }
--- @return table
function M.complete(messages, opts)
    local model, parser = opts.model, opts.parser
    if not model or not parser then
        error('No model/parser provided', 0)
    end

    local body = parser.build_body(model.id, messages, {}, {
        stream = false,
        temperature = 0.1,
        max_tokens = model.maxTokens,
    })

    local url = model.url
    local headers = type(model.headers) == 'function' and model:headers(messages) or model.headers or {}
    headers['Content-Type'] = 'application/json'

    local curl = require('slopcode.utils.curl')
    local data, err = curl.post(url, { json = true, headers = headers, body = body, max_time = 300 })
    if err then
        error(err)
    end

    return data
end

return M
