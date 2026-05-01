-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local status = require('slopcode.status')
local sync = require('slopcode.utils.vim').sync

--- @type table[]  event queue for batched rendering
local _queue = {}
--- @type vim.uv.Timer?
local _timer = nil
--- @type integer?
local _buf = nil
--- @type integer?
local _win = nil
--- @type table[]
local _folding = {}
--- @type function[]
local _listeners = {}
--- @type integer?
local _stream_offset = nil
--- @type string[]
local _stream_parsed = {}
--- @type string
local _stream_tail = ''
--- @type integer
local _buf_lines = 0

--- Append block to buffer. Inserts before the prompt line.
local function block_append(buf, text)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) or text == '' then
        return
    end
    local lines = vim.split(text, '\n', { plain = true })
    if lines[#lines] == '' then
        lines[#lines] = nil
    end
    if #lines == 0 then
        return
    end

    vim.api.nvim_buf_set_lines(buf, _buf_lines - 1, _buf_lines - 1, false, lines)
    _buf_lines = _buf_lines + #lines
end

--- Append streaming text incrementally.
local function stream_append(buf, text)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) or text == '' then
        return
    end

    local prev_parsed_n = #_stream_parsed
    local prev_had_tail = #_stream_tail > 0

    local combined = _stream_tail .. text
    local new_lines = vim.split(combined, '\n', { plain = true })
    if #new_lines == 0 then
        return
    end

    -- Separate complete lines from the (possibly) incomplete tail
    if combined:byte(-1) == 10 then -- ends with \n
        if new_lines[#new_lines] == '' then
            new_lines[#new_lines] = nil
        end
        _stream_tail = ''
    else
        _stream_tail = table.remove(new_lines)
    end

    for i = 1, #new_lines do
        _stream_parsed[#_stream_parsed + 1] = new_lines[i]
    end

    -- Build the changed portion: new complete lines + optional tail
    local changed = {}
    for i = 1, #new_lines do
        changed[i] = new_lines[i]
    end
    if #_stream_tail > 0 then
        changed[#changed + 1] = _stream_tail
    end

    if #changed == 0 then
        return
    end

    -- Replace only the tail-end of the stream region in the buffer
    if not _stream_offset then
        _stream_offset = _buf_lines - 1
        vim.api.nvim_buf_set_lines(buf, _stream_offset, _stream_offset, false, changed)
        _buf_lines = _stream_offset + #changed + 1
    else
        local old_count = prev_parsed_n + (prev_had_tail and 1 or 0)
        vim.api.nvim_buf_set_lines(buf, _stream_offset + prev_parsed_n, _stream_offset + old_count, false, changed)
        _buf_lines = _stream_offset + #_stream_parsed + (#_stream_tail > 0 and 1 or 0) + 1
    end
end

--- Ensure a blank line before the next content. Idempotent.
local function ensure_blank_line(buf)
    if _buf_lines >= 2 then
        local prev_lines = vim.api.nvim_buf_get_lines(buf, _buf_lines - 2, _buf_lines - 1, false)
        if prev_lines and prev_lines[1] == '' then
            return
        end
    end
    block_append(buf, '\n')
end

--- Format cumulative token usage into a display string for the winbar.
--- @param usage table
--- @return string
local function format_usage(usage)
    --- @param n integer
    --- @return string
    local function format_tokens(n)
        if n < 1000 then
            return tostring(n)
        end
        if n < 10000 then
            return string.format('%.1fk', n / 1000)
        end
        if n < 1000000 then
            return math.floor(n / 1000) .. 'k'
        end
        if n < 10000000 then
            return string.format('%.1fM', n / 1000000)
        end
        return math.floor(n / 1000000) .. 'M'
    end

    local parts = {}
    if usage.input > 0 then
        parts[#parts + 1] = '↑' .. format_tokens(usage.input)
    end
    if usage.output > 0 then
        parts[#parts + 1] = '↓' .. format_tokens(usage.output)
    end
    if usage.cache_read > 0 then
        parts[#parts + 1] = 'R' .. format_tokens(usage.cache_read)
    end
    if usage.cache_write > 0 then
        parts[#parts + 1] = 'W' .. format_tokens(usage.cache_write)
    end
    if usage.window > 0 then
        local pct_str = string.format('%.1f', usage.pct) .. '%'
        local ctx_str = format_tokens(usage.window)
        parts[#parts + 1] = pct_str .. '/' .. ctx_str
    end
    if #parts > 0 then
        return table.concat(parts, ' ')
    end
    return ''
end

--- Apply fold ranges to the window.
--- @param win integer?
--- @param folds table[]  array of {start_line, end_line}
--- @param clear_existing boolean
local function apply_folds(win, folds, clear_existing)
    if not (win and vim.api.nvim_win_is_valid(win)) or #folds == 0 then
        return
    end
    vim.api.nvim_win_call(win, function()
        if clear_existing then
            pcall(vim.cmd, 'normal! zE')
        end
        for _, r in ipairs(folds) do
            pcall(vim.cmd, r[1] .. ',' .. r[2] .. 'fold')
        end
    end)
end

--- Render a tool result block and return its line range.
--- @param buf integer
--- @param name string
--- @param label string
--- @param content string
--- @return integer start_line, integer end_line
local function render_tool_block(buf, name, label, content)
    local start = _buf_lines
    block_append(buf, '▸ ' .. name .. ': ' .. label .. '\n')
    block_append(buf, '````\n' .. content .. '\n````\n')
    local end_lnum = _buf_lines - 1
    return start, end_lnum
end

--- Dispatch a single event to update the buffer.
--- @param event table
local function dispatch(event)
    local t = event.type
    local quiet = event.quiet

    if t == 'user_message' and not quiet then
        ensure_blank_line(_buf)
        block_append(_buf, '> ' .. event.content .. '\n')
    elseif t == 'content_delta' then
        stream_append(_buf, event.content)
    elseif t == 'reasoning_delta' and not quiet then
        stream_append(_buf, event.content)
    elseif t == 'stream_start' then
        _stream_offset = nil
        _stream_parsed = {}
        _stream_tail = ''
        _buf_lines = vim.api.nvim_buf_line_count(_buf)
        ensure_blank_line(_buf)
        if not quiet then
            status.start()
        end
    elseif t == 'stream_end' then
        _stream_offset = nil
        _stream_parsed = {}
        _stream_tail = ''
        ensure_blank_line(_buf)
        if not quiet then
            status.stop()
        end
    elseif t == 'tool_start' then
    -- nothing for now
    elseif t == 'tool_result' then
        ensure_blank_line(_buf)
        local start_line, end_line = render_tool_block(_buf, event.name, event.label or event.args or '', event.content)
        if end_line >= start_line and quiet then
            _folding[#_folding + 1] = { start_line, end_line }
        end
    elseif t == 'status' then
        ensure_blank_line(_buf)
        block_append(_buf, '[!] ' .. event.content .. '\n')
    elseif t == 'usage' then
        status.subheader2(format_usage(event))
    elseif t == 'agent_done' then
        status.stop()
    end
end

--- Push an event onto the queue; schedules a drain if not pending.
--- @param event table
function M.push(event)
    _queue[#_queue + 1] = event
    if not _timer then
        _timer = vim.defer_fn(function()
            M.drain()
        end, 16)
    end
end

--- Process all queued events and render to the buffer.
function M.drain()
    sync()

    _timer = nil
    local events = _queue
    _queue = {}
    if not (_buf and vim.api.nvim_buf_is_valid(_buf)) then
        return
    end

    local lazyredraw = vim.o.lazyredraw
    vim.o.lazyredraw = true

    for _, event in ipairs(events) do
        dispatch(event)
    end

    -- Apply accumulated folds once at the end of the batch
    apply_folds(_win, _folding, false)
    _folding = {}

    for i = #_listeners, 1, -1 do
        local listener = _listeners[i]
        if listener then
            for _, event in ipairs(events) do
                listener(event)
            end
        end
    end

    vim.o.lazyredraw = lazyredraw
end

--- Attach the loop to a buffer and window.
--- @param buf integer
--- @param win integer
function M.attach(buf, win)
    _buf = buf
    _win = win
    _buf_lines = vim.api.nvim_buf_line_count(buf)
    status.attach(buf, win)
    status.header('slopcode')
end

--- Detach the loop and reset all internal state.
function M.detach()
    if _timer then
        _timer = nil
    end
    status.detach()
    _buf = nil
    _win = nil
    _buf_lines = 0
    _queue = {}
    _stream_offset = nil
    _stream_parsed = {}
    _stream_tail = ''
    _folding = {}
end

--- Subscribe a listener callback for all events. Returns an unsubscribe function.
--- @param listener function
--- @return function unsubscribe
function M.subscribe(listener)
    _listeners[#_listeners + 1] = listener
    return function()
        for i = 1, #_listeners do
            if _listeners[i] == listener then
                table.remove(_listeners, i)
                return
            end
        end
    end
end

--- Re-render all messages from scratch, clearing the buffer.
--- @param messages table[]
function M.redraw(messages)
    if not (_buf and vim.api.nvim_buf_is_valid(_buf)) then
        return
    end

    local lazyredraw = vim.o.lazyredraw
    vim.o.lazyredraw = true
    _folding = {}
    vim.api.nvim_buf_set_lines(_buf, 0, -1, false, {})
    vim.fn.prompt_setprompt(_buf, '> ')
    _buf_lines = vim.api.nvim_buf_line_count(_buf)

    for _, msg in ipairs(messages) do
        local meta = msg._meta or {}

        if msg.role == 'user' then
            dispatch({ type = 'user_message', content = msg.content })
        elseif msg.role == 'assistant' then
            dispatch({ type = 'stream_start', quiet = true })
            if meta.reasoning and meta.reasoning ~= '' then
                dispatch({ type = 'reasoning_delta', content = meta.reasoning })
            end
            if msg.content and msg.content ~= '' then
                dispatch({ type = 'content_delta', content = msg.content })
            end
            dispatch({ type = 'stream_end', quiet = true })
        elseif msg.role == 'tool' then
            dispatch({
                type = 'tool_result',
                content = msg.content,
                name = meta.name,
                label = meta.label,
                args = meta.args,
            })
        end
    end

    apply_folds(_win, _folding, true)
    _folding = {}
    vim.o.lazyredraw = lazyredraw
end

--- Get the current buffer handle.
--- @return integer?
function M.buf()
    return _buf
end

--- Get the current window handle.
--- @return integer?
function M.win()
    return _win
end

return M
