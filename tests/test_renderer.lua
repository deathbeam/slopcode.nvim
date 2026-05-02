-- SPDX-License-Identifier: MIT

--- Tests for slopcode.renderer module

local child = MiniTest.new_child_neovim()

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_renderer()
    child.lua([[
        require('slopcode.renderer')
    ]])
end

local function attach_renderer()
    child.lua([[
        local buf = vim.api.nvim_create_buf(true, true)
        vim.api.nvim_open_win(buf, true, { split = 'right' })
        vim.bo[buf].buftype = 'prompt'
        vim.fn.prompt_setprompt(buf, '> ')
        require('slopcode.renderer').attach(buf)
        require('slopcode.status').subheader1('test-model')
    ]])
end

local function get_buf_lines()
    return child.lua_get('vim.api.nvim_buf_get_lines(require("slopcode.renderer").buf(), 0, -1, false)')
end

-----------------------------------------------------------------------
-- Setup / Teardown
-----------------------------------------------------------------------

before_each(function()
    child.restart({ '-u', 'scripts/init.lua' })
end)

after_each(function()
    child.stop()
end)

-----------------------------------------------------------------------
-- Tests
-----------------------------------------------------------------------

describe('renderer.attach', function()
    it('stores buffer reference and finds window', function()
        load_renderer()
        attach_renderer()
        local buf = child.lua_get('require("slopcode.renderer").buf()')
        local win = child.lua_get('vim.api.nvim_win_get_buf(0)')
        MiniTest.expect.equality(type(buf), 'number')
        MiniTest.expect.equality(win, buf)
    end)
end)

describe('renderer.event rendering', function()
    it('renders user_message event', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'hello' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('hello'), nil)
    end)

    it('renders content_delta event', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'content_delta', content = 'Hi!' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('Hi!'), nil)
    end)

    it('renders reasoning_delta event', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'reasoning_delta', content = 'thinking...' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('thinking'), nil)
    end)

    it('renders tool_result event as foldable block', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({
                type = 'tool_result',
                name = 'read',
                args = 'foo.lua',
                content = 'local x = 1',
            })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('▸ read'), nil)
        MiniTest.expect.no_equality(joined:find('local x = 1'), nil)
    end)

    it('tool fold includes closing fence', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({
                type = 'tool_result',
                name = 'read',
                args = 'foo.lua',
                content = 'local x = 1',
            })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local fence_idx = nil
        for i, line in ipairs(lines) do
            if line == '````' then
                fence_idx = i
            end
        end
        MiniTest.expect.no_equality(fence_idx, nil)
        if fence_idx then
            MiniTest.expect.equality(lines[fence_idx], '````')
        end
    end)

    it('escalates fence when content has 4 backticks', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({
                type = 'tool_result',
                name = 'read',
                args = 'x',
                content = '```\ncode\n````\nmore',
            })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local fence_line = nil
        for i, line in ipairs(lines) do
            if line:match('^`%`%`%`%`$') then
                fence_line = line
            end
        end
        MiniTest.expect.no_equality(fence_line, nil)
    end)

    it('renders status event with [!] prefix', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'status', content = 'Aborted' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('%[!%] Aborted'), nil)
    end)

    it('renders queued user_message (no > prefix)', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'queued msg', quiet = true })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.equality(joined:find('> queued msg'), nil)
    end)

    it('renders quiet user_message (no > prefix)', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'quiet msg', quiet = true })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.equality(joined:find('> quiet msg'), nil)
    end)

    it('drain with no buffer does not error', function()
        load_renderer()
        -- Don't attach — no buffer
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'orphan' })
            require('slopcode.events').drain()
        ]])
        -- Just verify no error was thrown
        local buf = child.lua_get('require("slopcode.renderer").buf()')
        MiniTest.expect.equality(buf, vim.NIL)
    end)
end)

describe('renderer.stream_append', function()
    it('accumulates content across multiple deltas', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'Hello' })
            require('slopcode.events').push({ type = 'content_delta', content = ' world' })
            require('slopcode.events').push({ type = 'content_delta', content = '!' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('Hello world!'), nil)
    end)

    it('handles newlines in streaming content', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'line1\nline2\n' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('line1'), nil)
        MiniTest.expect.no_equality(joined:find('line2'), nil)
    end)

    it('handles incremental newlines across deltas', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'line1\n' })
            require('slopcode.events').push({ type = 'content_delta', content = 'line2' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('line1'), nil)
        MiniTest.expect.no_equality(joined:find('line2'), nil)
    end)

    it('resets stream state on stream_start', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            -- First stream
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'First' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
            -- Second stream
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'Second' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('First'), nil)
        MiniTest.expect.no_equality(joined:find('Second'), nil)
    end)
end)

describe('renderer.ensure_blank_line', function()
    it('does not produce double blank lines between sections', function()
        load_renderer()
        attach_renderer()
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'hello' })
            require('slopcode.events').push({ type = 'stream_start' })
            require('slopcode.events').push({ type = 'content_delta', content = 'Hi!' })
            require('slopcode.events').push({ type = 'stream_end' })
            require('slopcode.events').push({ type = 'user_message', content = 'next' })
            require('slopcode.events').drain()
        ]])
        local lines = get_buf_lines()
        local double_blank = false
        for i = 1, #lines - 1 do
            if lines[i] == '' and lines[i + 1] == '' then
                double_blank = true
            end
        end
        MiniTest.expect.equality(double_blank, false)
    end)
end)

describe('renderer.clear', function()
    it('clears buffer content and resets folds', function()
        load_renderer()
        attach_renderer()
        -- Push some content first
        child.lua([[
            require('slopcode.events').push({ type = 'user_message', content = 'old content' })
            require('slopcode.events').drain()
        ]])
        local lines_before = get_buf_lines()
        local joined_before = table.concat(lines_before, '\n')
        MiniTest.expect.no_equality(joined_before:find('old content'), nil)

        -- Clear
        child.lua([[
            require('slopcode.events').push({ type = 'clear' })
            require('slopcode.events').push({ type = 'user_message', content = 'new content' })
            require('slopcode.events').drain()
        ]])
        local lines_after = get_buf_lines()
        local joined_after = table.concat(lines_after, '\n')
        MiniTest.expect.equality(joined_after:find('old content'), nil)
        MiniTest.expect.no_equality(joined_after:find('new content'), nil)
    end)
end)
