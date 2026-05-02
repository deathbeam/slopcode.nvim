-- SPDX-License-Identifier: MIT

--- Tests for slopcode.events module

local child = MiniTest.new_child_neovim()

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_modules()
    child.lua([[
        require('slopcode.events')
    ]])
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

describe('events.subscribe', function()
    it('receives events from drain', function()
        load_modules()
        child.lua([[
            _G._received = {}
            local unsub = require('slopcode.events').subscribe(function(events)
                _G._received = events
            end)
            require('slopcode.events').push({ type = 'user_message', content = 'test' })
            require('slopcode.events').drain()
            _G._unsub = unsub
        ]])
        local count = child.lua_get('#_G._received')
        MiniTest.expect.equality(count, 1)
        local event_type = child.lua_get('_G._received[1].type')
        MiniTest.expect.equality(event_type, 'user_message')
    end)

    it('unsubscribe stops receiving events', function()
        load_modules()
        child.lua([[
            _G._received = {}
            local unsub = require('slopcode.events').subscribe(function(events)
                _G._received[#_G._received + 1] = events
            end)
            require('slopcode.events').push({ type = 'user_message', content = 'first' })
            require('slopcode.events').drain()
            unsub()
            require('slopcode.events').push({ type = 'user_message', content = 'second' })
            require('slopcode.events').drain()
        ]])
        local count = child.lua_get('#_G._received')
        MiniTest.expect.equality(count, 1)
    end)
end)

describe('events.batch', function()
    it('delivers all pushed events in one batch', function()
        load_modules()
        child.lua([[
            _G._received = nil
            require('slopcode.events').subscribe(function(events)
                _G._received = events
            end)
            require('slopcode.events').push({ type = 'a' })
            require('slopcode.events').push({ type = 'b' })
            require('slopcode.events').push({ type = 'c' })
            require('slopcode.events').drain()
        ]])
        local count = child.lua_get('#_G._received')
        MiniTest.expect.equality(count, 3)
    end)

    it('empty drain does not notify subscribers', function()
        load_modules()
        child.lua([[
            _G._called = false
            require('slopcode.events').subscribe(function()
                _G._called = true
            end)
            require('slopcode.events').drain()
        ]])
        local called = child.lua_get('_G._called')
        MiniTest.expect.equality(called, false)
    end)

    it('drain clears the queue', function()
        load_modules()
        child.lua([[
            _G._count = 0
            require('slopcode.events').subscribe(function(events)
                _G._count = _G._count + #events
            end)
            require('slopcode.events').push({ type = 'a' })
            require('slopcode.events').drain()
            require('slopcode.events').drain()
        ]])
        local count = child.lua_get('_G._count')
        MiniTest.expect.equality(count, 1)
    end)
end)
