-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local async = require('async')
local loop = require('slopcode.loop')
local agent = require('slopcode.agent')
local catalog = require('slopcode.catalog')
local config = require('slopcode.config')
local status = require('slopcode.status')
local sync = require('slopcode.utils.vim').sync

--- Create the chat buffer, window, keymaps, and prompt callback.
--- @param buf integer
--- @param win integer
local function create_ui()
    local layout = config.display.layout

    -- Clean up previous buffer if it exists
    local old_buf = loop.buf()
    if old_buf and vim.api.nvim_buf_is_valid(old_buf) then
        vim.api.nvim_buf_delete(old_buf, { force = true })
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local win

    if layout == 'replace' then
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, buf)
    elseif layout == 'hsplit' then
        win = vim.api.nvim_open_win(buf, true, { split = 'below' })
    else -- vsplit
        win = vim.api.nvim_open_win(buf, true, { split = 'right' })
    end

    -- Attach the event loop and status module
    loop.attach(buf, win)
    status.subheader1(config.model)

    vim.schedule(function()
        vim.bo[buf].buftype = 'prompt'
        vim.bo[buf].bufhidden = 'hide'
        vim.bo[buf].buflisted = false
        vim.bo[buf].swapfile = false
        vim.bo[buf].filetype = 'markdown'
        vim.bo[buf].syntax = 'off'
        vim.bo[buf].undolevels = -1

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
        vim.fn.prompt_setprompt(buf, '> ')
        vim.bo[buf].omnifunc = "v:lua.require'slopcode.chat'.omnifunc"

        vim.keymap.set('n', '<C-c>', function()
            require('slopcode.chat').abort()
        end, { buffer = buf, silent = true })
        vim.keymap.set('n', '<Tab>', function()
            require('slopcode.chat').model()
        end, { buffer = buf, silent = true })

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

        -- WinClosed autocmd
        local augroup = vim.api.nvim_create_augroup('slopcode', { clear = true })
        vim.api.nvim_create_autocmd('WinClosed', {
            group = augroup,
            callback = function(args)
                if tonumber(args.match) == win then
                    require('slopcode.chat').close()
                end
            end,
        })

        -- Redraw existing messages if any
        if #agent.messages() > 0 then
            loop.redraw(agent.messages())
        end
    end)
end

--- Open the chat window (or focus if already open).
function M.open()
    local win = loop.win()
    if win and vim.api.nvim_win_is_valid(win) then
        return vim.api.nvim_set_current_win(win)
    end
    create_ui()
end

--- Close the chat window, abort agent, and clean up resources.
function M.close()
    agent.abort()

    local buf = loop.buf()
    local win = loop.win()
    local layout = config.display.layout
    loop.detach()
    vim.cmd('stopinsert')

    if layout == 'replace' then
        -- Switch to previous buffer, then delete the chat buffer
        if win and vim.api.nvim_win_is_valid(win) then
            pcall(vim.cmd, 'bprev')
        end
        if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
        end
    else
        if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
        end
    end
end

--- Toggle the chat window open/closed.
function M.toggle()
    local win = loop.win()
    if win and vim.api.nvim_win_is_valid(win) then
        M.close()
    else
        M.open()
    end
end

--- Send a user message; queues it if the agent is already running.
--- @param user_text string
function M.send(user_text)
    if not user_text or user_text == '' then
        return
    end
    if agent.running() then
        agent.push(user_text)
        return
    end

    M.open()
    async.run(agent.run, user_text)
end

--- Reset the conversation history and redraw the buffer.
function M.reset()
    agent.reset()
    loop.redraw(agent.messages())
    loop.push({ type = 'status', content = 'Conversation reset' })
    loop.drain()
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
    async.run(function()
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
end

return M
