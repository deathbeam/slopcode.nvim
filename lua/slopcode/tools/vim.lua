-- SPDX-License-Identifier: GPL-2.0-only

local text = require('slopcode.utils.text')
local fs = require('slopcode.utils.fs')

local _help_index_cache = nil

--- @param path string
--- @param byte_offset integer?
--- @return string
local function read_file(path, byte_offset)
    local fd = fs.open(path, fs.O_RDONLY, tonumber('0644', 8))
    local stat = fs.fstat(fd)
    local offset = 0
    local size = stat.size
    if byte_offset and byte_offset > 1 then
        offset = byte_offset - 1
        size = size - offset
    end
    local data = fs.read(fd, size, offset)
    fs.close(fd)
    return data
end

--- @return table<string, string>, table<string, string[]>
local function build_help_index()
    local all_files = vim.fn.globpath(vim.o.runtimepath, 'doc/*', true, true)
    local help_files = {} -- filename → fullpath
    local tag_files = {} -- lang → { tags_path, ... }

    for _, fullpath in ipairs(all_files) do
        local file = vim.fn.fnamemodify(fullpath, ':t')
        if file == 'tags' then
            tag_files['en'] = tag_files['en'] or {}
            table.insert(tag_files['en'], fullpath)
        elseif file:match('^tags%-..$') then
            local lang = file:sub(-2)
            tag_files[lang] = tag_files[lang] or {}
            table.insert(tag_files[lang], fullpath)
        else
            help_files[file] = fullpath
        end
    end

    return help_files, tag_files
end

--- @param tag_files table<string, string[]>
--- @param help_files table<string, string>
--- @return table<string, {string, integer}>  topic → { file_path, byte_offset }
local function build_topic_index(tag_files, help_files)
    local topics = {}
    for _, tags_paths in pairs(tag_files) do
        for _, tags_path in ipairs(tags_paths) do
            local ok, content = pcall(read_file, tags_path)
            if ok and content then
                local lines = fs.to_lines(content)
                for _, line in ipairs(lines) do
                    if not line:match('^!_TAG_') then
                        local t, file, byte_str = line:match('^([^\t]+)\t([^\t]+)\t([^\t]+)')
                        if t and file and help_files[file] then
                            if not topics[t] then
                                topics[t] = { help_files[file], tonumber(byte_str) or 1 }
                            end
                        end
                    end
                end
            end
        end
    end
    return topics
end

--- @param topic string
--- @return string? file_path
--- @return integer? byte_offset
local function resolve_help(topic)
    if not _help_index_cache then
        local help_files, tag_files = build_help_index()
        _help_index_cache = {
            help_files = help_files,
            topics = build_topic_index(tag_files, help_files),
        }
    end

    local cache = _help_index_cache

    -- For index, just return help.txt
    if topic == '' then
        local path = cache.help_files['help.txt']
        if path then
            return path, 1
        end
        return nil, nil
    end

    -- Lookup in topic index (built once from all tag files)
    local entry = cache.topics[topic]
    if entry then
        return entry[1], entry[2]
    end

    -- Fallback: try topic as a filename
    for _, name in ipairs({ topic, topic .. '.txt' }) do
        local fp = cache.help_files[name]
        if fp and vim.fn.filereadable(fp) == 1 then
            return fp, 1
        end
    end

    return nil, nil
end

return {
    promptSnippet = 'Execute a Vim/Neovim ex-command, or look up help docs',

    promptGuidelines = {
        'Prefer the vim tool over bash for anything Vim/Neovim-specific (help docs, commands, settings, keymaps, etc.)',
    },

    description = 'Execute a Vim/Neovim ex-command and return its output, or look up help documentation.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            command = {
                type = 'string',
                description = 'Vim/Neovim ex-command to execute (omit leading colon). Examples: "ls" for buffers, "set foldmethod?" to check a value, "lua print(vim.o.tabstop)" for Lua expressions. Will NOT work for :help — use the help parameter instead.',
            },
            help = {
                type = 'string',
                description = 'Help topic to look up, e.g. "fold", "vim.o.foldmethod", "v:lua". Reads the help file from disk and returns it as plain text — no windows are opened.',
            },
        },
        required = { 'label' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local start_time = vim.uv.hrtime()
        local output

        if args.help then
            local topic = vim.trim(args.help)
            local path, byte_offset = resolve_help(topic)
            if not path then
                error('Help not found for topic: ' .. topic, 0)
            end
            output = read_file(path, byte_offset)
        else
            local command = args.command
            if not command or command == '' then
                error('vim: either "command" or "help" is required', 0)
            end

            local ok, result = pcall(vim.api.nvim_exec2, command, { output = true })
            if not ok then
                error('vim command failed: ' .. tostring(result) .. '\nCommand: ' .. command, 0)
            end

            output = result.output or ''
            output = vim.trim(tostring(output))
        end

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
