-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')
local text = require('slopcode.utils.text')
local system = async.wrap(3, vim.system)

return {
    promptSnippet = 'Find files by glob pattern (respects .gitignore)',

    description = 'Search for files by glob pattern (e.g. "*.lua", "src/**/*.ts"). Returns matching file paths relative to the search directory. Respects .gitignore. Uses rg --files.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            pattern = {
                type = 'string',
                description = "Glob pattern to match files, e.g. '*.ts', '**/*.json', or 'src/**/*.spec.ts'",
            },
            path = { type = 'string', description = 'Directory to search in (default: current directory)' },
            limit = { type = 'number', description = 'Maximum number of results (default: 1000)' },
        },
        required = { 'label', 'pattern' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local pattern = args.pattern
        local path = vim.fs.abspath(args.path or '.')
        local limit = args.limit or 1000

        if not pattern or pattern == '' then
            error('find: pattern is required', 0)
        end

        if vim.fn.executable('rg') ~= 1 then
            error('find: ripgrep (rg) is required — install it via your package manager', 0)
        end

        local stat = vim.uv.fs_stat(path)
        if not stat then
            error('find: path not found: ' .. path, 0)
        end
        if stat.type ~= 'directory' then
            error('find: not a directory: ' .. path, 0)
        end

        -- rg --files lists all searchable files (respects .gitignore, hidden).
        -- --glob filters by glob pattern. rg matches globs against full path.
        local cmd = {
            'rg',
            '--files',
            '--color=never',
            '--hidden',
            '--glob',
            pattern,
            path,
        }

        local result = system(cmd, { timeout = 30000 })
        local output = result.stdout or ''

        if output == '' then
            return 'No files found matching pattern.'
        end

        -- Split into lines and relativize
        local lines = vim.split(output, '\n', { plain = true })
        local relativized = {}

        for _, line in ipairs(lines) do
            local trimmed = line:gsub('\r$', ''):match('^%s*(.-)%s*$')
            if trimmed and trimmed ~= '' then
                relativized[#relativized + 1] = vim.fs.relpath(path, trimmed) or trimmed
            end
        end

        if #relativized == 0 then
            return 'No files found matching pattern.'
        end

        -- Truncate to limit
        local kept, notice = text.head(relativized, limit, 'results')
        local result_str = table.concat(kept, '\n')
        if notice then
            result_str = result_str .. '\n' .. notice
        end

        return result_str
    end,
}
