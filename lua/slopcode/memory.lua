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
local SUMMARY_POINT = 0.75
local TOOL_RESULT_MAX_CHARS = 2000

-- Summarization prompts
local SUMMARY_PREFIX = 'Previous conversation summary:\n'

local SUMMARIZATION_SYSTEM_PROMPT =
    [[You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.]]

local SUMMARIZATION_PROMPT =
    [[The conversation above is between a user and an AI coding assistant that uses tools (read/write/edit files, run commands, etc.).

Create a structured context checkpoint summary that another LLM will use to continue the work. Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

local UPDATE_SUMMARIZATION_PROMPT =
    [[The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

Update the existing structured summary with new information. RULES:
- PRESERVE all existing information from the previous summary
- ADD new progress, decisions, and context from the new messages
- UPDATE the Progress section: move items from "In Progress" to "Done" when completed
- UPDATE "Next Steps" based on what was accomplished
- PRESERVE exact file paths, function names, and error messages
- If something is no longer relevant, you may remove it

Use this EXACT format:

## Goal
[Preserve existing goals, add new ones if the task expanded]

## Constraints & Preferences
- [Preserve existing, add new ones discovered]

## Progress
### Done
- [x] [Include previously done items AND newly completed items]

### In Progress
- [ ] [Current work - update based on progress]

### Blocked
- [Current blockers - remove if resolved]

## Key Decisions
- **[Decision]**: [Brief rationale] (preserve all previous, add new)

## Next Steps
1. [Update based on current state]

## Critical Context
- [Preserve important context, add new if needed]

Keep each section concise. Preserve exact file paths, function names, and error messages.]]

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
            if content:match('^' .. SUMMARY_PREFIX) then
                parts[#parts + 1] = '[Previous conversation summary]:\n' .. content
            elseif content ~= '' then
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
        prompt_text = prompt_text .. '<previous-summary>\n' .. previous_summary .. '\n</previous-summary>\n\n'
    end
    prompt_text = prompt_text .. (previous_summary and UPDATE_SUMMARIZATION_PROMPT or SUMMARIZATION_PROMPT)

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
