-- SPDX-License-Identifier: MIT

--- Tests for slopcode.loop module

local child = MiniTest.new_child_neovim()

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_modules()
    child.lua([[
        require('slopcode.status')
        require('slopcode.loop')
    ]])
end

local function attach_loop()
    child.lua([[
        local buf = vim.api.nvim_create_buf(true, true)
        local win = vim.api.nvim_open_win(buf, true, { split = 'right' })
        require('slopcode.loop').attach(buf, win)
        require('slopcode.status').subheader1('test-model')
    ]])
end

local function get_buf_lines()
    return child.lua_get('vim.api.nvim_buf_get_lines(require("slopcode.loop").buf(), 0, -1, false)')
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

describe('loop.attach / detach', function()
    it('stores buffer and window references', function()
        load_modules()
        attach_loop()
        local buf = child.lua_get('require("slopcode.loop").buf()')
        local win = child.lua_get('require("slopcode.loop").win()')
        MiniTest.expect.equality(type(buf), 'number')
        MiniTest.expect.equality(type(win), 'number')
    end)

    it('clears references on detach', function()
        load_modules()
        attach_loop()
        child.lua('require("slopcode.loop").detach()')
        local buf = child.lua_get('require("slopcode.loop").buf()')
        MiniTest.expect.equality(buf, vim.NIL)
    end)

    it('clears all internal state on detach', function()
        load_modules()
        attach_loop()
        child.lua('require("slopcode.loop").detach()')
        local buf = child.lua_get('require("slopcode.loop").buf()')
        local win = child.lua_get('require("slopcode.loop").win()')
        MiniTest.expect.equality(buf, vim.NIL)
        MiniTest.expect.equality(win, vim.NIL)
    end)

    it('drain after detach is a no-op', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').detach()
            require('slopcode.loop').push({ type = 'user_message', content = 'after detach' })
            require('slopcode.loop').drain()
        ]])
        -- No error should occur
        local buf = child.lua_get('require("slopcode.loop").buf()')
        MiniTest.expect.equality(buf, vim.NIL)
    end)
end)

describe('loop.push / drain', function()
    it('renders user_message event', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'hello' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('hello'), nil)
    end)

    it('renders content_delta event', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'content_delta', content = 'Hi!' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('Hi!'), nil)
    end)

    it('renders reasoning_delta event', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'reasoning_delta', content = 'thinking...' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('thinking'), nil)
    end)

    it('renders tool_result event as foldable block', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({
                type = 'tool_result',
                name = 'read',
                args = 'foo.lua',
                content = 'local x = 1',
            })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('▸ read'), nil)
        MiniTest.expect.no_equality(joined:find('local x = 1'), nil)
    end)

    it('tool fold includes closing fence', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({
                type = 'tool_result',
                name = 'read',
                args = 'foo.lua',
                content = 'local x = 1',
            })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        -- Find the closing ```` in the buffer
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

    it('renders status event with [!] prefix', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'status', content = 'Aborted' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('%[!%] Aborted'), nil)
    end)

    it('renders queued user_message (no > prefix)', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'queued msg', quiet = true })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        -- queued messages should NOT have the '> ' prefix
        MiniTest.expect.equality(joined:find('> queued msg'), nil)
    end)

    it('renders quiet user_message (no > prefix)', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'quiet msg', quiet = true })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.equality(joined:find('> quiet msg'), nil)
    end)

    it('drain with no buffer does not error', function()
        load_modules()
        -- Don't attach — no buffer
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'orphan' })
            require('slopcode.loop').drain()
        ]])
        -- Just verify no error was thrown
        local buf = child.lua_get('require("slopcode.loop").buf()')
        MiniTest.expect.equality(buf, vim.NIL)
    end)
end)

describe('loop.stream_append', function()
    it('accumulates content across multiple deltas', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'Hello' })
            require('slopcode.loop').push({ type = 'content_delta', content = ' world' })
            require('slopcode.loop').push({ type = 'content_delta', content = '!' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('Hello world!'), nil)
    end)

    it('handles newlines in streaming content', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'line1\nline2\n' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('line1'), nil)
        MiniTest.expect.no_equality(joined:find('line2'), nil)
    end)

    it('handles incremental newlines across deltas', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'line1\n' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'line2' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('line1'), nil)
        MiniTest.expect.no_equality(joined:find('line2'), nil)
    end)

    it('resets stream state on stream_start', function()
        load_modules()
        attach_loop()
        child.lua([[
            -- First stream
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'First' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
            -- Second stream
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'Second' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('First'), nil)
        MiniTest.expect.no_equality(joined:find('Second'), nil)
    end)
end)

describe('loop.ensure_blank_line', function()
    it('does not produce double blank lines between sections', function()
        load_modules()
        attach_loop()
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'hello' })
            require('slopcode.loop').push({ type = 'stream_start' })
            require('slopcode.loop').push({ type = 'content_delta', content = 'Hi!' })
            require('slopcode.loop').push({ type = 'stream_end' })
            require('slopcode.loop').push({ type = 'user_message', content = 'next' })
            require('slopcode.loop').drain()
        ]])
        local lines = get_buf_lines()
        -- Check no consecutive blank lines
        local double_blank = false
        for i = 1, #lines - 1 do
            if lines[i] == '' and lines[i + 1] == '' then
                double_blank = true
            end
        end
        MiniTest.expect.equality(double_blank, false)
    end)
end)

describe('loop.redraw', function()
    it('rebuilds buffer from message list', function()
        load_modules()
        attach_loop()
        child.lua([[
            local messages = {
                { role = 'user', content = 'hello' },
                { role = 'assistant', content = 'Hi there!' },
                { role = 'user', content = 'how are you' },
                { role = 'assistant', content = "I'm good!" },
            }
            require('slopcode.loop').redraw(messages)
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('hello'), nil)
        MiniTest.expect.no_equality(joined:find('Hi there!'), nil)
        MiniTest.expect.no_equality(joined:find('how are you'), nil)
        MiniTest.expect.no_equality(joined:find("I'm good!"), nil)
    end)

    it('renders assistant reasoning in redraw', function()
        load_modules()
        attach_loop()
        child.lua([[
            local messages = {
                { role = 'assistant', content = 'Answer!', _meta = { reasoning = 'Let me think...' } },
            }
            require('slopcode.loop').redraw(messages)
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('Let me think'), nil)
        MiniTest.expect.no_equality(joined:find('Answer!'), nil)
    end)

    it('renders tool messages in redraw', function()
        load_modules()
        attach_loop()
        child.lua([[
            local messages = {
                { role = 'tool', content = 'file1.lua\nfile2.lua', _meta = { name = 'bash', args = 'ls' } },
            }
            require('slopcode.loop').redraw(messages)
        ]])
        local lines = get_buf_lines()
        local joined = table.concat(lines, '\n')
        MiniTest.expect.no_equality(joined:find('▸ bash'), nil)
        MiniTest.expect.no_equality(joined:find('file1.lua'), nil)
    end)

    it('clears buffer before redrawing', function()
        load_modules()
        attach_loop()
        -- Push some content first
        child.lua([[
            require('slopcode.loop').push({ type = 'user_message', content = 'old content' })
            require('slopcode.loop').drain()
        ]])
        local lines_before = get_buf_lines()
        local joined_before = table.concat(lines_before, '\n')
        MiniTest.expect.no_equality(joined_before:find('old content'), nil)

        -- Redraw with different messages
        child.lua([[
            local messages = {
                { role = 'user', content = 'new content' },
            }
            require('slopcode.loop').redraw(messages)
        ]])
        local lines_after = get_buf_lines()
        local joined_after = table.concat(lines_after, '\n')
        MiniTest.expect.equality(joined_after:find('old content'), nil)
        MiniTest.expect.no_equality(joined_after:find('new content'), nil)
    end)
end)

describe('loop.subscribe', function()
    it('receives events from drain', function()
        load_modules()
        attach_loop()
        child.lua([[
            _G._received = {}
            local unsub = require('slopcode.loop').subscribe(function(event)
                _G._received[#_G._received + 1] = event
            end)
            require('slopcode.loop').push({ type = 'user_message', content = 'test' })
            require('slopcode.loop').drain()
            _G._unsub = unsub
        ]])
        local count = child.lua_get('#_G._received')
        MiniTest.expect.equality(count, 1)
        local event_type = child.lua_get('_G._received[1].type')
        MiniTest.expect.equality(event_type, 'user_message')
    end)

    it('unsubscribe stops receiving events', function()
        load_modules()
        attach_loop()
        child.lua([[
            _G._received = {}
            local unsub = require('slopcode.loop').subscribe(function(event)
                _G._received[#_G._received + 1] = event
            end)
            require('slopcode.loop').push({ type = 'user_message', content = 'first' })
            require('slopcode.loop').drain()
            unsub()
            require('slopcode.loop').push({ type = 'user_message', content = 'second' })
            require('slopcode.loop').drain()
        ]])
        local count = child.lua_get('#_G._received')
        MiniTest.expect.equality(count, 1)
    end)
end)
