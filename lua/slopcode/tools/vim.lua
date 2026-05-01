-- SPDX-License-Identifier: GPL-2.0-only

local text = require('slopcode.utils.text')

return {
    promptSnippet = 'Execute a Vim/Neovim ex-command',

    promptGuidelines = {
        'Use :help <topic> for docs, :lua for Lua API calls, :ls for buffers, etc.',
    },

    description = 'Execute a Vim/Neovim ex-command and return its output, with execution time and truncation for large output.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            command = {
                type = 'string',
                description = 'The Vim/Neovim ex-command to execute. Omit the leading colon.',
            },
        },
        required = { 'label', 'command' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local command = args.command
        if not command or command == '' then
            error('vim: command is required', 0)
        end

        local start_time = vim.uv.hrtime()
        local ok, result = pcall(vim.api.nvim_exec2, command, { output = true })
        local elapsed = math.floor((vim.uv.hrtime() - start_time) / 1e6)

        if not ok then
            error('vim command failed: ' .. tostring(result) .. '\nCommand: ' .. command, 0)
        end

        local output = result.output or ''
        output = vim.trim(tostring(output))

        -- Tail truncation for large output
        local lines = vim.split(output, '\n', { plain = true })
        local kept, notice = text.tail(lines, 1000)

        local final = table.concat(kept, '\n')
        if notice then
            final = final .. '\n' .. notice
        end

        -- Append elapsed time
        local elapsed_str
        if elapsed < 1000 then
            elapsed_str = elapsed .. 'ms'
        else
            elapsed_str = string.format('%.1fs', elapsed / 1000)
        end
        final = final .. '\n[Elapsed: ' .. elapsed_str .. ']'

        return final
    end,
}
