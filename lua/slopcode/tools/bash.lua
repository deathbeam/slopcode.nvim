-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')
local text = require('slopcode.utils.text')
local system = async.wrap(3, vim.system)

return {
    promptSnippet = 'Execute a bash command',

    promptGuidelines = {
        'Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)',
    },

    description = 'Execute a bash command and return its output. Optionally provide a timeout in seconds.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            command = { type = 'string', description = 'The bash command to execute' },
            timeout = { type = 'number', description = 'Timeout in seconds (optional, no default timeout)' },
        },
        required = { 'label', 'command' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local opts = {}
        if args.timeout and args.timeout > 0 then
            opts.timeout = args.timeout * 1000
        end

        local start_time = vim.uv.hrtime()
        local ok, result = pcall(system, { 'sh', '-c', args.command }, opts)
        local elapsed = math.floor((vim.uv.hrtime() - start_time) / 1e6)

        if not ok then
            if type(result) == 'string' and result:find('timeout') then
                error('Command timed out after ' .. (args.timeout or 'unknown') .. ' seconds', 0)
            end
            error(tostring(result), 0)
        end

        local stdout = result.stdout or ''
        local stderr = result.stderr or ''
        local output = stdout .. stderr
        output = vim.trim(output)

        if result.code ~= 0 and result.code ~= nil then
            error('(exit ' .. result.code .. '): ' .. output, 0)
        end

        -- Tail truncation for large output
        local lines = vim.split(output, '\n', { plain = true })
        local kept, notice = text.tail(lines, 2000)

        local final = table.concat(kept, '\n')

        -- Save full output to temp file if truncated
        if notice then
            local tmp = os.tmpname()
            local f = io.open(tmp, 'w')
            if f then
                f:write(output)
                f:close()
                notice = notice .. '\n[Full output: ' .. tmp .. ']'
            end
        end

        -- Append elapsed time
        local elapsed_str
        if elapsed < 1000 then
            elapsed_str = elapsed .. 'ms'
        else
            elapsed_str = string.format('%.1fs', elapsed / 1000)
        end

        if notice then
            final = final .. '\n' .. notice
        end
        final = final .. '\n[Elapsed: ' .. elapsed_str .. ']'

        return final
    end,
}
