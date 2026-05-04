-- SPDX-License-Identifier: MIT

--- Tests for slopcode.status module

local child = MiniTest.new_child_neovim()

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_status()
    child.lua([[require('slopcode.status')]])
end

local function resolve()
    return child.lua_get([[require('slopcode.status').resolve()]])
end

-----------------------------------------------------------------------
-- Setup / Teardown
-----------------------------------------------------------------------

before_each(function()
    child.restart({ '-u', 'scripts/init.lua' })
    child.lua([[
        local buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_open_win(buf, true, { split = 'right' })
        _G._test_buf = buf
    ]])
end)

after_each(function()
    child.stop()
end)

-----------------------------------------------------------------------
-- Tests
-----------------------------------------------------------------------

describe('status.attach', function()
    it('sets winbar to %! expression', function()
        load_status()
        child.lua([[require('slopcode.status').attach(_G._test_buf)]])
        local winbar = child.lua_get('vim.wo[vim.fn.win_getid(vim.fn.bufwinnr(_G._test_buf))].winbar')
        MiniTest.expect.equality(winbar, "%!v:lua.require'slopcode.status'.resolve()")
    end)

    it('shows idle state with slopcode title', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').header('slopcode')
        ]])
        MiniTest.expect.equality(resolve(), '%#Title# slopcode %*')
    end)
end)

describe('status.subheader', function()
    it('shows model name in idle winbar', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').subheader1('gpt-4o')
        ]])
        MiniTest.expect.equality(resolve(), '%#Title#  %*%=%#NonText# gpt-4o %*')
    end)

    it('clears model when set to empty string', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').subheader1('gpt-4o')
            require('slopcode.status').subheader1('')
        ]])
        MiniTest.expect.equality(resolve(), '%#Title#  %*')
    end)
end)

describe('status.start / status.stop', function()
    it('shows busy spinner with model name', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').subheader1('gpt-4o')
            require('slopcode.status').start()
        ]])
        local result = resolve()
        MiniTest.expect.no_equality(result:find('Working'), nil)
        MiniTest.expect.no_equality(result:find('gpt%-4o'), nil)
        MiniTest.expect.no_equality(result:find('Comment'), nil)
        MiniTest.expect.no_equality(result:find('NonText'), nil)
    end)

    it('returns to idle state after stop', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').subheader1('gpt-4o')
            require('slopcode.status').start()
            require('slopcode.status').stop()
        ]])
        MiniTest.expect.equality(resolve(), '%#Title#  %*%=%#NonText# gpt-4o %*')
    end)
end)

describe('status.notify', function()
    it('shows notification in winbar', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').notify('Saved!', 'info', 5000)
        ]])
        local result = resolve()
        MiniTest.expect.no_equality(result:find('Saved!'), nil)
        MiniTest.expect.no_equality(result:find('WarningMsg'), nil)
    end)

    it('clears notification after expiry', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').notify('Saved!', 'info', 1)
        ]])
        child.lua([[vim.uv.sleep(50)]])
        MiniTest.expect.equality(resolve(), '%#Title#  %*')
    end)

    it('replaces previous notification', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').notify('First', 'info', 5000)
            require('slopcode.status').notify('Second', 'info', 5000)
        ]])
        local result = resolve()
        MiniTest.expect.no_equality(result:find('Second'), nil)
        MiniTest.expect.equality(result:find('First'), nil)
    end)

    it('escapes % in notification message', function()
        load_status()
        child.lua([[
            require('slopcode.status').attach(_G._test_buf)
            require('slopcode.status').notify('50% done', 'info', 5000)
        ]])
        local result = resolve()
        MiniTest.expect.no_equality(result:find('50%%%% done'), nil)
    end)
end)
