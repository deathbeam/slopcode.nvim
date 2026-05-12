-- SPDX-License-Identifier: MIT

local M = {}

local async = require('async')

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

--- Resolve a path to a buffer number: try the given path, then its absolute form.
--- @param path string
--- @return integer bufnr (-1 if not found)
function M.find_buf(path)
    M.sync()
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
