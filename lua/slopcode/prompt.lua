-- SPDX-License-Identifier: MIT

local M = {}

local sync = require('slopcode.utils.vim').sync

--- @type string?
local _cached = nil

--- @param str string
--- @return string
local function escape_xml(str)
    if not str then
        return ''
    end

    return str:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'):gsub("'", '&apos;') or ''
end

--- @param path string
--- @return boolean
local function is_dir(path)
    local stat = vim.uv.fs_stat(path)
    return stat and stat.type == 'directory' or false
end

--- @async
--- @return string
function M.build()
    if _cached then
        return _cached
    end

    local config = require('slopcode.config')
    local cwd = vim.uv.cwd()
    _cached = vim.trim(config.system_prompt) .. '\n'

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

    sync()
    local doc_dirs = {}
    for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
        local doc = rtp .. '/doc'
        if is_dir(doc) then
            doc_dirs[#doc_dirs + 1] = '- ' .. doc
        end
    end
    if #doc_dirs > 0 then
        _cached = _cached:gsub('%${DOCUMENTATION_FILES}', function()
            return table.concat(doc_dirs, '\n')
        end)
    end

    local context_files = require('slopcode.context').build()
    if #context_files > 0 then
        local lines = {
            '',
            '<project_context>',
        }

        for _, section in ipairs(context_files) do
            lines[#lines + 1] = ''
            lines[#lines + 1] = string.format('<project_instructions path="%s">', section.path)
            lines[#lines + 1] = escape_xml(section.content)
            lines[#lines + 1] = '</project_instructions>'
        end

        lines[#lines + 1] = ''
        lines[#lines + 1] = '</project_context>'

        _cached = _cached .. table.concat(lines, '\n') .. '\n'
    end

    local skill_files = require('slopcode.skills').build()
    if #skill_files > 0 then
        local lines = {
            '',
            'The following skills provide specialized instructions for specific tasks.',
            "Use the read tool to load a skill's file when the task matches its description.",
            'When a skill file references a relative path, resolve it against the skill directory',
            '(parent of SKILL.md) and use that absolute path in tool commands.',
            'When /<skill_name> is used, treat it as skill activation and load the corresponding skill file.',
            '',
            '<available_skills>',
        }

        for _, skill in ipairs(skill_files) do
            lines[#lines + 1] = '  <skill>'
            lines[#lines + 1] = '    <name>' .. escape_xml(skill.name) .. '</name>'
            lines[#lines + 1] = '    <description>' .. escape_xml(skill.description) .. '</description>'
            lines[#lines + 1] = '    <location>' .. escape_xml(skill.path) .. '</location>'
            lines[#lines + 1] = '  </skill>'
        end

        lines[#lines + 1] = '</available_skills>'
        _cached = _cached .. table.concat(lines, '\n') .. '\n'
    end

    return _cached
end

function M.invalidate()
    _cached = nil
end

return M
