-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local config = require('slopcode.config')
local fs = require('slopcode.utils.fs')
local sync = require('slopcode.utils.vim').sync

--- @type string?
local _cached = nil

--- @param cwd string
--- @param paths string[]
--- @return {path: string, content: string}[]
local function load_context_files(cwd, paths)
    local seen = {}

    for _, path in ipairs(paths) do
        local abs_path = vim.fs.abspath(path)
        seen[abs_path] = true
    end

    local sections = {}

    for path, _ in pairs(seen) do
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type ~= 'directory' then
            local rel_path = vim.fs.relpath(cwd, path)
            local fd = fs.open(path, fs.O_RDONLY, tonumber('0644', 8))
            local fstat = fs.fstat(fd)
            local data = fs.read(fd, fstat.size, 0)
            fs.close(fd)

            sections[#sections + 1] = {
                path = rel_path,
                content = data,
            }
        end
    end

    return sections
end

--- Build and cache the system prompt.
--- Returns cached result on subsequent calls until invalidated.
--- @return string
function M.build()
    if _cached then
        return _cached
    end

    sync()

    local cwd = vim.fn.getcwd()
    _cached = vim.trim(config.system_prompt)

    local prompt_snippets = {}
    local prompt_guidelines = {}
    for tool_name, tool in pairs(config.tools or {}) do
        if tool.promptSnippet then
            prompt_snippets[#prompt_snippets + 1] = string.format('- %s: %s', tool_name, tool.promptSnippet)
        end
        if tool.promptGuidelines then
            for _, guideline in ipairs(tool.promptGuidelines) do
                prompt_guidelines[#prompt_guidelines + 1] = string.format('- %s', guideline)
            end
        end
    end
    _cached = _cached:gsub('%${PROMPT_SNIPPETS}', function()
        return table.concat(prompt_snippets, '\n')
    end)
    _cached = _cached:gsub('%${PROMPT_GUIDELINES}', function()
        return table.concat(prompt_guidelines, '\n')
    end)
    _cached = _cached:gsub('%${CWD}', function()
        return cwd
    end)
    _cached = _cached:gsub('%${DATE}', function()
        return os.date('%Y-%m-%d')
    end)

    local context_files = load_context_files(cwd, config.context or {})
    if #context_files > 0 then
        local lines = {
            '',
            '',
            '# Project Context',
            '',
            'Project-specific instructions and guidelines:',
            '',
        }

        for _, section in ipairs(context_files) do
            lines[#lines + 1] = string.format('## %s', section.path)
            lines[#lines + 1] = ''
            lines[#lines + 1] = section.content
        end

        _cached = _cached .. table.concat(lines, '\n')
    end

    return _cached
end

function M.invalidate()
    _cached = nil
end

return M
