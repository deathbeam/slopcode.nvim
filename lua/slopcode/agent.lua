-- SPDX-License-Identifier: MIT

--- Core agent logic: manages conversation, streams LLM responses,
--- executes tool calls. Pushes all rendering events to the event bus.
local M = {}

local config = require('slopcode.config')
local catalog = require('slopcode.catalog')
local api = require('slopcode.api')
local async = require('async')
local prompt = require('slopcode.prompt')
local memory = require('slopcode.memory')
local events = require('slopcode.events')
local text = require('slopcode.utils.text')
local sync = require('slopcode.utils.vim').sync
local sessions = require('slopcode.sessions')

--- @type table[]  conversation messages
local _messages = {}
--- @type string?  persistent conversation ID (reset on M.reset)
local _session_id = nil
--- @type boolean
local _running = false
--- @type function?
local _cancel_fn = nil
--- @type vim.async.Task[]  currently running tool tasks
local _tasks = {}
--- @type string[]  queued user messages to inject before next turn
local _queue = {}
--- @type { requests: integer, input: integer, output: integer, cache_read: integer, cache_write: integer }
local _usage = { requests = 0, input = 0, output = 0, cache_read = 0, cache_write = 0 }

local function execute_tools(tool_calls)
    local tasks = {}
    local meta = {}

    for i, tc in ipairs(tool_calls) do
        local fn = tc['function']
        local name = fn.name
        local args_json = fn.arguments or '{}'
        local call_id = tc.call_id or tc.id or ''
        local ok, args_decoded = pcall(vim.json.decode, args_json, { luanil = { object = true, array = true } })

        meta[i] = {
            name = name,
            label = ok and args_decoded.label,
            args = args_json,
            call_id = call_id,
        }

        local tool = config.tools[name]
        local handler = tool and tool.handler
        tasks[i] = async.run(function()
            if not handler then
                return 'Error: unknown tool: ' .. name
            end
            if not ok then
                return 'Error: invalid tool call arguments: ' .. args_json
            end

            sync()
            local ok2, result = pcall(handler, args_decoded)
            if not ok2 then
                return 'Error: ' .. tostring(result)
            end
            return result or ''
        end)
    end

    _tasks = tasks
    local ok, results = pcall(async.await_all, tasks)
    if not ok then
        results = {}
    end
    _tasks = {}

    local output = {}

    for i, m in ipairs(meta) do
        local res = results[i] or {}
        local content = res[1] or 'Tool call cancelled'
        output[i] = {
            name = m.name,
            tool_call_id = m.call_id,
            label = m.label,
            args = m.args,
            content = content,
        }
    end

    return output
end

--- Convert a single message to its rendering events and push them.
--- @param msg table
local function push_message_events(msg)
    local meta = msg._meta or {}

    if msg.role == 'user' then
        events.push({ type = 'user_message', content = msg.content })
    elseif msg.role == 'assistant' then
        events.push({ type = 'stream_start', quiet = true })
        if meta.reasoning and meta.reasoning ~= '' then
            events.push({ type = 'reasoning_start' })
            events.push({ type = 'reasoning_delta', content = meta.reasoning })
        end
        if msg.content and msg.content ~= '' then
            events.push({ type = 'content_start' })
            events.push({ type = 'content_delta', content = msg.content })
        end
        events.push({ type = 'stream_end', quiet = true })
    elseif msg.role == 'tool' then
        events.push({
            type = 'tool_result',
            content = msg.content,
            name = meta.name,
            label = meta.label,
            args = meta.args,
        })
    end
end

--- @async
--- Stream one turn from the API.
--- @param session_id string
--- @param model table
--- @param parser table
--- @return table result
local function stream_turn(session_id, model, parser)
    local api_messages = { { role = 'system', content = prompt.build() or '' } }
    for _, msg in ipairs(_messages) do
        local m = {}
        for k, v in pairs(msg) do
            if k ~= '_meta' then
                m[k] = v
            end
        end
        api_messages[#api_messages + 1] = m
    end

    local in_content = false
    local in_reasoning = false

    local tools = {}
    for name, tool in pairs(config.tools) do
        tools[#tools + 1] = {
            name = name,
            description = tool.description or '',
            parameters = tool.parameters or { type = 'object', properties = {} },
        }
    end

    events.push({ type = 'stream_start' })

    local r = async.await(function(resolve)
        local ok, cancel_fn = pcall(api.stream, api_messages, tools, {
            session_id = session_id,
            temperature = config.temperature,
            max_tokens = config.clamp_output_tokens,
            reasoning_effort = config.reasoning_effort,
            model = model,
            parser = parser,
            on_reasoning = function(chunk)
                if not in_reasoning then
                    in_reasoning = true

                    if in_content then
                        events.push({ type = 'content_end' })
                        in_content = false
                    end

                    events.push({ type = 'reasoning_start', quiet = config.hide_reasoning })
                end

                events.push({ type = 'reasoning_delta', content = chunk, quiet = config.hide_reasoning })
            end,
            on_content = function(chunk)
                if not in_content then
                    in_content = true

                    if in_reasoning then
                        events.push({ type = 'reasoning_end' })
                        in_reasoning = false
                    end

                    events.push({ type = 'content_start' })
                end

                events.push({ type = 'content_delta', content = chunk })
            end,
            on_done = function(result)
                resolve(result)
            end,
            on_abort = function()
                resolve({ aborted = true })
            end,
            on_error = function(err)
                resolve({ error = err })
            end,
        })

        if not ok or type(cancel_fn) ~= 'function' then
            resolve({ error = tostring(cancel_fn) })
            return
        end

        _cancel_fn = cancel_fn
    end)

    if in_content then
        events.push({ type = 'content_end' })
    elseif in_reasoning then
        events.push({ type = 'reasoning_end' })
    end

    _cancel_fn = nil

    if r.usage then
        _usage.requests = _usage.requests + 1
        _usage.input = _usage.input + (r.usage.input_tokens or r.usage.prompt_tokens or r.usage.input or 0)
        _usage.output = _usage.output + (r.usage.output_tokens or r.usage.completion_tokens or r.usage.output or 0)
        _usage.cache_read = _usage.cache_read + (r.usage.cache_read_input_tokens or r.usage.cache_read or 0)
        _usage.cache_write = _usage.cache_write + (r.usage.cache_creation_input_tokens or r.usage.cache_write or 0)
    end

    events.push({
        type = 'stream_end',
        result = r,
        error = r.error,
        aborted = r.aborted,
    })

    return r
end

--- Is the agent currently running?
--- @return boolean
function M.running()
    return _running
end

--- Get the current conversation messages.
--- @return table[]
function M.messages()
    return _messages
end

--- Abort the current run.
function M.abort()
    if _cancel_fn then
        _cancel_fn()
        _cancel_fn = nil
    end

    for _, t in ipairs(_tasks) do
        t:close()
    end
end

--- Reset conversation state.
function M.reset()
    M.abort()

    _session_id = nil
    _messages = {}
    _queue = {}
    for k in pairs(_usage) do
        _usage[k] = 0
    end

    prompt.invalidate()
    events.push({ type = 'clear' })
    events.push({ type = 'status', content = 'Conversation reset' })
    events.drain()
end

--- Enqueue a user message (injected before the next LLM call).
--- @param text string
function M.push(text)
    _queue[#_queue + 1] = text
    events.push({ type = 'user_message', content = text, quiet = true })
end

--- Drain and return all queued messages.
--- @return string[]
function M.drain()
    local msgs = _queue
    _queue = {}
    return msgs
end

--- @async
--- Core agent loop: compact → stream → tool_calls → repeat.
--- Checks for queued messages between turns.
--- @param user_text string
function M.run(user_text)
    if not _session_id then
        _session_id = text.uuid()
    end

    events.push({ type = 'agent_start', session_id = _session_id })
    _running = true

    local model, parser = catalog.model()
    if not model or not parser then
        events.push({
            type = 'status',
            content = 'Error: No model/parser for: ' .. config.model,
        })
        events.push({ type = 'stream_end' })
        events.push({ type = 'agent_end' })
        _running = false
        return
    end

    _messages[#_messages + 1] = { role = 'user', content = user_text }
    events.push({ type = 'user_message', content = user_text, quiet = true })

    local ok, err = pcall(function()
        while true do
            -- Compact history
            if memory.should_compact(_messages, model.contextWindow) then
                events.push({ type = 'status', content = 'Compacting context...' })
                _messages = memory.compact(_messages, { model = model, parser = parser })
                _session_id = text.uuid()

                events.push({ type = 'clear' })
                for _, msg in ipairs(_messages) do
                    push_message_events(msg)
                end
                events.push({ type = 'status', content = 'Context compacted' })
            end

            -- Inject queued messages
            local queued = M.drain()
            for _, text in ipairs(queued) do
                _messages[#_messages + 1] = { role = 'user', content = text }
                events.push({ type = 'user_message', content = text })
            end

            -- Stream one turn
            local result = stream_turn(_session_id, model, parser)

            -- Update usage
            events.push({
                type = 'usage',
                requests = _usage.requests,
                input = _usage.input,
                output = _usage.output,
                cache_read = _usage.cache_read,
                cache_write = _usage.cache_write,
                pct = model.contextWindow and (memory.estimate(_messages) / model.contextWindow * 100) or 0,
                window = model.contextWindow,
            })

            -- Handle result
            if result.aborted then
                -- we aborted, done
                events.push({ type = 'status', content = 'Aborted' })
                sessions.save(_messages, _session_id)
                return
            elseif result.error then
                -- error, we are done
                events.push({
                    type = 'status',
                    content = 'Error: ' .. tostring(result.error),
                })
                sessions.save(_messages, _session_id)
                return
            elseif result.tool_calls and #result.tool_calls > 0 then
                -- continue to next turn
                _messages[#_messages + 1] = {
                    role = 'assistant',
                    content = result.content ~= '' and result.content or nil,
                    reasoning_content = result.reasoning ~= '' and result.reasoning or nil,
                    tool_calls = result.tool_calls,
                }

                for _, tr in ipairs(execute_tools(result.tool_calls)) do
                    events.push({
                        type = 'tool_result',
                        name = tr.name,
                        label = tr.label,
                        args = tr.args,
                        content = tr.content,
                    })

                    _messages[#_messages + 1] = {
                        role = 'tool',
                        content = tr.content,
                        tool_call_id = tr.tool_call_id,

                        _meta = {
                            name = tr.name,
                            label = tr.label,
                            args = tr.args,
                        },
                    }
                end
                sessions.save(_messages, _session_id)
            elseif result.finish_reason == 'incomplete' then
                -- try again
                events.push({
                    type = 'status',
                    content = 'Stream ended unexpectedly, retrying...',
                })
            else
                -- store response message
                _messages[#_messages + 1] = {
                    role = 'assistant',
                    content = result.content,
                    reasoning_content = result.reasoning ~= '' and result.reasoning or nil,
                }

                sessions.save(_messages, _session_id)

                -- if messages arrived during streaming, continue; otherwise stop
                local late = M.drain()
                if #late == 0 then
                    break
                end
                for _, text in ipairs(late) do
                    _messages[#_messages + 1] = { role = 'user', content = text }
                    events.push({ type = 'user_message', content = text })
                end
            end
        end
    end)

    if not ok then
        events.push({ type = 'status', content = 'Error: ' .. tostring(err) })
    end

    events.push({ type = 'agent_end' })
    _running = false
end

return M
