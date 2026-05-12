-- SPDX-License-Identifier: MIT

local M = {}

local api = require('slopcode.api')

-- Token estimation constants (based on Gemini CLI heuristic)
local ASCII_TOKENS_PER_CHAR = 0.25
local NON_ASCII_TOKENS_PER_CHAR = 1.3
local MAX_CHARS_FOR_FULL_HEURISTIC = 100000
local DEFAULT_CHARS_PER_TOKEN = 4

-- Compaction thresholds
local KEEP_RECENT = 6
local SUMMARY_POINT = 0.6
local TOOL_RESULT_MAX_CHARS = 2000

-- Summarization prompts
local SUMMARY_PREFIX = '[Previous conversation summary]:\n'

local SUMMARIZATION_SYSTEM_PROMPT = [[You are a context summarization assistant. ONLY output the structured summary.
Do NOT continue the conversation. Do NOT respond to any questions.]]

local SUMMARY_TEMPLATE =
    [[Output exactly the Markdown structure shown inside <template> and keep the section order unchanged. Do not include the <template> tags in your response.

## Goal
- [single-sentence task summaries]

## Constraints & Preferences
- [user constraints, preferences, specs, or "(none)"]

## Progress
- [x] [completed work]
- [ ] [current work]
- [!] [blockers]
or "(none)"

## Key Decisions
- [decision and why, or "(none)"]

## Critical Context
- [exact file paths, error strings, identifiers, or "(none)"]

Rules:
- Keep every section, even when empty (use "(none)").
- Use terse bullets, not prose.
- Preserve exact file paths, function names, and error messages.
- Do not mention the summary process or that context was compacted.]]

local CREATE_PROMPT = [[Create a new anchored summary from the conversation history above.]]

local UPDATE_PROMPT = [[Update the anchored summary below using the conversation history above.
Preserve still-true details, remove stale details, and merge in the new facts.
<previous-summary>
%s
</previous-summary>]]

--- @param text string
--- @return integer
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

--- @param text string
--- @param max_chars integer
--- @return string
local function truncate(text, max_chars)
    if #text <= max_chars then
        return text
    end
    return text:sub(1, max_chars) .. '\n\n[... ' .. (#text - max_chars) .. ' more characters truncated]'
end

--- @param messages table[]
--- @return string
local function serialize_messages(messages)
    local parts = {}

    for _, msg in ipairs(messages) do
        if msg.role == 'user' then
            local content = msg.content or ''
            if content ~= '' then
                parts[#parts + 1] = '[User]: ' .. content
            end
        elseif msg.role == 'assistant' then
            local text_parts = {}
            local reasoning_parts = {}
            local tool_calls = {}

            if msg._meta and msg._meta.reasoning then
                reasoning_parts[#reasoning_parts + 1] = msg._meta.reasoning
            end
            if msg.content and msg.content ~= '' then
                text_parts[#text_parts + 1] = msg.content
            end
            if msg.tool_calls and #msg.tool_calls > 0 then
                for _, tc in ipairs(msg.tool_calls) do
                    local fn = tc['function'] or tc
                    tool_calls[#tool_calls + 1] = (fn.name or '') .. '(' .. (fn.arguments or '{}') .. ')'
                end
            end

            if #reasoning_parts > 0 then
                parts[#parts + 1] = '[Assistant thinking]:\n' .. table.concat(reasoning_parts, '\n')
            end
            if #text_parts > 0 then
                parts[#parts + 1] = '[Assistant]: ' .. table.concat(text_parts, '\n')
            end
            if #tool_calls > 0 then
                parts[#parts + 1] = '[Assistant tool calls]: ' .. table.concat(tool_calls, '; ')
            end
        elseif msg.role == 'tool' then
            local content = msg.content or ''
            if content ~= '' then
                local label = ''
                if msg._meta then
                    label = msg._meta.label and (' (' .. msg._meta.label .. ')')
                        or msg._meta.name and (' (' .. msg._meta.name .. ')')
                        or ''
                end
                parts[#parts + 1] = '[Tool result' .. label .. ']: ' .. truncate(content, TOOL_RESULT_MAX_CHARS)
            end
        end
    end

    return table.concat(parts, '\n\n')
end

--- @param messages table[]
--- @return string
local function serialize_file_ops(messages)
    local read_files = {}
    local modified_files = {}
    local seen_read = {}
    local seen_modified = {}

    for _, msg in ipairs(messages) do
        if msg.role == 'assistant' and msg.tool_calls then
            for _, tc in ipairs(msg.tool_calls) do
                local fn = tc['function'] or tc
                local name = fn.name or ''
                local ok, args =
                    pcall(vim.json.decode, fn.arguments or '{}', { luanil = { object = true, array = true } })
                if ok and type(args) == 'table' and type(args.path) == 'string' then
                    if name == 'read' and not seen_read[args.path] then
                        read_files[#read_files + 1] = args.path
                        seen_read[args.path] = true
                    elseif (name == 'write' or name == 'edit') and not seen_modified[args.path] then
                        modified_files[#modified_files + 1] = args.path
                        seen_modified[args.path] = true
                    end
                end
            end
        end
    end

    table.sort(read_files)
    table.sort(modified_files)

    local sections = {}
    if #read_files > 0 then
        sections[#sections + 1] = '<read-files>\n' .. table.concat(read_files, '\n') .. '\n</read-files>'
    end
    if #modified_files > 0 then
        sections[#sections + 1] = '<modified-files>\n' .. table.concat(modified_files, '\n') .. '\n</modified-files>'
    end
    if #sections == 0 then
        return ''
    end
    return '\n\n' .. table.concat(sections, '\n\n')
end

--- @param messages table[]
--- @return integer
function M.estimate(messages)
    local total = 0
    for _, msg in ipairs(messages) do
        if type(msg.content) == 'string' then
            total = total + estimate_tokens(msg.content)
        end
        if msg.tool_calls and #msg.tool_calls > 0 then
            total = total + estimate_tokens(vim.json.encode(msg.tool_calls))
        end
        if msg.role == 'tool' and msg.tool_call_id then
            total = total + estimate_tokens(msg.tool_call_id)
        end
    end
    return math.floor(total)
end

--- @param messages table[]
--- @param context_window integer
--- @return boolean
function M.should_compact(messages, context_window)
    return M.estimate(messages) >= math.floor(context_window * SUMMARY_POINT) and #messages > KEEP_RECENT + 1
end

--- @async
--- @param messages table[]
--- @param opts { model: table, parser: table }
--- @return table[] compacted
function M.compact(messages, opts)
    local parser = opts.parser
    local start = messages[1] and messages[1].role == 'system' and 2 or 1
    local end_idx = #messages - KEEP_RECENT
    if end_idx < start then
        return messages
    end

    -- Separate existing summary from messages to re-summarize
    local to_summarize = {}
    local previous_summary = nil
    for i = start, end_idx do
        local msg = messages[i]
        if msg.role == 'user' and msg.content and msg.content:match('^' .. SUMMARY_PREFIX) then
            previous_summary = msg.content:gsub('^' .. SUMMARY_PREFIX, '')
        else
            to_summarize[#to_summarize + 1] = msg
        end
    end

    local conversation_text = serialize_messages(to_summarize)

    local prompt_text = '<conversation>\n' .. conversation_text .. '\n</conversation>\n\n'
    if previous_summary then
        prompt_text = prompt_text .. UPDATE_PROMPT:format(previous_summary) .. '\n\n' .. SUMMARY_TEMPLATE
    else
        prompt_text = prompt_text .. CREATE_PROMPT .. '\n\n' .. SUMMARY_TEMPLATE
    end

    local response = api.complete({
        {
            role = 'system',
            content = SUMMARIZATION_SYSTEM_PROMPT,
        },
        { role = 'user', content = prompt_text },
    }, opts)

    local summary = parser and parser.extract_content and parser.extract_content(response) or ''
    if summary == '' then
        summary = 'Previous conversation compacted (summary unavailable).'
    else
        summary = SUMMARY_PREFIX .. summary
    end
    summary = summary .. serialize_file_ops(to_summarize)

    local new_messages = {}
    if messages[1] and messages[1].role == 'system' then
        new_messages[1] = messages[1]
    end
    new_messages[#new_messages + 1] = { role = 'user', content = summary }
    for i = #messages - KEEP_RECENT + 1, #messages do
        new_messages[#new_messages + 1] = messages[i]
    end
    return new_messages
end

return M
