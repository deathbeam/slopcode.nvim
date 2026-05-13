-- SPDX-License-Identifier: MIT

local async = require('async')
local system = async.wrap(3, vim.system)

return {
    promptSnippet = 'Fetch a webpage',

    description = 'Fetch a webpage and return its text content. Uses lynx to convert HTML to plain text.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            url = { type = 'string', description = 'The URL to fetch' },
            offset = { type = 'number', description = 'Line number to start reading from (1-indexed, default: 1)' },
            limit = { type = 'number', description = 'Maximum number of lines to read (default: 250)' },
        },
        required = { 'label', 'url' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local url = args.url
        if not url or url == '' then
            error('url is required', 0)
        end
        local result = system({ 'lynx', '-dump', url }, { timeout = 30000 })
        if result.code ~= 0 then
            local err = vim.trim(result.stderr or '')
            if err == '' then
                err = 'lynx exited with code ' .. result.code
            end
            error(err, 0)
        end
        local output = vim.trim(result.stdout or '')
        local lines = vim.split(output, '\n', { plain = true })
        local total = #lines
        if total == 0 then
            return output
        end
        local start_line = args.offset and math.max(1, args.offset) or 1
        if start_line > total then
            error('Offset ' .. start_line .. ' is beyond end of output (' .. total .. ' lines total)', 0)
        end
        local limit = args.limit or 250
        local end_line = math.min(start_line + limit - 1, total)
        local sliced = {}
        for i = start_line, end_line do
            sliced[#sliced + 1] = lines[i]
        end
        local result_str = table.concat(sliced, '\n')
        local remaining = total - end_line
        if remaining > 0 then
            local next_offset = end_line + 1
            result_str = result_str
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
        return result_str
    end,
}
