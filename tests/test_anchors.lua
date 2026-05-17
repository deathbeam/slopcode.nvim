-- SPDX-License-Identifier: MIT

--- Tests for slopcode anchors module and edit tool

local child = MiniTest.new_child_neovim()
local anchors = require('slopcode.anchors')
-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function load_config()
    child.lua("require('slopcode.config')")
end

--- Run a tool handler inside async.run + pcall
--- Returns: ok, result  (ok from pcall, result is the handler return or error string)
local function run_handler(tool_name, args)
    child.lua('_G._tool_args = ' .. vim.inspect(args))
    local code = string.format(
        [[
        local async = require('async')
        local config = require('slopcode.config')
        local tool = config.tools["%s"]
        local handler = tool and tool.handler
        local args = _G._tool_args
        local task = async.run(function()
            local ok, result = pcall(handler, args)
            return ok, result
        end)
        local ok, result = task:wait()
        _G._tool_ok = ok
        _G._tool_result = result
    ]],
        tool_name
    )
    child.lua(code)
    return child.lua_get('_G._tool_ok'), child.lua_get('_G._tool_result')
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
-- Tests: anchors module
-----------------------------------------------------------------------

describe('anchors module', function()
    it('hash is deterministic', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local h1 = anchors.hash(1, "hello world")
            local h2 = anchors.hash(1, "hello world")
            _G._h1, _G._h2 = h1, h2
        ]])
        MiniTest.expect.equality(child.lua_get('_G._h1'), child.lua_get('_G._h2'))
    end)

    it('hash produces 2-char bigram from BPE alphabet', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local h = anchors.hash(1, "test")
            _G._hash = h
            _G._len = #h
        ]])
        MiniTest.expect.equality(child.lua_get('_G._len'), 2)
        local hash = child.lua_get('_G._hash')
        MiniTest.expect.no_equality(hash:match('^%l%l$'), nil)
    end)

    it('different lines produce different hashes', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local h1 = anchors.hash(1, "aaa")
            local h2 = anchors.hash(2, "bbb")
            _G._diff = (h1 ~= h2)
        ]])
        MiniTest.expect.equality(child.lua_get('_G._diff'), true)
    end)

    it('format produces LINETAG§content format', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local formatted = anchors.format(5, "local x = 1")
            _G._formatted = formatted
        ]])
        local formatted = child.lua_get('_G._formatted')
        local line_num, hash, content = anchors.parse(formatted)
        MiniTest.expect.equality(line_num, 5)
        MiniTest.expect.equality(content, 'local x = 1')
        MiniTest.expect.equality(#hash, 2)
    end)

    it('structural lines get ordinal suffix hashes', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            -- Line with only braces/whitespace → ordinal suffix
            local h1 = anchors.hash(1, "}")
            local h2 = anchors.hash(2, "}")
            local h3 = anchors.hash(3, "  }")
            _G._h1, _G._h2, _G._h3 = h1, h2, h3
        ]])
        MiniTest.expect.equality(child.lua_get('_G._h1'), 'st')
        MiniTest.expect.equality(child.lua_get('_G._h2'), 'nd')
        MiniTest.expect.equality(child.lua_get('_G._h3'), 'rd')
    end)

    it('apply_edits accepts valid anchor', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local text = "hello\nworld"
            local start = anchors.hash(1, "hello")
            local end_h = anchors.hash(2, "world")
            local ok, result = pcall(anchors.apply_edits, text, {
                { start_anchor = "1" .. start, end_anchor = "2" .. end_h, repl_lines = { "hi" } },
            })
            _G._ok = ok
        ]])
        MiniTest.expect.equality(child.lua_get('_G._ok'), true)
    end)

    it('apply_edits rejects stale anchor', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local text = "hello\nworld"
            local ok, err = pcall(anchors.apply_edits, text, {
                { start_anchor = "1zz", end_anchor = "1zz", repl_lines = { "nope" } },
            })
            _G._ok, _G._err = ok, err
        ]])
        MiniTest.expect.equality(child.lua_get('_G._ok'), false)
        MiniTest.expect.no_equality(child.lua_get('_G._err'):find('Stale'), nil)
    end)

    it('apply_edits rejects out-of-range line', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local text = "hello"
            local ok, err = pcall(anchors.apply_edits, text, {
                { start_anchor = "99ab", end_anchor = "99ab", repl_lines = { "nope" } },
            })
            _G._ok, _G._err = ok, err
        ]])
        MiniTest.expect.equality(child.lua_get('_G._ok'), false)
        MiniTest.expect.no_equality(child.lua_get('_G._err'):find('does not exist'), nil)
    end)

    it('apply_edits reports stale when one of multiple edits is bad', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local text = "hello\nworld"
            local start = anchors.hash(1, "hello")
            local ok, err = pcall(anchors.apply_edits, text, {
                { start_anchor = "1" .. start, end_anchor = "1" .. start, repl_lines = { "hi" } },
                { start_anchor = "2zz", end_anchor = "2zz", repl_lines = { "nope" } },
            })
            _G._ok, _G._err = ok, err
        ]])
        MiniTest.expect.equality(child.lua_get('_G._ok'), false)
        MiniTest.expect.no_equality(child.lua_get('_G._err'):find('Stale'), nil)
    end)

    it('apply_edits gives helpful error for hash-only anchor input', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            local text = "hello\nworld"
            local ok, err = pcall(anchors.apply_edits, text, {
                { start_anchor = "ab", end_anchor = "ab", repl_lines = { "nope" } },
            })
            _G._ok, _G._err = ok, err
        ]])
        MiniTest.expect.equality(child.lua_get('_G._ok'), false)
        MiniTest.expect.no_equality(child.lua_get('_G._err'):find('2-letter suffix'), nil)
    end)

    it('strips § prefixes from any line that has them', function()
        load_config()
        child.lua([[
            local anchors = require('slopcode.anchors')
            -- Lines with § prefix get stripped
            local r1 = anchors.strip({ '1ab§hello', '2cd§world' })
            _G._m1_n = #r1
            _G._m1_a = r1[1]
            _G._m1_b = r1[2]
            -- Also strips >>> markers before §
            local r2 = anchors.strip({ '>>> 1ab§hello', '>>> 2cd§world' })
            _G._m2_n = #r2
            _G._m2_a = r2[1]
            _G._m2_b = r2[2]
            -- Lines without § are left untouched (no diff stripping)
            local r3 = anchors.strip({ '+ line1', '+ line2', '+ line3' })
            _G._m3_n = #r3
            _G._m3_a = r3[1]
            -- Truncation notices no longer special-cased, left as-is
            local r4 = anchors.strip({ '1ab§hello', '[5 more lines]', '2cd§world' })
            _G._m4_n = #r4
            _G._m4_a = r4[1]
            _G._m4_b = r4[2]
            _G._m4_c = r4[3]
            -- Mixed: only §-prefixed lines are stripped
            local r5 = anchors.strip({ '1ab§hello', 'plain text' })
            _G._m5_n = #r5
            _G._m5_a = r5[1]
            _G._m5_b = r5[2]
            -- Partial hashline (no line number) also stripped if § present
            local r6 = anchors.strip({ 'ab§hello', 'cd§world' })
            _G._m6_n = #r6
            _G._m6_a = r6[1]
            _G._m6_b = r6[2]
        ]])
        -- All §-prefixed lines stripped
        MiniTest.expect.equality(child.lua_get('_G._m1_n'), 2)
        MiniTest.expect.equality(child.lua_get('_G._m1_a'), 'hello')
        MiniTest.expect.equality(child.lua_get('_G._m1_b'), 'world')
        -- Same with >>> markers
        MiniTest.expect.equality(child.lua_get('_G._m2_n'), 2)
        MiniTest.expect.equality(child.lua_get('_G._m2_a'), 'hello')
        MiniTest.expect.equality(child.lua_get('_G._m2_b'), 'world')
        -- Diff lines without § are untouched
        MiniTest.expect.equality(child.lua_get('_G._m3_n'), 3)
        MiniTest.expect.equality(child.lua_get('_G._m3_a'), '+ line1')
        -- Truncation notices left as-is
        MiniTest.expect.equality(child.lua_get('_G._m4_n'), 3)
        MiniTest.expect.equality(child.lua_get('_G._m4_a'), 'hello')
        MiniTest.expect.equality(child.lua_get('_G._m4_b'), '[5 more lines]')
        MiniTest.expect.equality(child.lua_get('_G._m4_c'), 'world')
        -- Mixed: only §-prefixed stripped
        MiniTest.expect.equality(child.lua_get('_G._m5_n'), 2)
        MiniTest.expect.equality(child.lua_get('_G._m5_a'), 'hello')
        MiniTest.expect.equality(child.lua_get('_G._m5_b'), 'plain text')
        -- Partial hashline also stripped
        MiniTest.expect.equality(child.lua_get('_G._m6_n'), 2)
        MiniTest.expect.equality(child.lua_get('_G._m6_a'), 'hello')
        MiniTest.expect.equality(child.lua_get('_G._m6_b'), 'world')
    end)
end)

-----------------------------------------------------------------------
-- Tests: read tool with anchors
-----------------------------------------------------------------------

describe('read tool with anchors', function()
    it('returns lines with LINETAG§content prefix', function()
        load_config()
        write_temp('/tmp/slopcode_test_anchor_read.txt', 'line1\nline2\nline3')
        local ok, result = run_handler('read', { path = '/tmp/slopcode_test_anchor_read.txt' })
        MiniTest.expect.equality(ok, true)
        -- Each line should have a § separator
        local lines = vim.split(result, '\n', { plain = true })
        for _, line in ipairs(lines) do
            if line ~= '' and not line:find('^%[') then
                local line_num, hash, content = anchors.parse(line)
                MiniTest.expect.no_equality(line_num, nil)
                MiniTest.expect.equality(#hash, 2)
            end
        end
    end)

    it('anchor prefixes contain actual content after separator', function()
        load_config()
        write_temp('/tmp/slopcode_test_anchor_content.txt', 'hello world')
        local ok, result = run_handler('read', { path = '/tmp/slopcode_test_anchor_content.txt' })
        MiniTest.expect.equality(ok, true)
        local line_num, hash, content = anchors.parse(vim.trim(result))
        MiniTest.expect.equality(line_num, 1)
        MiniTest.expect.equality(content, 'hello world')
    end)
end)

-----------------------------------------------------------------------
-- Tests: edit tool (anchor-based)
-----------------------------------------------------------------------

describe('edit tool', function()
    it('replaces a single line using anchors', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_single.txt', 'aaa\nbbb\nccc')

        -- First, read the file to get anchors
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_single.txt' })
        MiniTest.expect.equality(ok_read, true)

        -- Parse anchors from read output
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Replace line 2 (bbb → XXX)
        MiniTest.expect.no_equality(anchors_list[2], nil)
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_single.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = { 'XXX' } },
            },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Replaced 1 range'), nil)

        -- Verify file content
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_single.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nXXX\nccc')
    end)

    it('replaces a range of lines using anchors', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_range.txt', 'aaa\nbbb\nccc\nddd\neee')

        -- Read to get anchors
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_range.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Replace lines 2-4 (bbb,ccc,ddd → NEW)
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_range.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[4], replacement = { 'NEW' } },
            },
        })
        MiniTest.expect.equality(ok, true)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_range.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nNEW\neee')
    end)

    it('deletes lines using empty replacement', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_delete.txt', 'aaa\nbbb\nccc')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_delete.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Delete line 2
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_delete.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = {} },
            },
        })
        MiniTest.expect.equality(ok, true)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_delete.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nccc')
    end)

    it('inserts lines by replacing a single line with multiple', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_insert.txt', 'aaa\nbbb\nccc')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_insert.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Replace line 2 with two lines
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_insert.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = { 'x1', 'x2' } },
            },
        })
        MiniTest.expect.equality(ok, true)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_insert.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nx1\nx2\nccc')
    end)

    it('returns error for invalid anchor', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_badanchor.txt', 'aaa\nbbb')

        local ok_read, _ = run_handler('read', { path = '/tmp/slopcode_test_ef_badanchor.txt' })
        MiniTest.expect.equality(ok_read, true)

        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_badanchor.txt',
            edits = {
                { start_anchor = '1zz', end_anchor = '1zz', replacement = { 'nope' } },
            },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('Stale'), nil)
    end)

    it('returns error for overlapping edits', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_overlap.txt', 'aaa\nbbb\nccc\nddd')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_overlap.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Overlapping: edit 1 covers lines 1-3, edit 2 covers lines 3-4
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_overlap.txt',
            edits = {
                { start_anchor = anchors_list[1], end_anchor = anchors_list[3], replacement = { 'x' } },
                { start_anchor = anchors_list[3], end_anchor = anchors_list[4], replacement = { 'y' } },
            },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('overlap'), nil)
    end)

    it('returns error when edits is empty', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_empty.txt', 'original')
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_empty.txt',
            edits = {},
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('at least one'), nil)
    end)

    it('allows sequential edits after re-reading', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_seq.txt', 'aaa\nbbb\nccc\nddd\neee')

        -- First read
        local ok_read1, read_result1 = run_handler('read', { path = '/tmp/slopcode_test_ef_seq.txt' })
        MiniTest.expect.equality(ok_read1, true)

        local read_lines1 = vim.split(read_result1, '\n', { plain = true })
        local anchors1 = {}
        for _, line in ipairs(read_lines1) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors1[line_num] = line_num .. hash
            end
        end

        -- First edit: replace line 1
        local ok1, _ = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_seq.txt',
            edits = {
                { start_anchor = anchors1[1], end_anchor = anchors1[1], replacement = { 'AAA' } },
            },
        })
        MiniTest.expect.equality(ok1, true)

        -- Re-read to get updated anchors
        local ok_read2, read_result2 = run_handler('read', { path = '/tmp/slopcode_test_ef_seq.txt' })
        MiniTest.expect.equality(ok_read2, true)

        local read_lines2 = vim.split(read_result2, '\n', { plain = true })
        local anchors2 = {}
        for _, line in ipairs(read_lines2) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors2[line_num] = line_num .. hash
            end
        end

        -- Second edit: replace line 5 (eee → EEE)
        MiniTest.expect.no_equality(anchors2[5], nil)
        local ok2, _ = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_seq.txt',
            edits = {
                { start_anchor = anchors2[5], end_anchor = anchors2[5], replacement = { 'EEE' } },
            },
        })
        MiniTest.expect.equality(ok2, true)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_seq.txt'), '\\n')")
        MiniTest.expect.equality(content, 'AAA\nbbb\nccc\nddd\nEEE')
    end)

    it('fails with stale anchor after file changed externally', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_stale.txt', 'original')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_stale.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- External change: write different content directly
        write_temp('/tmp/slopcode_test_ef_stale.txt', 'modified')

        -- The anchor from the old read should now be stale
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_stale.txt',
            edits = {
                { start_anchor = anchors_list[1], end_anchor = anchors_list[1], replacement = { 'new' } },
            },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('Stale'), nil)
    end)

    it('works with buffer-backed files', function()
        load_config()
        -- Write file to disk first, then open in buffer
        write_temp('/tmp/slopcode_test_ef_buf.txt', 'buf_aaa\nbuf_bbb\nbuf_ccc')
        child.lua([[
            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_name(buf, "/tmp/slopcode_test_ef_buf.txt")
            vim.fn.bufadd("/tmp/slopcode_test_ef_buf.txt")
            vim.fn.bufload(buf)
        ]])

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_buf.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_buf.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = { 'BUF_XXX' } },
            },
        })
        MiniTest.expect.equality(ok, true)

        -- Verify file content on disk
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_buf.txt'), '\\n')")
        MiniTest.expect.equality(content, 'buf_aaa\nBUF_XXX\nbuf_ccc')
    end)
    it('rejects hashline display prefixes in replacement', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_hashline.txt', 'aaa\nbbb\nccc')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_hashline.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        -- Replacement contains a hashline display prefix (LLM mistake) — gets stripped
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_hashline.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = { '2xx§newline' } },
            },
        })
        -- Should strip the prefix and produce 'newline'
        MiniTest.expect.equality(ok, true)
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_hashline.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nnewline\nccc')
    end)
    it('returns no changes message for noop edit', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_noop.txt', 'aaa\nbbb\nccc')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_noop.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        -- Replace line with identical content
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_noop.txt',
            edits = {
                { start_anchor = anchors_list[2], end_anchor = anchors_list[2], replacement = { 'bbb' } },
            },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('No changes'), nil)
    end)
    it('auto-absorbs 2+ boundary duplicates', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_boundary.txt', 'aaa\nbbb\nccc\nddd')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_boundary.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_boundary.txt',
            edits = {
                { start_anchor = anchors_list[1], end_anchor = anchors_list[2], replacement = { 'ccc', 'ddd' } },
            },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Auto-absorbed', 1, true), nil)
    end)
    it('includes anchor response with changed range', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_response.txt', 'aaa\nbbb\nccc\nddd\neee')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_response.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        -- Replace line 3
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_response.txt',
            edits = {
                { start_anchor = anchors_list[3], end_anchor = anchors_list[3], replacement = { 'CCC' } },
            },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('--- Anchors'), nil)
    end)
    it('auto-rebases anchor when line shifted within ±5', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_rebase.txt', 'aaa\nbbb\nccc\nddd\neee')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_rebase.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        -- Insert 2 lines at the top, shifting everything down by 2
        write_temp('/tmp/slopcode_test_ef_rebase.txt', 'NEW1\nNEW2\naaa\nbbb\nccc\nddd\neee')
        -- The old anchor for 'ccc' was line 3, now it's line 5 (shifted by 2, within ±5)
        -- The hash for 'ccc' at line 5 should match the old hash at line 3
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_rebase.txt',
            edits = {
                { start_anchor = anchors_list[3], end_anchor = anchors_list[3], replacement = { 'CCC' } },
            },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('auto-rebased', 1, true), nil)
        -- Verify the correct line was edited (line 5, which is 'ccc')
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_rebase.txt'), '\\n')")
        MiniTest.expect.equality(content, 'NEW1\nNEW2\naaa\nbbb\nCCC\nddd\neee')
    end)
    it('stale anchor error includes recovery context', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_recovery.txt', 'aaa\nbbb\nccc\nddd\neee')
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_recovery.txt' })
        MiniTest.expect.equality(ok_read, true)
        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end
        -- External change: replace content entirely
        write_temp('/tmp/slopcode_test_ef_recovery.txt', 'xxx\nyyy\nzzz')
        -- The old anchor should be stale, and the error should include recovery context
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_recovery.txt',
            edits = {
                { start_anchor = anchors_list[3], end_anchor = anchors_list[3], replacement = { 'NEW' } },
            },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('E_STALE_ANCHOR'), nil)
        MiniTest.expect.no_equality(result:find('>>>'), nil)
    end)
end)

describe('edit tool with empty lines', function()
    it('handles files with empty lines (no stale anchor false positive)', function()
        load_config()
        -- File with empty lines between content lines
        write_temp('/tmp/slopcode_test_ef_empty.txt', 'aaa\n\nbbb\n\nccc')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_empty.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Line 1 = aaa, Line 2 = empty, Line 3 = bbb, Line 4 = empty, Line 5 = ccc
        MiniTest.expect.equality(anchors_list[1] ~= nil, true)
        MiniTest.expect.equality(anchors_list[2] ~= nil, true)
        MiniTest.expect.equality(anchors_list[3] ~= nil, true)
        MiniTest.expect.equality(anchors_list[4] ~= nil, true)
        MiniTest.expect.equality(anchors_list[5] ~= nil, true)

        -- Replace line 3 (bbb) using anchors from read
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_empty.txt',
            edits = {
                {
                    start_anchor = anchors_list[3],
                    end_anchor = anchors_list[3],
                    replacement = { 'BBB' },
                },
            },
        })
        MiniTest.expect.equality(ok, true, result)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_empty.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\n\nBBB\n\nccc')
    end)

    it('handles editing an empty line in a file with gaps', function()
        load_config()
        write_temp('/tmp/slopcode_test_ef_edit_empty.txt', 'aaa\n\nbbb')

        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_ef_edit_empty.txt' })
        MiniTest.expect.equality(ok_read, true)

        local read_lines = vim.split(read_result, '\n', { plain = true })
        local anchors_list = {}
        for _, line in ipairs(read_lines) do
            local line_num, hash, _ = anchors.parse(line)
            if line_num then
                anchors_list[line_num] = line_num .. hash
            end
        end

        -- Replace the empty line 2 with content
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_ef_edit_empty.txt',
            edits = {
                {
                    start_anchor = anchors_list[2],
                    end_anchor = anchors_list[2],
                    replacement = { 'INSERTED' },
                },
            },
        })
        MiniTest.expect.equality(ok, true, result)

        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ef_edit_empty.txt'), '\\n')")
        MiniTest.expect.equality(content, 'aaa\nINSERTED\nbbb')
    end)
end)
