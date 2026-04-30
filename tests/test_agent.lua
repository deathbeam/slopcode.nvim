-- SPDX-License-Identifier: GPL-2.0-only

--- Tests for slopcode.agent module

local child = MiniTest.new_child_neovim()

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

describe('agent module', function()
    it('messages table is initially empty', function()
        child.lua('require("slopcode.agent")')
        local count = child.lua_get('#require("slopcode.agent").messages()')
        MiniTest.expect.equality(count, 0)
    end)

    it('running returns false initially', function()
        child.lua('require("slopcode.agent")')
        local running = child.lua_get('require("slopcode.agent").running()')
        MiniTest.expect.equality(running, false)
    end)

    it('push adds to queue and drain returns it', function()
        child.lua('require("slopcode.agent")')
        child.lua('require("slopcode.agent").push("test message")')
        local msgs = child.lua_get('require("slopcode.agent").drain()')
        MiniTest.expect.equality(type(msgs), 'table')
        MiniTest.expect.equality(#msgs, 1)
        MiniTest.expect.equality(msgs[1], 'test message')
    end)

    it('drain clears the queue', function()
        child.lua('require("slopcode.agent")')
        child.lua('require("slopcode.agent").push("msg1")')
        child.lua('require("slopcode.agent").drain()')
        local msgs = child.lua_get('require("slopcode.agent").drain()')
        MiniTest.expect.equality(#msgs, 0)
    end)

    it('reset clears messages in-place', function()
        child.lua([[
            require("slopcode.agent")
            local agent = require("slopcode.agent")
            table.insert(agent.messages(), { role = "user", content = "hello" })
        ]])
        local count_before = child.lua_get('#require("slopcode.agent").messages()')
        MiniTest.expect.equality(count_before, 1)

        child.lua('require("slopcode.agent").reset()')
        local count_after = child.lua_get('#require("slopcode.agent").messages()')
        MiniTest.expect.equality(count_after, 0)
    end)
end)
