-- SPDX-License-Identifier: MIT

local fs = require('slopcode.utils.fs')
local text = require('slopcode.utils.text')
local sync = require('slopcode.utils.vim').sync

local M = {}

--- @type string? cached session directory
local _session_dir = nil

--- @return string
local function cwd_slug()
    local cwd = vim.uv.cwd()
    local slug = cwd:gsub('/', '_'):gsub('^_', '')
    slug = slug:gsub('[^%w_%-]', function(c)
        return string.format('_%02X', string.byte(c))
    end)
    return slug
end

--- @param msg table
--- @return string[]
local function message_to_xml(msg)
    local role = msg.role
    local lines = {}
    lines[#lines + 1] = '  <' .. role .. '>'

    -- _meta fields as child elements (e.g. reasoning)
    local meta = msg._meta or {}
    local meta_keys = {}
    for k in pairs(meta) do
        meta_keys[#meta_keys + 1] = k
    end
    table.sort(meta_keys)
    for _, k in ipairs(meta_keys) do
        local v = meta[k]
        if v ~= nil then
            lines[#lines + 1] = '    <' .. k .. '>' .. text.xml_escape(tostring(v)) .. '</' .. k .. '>'
        end
    end

    -- Content (user messages, assistant replies, tool results)
    local content = msg.content or ''
    if content ~= '' then
        lines[#lines + 1] = '    <content>' .. text.xml_escape(content) .. '</content>'
    end

    lines[#lines + 1] = '  </' .. role .. '>'
    return lines
end

--- Get the session directory for the current working directory.
--- Creates the directory if it doesn't exist.
--- @return string
function M.dir()
    if _session_dir then
        return _session_dir
    end

    sync()
    local data_dir = vim.fn.stdpath('state')
    _session_dir = data_dir .. '/slopcode/sessions/' .. cwd_slug()
    vim.fn.mkdir(_session_dir, 'p')
    return _session_dir
end

--- Save conversation messages to an XML session file
--- @param messages table[] conversation messages
--- @param session_id string?
function M.save(messages, session_id)
    if #messages == 0 then
        return
    end

    local dir = M.dir()
    local filename = dir .. '/' .. (session_id or 'session') .. '.xml'

    local lines = {}
    lines[#lines + 1] = '<conversation>'
    for _, msg in ipairs(messages) do
        if msg.role ~= 'tool' then -- skip tool results
            for _, l in ipairs(message_to_xml(msg)) do
                lines[#lines + 1] = l
            end
        end
    end
    lines[#lines + 1] = '</conversation>'

    local content = table.concat(lines, '\n') .. '\n'

    local ok, fd = pcall(fs.open, filename, bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_TRUNC), 493)
    if not ok then
        return
    end
    fs.write(fd, content)
    fs.close(fd)
end

return M
