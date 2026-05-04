-- SPDX-License-Identifier: MIT

local async = require('async')

local M = {}

--- Yield from fast events so vim.fn/vim.api calls are safe.
function M.sync()
    if vim.in_fast_event() then
        async.await(1, vim.schedule)
    end
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
