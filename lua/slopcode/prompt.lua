-- SPDX-License-Identifier: GPL-2.0-only

local M = {}

local config = require('slopcode.config')
local sync = require('slopcode.utils.vim').sync

--- @type string?
local _cached = nil

--- Load and cache the system prompt with context files and template expansion.
--- @async
--- @return string
function M.load()
    if _cached then
        return _cached
    end

    sync()

    local cwd = vim.fn.getcwd()
    local found, seen = {}, {}

    for _, raw in ipairs(config.context or {}) do
        local pattern = vim.fs.abspath(raw)
        local is_glob = pattern:find('[%*%?%[%]]')
        local has_path_sep = pattern:find('/')

        if not has_path_sep then
            local dirs = {}
            local dir = cwd
            while dir ~= '/' and dir ~= '' do
                dirs[#dirs + 1] = dir
                local parent = vim.fn.fnamemodify(dir, ':h')
                if parent == dir then
                    break
                end
                dir = parent
            end
            for i = #dirs, 1, -1 do
                local f = dirs[i] .. '/' .. pattern
                if vim.fn.filereadable(f) == 1 and not seen[f] then
                    found[#found + 1] = f
                    seen[f] = true
                end
            end
        elseif is_glob then
            for _, f in ipairs(vim.fn.glob(pattern, false, true)) do
                if vim.fn.filereadable(f) == 1 and not seen[f] then
                    found[#found + 1] = f
                    seen[f] = true
                end
            end
        else
            local f = pattern
            if not f:find('^/') then
                f = cwd .. '/' .. pattern
            end
            if vim.fn.filereadable(f) == 1 and not seen[f] then
                found[#found + 1] = f
                seen[f] = true
            end
        end
    end

    local sections = {}
    for _, f in ipairs(found) do
        local lines = vim.fn.readfile(f)
        if lines and #lines > 0 then
            local rel = vim.fn.fnamemodify(f, ':~:.')
            sections[#sections + 1] = '## ' .. rel .. '\n\n' .. table.concat(lines, '\n')
        end
    end

    _cached = config.system_prompt

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

    if #sections > 0 then
        _cached = _cached .. '\n\n# Project Context\n\n'
        _cached = _cached .. 'Project-specific instructions and guidelines:\n\n'
        _cached = _cached .. table.concat(sections, '\n\n')
    end

    return _cached
end

--- Invalidate the cached prompt and reload from scratch.
--- @async
--- @return string
function M.reload()
    _cached = nil
    return M.load()
end

return M
