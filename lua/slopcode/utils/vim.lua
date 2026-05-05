-- SPDX-License-Identifier: MIT

local async = require('async')

local M = {}

--- Yield from fast events so vim.fn/vim.api calls are safe.
function M.sync()
    if not vim.in_fast_event() then
        return
    end
    -- If we're in an async context, yield to the main loop
    local ok = pcall(async.await, 1, vim.schedule)
    if ok then
        return
    end
    -- Not in async context and in fast event: yield via coroutine if possible
    local co = coroutine.running()
    if co then
        vim.schedule(function()
            coroutine.resume(co)
        end)
        coroutine.yield()
    end
    -- If no coroutine (main thread in fast event), caller must handle this
end

--- Find a valid window displaying the given buffer.
--- @param buf integer?
--- @return integer? win
function M.win_for_buf(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return nil
    end

    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == buf then
            if vim.api.nvim_win_is_valid(win) then
                return win
            end
            return nil
        end
    end

    return nil
end

return M
