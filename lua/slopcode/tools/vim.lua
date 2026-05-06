-- SPDX-License-Identifier: MIT

local text = require('slopcode.utils.text')

return {
    promptSnippet = 'Execute a Vim/Neovim ex-command',
    promptGuidelines = {
        'Prefer the vim tool over bash for anything Vim/Neovim-specific (commands, settings, keymaps, etc.)',
    },
    description = 'Execute a Vim/Neovim ex-command and return its output.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            command = {
                type = 'string',
                description = 'Vim/Neovim ex-command to execute (omit leading colon). Examples: "ls" for buffers, "set foldmethod?" to check a value, "lua print(vim.o.tabstop)" for Lua expressions. For help/docs, use the read tool on files in the doc/ directories from the system prompt.',
            },
        },
        required = { 'label', 'command' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local start_time = vim.uv.hrtime()
        local command = args.command

        if not command or command == '' then
            error('vim: "command" is required', 0)
        end

        local ok, result = pcall(vim.api.nvim_exec2, command, { output = true })
        if not ok then
            error('vim command failed: ' .. tostring(result) .. '\nCommand: ' .. command, 0)
        end

        local output = result.output or ''
        output = vim.trim(tostring(output))

        local elapsed = math.floor((vim.uv.hrtime() - start_time) / 1e6)
        local lines = vim.split(output, '\n', { plain = true })
        local kept, notice = text.tail(lines, 1000)
        local final = table.concat(kept, '\n')
        if notice then
            final = final .. '\n' .. notice
        end

        local elapsed_str = elapsed < 1000 and (elapsed .. 'ms') or string.format('%.1fs', elapsed / 1000)
        final = final .. '\n[Elapsed: ' .. elapsed_str .. ']'

        return final
    end,
}
