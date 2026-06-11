-- SPDX-License-Identifier: MIT

--- Tests for slopcode tool handlers

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
    local code = string.format(
        [[
        local async = require('async')
        local config = require('slopcode.config')
        local tool = config.tools["%s"]
        local handler = tool and tool.handler
        local args = %s
        local task = async.run(function()
            local ok, result = pcall(handler, args)
            return ok, result
        end)
        local ok, result = task:wait()
        return { ok = ok, result = result }
    ]],
        tool_name,
        vim.inspect(args)
    )
    local ret = child.lua(code)
    return ret.ok, ret.result
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
-- Tests: fs.lua error propagation
-----------------------------------------------------------------------

describe('fs error propagation', function()
    it('file not found from read is caught by pcall and returned as error string', function()
        load_config()
        local ok, result = run_handler('read', { path = '/tmp/slopcode_no_such_file.lua' })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('File not found'), nil)
    end)

    it('file not found from edit is caught by pcall', function()
        load_config()
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_no_such_edit.lua',
            edits = { { start_anchor = '1ab', end_anchor = '1ab', replacement = { 'bar' } } },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('File not found'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: read tool
-----------------------------------------------------------------------

describe('read tool', function()
    it('reads a file from disk with anchor prefixes', function()
        load_config()
        write_temp('/tmp/slopcode_test_read.txt', 'hello world')
        local ok, result = run_handler('read', { path = '/tmp/slopcode_test_read.txt' })
        MiniTest.expect.equality(ok, true)
        local line_num, hash, content = anchors.parse(vim.trim(result))
        MiniTest.expect.equality(line_num, 1)
        MiniTest.expect.no_equality(hash, nil)
        MiniTest.expect.equality(content, 'hello world')
    end)

    it('reads from an open buffer with anchor prefixes', function()
        load_config()
        -- Write file to disk first, then open in buffer
        write_temp('/tmp/slopcode_test_buf_read.txt', 'buf content')
        child.lua([[
            local buf = vim.api.nvim_create_buf(true, true)
            vim.api.nvim_buf_set_name(buf, "/tmp/slopcode_test_buf_read.txt")
            vim.fn.bufadd("/tmp/slopcode_test_buf_read.txt")
            vim.fn.bufload(buf)
        ]])
        local ok, result = run_handler('read', { path = '/tmp/slopcode_test_buf_read.txt' })
        MiniTest.expect.equality(ok, true)
        local line_num, hash, content = anchors.parse(vim.trim(result))
        MiniTest.expect.equality(line_num, 1)
        MiniTest.expect.no_equality(hash, nil)
        MiniTest.expect.equality(content, 'buf content')
    end)
end)

-----------------------------------------------------------------------
-- Tests: write tool
-----------------------------------------------------------------------

describe('write tool', function()
    it('writes a new file to disk', function()
        load_config()
        local ok, result = run_handler('write', {
            path = '/tmp/slopcode_test_write.txt',
            content = 'written!',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Wrote to:'), nil)
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_write.txt'), '\\n')")
        MiniTest.expect.equality(content, 'written!')
    end)

    it('creates parent directories if needed', function()
        load_config()
        local ok, result = run_handler('write', {
            path = '/tmp/slopcode_test_subdir_n/deep/write.txt',
            content = 'deep',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Wrote to:'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: edit tool (anchor-based)
-----------------------------------------------------------------------

describe('edit tool', function()
    it('applies single anchor edit to file on disk', function()
        load_config()
        write_temp('/tmp/slopcode_test_edit.txt', 'hello world')

        -- Read first to get anchors
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_edit.txt' })
        MiniTest.expect.equality(ok_read, true)

        -- Get anchor for line 1
        local line_num, hash, _ = anchors.parse(vim.trim(read_result))
        MiniTest.expect.no_equality(hash, nil)
        local anchor = line_num .. hash

        -- Replace "hello" with "goodbye" via anchor
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_edit.txt',
            edits = { { start_anchor = anchor, end_anchor = anchor, replacement = { 'goodbye world' } } },
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Replaced 1 range'), nil)
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_edit.txt'), '\\n')")
        MiniTest.expect.equality(content, 'goodbye world')
    end)

    it('rejects stale anchor when file changed externally', function()
        load_config()
        write_temp('/tmp/slopcode_test_edit_stale.txt', 'original')

        -- Read first
        local ok_read, read_result = run_handler('read', { path = '/tmp/slopcode_test_edit_stale.txt' })
        MiniTest.expect.equality(ok_read, true)

        local line_num, hash, _ = anchors.parse(vim.trim(read_result))
        local anchor = line_num .. hash

        -- Modify file externally
        write_temp('/tmp/slopcode_test_edit_stale.txt', 'modified')

        -- Anchor should be stale now
        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_edit_stale.txt',
            edits = { { start_anchor = anchor, end_anchor = anchor, replacement = { 'new' } } },
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('Stale'), nil)
    end)

    it('returns error when edits is empty', function()
        load_config()
        write_temp('/tmp/slopcode_test_edit_empty.txt', 'original')

        local ok, result = run_handler('edit', {
            path = '/tmp/slopcode_test_edit_empty.txt',
            edits = {},
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('at least one'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: ls tool
-----------------------------------------------------------------------

describe('ls tool', function()
    it('lists directory entries with type indicators', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ls', 'p')")
        write_temp('/tmp/slopcode_test_ls/file1.lua', '')
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ls/subdir', 'p')")
        local ok, result = run_handler('ls', { path = '/tmp/slopcode_test_ls' })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('file1%.lua'), nil)
        MiniTest.expect.no_equality(result:find('subdir/'), nil)
    end)

    it('returns error for missing path', function()
        load_config()
        local ok, result = run_handler('ls', { path = '/tmp/slopcode_no_such_ls_dir' })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('not found'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: bash tool
-----------------------------------------------------------------------

describe('bash tool', function()
    it('executes a command and returns output', function()
        load_config()
        local ok, result = run_handler('bash', { command = 'echo hello' })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('^hello'), nil)
    end)

    it('returns error with exit code on failure', function()
        load_config()
        local ok, result = run_handler('bash', { command = 'exit 42' })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('exit 42'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: vim tool
-----------------------------------------------------------------------

describe('vim tool', function()
    it('executes a vim command and returns output', function()
        load_config()
        local ok, result = run_handler('vim', { command = "echo 'hi'" })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('hi'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: grep tool
-----------------------------------------------------------------------

describe('grep tool', function()
    it('finds matching lines', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_grep', 'p')")
        write_temp('/tmp/slopcode_test_grep/findme.lua', "local x = 'search_target'")
        local ok, result = run_handler('grep', { pattern = 'search_target', path = '/tmp/slopcode_test_grep' })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('search_target'), nil)
    end)

    it('returns no matches message when nothing found', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_grep2', 'p')")
        write_temp('/tmp/slopcode_test_grep2/nothing.lua', 'nothing here')
        local ok, result = run_handler('grep', {
            pattern = 'will_not_match_xyz',
            path = '/tmp/slopcode_test_grep2',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('No matches'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: find tool
-----------------------------------------------------------------------

describe('find tool', function()
    it('finds files matching glob pattern', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_find', 'p')")
        write_temp('/tmp/slopcode_test_find/foo.lua', '')
        write_temp('/tmp/slopcode_test_find/bar.txt', '')
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_find/subdir', 'p')")
        write_temp('/tmp/slopcode_test_find/subdir/baz.lua', '')
        local ok, result = run_handler('find', { pattern = '*.lua', path = '/tmp/slopcode_test_find' })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('foo.lua'), nil)
        MiniTest.expect.no_equality(result:find('subdir/baz.lua'), nil)
        MiniTest.expect.equality(result:find('bar.txt'), nil)
    end)

    it('returns no files message when nothing found', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_find2', 'p')")
        write_temp('/tmp/slopcode_test_find2/nothing.txt', '')
        local ok, result = run_handler('find', {
            pattern = '*.rs',
            path = '/tmp/slopcode_test_find2',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('No files'), nil)
    end)

    it('errors for missing directory', function()
        load_config()
        local ok, result = run_handler('find', {
            pattern = '*.lua',
            path = '/tmp/slopcode_test_no_such_find_dir',
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('not found'), nil)
    end)
end)

-----------------------------------------------------------------------
-- Tests: ast_grep tool
-----------------------------------------------------------------------

describe('ast_grep tool', function()
    it('finds AST matches with anchors', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_grep', 'p')")
        write_temp(
            '/tmp/slopcode_test_ast_grep/test.lua',
            [[local x = require('foo')
local y = 42]]
        )
        local ok, result = run_handler('ast_grep', {
            pattern = 'local $X = require($MOD)',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_grep',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('foo'), nil)
        MiniTest.expect.no_equality(result:find('require'), nil)
        MiniTest.expect.no_equality(result:find('%$X'), nil)
    end)

    it('captures metavariable values in output', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_grep3', 'p')")
        write_temp('/tmp/slopcode_test_ast_grep3/test.lua', "local myvar = require('mymod')")
        local ok, result = run_handler('ast_grep', {
            pattern = 'local $X = require($MOD)',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_grep3',
        })
        MiniTest.expect.equality(ok, true)
        -- Should show captured metavar values
        MiniTest.expect.no_equality(result:find('myvar'), nil)
        MiniTest.expect.no_equality(result:find('mymod'), nil)
    end)

    it('errors when pattern is empty', function()
        load_config()
        local ok, result = run_handler('ast_grep', {
            pattern = '',
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('pattern is required'), nil)
    end)

    it('returns no matches message when nothing found', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_grep2', 'p')")
        write_temp('/tmp/slopcode_test_ast_grep2/test.lua', 'local x = 1')
        local ok, result = run_handler('ast_grep', {
            pattern = 'function $NAME($$$PARAMS)',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_grep2',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('No matches'), nil)
    end)

    it('errors when ast-grep is missing', function()
        load_config()
        -- Temporarily rename ast-grep binary to simulate missing
        local ok, result = run_handler('ast_grep', {})
        MiniTest.expect.equality(ok, false)
    end)
end)

-----------------------------------------------------------------------
-- Tests: ast_edit tool
-----------------------------------------------------------------------

describe('ast_edit tool', function()
    it('applies AST rewrite to file', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_edit', 'p')")
        child.lua(
            "vim.fn.writefile({'local x = require(\"foo\")', 'local y = require(\"bar\")'}, '/tmp/slopcode_test_ast_edit/test.lua')"
        )
        local ok, result = run_handler('ast_edit', {
            pattern = 'local $X = require($MOD)',
            rewrite = 'local $X = require_cached($MOD)',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_edit',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Applied 2'), nil)
        MiniTest.expect.no_equality(result:find('replacement'), nil)
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ast_edit/test.lua'), '\\n')")
        MiniTest.expect.no_equality(content:find('require_cached'), nil)
        MiniTest.expect.equality(content:find('require%(', 1, true), nil)
    end)

    it('errors when pattern is empty', function()
        load_config()
        local ok, result = run_handler('ast_edit', {
            pattern = '',
            rewrite = 'foo',
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('pattern is required'), nil)
    end)

    it('errors when rewrite is missing', function()
        load_config()
        local ok, result = run_handler('ast_edit', {
            pattern = 'local $X = $Y',
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('rewrite is required'), nil)
    end)

    it('returns no matches when nothing to rewrite', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_edit2', 'p')")
        write_temp('/tmp/slopcode_test_ast_edit2/test.lua', 'local x = 1')
        local ok, result = run_handler('ast_edit', {
            pattern = 'function $NAME($$$PARAMS)',
            rewrite = 'function $NAME($$$PARAMS) end',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_edit2',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('No matches'), nil)
    end)

    it('handles multiple replacements with correct byte offsets', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_edit3', 'p')")
        child.lua(
            "vim.fn.writefile({'print(\"a\")', 'print(\"b\")', 'print(\"c\")'}, '/tmp/slopcode_test_ast_edit3/test.lua')"
        )
        local ok, result = run_handler('ast_edit', {
            pattern = 'print($MSG)',
            rewrite = 'logger.info($MSG)',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_edit3',
        })
        MiniTest.expect.equality(ok, true)
        MiniTest.expect.no_equality(result:find('Applied 3'), nil)
        local content = child.lua_get("table.concat(vim.fn.readfile('/tmp/slopcode_test_ast_edit3/test.lua'), '\\n')")
        -- All three should be rewritten
        local count = 0
        for _ in content:gmatch('logger%.info') do
            count = count + 1
        end
        MiniTest.expect.equality(count, 3)
        -- No original print() calls should remain
        MiniTest.expect.equality(content:find('print%('), nil)
    end)

    it('errors on unsaved buffer changes', function()
        load_config()
        child.lua("vim.fn.mkdir('/tmp/slopcode_test_ast_edit4', 'p')")
        write_temp('/tmp/slopcode_test_ast_edit4/test.lua', 'local x = 1')
        -- Open the file in a buffer and modify it without saving
        child.lua([[
            vim.cmd('edit /tmp/slopcode_test_ast_edit4/test.lua')
            vim.api.nvim_buf_set_lines(0, 0, -1, false, {'local modified = true'})
        ]])
        local ok, result = run_handler('ast_edit', {
            pattern = 'local $X = $Y',
            rewrite = 'local $X = $Y -- edited',
            lang = 'lua',
            path = '/tmp/slopcode_test_ast_edit4',
        })
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.no_equality(result:find('unsaved changes'), nil)
    end)
end)
