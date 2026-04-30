-- SPDX-License-Identifier: GPL-2.0-only

-- Project-specific test setup: runtimepath + dependencies
-- Sourced by scripts/minitest.lua and used as -u init for child Neovim processes
-- in test files (child.restart({ "-u", "scripts/init.lua" }))

vim.opt.runtimepath:append(vim.fn.getcwd())

for name, url in pairs({
    ['mini.test'] = 'https://github.com/nvim-mini/mini.test',
    ['async.nvim'] = 'https://github.com/lewis6991/async.nvim',
}) do
    local install_path = vim.fn.fnamemodify('.deps/' .. name, ':p')
    if vim.fn.isdirectory(install_path) == 0 then
        vim.fn.system({ 'git', 'clone', '--depth=1', url, install_path })
        if vim.v.shell_error ~= 0 then
            error('Failed to clone ' .. name)
        end
    end
    vim.opt.runtimepath:append(install_path)
end
