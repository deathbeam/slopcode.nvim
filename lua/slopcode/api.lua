-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

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

--- Stream a completion request via SSE. Returns a SystemObj (use :kill() to abort).
--- @param messages table[]
--- @param tools table tool definitions
--- @param opts table { model, parser, on_content, on_reasoning, on_done, on_error }
--- @return vim.SystemObj
function M.stream(messages, tools, opts)
    local model, parser = opts.model, opts.parser
    if not model or not parser then
        opts.on_error('No model/parser provided')
        error('No model/parser provided')
    end

    local body = parser.build_body(model.id, messages, tools, {
        temperature = 0.1,
        max_tokens = model.maxTokens or 4096,
    })

    local url = model.url
    local headers = type(model.headers) == 'function' and model:headers() or model.headers or {}
    headers['Content-Type'] = 'application/json'
    headers['Accept'] = 'text/event-stream'

    local curl = require('slopcode.utils.curl')
    local c = curl.cmd('POST', url, { headers = headers, body = body, stream = true })

    local state = { content = '', reasoning = '', tool_calls = {}, parser = parser }
    local sse_buffer = ''
    local completed = false

    local obj = vim.system(c.args, {
        text = true,
        stdout = function(err, data)
            if err or not data then
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
        if not completed then
            completed = true

            if result.code ~= 0 then
                local err_msg = vim.trim(result.stderr or '')
                if err_msg == '' then
                    err_msg = 'curl exited with code ' .. result.code
                end
                opts.on_error(err_msg)
            elseif state.finish_reason and state.finish_reason:find('^error') then
                opts.on_error(state.finish_reason)
            elseif state.finish_reason == nil and state.content == '' and #state.tool_calls == 0 then
                local err_msg = vim.trim(sse_buffer or '')
                if err_msg == '' then
                    err_msg = 'curl response ended without content or finish reason'
                end
                opts.on_error(err_msg)
            else
                opts.on_done({
                    content = state.content or '',
                    reasoning = state.reasoning or '',
                    tool_calls = state.tool_calls or {},
                    finish_reason = state.finish_reason,
                    usage = state.usage,
                    response_id = state.response_id,
                })
            end
        end
    end)

    return obj
end

--- Non-streaming completion request.
--- @async
--- @param messages table[]
--- @param opts table
--- @return table
function M.complete(messages, opts)
    local model, parser = opts.model, opts.parser
    if not model or not parser then
        error('No model/parser provided', 0)
    end

    local body = parser.build_body(model.id, messages, {}, {
        temperature = 0.1,
        max_tokens = model.maxTokens or 4096,
    })
    body.stream = false

    local url = model.url
    local headers = type(model.headers) == 'function' and model:headers() or model.headers or {}
    headers['Content-Type'] = 'application/json'

    local curl = require('slopcode.utils.curl')
    local data, err = curl.post(url, { json = true, headers = headers, body = body, max_time = 300 })
    if err then
        error(err)
    end
    return data
end

return M
