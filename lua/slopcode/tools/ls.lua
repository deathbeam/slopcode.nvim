-- SPDX-License-Identifier: GPL-2.0-only

local text = require('slopcode.utils.text')

return {
    promptSnippet = 'List directory contents',

    description = 'List directory contents. Shows file names with type indicators (/ for dirs, * for executables).',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            path = { type = 'string', description = 'Directory to list (default: current directory)' },
            limit = { type = 'number', description = 'Maximum number of entries to return (default: 250)' },
        },
        required = { 'label' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local path = args.path and vim.fn.expand(args.path) or '.'
        local limit = args.limit or 250
        local stat = vim.uv.fs_stat(path)

        if not stat then
            error('ls: path not found: ' .. path, 0)
        end
        if stat.type ~= 'directory' then
            return path
        end

        local entries = {}
        for name, type in vim.fs.dir(path) do
            if name ~= '.' and name ~= '..' then
                local suffix = ''
                if type == 'directory' then
                    suffix = '/'
                elseif type == 'link' then
                    suffix = '@'
                elseif type == 'file' then
                    local full_path = path .. '/' .. name
                    local fstat = vim.uv.fs_stat(full_path)
                    if fstat and fstat.mode then
                        -- Check any execute bit (owner/group/other = 0o111 = 0x49)
                        if bit.band(fstat.mode, 0x49) ~= 0 then
                            suffix = '*'
                        end
                    end
                end
                entries[#entries + 1] = name .. suffix
            end
        end

        table.sort(entries)

        if #entries == 0 then
            return '(empty directory)'
        end

        local kept, notice = text.head(entries, limit, 'entries')
        local result = table.concat(kept, '\n')
        if notice then
            result = result .. '\n' .. notice
        end

        return result
    end,
}
