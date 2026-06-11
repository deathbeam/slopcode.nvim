-- SPDX-License-Identifier: MIT

local async = require('async')
local anchors = require('slopcode.anchors')
local text = require('slopcode.utils.text')
local system = async.wrap(3, vim.system)

--- Parse ast-grep JSON output into formatted match lines.
--- @param matches table[]  Decoded JSON matches from ast-grep
--- @param max_line_len integer  Max chars per output line
--- @param base_path string  Base directory for relativizing file paths
--- @return string[] formatted
--- @return integer match_count
local function format_matches(matches, max_line_len, base_path)
    local formatted = {}
    local match_count = 0
    local last_file = nil

    for _, m in ipairs(matches) do
        if m.file ~= last_file then
            if #formatted > 0 then
                formatted[#formatted + 1] = ''
            end
            last_file = m.file
        end

        local rel_path = base_path and (vim.fs.relpath(base_path, m.file) or m.file) or m.file
        local line_num = m.range.start.line + 1 -- ast-grep uses 0-based lines
        local match_text = m.text or ''
        local truncated = text.line(match_text, max_line_len)

        match_count = match_count + 1
        formatted[#formatted + 1] = rel_path .. ':' .. anchors.format(line_num, truncated)

        -- Append metavariable info if present (useful for the LLM to see captures)
        if m.metaVariables then
            local mv_parts = {}
            for var_name, var_data in pairs(m.metaVariables.single or {}) do
                mv_parts[#mv_parts + 1] = string.format('  $%s = %s', var_name, var_data.text)
            end
            for var_name, var_data in pairs(m.metaVariables.multi or {}) do
                if type(var_data) == 'table' and #var_data > 0 then
                    local vals = {}
                    for _, v in ipairs(var_data) do
                        vals[#vals + 1] = v.text
                    end
                    mv_parts[#mv_parts + 1] = string.format('  $%s = %s', var_name, table.concat(vals, ', '))
                end
            end
            if #mv_parts > 0 then
                formatted[#formatted + 1] = table.concat(mv_parts, '\n')
            end
        end
    end

    return formatted, match_count
end

return {
    promptSnippet = 'Search code using AST pattern matching with metavariables',

    description = 'Search code using AST (Abstract Syntax Tree) pattern matching. Supports metavariables: $NAME captures one AST node, $_ matches one without binding, $$$NAME captures zero-or-more (lazy), $$$ matches zero-or-more without binding. Use $$$NAME, NOT $$NAME (two-dollar form is invalid). Metavar names must be the WHOLE AST node — partial text like prefix$VAR or "hello $NAME" does NOT work. When the same metavar appears twice, both must match identical code. Patterns must parse as valid AST for the target language. Requires ast-grep (https://ast-grep.github.io/). Examples: "function $NAME($$$PARAMS)" finds function declarations, "local $X = require($MOD)" finds require() calls.',

    promptGuidelines = {
        'Use ast_grep when you need structural code search — it understands syntax, not just text',
    },

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            pattern = {
                type = 'string',
                description = "AST pattern with metavariables. Use $VAR for a single node, $$$VAR for multi-node (e.g. 'function $NAME($$$PARAMS)', 'local $X = require($MOD)')",
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
            context = {
                type = 'number',
                description = 'Number of context lines before and after each match (default: 0)',
            },
            limit = { type = 'number', description = 'Maximum number of matches to return (default: 100)' },
        },
        required = { 'label', 'pattern' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local pattern = args.pattern
        local path = vim.fs.abspath(args.path or '.')
        local limit = args.limit or 100
        local context = args.context or 0
        local max_line_len = 500

        if not pattern or pattern == '' then
            error('ast_grep: pattern is required', 0)
        end

        if vim.fn.executable('ast-grep') ~= 1 then
            error(
                'ast_grep: ast-grep is required — install it via your package manager or at https://ast-grep.github.io/',
                0
            )
        end

        -- Build ast-grep command
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

        if context > 0 then
            cmd[#cmd + 1] = '-C'
            cmd[#cmd + 1] = tostring(context)
        end

        cmd[#cmd + 1] = '--pattern'
        cmd[#cmd + 1] = pattern
        cmd[#cmd + 1] = '--'
        cmd[#cmd + 1] = path

        local result = system(cmd, { timeout = 30000 })
        local output = result.stdout or ''

        if output == '' then
            return 'No matches found.'
        end

        local ok, decoded = pcall(vim.json.decode, output, { luanil = { object = true, array = true } })
        if not ok or type(decoded) ~= 'table' then
            return 'No matches found.'
        end

        local formatted, match_count = format_matches(decoded, max_line_len, path)

        if match_count == 0 then
            return 'No matches found.'
        end

        -- Truncate to limit
        local kept, notice = text.head(formatted, limit, 'matches')

        local result_str = table.concat(kept, '\n')
        if notice then
            result_str = result_str .. '\n' .. notice
        end
        return result_str
    end,
}
