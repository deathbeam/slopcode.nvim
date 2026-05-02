-- SPDX-License-Identifier: MIT

--- Subscribes to the event bus and writes rendered content to a buffer.
local M = {}

local events = require('slopcode.events')
local status = require('slopcode.status')
local vim_utils = require('slopcode.utils.vim')
local config = require('slopcode.config')

--- @type integer?
local _buf = nil
--- @type table[]
local _folding = {}

--- @param buf integer
--- @param text string
local function stream_append(buf, text)
    local lines = vim.split(text, '\n', { plain = true })
    if #lines == 0 then
        return
    end
    vim.fn.prompt_appendbuf(buf, lines)
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
    if usage.requests > 0 then
        parts[#parts + 1] = ' ' .. usage.requests
    end
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

--- @param folds table[]  array of {start_line, end_line}
local function apply_folds(folds)
    local win = vim_utils.win_for_buf(_buf)
    if not win or #folds == 0 then
        return
    end
    vim.api.nvim_win_call(win, function()
        for _, r in ipairs(folds) do
            pcall(vim.cmd, r[1] .. ',' .. r[2] .. 'fold')
        end
    end)
end

--- @param buf integer
--- @param name string
--- @param label string
--- @param content string
local function render_tool_block(buf, name, label, content)
    -- Find the longest backtick run in content to avoid fence collisions
    local max_backticks = 3
    for run in content:gmatch('(`+)') do
        local len = #run
        if len > max_backticks then
            max_backticks = len
        end
    end

    local fence = string.rep('`', max_backticks + 1)
    stream_append(buf, '▸ ' .. name .. ': ' .. label .. '\n')
    stream_append(buf, fence .. '\n' .. content .. '\n' .. fence .. '\n')
end

--- Dispatch a single event to update the buffer.
--- @param event table
local function dispatch(event)
    local t = event.type
    local quiet = event.quiet

    if t == 'user_message' and not quiet then
        stream_append(_buf, '\n')
        stream_append(_buf, '> ' .. event.content .. '\n')
    elseif t == 'content_delta' then
        stream_append(_buf, event.content)
    elseif t == 'reasoning_delta' and not quiet then
        stream_append(_buf, event.content)
    elseif t == 'stream_start' then
        -- nothing for now
    elseif t == 'stream_end' then
        -- nothing for now
    elseif t == 'content_start' then
        stream_append(_buf, '\n')
    elseif t == 'content_end' then
        -- nothing for now
    elseif t == 'reasoning_start' and not quiet then
        stream_append(_buf, '\n')
    elseif t == 'reasoning_end' and not quiet then
        -- nothing for now
    elseif t == 'tool_result' then
        stream_append(_buf, '\n')
        local start_lnum = vim.api.nvim_buf_get_mark(_buf, ':')[1] - 1
        render_tool_block(_buf, event.name, event.label or event.args or '', event.content)
        local end_lnum = vim.api.nvim_buf_get_mark(_buf, ':')[1] - 2
        if end_lnum >= start_lnum then
            _folding[#_folding + 1] = { start_lnum, end_lnum }
        end
    elseif t == 'status' then
        stream_append(_buf, '\n')
        stream_append(_buf, '[!] ' .. event.content .. '\n')
    elseif t == 'usage' then
        status.subheader2(format_usage(event))
    elseif t == 'agent_start' then
        status.start()
    elseif t == 'agent_end' then
        status.stop()
        stream_append(_buf, '\n')
    elseif t == 'clear' then
        vim.cmd('normal! zE')
        vim.api.nvim_buf_set_lines(_buf, 0, vim.api.nvim_buf_get_mark(_buf, ':')[1] - 1, false, { '' })
        _folding = {}
    end
end

--- Handle a batch of events from the event bus.
--- @param evs table[]
local function handle_batch(evs)
    if not (_buf and vim.api.nvim_buf_is_valid(_buf)) then
        return
    end

    local lazyredraw = vim.o.lazyredraw
    vim.o.lazyredraw = true

    for _, event in ipairs(evs) do
        dispatch(event)
    end

    apply_folds(_folding)
    _folding = {}

    vim.o.lazyredraw = lazyredraw
end

--- Attach the renderer to a buffer.
--- Subscribes to the event bus.
--- @param buf integer
--- @return function unsubscribe
function M.attach(buf)
    _buf = buf
    _folding = {}
    status.attach(buf)
    status.header('slopcode')
    return events.subscribe(handle_batch)
end

--- Get the current buffer handle.
--- @return integer?
function M.buf()
    return _buf
end

return M
