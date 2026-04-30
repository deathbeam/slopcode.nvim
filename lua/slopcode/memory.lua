-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local api = require('slopcode.api')

--- Estimate token count from text length (rough: 1 token per 4 chars).
--- @param text string
--- @return integer
local function estimate_tokens(text)
    if type(text) ~= 'string' then
        return 0
    end
    return math.ceil(#text / 4)
end

--- Estimate total token count across all messages.
--- @param messages table[]
--- @return integer
local function estimate_messages_tokens(messages)
    local total = 0
    for _, msg in ipairs(messages) do
        if type(msg.content) == 'string' then
            total = total + estimate_tokens(msg.content)
        end
    end
    return total
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
