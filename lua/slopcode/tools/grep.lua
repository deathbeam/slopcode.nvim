-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')
local anchors = require('slopcode.anchors')
local text = require('slopcode.utils.text')
local system = async.wrap(3, vim.system)

--- @param val any
--- @return boolean
local function is_truthy(val)
    if type(val) == 'boolean' then
        return val
    end
    if type(val) == 'string' then
        return val == 'true' or val == '1' or val == 'yes'
    end
    return false
end

--- @param json_lines string[]  Lines from rg --json output
--- @param context integer  Number of context lines requested
--- @param max_line_len integer  Max chars per output line
--- @param base_path string  Base directory for relativizing file paths
--- @return string[] formatted  Formatted output lines
--- @return integer match_count  Number of match lines
local function parse_rg_json(json_lines, context, max_line_len, base_path)
    local matches = {} -- { file, line_num, text, is_match }
    local current_file = nil

    for _, line in ipairs(json_lines) do
        if line == '' then
            goto continue
        end
        local ok, data = pcall(vim.json.decode, line)
        if not ok or type(data) ~= 'table' then
            goto continue
        end

        if data.type == 'begin' then
            current_file = data.data and data.data.path and data.data.path.text or nil
            if current_file and base_path then
                current_file = vim.fs.relpath(base_path, current_file) or current_file
            end
        elseif data.type == 'match' then
            if data.data then
                local line_num = data.data.line_number
                local text = data.data.lines and data.data.lines.text or ''
                text = text:gsub('\r\n$', ''):gsub('\n$', '')
                matches[#matches + 1] = {
                    file = current_file,
                    line_num = line_num,
                    text = text,
                    is_match = true,
                }
            end
        elseif data.type == 'context' and context > 0 then
            if data.data then
                local line_num = data.data.line_number
                local text = data.data.lines and data.data.lines.text or ''
                text = text:gsub('\r\n$', ''):gsub('\n$', '')
                matches[#matches + 1] = {
                    file = current_file,
                    line_num = line_num,
                    text = text,
                    is_match = false,
                }
            end
        end

        ::continue::
    end

    -- Format output
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

        local text = text.line(m.text, max_line_len)
        if m.is_match then
            match_count = match_count + 1
            local hash = anchors.hash(m.line_num, m.text)
            formatted[#formatted + 1] = m.file .. ':' .. m.line_num .. anchors.hash(m.line_num, m.text) .. '|' .. text
        else
            formatted[#formatted + 1] = m.file .. '-' .. m.line_num .. '- ' .. text
        end
    end

    return formatted, match_count
end

return {
    promptSnippet = 'Search file contents by pattern, returns hashline anchors',

    description = 'Search file contents by pattern (regex or literal). Returns matching lines with hashline anchors — use these anchors in edit calls to target specific lines. Requires ripgrep (rg).',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            pattern = { type = 'string', description = 'Search pattern (regex or literal string)' },
            path = { type = 'string', description = 'Directory or file to search in (default: current directory)' },
            glob = { type = 'string', description = "Filter files by glob pattern, e.g. '*.lua' or '**/*.ts'" },
            ignore_case = { type = 'boolean', description = 'Case-insensitive search (default: false)' },
            literal = {
                type = 'boolean',
                description = 'Treat pattern as literal string instead of regex (default: false)',
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
            error('grep: pattern is required', 0)
        end

        if vim.fn.executable('rg') ~= 1 then
            error('grep: ripgrep (rg) is required — install it via your package manager', 0)
        end

        -- Build rg command with --json
        local cmd = { 'rg', '--json', '--line-number', '--color=never', '--hidden' }

        if is_truthy(args.ignore_case) then
            cmd[#cmd + 1] = '--ignore-case'
        end
        if is_truthy(args.literal) then
            cmd[#cmd + 1] = '--fixed-strings'
        end
        if context > 0 then
            cmd[#cmd + 1] = '--context'
            cmd[#cmd + 1] = tostring(context)
        end
        if args.glob and args.glob ~= '' then
            cmd[#cmd + 1] = '--glob'
            cmd[#cmd + 1] = args.glob
        end

        cmd[#cmd + 1] = '--'
        cmd[#cmd + 1] = pattern
        cmd[#cmd + 1] = path

        local result = system(cmd, { timeout = 30000 })
        local output = result.stdout or ''

        if output == '' then
            return 'No matches found.'
        end

        local json_lines = vim.split(output, '\n', { plain = true })
        local formatted, match_count = parse_rg_json(json_lines, context, max_line_len, path)

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
