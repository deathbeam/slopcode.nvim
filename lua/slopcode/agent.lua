-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local config = require('slopcode.config')
local catalog = require('slopcode.catalog')
local api = require('slopcode.api')
local async = require('async')
local prompt = require('slopcode.prompt')
local tools = require('slopcode.tools')
local memory = require('slopcode.memory')
local loop = require('slopcode.loop')

--- @type table[]  conversation messages
local _messages = {}
--- @type boolean
local _running = false
--- @type vim.SystemObj?
local _job = nil
--- @type boolean
local _aborted = false
--- @type string[]  queued user messages to inject before next turn
local _queue = {}
--- @type { input: integer, output: integer, cache_read: integer, cache_write: integer }
local _usage = { input = 0, output = 0, cache_read = 0, cache_write = 0 }

--- @async
--- Stream one turn from the API.
--- @param model table
--- @param parser table
--- @return table result
local function stream_turn(model, parser)
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

    local response_text = ''
    local reasoning_text = ''

    loop.push({ type = 'stream_start' })

    local result = async.await(function(resolve)
        local ok, job_or_err = pcall(api.stream, api_messages, tools.get_definitions(), {
            model = model,
            parser = parser,
            on_reasoning = function(chunk)
                reasoning_text = reasoning_text .. chunk
                loop.push({ type = 'reasoning_delta', content = chunk, quiet = not config.display.thinking })
            end,
            on_content = function(chunk)
                response_text = response_text .. chunk
                loop.push({ type = 'content_delta', content = chunk })
            end,
            on_done = function(r)
                _job = nil
                if _aborted then
                    _aborted = false
                    resolve({ aborted = true })
                else
                    r.content = response_text
                    r.reasoning = reasoning_text
                    -- Accumulate usage from the result
                    if r.usage then
                        _usage.input = _usage.input
                            + (r.usage.input_tokens or r.usage.prompt_tokens or r.usage.input or 0)
                        _usage.output = _usage.output
                            + (r.usage.output_tokens or r.usage.completion_tokens or r.usage.output or 0)
                        _usage.cache_read = _usage.cache_read
                            + (r.usage.cache_read_input_tokens or r.usage.cache_read or 0)
                        _usage.cache_write = _usage.cache_write
                            + (r.usage.cache_creation_input_tokens or r.usage.cache_write or 0)
                    end
                    resolve(r)
                end
            end,
            on_error = function(err)
                _job = nil
                if _aborted then
                    _aborted = false
                    resolve({ aborted = true })
                else
                    resolve({ error = err })
                end
            end,
        })
        if not ok then
            resolve({ error = tostring(job_or_err) })
            return
        end
        _job = job_or_err
    end)

    loop.drain() -- flush stream deltas before proceeding

    loop.push({
        type = 'stream_end',
        result = result,
        error = result.error,
        aborted = result.aborted,
    })

    return result
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
    _aborted = true
    if _job then
        pcall(_job.kill, _job)
        _job = nil
    end
end

--- Reset conversation state.
function M.reset()
    for k in pairs(_messages) do
        _messages[k] = nil
    end
    _aborted = false
    _running = false
    _job = nil
    for k in pairs(_queue) do
        _queue[k] = nil
    end
    for k in pairs(_usage) do
        _usage[k] = nil
    end
    prompt.invalidate()
end

--- Enqueue a user message (injected before the next LLM call).
--- @param text string
function M.push(text)
    _queue[#_queue + 1] = text
    loop.push({ type = 'user_message', content = text, quiet = true })
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
    _running = true

    local model, parser = catalog.model()
    if not model or not parser then
        loop.push({
            type = 'status',
            content = 'Error: No model/parser for: ' .. config.model,
        })
        loop.push({ type = 'stream_end' })
        loop.push({ type = 'agent_done' })
        _running = false
        return
    end

    _messages[#_messages + 1] = { role = 'user', content = user_text }
    loop.push({ type = 'user_message', content = user_text, quiet = true })

    local ok, err = pcall(function()
        while true do
            -- Compact history
            local compacted, did_compact = memory.compact(_messages, { model = model, parser = parser })
            if did_compact then
                for k in pairs(_messages) do
                    _messages[k] = nil
                end
                for i, msg in ipairs(compacted) do
                    _messages[i] = msg
                end
                loop.redraw(_messages)
                loop.push({ type = 'status', content = 'Context compacted' })
            end

            -- Inject queued messages
            local queued = M.drain()
            for _, text in ipairs(queued) do
                _messages[#_messages + 1] = { role = 'user', content = text }
                loop.push({ type = 'user_message', content = text })
            end

            -- Stream one turn
            local result = stream_turn(model, parser)

            -- Update usage
            loop.push({
                type = 'usage',
                input = _usage.input,
                output = _usage.output,
                cache_read = _usage.cache_read,
                cache_write = _usage.cache_write,
                pct = model.contextWindow and (memory.estimate(_messages) / model.contextWindow * 100) or 0,
                window = model.contextWindow or 128000,
            })

            -- Handle result
            if result.aborted then
                -- we aborted, done
                loop.push({ type = 'status', content = 'Aborted' })
                return
            elseif result.error then
                -- error, we are done
                loop.push({
                    type = 'status',
                    content = 'Error: ' .. tostring(result.error),
                })
                return
            elseif result.tool_calls and #result.tool_calls > 0 then
                -- continue to next turn
                _messages[#_messages + 1] = {
                    role = 'assistant',
                    content = result.content ~= '' and result.content or nil,
                    tool_calls = result.tool_calls,

                    _meta = {
                        reasoning = result.reasoning ~= '' and result.reasoning,
                    },
                }

                for _, tr in ipairs(tools.execute_all(result.tool_calls)) do
                    loop.push({
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
            elseif result.finish_reason == 'incomplete' then
                -- try again
                loop.push({
                    type = 'status',
                    content = 'Stream ended unexpectedly, retrying...',
                })
            else
                -- store response message
                _messages[#_messages + 1] = {
                    role = 'assistant',
                    content = result.content,

                    _meta = {
                        reasoning = result.reasoning ~= '' and result.reasoning or nil,
                    },
                }

                -- if messages arrived during streaming, continue; otherwise stop
                local late = M.drain()
                if #late == 0 then
                    break
                end
                for _, text in ipairs(late) do
                    _messages[#_messages + 1] = { role = 'user', content = text }
                    loop.push({ type = 'user_message', content = text })
                end
            end
        end
    end)

    if not ok then
        loop.push({ type = 'status', content = 'Error: ' .. tostring(err) })
    end

    loop.push({ type = 'agent_done' })
    _running = false
end

return M
