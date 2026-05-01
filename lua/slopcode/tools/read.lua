-- SPDX-License-Identifier: GPL-2.0-only

local fs = require('slopcode.utils.fs')
local anchors = require('slopcode.anchors')
local text = require('slopcode.utils.text')

return {
    promptSnippet = 'Read a text file with hashline anchors for edit',

    promptGuidelines = {
        'When the user references a file with @path, use the read tool to examine it.',
        'Use read before edit when you do not have current anchors for the file',
        'If read is truncated, continue with the offset it suggests — do not guess unseen lines',
    },

    description = 'Read the contents of a file from the filesystem. Use offset/limit for large files. Each line is prefixed with a hash anchor (e.g. "5ab|line content") — use these anchors in edit calls to target specific lines.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            path = { type = 'string', description = 'Path to the file to read (relative or absolute)' },
            offset = { type = 'number', description = 'Line number to start reading from (1-indexed, default: 1)' },
            limit = { type = 'number', description = 'Maximum number of lines to read (default: 2000)' },
        },
        required = { 'label', 'path' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local path = vim.fn.expand(args.path)
        local offset = args.offset
        local limit = args.limit or 2000

        -- Always read from filesystem
        fs.assert_file(path)
        local fd = fs.open(path, fs.O_RDONLY, tonumber('0644', 8))
        local stat = fs.fstat(fd)
        local data = fs.read(fd, stat.size, 0)
        fs.close(fd)
        data = data:gsub('\r\n', '\n'):gsub('\r', '\n')
        local lines = fs.to_lines(data)

        local total = #lines
        if total == 0 then
            return 'File is empty. Use edit with replacement to insert content.'
        end

        local start_line = offset and math.max(1, offset) or 1
        if start_line > total then
            error('Offset ' .. start_line .. ' is beyond end of file (' .. total .. ' lines total)', 0)
        end
        local end_line = math.min(start_line + limit - 1, total)

        -- Format lines with hash anchors
        local out = {}
        for i = start_line, end_line do
            out[#out + 1] = anchors.format(i, lines[i])
        end

        -- Truncate if needed
        local kept, notice = text.head(out, 2000, 'lines')
        local result = table.concat(kept, '\n')

        local remaining = total - end_line
        if remaining > 0 then
            local next_offset = end_line + 1
            result = result
                .. '\n\n[Showing lines '
                .. start_line
                .. '-'
                .. end_line
                .. ' of '
                .. total
                .. '. Use offset='
                .. next_offset
                .. ' to continue.]'
        end

        if notice then
            result = result .. '\n' .. notice
        end

        return result
    end,
}
