-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')
local sync = require('slopcode.utils.vim').sync

--- Wrap a libuv callback-style function into an async function.
--- @param argc integer  Position of the callback argument
--- @param fn function  The libuv function to wrap
--- @return function
local function wrap_uv(argc, fn)
    return function(...)
        local args = { ... }
        local ok, val = async.await(function(resolve)
            args[argc] = function(err, ...)
                if err then
                    resolve(false, err)
                else
                    resolve(true, ...)
                end
            end
            fn(unpack(args, 1, argc))
        end)
        if not ok then
            error(val, 0)
        end
        return val
    end
end

local M = {
    open = wrap_uv(4, vim.uv.fs_open),
    fstat = wrap_uv(2, vim.uv.fs_fstat),
    read = wrap_uv(4, vim.uv.fs_read),
    write = wrap_uv(4, vim.uv.fs_write),
    close = wrap_uv(2, vim.uv.fs_close),
    mkdir = wrap_uv(3, vim.uv.fs_mkdir),
    O_RDONLY = vim.uv.constants.O_RDONLY,
    O_WRONLY = vim.uv.constants.O_WRONLY,
    O_CREAT = vim.uv.constants.O_CREAT,
    O_TRUNC = vim.uv.constants.O_TRUNC,
}

--- Assert that a path exists and is not a directory.
--- @param path string
function M.assert_file(path)
    local stat = vim.uv.fs_stat(path)
    if not stat then
        error('File not found: ' .. path, 0)
    end
    if stat.type == 'directory' then
        error('Is a directory: ' .. path, 0)
    end
end

--- Split content into lines, stripping the trailing empty line from a terminal \n.
--- @param content string
--- @return string[] lines
function M.to_lines(content)
    if content == '' then
        return {}
    end
    local lines = vim.split(content, '\n', { plain = true })
    if #lines > 0 and lines[#lines] == '' then
        lines[#lines] = nil
    end
    return lines
end

--- Resolve a path to a buffer number: try the given path, then its absolute form.
--- @param path string
--- @return integer bufnr (-1 if not found)
function M.find_buf(path)
    sync()
    local buf = vim.fn.bufnr(path)
    if buf ~= -1 then
        return buf
    end
    local abs = vim.fn.fnamemodify(path, ':p')
    if abs ~= path then
        buf = vim.fn.bufnr(abs)
        if buf ~= -1 then
            return buf
        end
    end
    return -1
end

--- Check if a loaded buffer for the given path has unsaved changes.
--- @param path string
--- @return boolean modified, integer? bufnr
function M.is_modified_buf(path)
    local buf = M.find_buf(path)
    if buf == -1 or not vim.api.nvim_buf_is_loaded(buf) then
        return false, nil
    end
    return vim.bo[buf].modified, buf
end

--- Reload a loaded buffer from disk if it exists.
--- @param path string
function M.refresh_buf(path)
    local buf = M.find_buf(path)
    if buf ~= -1 and vim.api.nvim_buf_is_loaded(buf) then
        vim.api.nvim_buf_call(buf, function()
            vim.cmd('silent! checktime')
        end)
    end
end

return M
