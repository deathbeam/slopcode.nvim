-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local api = require('slopcode.api')

-- Based on: https://github.com/google-gemini/gemini-cli/blob/main/packages/core/src/utils/tokenCalculation.ts
-- Token estimation constants
-- ASCII characters (0-127) are roughly 4 chars per token
local ASCII_TOKENS_PER_CHAR = 0.25
-- Non-ASCII characters (CJK, emoji, etc.) are often 1-2 tokens per char.
-- We use 1.3 as a conservative estimate to avoid underestimation.
local NON_ASCII_TOKENS_PER_CHAR = 1.3
-- Maximum chars before falling back to simple length/chars_per_token
local MAX_CHARS_FOR_FULL_HEURISTIC = 100000
local DEFAULT_CHARS_PER_TOKEN = 4

--- Estimate token count from text with character-aware heuristic.
--- ASCII chars are ~0.25 tokens each (4 chars/token),
--- non-ASCII chars (CJK, emoji, etc.) are ~1.3 tokens each.
--- For very long strings, falls back to length/chars_per_token for performance.
--- @param text string
--- @return number
local function estimate_tokens(text)
    if type(text) ~= 'string' then
        return 0
    end

    local len = #text
    if len > MAX_CHARS_FOR_FULL_HEURISTIC then
        return len / DEFAULT_CHARS_PER_TOKEN
    end

    local tokens = 0
    for i = 1, len do
        if text:byte(i) <= 127 then
            tokens = tokens + ASCII_TOKENS_PER_CHAR
        else
            tokens = tokens + NON_ASCII_TOKENS_PER_CHAR
        end
    end
    return tokens
end

--- Estimate tokens for tool calls JSON (part of assistant messages).
--- @param tool_calls table[]
--- @return number
local function estimate_tool_calls_tokens(tool_calls)
    if not tool_calls or #tool_calls == 0 then
        return 0
    end
    return estimate_tokens(vim.json.encode(tool_calls))
end

--- Estimate total token count across all messages.
--- Counts content text, tool calls in assistant messages, and tool_call_id in tool messages.
--- @param messages table[]
--- @return integer
local function estimate_messages_tokens(messages)
    local total = 0
    for _, msg in ipairs(messages) do
        if type(msg.content) == 'string' then
            total = total + estimate_tokens(msg.content)
        end
        -- Tool calls in assistant messages contribute tokens
        if msg.tool_calls then
            total = total + estimate_tool_calls_tokens(msg.tool_calls)
        end
        -- Tool role messages have a tool_call_id that counts
        if msg.role == 'tool' and msg.tool_call_id then
            total = total + estimate_tokens(msg.tool_call_id)
        end
    end
    return math.floor(total)
end

--- Compact messages when they exceed the context window.
--- @async
--- @param messages table[]
--- @param opts { model: table, parser: table }
--- @return table[] compacted, boolean did_compact
function M.compact(messages, opts)
    local model, parser = opts.model, opts.parser
    if not model or not parser then
        error('No model/parser provided', 0)
    end

    local context_window = model.contextWindow or 128000
    local max_tokens = math.floor(context_window * 0.75)
    local keep_recent = 6

    if estimate_messages_tokens(messages) < max_tokens or #messages <= keep_recent + 1 then
        return messages, false
    end

    local start = messages[1] and messages[1].role == 'system' and 2 or 1
    local end_idx = #messages - keep_recent
    if end_idx < start then
        return messages, false
    end

    local to_summarize = {}
    for i = start, end_idx do
        to_summarize[#to_summarize + 1] = { role = messages[i].role, content = messages[i].content or '' }
    end

    local response = api.complete({
        {
            role = 'system',
            content = 'Summarize the conversation concisely. Preserve key decisions, code, file paths, and context.',
        },
        { role = 'user', content = 'Summarize:\n\n' .. vim.json.encode(to_summarize) },
    }, opts)

    local summary = parser and parser.extract_content and parser.extract_content(response) or ''
    if summary == '' then
        summary = 'Previous conversation compacted (summary unavailable).'
    else
        summary = 'Previous conversation summary: ' .. summary
    end

    local new_messages = {}
    if messages[1] and messages[1].role == 'system' then
        new_messages[1] = messages[1]
    end
    new_messages[#new_messages + 1] = { role = 'system', content = summary }
    for i = #messages - keep_recent + 1, #messages do
        new_messages[#new_messages + 1] = messages[i]
    end
    return new_messages, true
end

return M
