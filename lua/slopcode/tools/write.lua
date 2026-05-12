-- SPDX-License-Identifier: MIT

local fs = require('slopcode.utils.fs')
local vim_utils = require('slopcode.utils.vim')

return {
    promptSnippet = 'Create or overwrite a file',

    description = 'Create or overwrite a file with the given content. Always writes to the filesystem. Errors if a buffer with unsaved changes exists for the file. Creates parent directories if needed.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            path = { type = 'string', description = 'Path to write to' },
            content = { type = 'string', description = 'Content to write' },
        },
        required = { 'label', 'path', 'content' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local path = vim.fs.abspath(args.path)
        local content = args.content or ''

        -- Check for unsaved buffer changes before writing
        local modified, mod_buf = vim_utils.is_modified_buf(path)
        if modified then
            error(
                'File has unsaved changes in buffer ' .. mod_buf .. ': ' .. path .. '. Save or discard changes first.',
                0
            )
        end

        -- Create parent directories if needed
        local dir = vim.fs.dirname(path)
        if dir and dir ~= '' and dir ~= '.' and vim.fn.isdirectory(dir) == 0 then
            vim.fn.mkdir(dir, 'p')
        end

        -- Write to filesystem
        local fd = fs.open(path, bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_TRUNC), tonumber('0644', 8))
        fs.write(fd, content)
        fs.close(fd)

        -- Refresh any loaded buffer from disk
        vim_utils.refresh_buf(path)

        return 'Wrote to: ' .. path
    end,
}
