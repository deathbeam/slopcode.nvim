-- SPDX-License-Identifier: MIT

local M = {}

local async = require('async')
local system = async.wrap(3, vim.system)
local fs = require('slopcode.utils.fs')
local text = require('slopcode.utils.text')

--- @type table?
local _cached = nil

--- @param path string
--- @return boolean
local function is_dir(path)
    local stat = vim.uv.fs_stat(path)
    return stat and stat.type == 'directory' or false
end

--- @param v string
--- @return any
local function parse_value(v)
    v = v:match('^%s*(.-)%s*$')
    if not v or v == '' then
        return nil
    end
    if v == 'true' then
        return true
    end
    if v == 'false' then
        return false
    end
    local quoted = v:match("^'(.-)'$") or v:match('^"(.-)"$')
    if quoted then
        return quoted
    end
    local n = tonumber(v)
    if n then
        return n
    end
    return v
end

--- Join block scalar lines.
--- For folded (>): fold non-blank lines with spaces, blank lines separate paragraphs.
--- For literal (|): join with newlines.
--- @param lines string[]
--- @param scalar_type 'folded'|'literal'
--- @return string
local function join_block_scalar(lines, scalar_type)
    if scalar_type == 'folded' then
        local paragraphs = {}
        local current = {}
        for _, line in ipairs(lines) do
            if line == '' then
                if #current > 0 then
                    paragraphs[#paragraphs + 1] = table.concat(current, ' ')
                    current = {}
                end
            else
                current[#current + 1] = line
            end
        end
        if #current > 0 then
            paragraphs[#paragraphs + 1] = table.concat(current, ' ')
        end
        return table.concat(paragraphs, '\n')
    end
    return table.concat(lines, '\n')
end

--- Parse YAML-like frontmatter from a string.
---
--- Recognizes `---` delimiters on their own line, simple key: value pairs,
--- quoted strings, booleans, numbers, indented continuation lines,
--- and block scalars (`|` literal, `>` folded).
---
--- @param content string
--- @return table frontmatter, string body
local function parse_frontmatter(content)
    --- @param line string
    --- @return boolean
    local function is_delimiter(line)
        return line:match('^%-%-%-[ \t]*$') ~= nil
    end

    local lines = text.to_lines(content)
    if #lines < 2 or not is_delimiter(lines[1]) then
        return {}, content
    end

    -- Find closing delimiter
    local closing_idx
    for i = 2, #lines do
        if is_delimiter(lines[i]) then
            closing_idx = i
            break
        end
    end
    if not closing_idx then
        return {}, content
    end

    local yaml_lines = {}
    for i = 2, closing_idx - 1 do
        yaml_lines[#yaml_lines + 1] = lines[i]
    end

    -- Reconstruct body from remaining lines
    local body_lines = {}
    for i = closing_idx + 1, #lines do
        body_lines[#body_lines + 1] = lines[i]
    end
    local body = table.concat(body_lines, '\n')

    local fm = {}
    local current_key, current_values, current_scalar

    for _, line in ipairs(yaml_lines) do
        -- Try to match a key: value pair
        local key, value = line:match('^([%w%-_]+)%s*:%s*(.*)$')

        if key then
            -- Finalize previous key
            if current_key and current_values then
                fm[current_key] = current_scalar and join_block_scalar(current_values, current_scalar)
                    or current_values[1]
            end

            local trimmed = value:match('^[ \t]*(.-)[ \t]*$')
            if trimmed == '|' or trimmed == '|-' or trimmed == '|+' then
                current_key, current_values, current_scalar = key, {}, 'literal'
            elseif trimmed == '>' or trimmed == '>-' or trimmed == '>+' then
                current_key, current_values, current_scalar = key, {}, 'folded'
            else
                current_key, current_values, current_scalar = key, { parse_value(value) }, nil
            end
        elseif current_key and current_scalar and current_values then
            -- Continuation of a block scalar
            current_values[#current_values + 1] = line:match('^[ \t]*(.-)[ \t]*$') or ''
        end
    end

    -- Finalize last key
    if current_key and current_values then
        fm[current_key] = current_scalar and join_block_scalar(current_values, current_scalar) or current_values[1]
    end

    return fm, body
end

--- @async
--- @return {name: string, description: string, license: string?, compatibility: string?, path: string, content: string}[]
function M.build()
    if _cached then
        return _cached
    end

    local paths = require('slopcode.config').skills or {}
    local seen = {}
    for _, path in ipairs(paths) do
        seen[vim.fs.abspath(vim.fs.normalize(path))] = true
    end

    local skills = {}

    for path, _ in pairs(seen) do
        if is_dir(path) then
            local result = system({
                'rg',
                '--files',
                '--color=never',
                '--hidden',
                '--glob',
                'SKILL.md',
                path,
            })

            local files = vim.split(result.stdout or '', '\n', { plain = true, trimempty = true })

            for _, file in ipairs(files) do
                local fd = fs.open(file, fs.O_RDONLY, tonumber('0644', 8))
                local stat = fs.fstat(fd)
                local data = fs.read(fd, stat.size, 0)
                fs.close(fd)
                local fm, body = parse_frontmatter(data)

                if fm.name and fm.description then
                    skills[#skills + 1] = {
                        name = fm.name,
                        description = fm.description,
                        license = fm.license,
                        compatibility = fm.compatibility,
                        path = file,
                        content = body,
                    }
                end
            end
        end
    end

    -- Deduplicate by name (first wins)
    local unique_skills = {}
    for _, skill in ipairs(skills) do
        if not unique_skills[skill.name] then
            unique_skills[skill.name] = skill
        end
    end

    _cached = vim.tbl_values(unique_skills)
    return _cached
end

function M.invalidate()
    _cached = nil
end

return M
