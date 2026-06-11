-- SPDX-License-Identifier: MIT

local async = require('async')
local fs = require('slopcode.utils.fs')
local vim_utils = require('slopcode.utils.vim')
local system = async.wrap(3, vim.system)

--- Apply a list of replacements to file content.
--- Replacements are applied in reverse byte offset order to maintain validity.
--- @param content string  Original file content
--- @param replacements table[]  Replacements with byteOffset and replacement text
--- @return string  New file content
local function apply_replacements(content, replacements)
    -- Sort in reverse order (by start byte offset) so earlier positions stay valid
    table.sort(replacements, function(a, b)
        return a.byteOffset.start > b.byteOffset.start
    end)

    local result = content
    for _, r in ipairs(replacements) do
        local byte_end = r.byteOffset['end'] + 1 -- Lua is 1-indexed
        local start_byte = r.byteOffset.start + 1 -- Lua is 1-indexed
        local before = result:sub(1, start_byte - 1)
        local after = result:sub(byte_end)
        result = before .. (r.replacement or '') .. after
    end
    return result
end

return {
    promptSnippet = 'Edit code using AST-based structural find-and-replace',

    description = 'Edit code using AST (Abstract Syntax Tree) based structural find-and-replace. Uses metavariables: $NAME captures one AST node, $_ matches one without binding, $$$NAME captures zero-or-more (lazy), $$$ matches zero-or-more without binding. Use $$$NAME, NOT $$NAME (two-dollar form is invalid). Metavar names must be the WHOLE AST node. When the same metavar appears twice, both must match identical code. Rewrite string references captured metavariables (e.g. $NAME, $$$ARGS). Each rewrite is 1:1 — cannot split or merge captures. Delete matched code with empty rewrite. Unlike regex-based edit, this understands code structure — it will not match inside strings or comments. Requires ast-grep (https://ast-grep.github.io/). Examples: rename "print($$$MSG)" to "log($$$MSG)", or "function $NAME($$$PARAMS)" to "function $NAME($$$PARAMS) return nil end".',

    promptGuidelines = {
        'Use ast_edit for structural code transformations across multiple files — it handles formatting differences and understands syntax',
    },

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            pattern = {
                type = 'string',
                description = "AST pattern with metavariables to match. Use $VAR for a single node, $$$VAR for multi-node. Example: 'function $NAME($$$PARAMS)'",
            },
            rewrite = {
                type = 'string',
                description = "Replacement string, can reference metavariables from the pattern. Example: 'function $NAME($$$PARAMS) return nil end'",
            },
            lang = {
                type = 'string',
                description = "Language to parse (e.g. 'lua', 'python', 'rust', 'typescript'). Auto-detected from file extension if omitted.",
            },
            path = { type = 'string', description = 'Directory or file to search in (default: current directory)' },
            glob = { type = 'string', description = "Filter files by glob pattern, e.g. '*.lua' or '**/*.ts'" },
            strictness = {
                type = 'string',
                description = "Pattern strictness: 'cst', 'smart', 'ast', 'relaxed', 'signature', or 'template' (default: smart)",
            },
        },
        required = { 'label', 'pattern', 'rewrite' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local pattern = args.pattern
        local rewrite = args.rewrite
        local path = vim.fs.abspath(args.path or '.')

        if not pattern or pattern == '' then
            error('ast_edit: pattern is required', 0)
        end

        if not rewrite or rewrite == '' then
            error('ast_edit: rewrite is required', 0)
        end

        if vim.fn.executable('ast-grep') ~= 1 then
            error(
                'ast_edit: ast-grep is required — install it via your package manager or at https://ast-grep.github.io/',
                0
            )
        end

        -- Build ast-grep command with --rewrite
        local cmd = { 'ast-grep', 'run', '--json=compact', '--color=never' }

        if args.lang and args.lang ~= '' then
            cmd[#cmd + 1] = '--lang'
            cmd[#cmd + 1] = args.lang
        end

        if args.glob and args.glob ~= '' then
            cmd[#cmd + 1] = '--globs'
            cmd[#cmd + 1] = args.glob
        end

        if args.strictness and args.strictness ~= '' then
            cmd[#cmd + 1] = '--strictness'
            cmd[#cmd + 1] = args.strictness
        end

        cmd[#cmd + 1] = '--pattern'
        cmd[#cmd + 1] = pattern
        cmd[#cmd + 1] = '--rewrite'
        cmd[#cmd + 1] = rewrite
        cmd[#cmd + 1] = '--'
        cmd[#cmd + 1] = path

        local result = system(cmd, { timeout = 30000 })
        local output = result.stdout or ''

        if output == '' then
            return 'No matches found. Nothing to rewrite.'
        end

        local ok, decoded = pcall(vim.json.decode, output, { luanil = { object = true, array = true } })
        if not ok or type(decoded) ~= 'table' or #decoded == 0 then
            return 'No matches found. Nothing to rewrite.'
        end

        -- Group replacements by file
        local file_replacements = {} --- @type table<string,table>
        local file_languages = {} --- @type table<string, string>

        for _, m in ipairs(decoded) do
            if m.file and m.replacement and m.replacementOffsets then
                if not file_replacements[m.file] then
                    file_replacements[m.file] = {}
                end
                file_replacements[m.file][#file_replacements[m.file] + 1] = {
                    byteOffset = m.replacementOffsets,
                    replacement = m.replacement,
                    text = m.text,
                }
                file_languages[m.file] = m.language
            end
        end

        if not next(file_replacements) then
            return 'No matches found. Nothing to rewrite.'
        end

        -- Apply replacements per file
        local file_count = 0
        local total_replacements = 0
        local summary_lines = {}

        for file_path, replacements in pairs(file_replacements) do
            local search_dir = vim.fs.abspath(args.path or '.')
            -- ast-grep returns absolute paths; fallback to relative join if not
            local abspath = file_path:sub(1, 1) == '/' and file_path or search_dir .. '/' .. file_path

            -- Check for unsaved buffer changes first (always an error)
            local modified, mod_buf = vim_utils.is_modified_buf(abspath)
            if modified then
                error(
                    'File has unsaved changes in buffer '
                        .. mod_buf
                        .. ': '
                        .. abspath
                        .. '. Save or discard changes first.',
                    0
                )
            end

            -- Check if file exists
            local stat = vim.uv.fs_stat(abspath)
            if not stat then
                summary_lines[#summary_lines + 1] = '  Skipped (not found): ' .. file_path
            else
                -- Read file content
                local fd = fs.open(abspath, fs.O_RDONLY, tonumber('0644', 8))
                local file_stat = fs.fstat(fd)
                local data = fs.read(fd, file_stat.size, 0)
                fs.close(fd)
                data = data:gsub('\r\n', '\n'):gsub('\r', '\n')

                -- Apply replacements
                local new_data = apply_replacements(data, replacements)

                if new_data == data then
                    summary_lines[#summary_lines + 1] = '  No change: ' .. file_path
                else
                    -- Write to filesystem
                    local wfd = fs.open(abspath, bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_TRUNC), tonumber('0644', 8))
                    fs.write(wfd, new_data)
                    fs.close(wfd)

                    -- Refresh any loaded buffer from disk
                    vim_utils.refresh_buf(abspath)

                    -- Build per-file summary
                    local lang_suffix = file_languages[file_path] and (' (' .. file_languages[file_path] .. ')') or ''
                    local rel_path = vim.fs.relpath(vim.uv.cwd(), abspath) or file_path
                    summary_lines[#summary_lines + 1] =
                        string.format('  %d replacement(s) in: %s%s', #replacements, rel_path, lang_suffix)
                    file_count = file_count + 1
                    total_replacements = total_replacements + #replacements
                end
            end
        end

        if file_count == 0 then
            return 'No files were modified.'
        end

        local result_str = string.format(
            'Applied %d AST replacement(s) across %d file(s):\n%s',
            total_replacements,
            file_count,
            table.concat(summary_lines, '\n')
        )
        return result_str
    end,
}
