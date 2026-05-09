-- SPDX-License-Identifier: MIT

local M = {}

--- Keep the first N lines. Returns kept lines and a notice string if truncated.
--- @param lines string[]
--- @param max_lines integer
--- @param label? string  "lines", "entries", "matches"
--- @return string[] kept
--- @return string? notice
function M.head(lines, max_lines, label)
    label = label or 'lines'
    if #lines <= max_lines then
        return lines, nil
    end
    local kept = {}
    for i = 1, max_lines do
        kept[i] = lines[i]
    end
    return kept, string.format('... (%d more %s truncated)', #lines - max_lines, label)
end

--- Keep the last N lines. Returns kept lines and a notice string if truncated.
--- @param lines string[]
--- @param max_lines integer
--- @return string[] kept
--- @return string? notice
function M.tail(lines, max_lines)
    if #lines <= max_lines then
        return lines, nil
    end
    local kept = {}
    local start = #lines - max_lines + 1
    for i = start, #lines do
        kept[#kept + 1] = lines[i]
    end
    return kept, string.format('... (%d earlier lines truncated)', start - 1)
end

--- Truncate a single line to max_len chars, appending "..." if truncated.
--- @param line string
--- @param max_len integer
--- @return string
function M.line(line, max_len)
    if #line <= max_len then
        return line
    end
    return line:sub(1, max_len) .. '...'
end

--- Generate a UUID
---@return string
function M.uuid()
    local template = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return (
        string.gsub(template, '[xy]', function(c)
            local v = (c == 'x') and math.random(0, 0xf) or math.random(8, 0xb)
            return string.format('%x', v)
        end)
    )
end

function M.xml_escape(s)
    s = string.gsub(s, '&', '&amp;')
    s = string.gsub(s, '<', '&lt;')
    s = string.gsub(s, '>', '&gt;')
    s = string.gsub(s, '"', '&quot;')
    s = string.gsub(s, "'", '&apos;')
    return s
end

return M
