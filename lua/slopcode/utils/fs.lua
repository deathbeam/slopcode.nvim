-- SPDX-License-Identifier: MIT

local async = require('async')

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

return M
