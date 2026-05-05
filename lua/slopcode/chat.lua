-- SPDX-License-Identifier: MIT

local M = {}

local async = require('async')
local loop = require('slopcode.loop')
local agent = require('slopcode.agent')
local catalog = require('slopcode.catalog')
local config = require('slopcode.config')
local status = require('slopcode.status')
local vim_utils = require('slopcode.utils.vim')
local sync = vim_utils.sync

--- @param buf integer
--- @param wc table
--- @return integer
local function create_window(buf, wc)
    local function resolve_dim(value, dim)
        if value <= 1 then
            return math.floor(dim * value)
        end
        return math.floor(value)
    end

    local layout = wc.layout

    local win
    if layout == 'replace' then
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    elseif layout == 'float' then
        local width = resolve_dim(wc.width, vim.o.columns)
        local height = resolve_dim(wc.height, vim.o.lines)
        local row = wc.row
        local col = wc.col
        if row == nil or col == nil then
            row = math.floor((vim.o.lines - height) / 2)
            col = math.floor((vim.o.columns - width) / 2)
        end

        win = vim.api.nvim_open_win(buf, true, {
            relative = wc.relative or 'editor',
            width = width,
            height = height,
            row = row,
            col = col,
            style = 'minimal',
            border = wc.border or 'single',
            title = wc.title or 'slopcode',
            footer = wc.footer,
            zindex = wc.zindex or 1,
        })

        vim.wo[win].winblend = wc.blend or 0
    else
        local split = layout == 'horizontal' and 'below' or 'right'
        win = vim.api.nvim_open_win(buf, true, { split = split })
        local width = resolve_dim(wc.width, vim.o.columns)
        local height = resolve_dim(wc.height, vim.o.lines)
        if layout == 'vertical' and width > 0 then
            vim.api.nvim_win_set_width(win, width)
        elseif layout == 'horizontal' and height > 0 then
            vim.api.nvim_win_set_height(win, height)
        end
    end

    vim.wo[win].foldmethod = 'manual'
    vim.wo[win].foldtext =
        "substitute(getline(v:foldstart),'^[▸▶] ','▸ ','').'  [+'.(v:foldend-v:foldstart+1).' lines]'"
    vim.wo[win].foldminlines = 2
    vim.wo[win].foldlevel = 0
    vim.wo[win].conceallevel = 2
    vim.wo[win].concealcursor = 'ncv'
    vim.wo[win].wrap = true
    vim.wo[win].linebreak = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = 'no'
    vim.wo[win].spell = false
    vim.wo[win].foldcolumn = '0'
    vim.wo[win].statuscolumn = ''

    return win
end

--- @param buf integer
local function setup_buffer(buf)
    vim.bo[buf].buftype = 'prompt'
    vim.bo[buf].bufhidden = 'hide'
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = 'slopcode'
    vim.bo[buf].syntax = 'off'
    vim.bo[buf].undolevels = -1
    vim.bo[buf].omnifunc = "v:lua.require'slopcode.chat'.omnifunc"
    vim.api.nvim_buf_set_name(buf, 'slopcode://chat')

    vim.fn.prompt_setprompt(buf, '> ')
    vim.fn.prompt_setcallback(buf, function(text)
        if agent.running() then
            agent.push(text)
            return
        end
        if text and text ~= '' then
            vim.schedule(function()
                require('slopcode.chat').send(text)
            end)
        end
    end)

    vim.fn.prompt_setinterrupt(buf, function()
        require('slopcode.chat').abort()
    end)

    vim.keymap.set('n', '<C-c>', function()
        require('slopcode.chat').abort()
    end, { buffer = buf, silent = true })
    vim.keymap.set('n', '<Tab>', function()
        require('slopcode.chat').model()
    end, { buffer = buf, silent = true })
end

--- Open the chat window
--- @param opts? table  window options override
function M.open(opts)
    local wc = vim.tbl_extend('force', config.window, opts or {})
    local layout = wc.layout
    local buf = loop.buf()
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        buf = vim.api.nvim_create_buf(true, true)
    end
    local win = vim_utils.win_for_buf(buf)
    if win then
        if vim.w[win].slopcode_layout == layout then
            return vim.api.nvim_set_current_win(win)
        end
        M.close()
    end

    win = create_window(buf, wc)
    vim.w[win].slopcode_layout = layout

    vim.schedule(function()
        setup_buffer(buf)
        loop.attach(buf)
        status.subheader1(config.model)
    end)
end

--- Close the chat window
function M.close()
    local buf = loop.buf()
    local win = vim_utils.win_for_buf(buf)
    if not win then
        return
    end

    -- Stop insert, close window or revert to previous buffer
    vim.cmd('stopinsert')
    local layout = vim.w[win].slopcode_layout
    if layout == 'replace' then
        pcall(vim.cmd, 'bprev')
    else
        pcall(vim.api.nvim_win_close, win, true)
    end
end

--- Toggle the chat window open/closed.
--- @param opts? table  window options override
function M.toggle(opts)
    if vim_utils.win_for_buf(loop.buf()) then
        M.close()
    else
        M.open(opts)
    end
end

--- Send a user message; queues it if the agent is already running.
--- @param user_text string
function M.send(user_text)
    if not user_text or vim.trim(user_text) == '' then
        return
    end
    if agent.running() then
        agent.push(user_text)
        return
    end
    async.run(agent.run, user_text):raise_on_error()
end

--- Reset the conversation history and redraw the buffer.
function M.reset()
    agent.reset()
end

--- Save the conversation messages to a JSON file.
--- @param path? string  Output file path (prompts if omitted)
function M.save(path)
    path = path or vim.fn.input('Save conversation to: ', '', 'file')
    if path == '' then
        return status.notify('Save cancelled', 'warn')
    end
    local f = io.open(path, 'w')
    if not f then
        return status.notify('Failed to save to: ' .. path, 'error')
    end
    f:write(vim.json.encode({ messages = agent.messages(), saved_at = os.date('%Y-%m-%d %H:%M:%S') }))
    f:close()
    status.notify('Saved to ' .. path)
end

--- Abort the current streaming agent run.
function M.abort()
    agent.abort()
end

--- Omnifunc for @path and /skill completion in the prompt buffer.
--- @param findstart integer  1 to find start column, 0 to get completions
--- @param base string  Text being completed
--- @return integer|string|table
function M.omnifunc(findstart, base)
    local line = vim.api.nvim_get_current_line()
    local col = vim.api.nvim_win_get_cursor(0)[2]
    if findstart == 1 then
        local trigger = line:sub(1, col + 1):match('.*()@%S*$') or line:sub(1, col + 1):match('.*()/%S*$')
        return trigger and (tonumber(trigger) - 1) or -3
    end

    local char = base:sub(1, 1)
    local items = {}

    if char == '@' then
        -- @path completion
        local query = base:sub(2)
        for _, b in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_loaded(b) and vim.fn.buflisted(b) == 1 then
                local name = vim.api.nvim_buf_get_name(b)
                if name and name ~= '' then
                    local rel = vim.fn.fnamemodify(name, ':.')
                    if query == '' or rel:find(query, 1, true) then
                        items[#items + 1] = { word = '@' .. rel, abbr = rel, kind = 'buffer' }
                    end
                end
            end
        end
        for _, f in ipairs(vim.fn.getcompletion(query, 'file')) do
            items[#items + 1] = { word = '@' .. f, abbr = f, kind = 'file' }
        end
    elseif char == '/' then
        -- /command completion
        local query = base:sub(2)
        local skills = async.run(require('slopcode.skills').build):wait()
        for _, skill in ipairs(skills) do
            local name = skill.name or ''
            if query == '' or name:lower():find(query:lower(), 1, true) then
                items[#items + 1] = {
                    word = '/' .. name,
                    info = skill.description or '',
                    abbr = name,
                    kind = 'skill',
                }
            end
        end
    end

    return #items > 0 and items or -3
end

--- Open a model selection prompt and update the active model.
function M.model()
    async
        .run(function()
            local models = catalog.build()
            if not models or #models == 0 then
                return status.notify('No models available', 'warn')
            end
            local labels = {}
            for _, m in ipairs(models) do
                labels[#labels + 1] = m.key
            end
            sync()
            local label = async.await(3, vim.ui.select, labels, { prompt = 'Select model: ' })
            if label then
                config.model = label
                status.subheader1(label)
                status.notify('Model: ' .. label, 'info', 3000)
            end
        end)
        :raise_on_error()
end

return M
