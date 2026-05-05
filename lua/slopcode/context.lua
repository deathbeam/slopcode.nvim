-- SPDX-License-Identifier: MIT

local M = {}

local fs = require('slopcode.utils.fs')
local sync = require('slopcode.utils.vim').sync

--- @type table?
local _cached = nil

--- @return {path: string, content: string}[]
function M.build()
    if _cached then
        return _cached
    end

    local paths = require('slopcode.config').context or {}
    local cwd = vim.uv.cwd()

    local seen = {}
    for _, path in ipairs(paths) do
        seen[vim.fs.abspath(vim.fs.normalize(path))] = true
    end

    local sections = {}

    for path, _ in pairs(seen) do
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type ~= 'directory' then
            local rel_path = vim.fs.relpath(cwd, path) or path
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

function M.invalidate()
    _cached = nil
end

return M
