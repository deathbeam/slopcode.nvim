-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')

local M = {}

--- Yield from fast events so vim.fn/vim.api calls are safe.
function M.sync()
    if vim.in_fast_event() then
        async.await(1, vim.schedule)
    end
end

return M
