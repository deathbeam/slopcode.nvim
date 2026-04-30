-- SPDX-License-Identifier: GPL-2.0-only

return {
    promptSnippet = 'Execute a Vim/Neovim command',

    description = 'Execute a Vim/Neovim ex-command and return its output. Use :help <topic> for docs, :lua for Lua API calls, :ls for buffers, etc.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            command = { type = 'string', description = 'The Vim/Neovim command to execute' },
        },
        required = { 'label', 'command' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local ok, output = pcall(vim.fn.execute, args.command)
        if not ok then
            error(tostring(output), 0)
        end
        return vim.trim(tostring(output))
    end,
}
