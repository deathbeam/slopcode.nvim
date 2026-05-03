-- SPDX-License-Identifier: GPL-2.0-only

--- Tests for slopcode.prompt module
---
--- Tests template expansion and context file resolution.
--- Uses child Neovim because prompt.lua calls vim.fn and vim.api.

local child = MiniTest.new_child_neovim()

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_config()
    child.lua("require('slopcode.config')")
end

--- Write content to a temp file using vim.fn.writefile
local function write_temp(path, content)
    local lines = vim.split(content, '\n', { plain = true })
    child.lua(string.format("vim.fn.writefile(%s, '%s')", vim.inspect(lines), path))
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
-- Tests: template variable expansion
-----------------------------------------------------------------------

describe('prompt template expansion', function()
    it('expands ${CWD} to current working directory', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {} -- skip file resolution
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        local cwd = child.lua_get('vim.fn.getcwd()')
        MiniTest.expect.no_equality(result:find(cwd, 1, true), nil)
    end)

    it('expands ${DATE} to YYYY-MM-DD format', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:match('%d%d%d%d%-%d%d%-%d%d'), nil)
    end)

    it('expands ${PROMPT_SNIPPETS} from tool definitions', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:find('read:'), nil)
        MiniTest.expect.no_equality(result:find('Read a text file'), nil)
    end)

    it('expands ${PROMPT_GUIDELINES} from tool definitions', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:find('Use read before edit'), nil)
    end)

    it('no leftover template variables after expansion', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.equality(result:find('${CWD}'), nil)
        MiniTest.expect.equality(result:find('${DATE}'), nil)
        MiniTest.expect.equality(result:find('${PROMPT_SNIPPETS}'), nil)
        MiniTest.expect.equality(result:find('${PROMPT_GUIDELINES}'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: caching
-----------------------------------------------------------------------

describe('prompt caching', function()
    it('returns same result on second load call', function()
        load_config()
        local r1, r2 = unpack(child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            local r1 = require('async').run(prompt.build):wait()
            local r2 = require('async').run(prompt.build):wait()
            return { r1, r2 }
        ]]))
        MiniTest.expect.equality(r1, r2)
    end)

    it('reload clears cache and re-evaluates', function()
        load_config()
        local r1, r2 = unpack(child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            local r1 = require('async').run(prompt.build):wait()
            -- Change the system prompt
            require('slopcode.config').system_prompt = 'New prompt ${CWD}'
            prompt.invalidate()
            local r2 = require('async').run(prompt.build):wait()
            return { r1, r2 }
        ]]))
        MiniTest.expect.no_equality(r1, r2)
        MiniTest.expect.no_equality(r2:find('New prompt'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: context file resolution
-----------------------------------------------------------------------

describe('prompt context file resolution', function()
    it('appends context file content to prompt', function()
        load_config()
        write_temp('/tmp/slopcode_test_context.txt', 'Important context here')
        local result = child.lua([[
            require('slopcode.config').context = { '/tmp/slopcode_test_context.txt' }
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:find('Important context here'), nil)
        MiniTest.expect.no_equality(result:find('Project Context'), nil)
    end)

    it('skips non-existent context files silently', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = { '/tmp/slopcode_no_such_context_file.txt' }
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.equality(result:find('Project Context'), nil)
    end)

    it('resolves bare filenames from cwd upward to root', function()
        load_config()
        local cwd = vim.fn.getcwd()
        write_temp(cwd .. '/TEST_CONTEXT.md', 'Test context from cwd')
        local result = child.lua([[
            require('slopcode.config').context = { 'TEST_CONTEXT.md' }
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:find('Test context from cwd'), nil)
        os.remove(cwd .. '/TEST_CONTEXT.md')
    end)

    it('deduplicates context files found at multiple directory levels', function()
        load_config()
        local cwd = vim.fn.getcwd()
        write_temp(cwd .. '/DEDUP_CTX.md', 'dedup content')
        local result = child.lua([[
            require('slopcode.config').context = { 'DEDUP_CTX.md' }
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        local _, count = result:gsub('dedup content', '')
        MiniTest.expect.equality(count, 1)
        os.remove(cwd .. '/DEDUP_CTX.md')
    end)

    it('includes section header with relative path', function()
        load_config()
        write_temp('/tmp/slopcode_test_section.txt', 'Section body')
        local result = child.lua([[
            require('slopcode.config').context = { '/tmp/slopcode_test_section.txt' }
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.no_equality(result:find('## '), nil)
    end)

    it('no Project Context section when no context files found', function()
        load_config()
        local result = child.lua([[
            require('slopcode.config').context = {}
            local prompt = require('slopcode.prompt')
            prompt.invalidate()
            return require('async').run(prompt.build):wait()
        ]])
        MiniTest.expect.equality(result:find('Project Context'), nil)
    end)
end)
