-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local FRAMES = { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
local INTERVAL = 80
local NOTIFY_MS = 5000

--- @type integer?
local _buf = nil
--- @type integer?
local _win = nil
--- @type vim.uv.Timer?
local _timer = nil
--- @type integer
local _idx = 1
--- @type boolean
local _busy = false
--- @type string
local _header = ''
--- @type string
local _subheader1 = ''
--- @type string
local _subheader2 = ''
--- @type string
local _busy_text = ''
--- @type { msg: string, expires: integer }?
local _notify = nil
--- @type vim.uv.Timer?
local _notify_timer = nil

--- Escape % signs for winbar.
--- @param str string
--- @return string
local function esc(str)
    return str:gsub('%%', '%%%%')
end

local function tick()
    if not (_buf and vim.api.nvim_buf_is_valid(_buf)) then
        return
    end

    if _busy then
        vim.bo[_buf].busy = 1
        _busy_text = FRAMES[_idx] .. ' Working...'
        _idx = _idx % #FRAMES + 1
    else
        vim.bo[_buf].busy = 0
        _busy_text = ''
    end

    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_win_call(_win, function()
            vim.cmd('redrawstatus')
        end)
    end
end

--- Resolve function (called by winbar %! expression).
--- @return string
function M.resolve()
    local title = _header
    local title_type = 'Title'
    if _notify and (_notify.expires - vim.uv.now() > 0) then
        title = _notify.msg
        title_type = 'WarningMsg'
    elseif _busy then
        title = _busy_text
        title_type = 'Comment'
    end

    local subheader = esc(_subheader1)
    if _subheader2 ~= '' then
        subheader = subheader .. ' ' .. esc(_subheader2)
    end

    return '%#'
        .. title_type
        .. '# '
        .. esc(title)
        .. ' %*'
        .. (subheader ~= '' and ('%=%#NonText# ' .. subheader .. ' %*') or '')
end

--- Attach status module to a buffer/window pair.
--- @param buf integer
--- @param win integer
function M.attach(buf, win)
    _buf = buf
    _win = win
    _busy = false
    _busy_text = ''
    _header = ''
    _subheader1 = ''
    _subheader2 = ''
    _notify = nil

    if win and vim.api.nvim_win_is_valid(win) then
        vim.wo[win].winbar = "%!v:lua.require'slopcode.status'.resolve()"
    end
end

--- Detach status module and clean up timers.
function M.detach()
    if _timer then
        _timer:stop()
        _timer:close()
        _timer = nil
    end
    if _notify_timer then
        _notify_timer:stop()
        _notify_timer:close()
        _notify_timer = nil
    end

    _buf = nil
    _win = nil
    _busy = false
    _busy_text = ''
    _header = ''
    _subheader1 = ''
    _subheader2 = ''
    _notify = nil
end

--- Start the spinner animation.
function M.start()
    _busy = true
    _idx = 1
    if _timer then
        return
    end
    tick()
    _timer = vim.uv.new_timer()
    _timer:start(
        0,
        INTERVAL,
        vim.schedule_wrap(function()
            tick()
        end)
    )
end

--- Stop the spinner animation.
function M.stop()
    if _timer then
        _timer:stop()
        _timer:close()
        _timer = nil
    end
    _busy = false
    _busy_text = ''
    _idx = 1
    tick()
end

--- Show a transient notification in the winbar + vim.notify.
--- @param msg string
--- @param level? string vim.notify level name ("info"|"warn"|"error"), default "info"
--- @param ms? integer duration in milliseconds (default 5000)
function M.notify(msg, level, ms)
    level = level or 'info'
    ms = ms or NOTIFY_MS
    local levels = { trace = 0, debug = 1, info = 2, warn = 3, error = 4 }
    vim.schedule(function()
        vim.notify('[' .. _header .. '] ' .. msg, levels[level] or 2)
    end)
    if not (_buf and vim.api.nvim_buf_is_valid(_buf)) then
        return
    end
    _notify = { msg = msg, expires = vim.uv.now() + ms }
    if _win and vim.api.nvim_win_is_valid(_win) then
        vim.api.nvim_win_call(_win, function()
            vim.cmd('redrawstatus')
        end)
    end
    if _notify_timer then
        _notify_timer:stop()
        _notify_timer:close()
    end
    _notify_timer = vim.uv.new_timer()
    _notify_timer:start(
        ms,
        0,
        vim.schedule_wrap(function()
            _notify_timer:close()
            _notify_timer = nil
            _notify = nil
            if _win and vim.api.nvim_win_is_valid(_win) then
                vim.api.nvim_win_call(_win, function()
                    vim.cmd('redrawstatus')
                end)
            end
        end)
    )
end

--- @param text string
function M.header(text)
    _header = text or ''
    tick()
end

--- @param text string
function M.subheader1(text)
    _subheader1 = text or ''
    tick()
end

--- @param text string
function M.subheader2(text)
    _subheader2 = text or ''
    tick()
end

return M
