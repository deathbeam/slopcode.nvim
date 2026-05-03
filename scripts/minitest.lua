-- SPDX-License-Identifier: MIT

-- Project-specific test runner for mini.test
-- Sourced automatically by MiniTest.run() (via config.script_path)
--
-- Handles:
--   - Adding project root + dependencies to runtimepath
--   - Cloning dependencies into .deps/ if missing
--   - Setting up _G.test_rtp_args for child Neovim processes
--   - Collecting and executing tests

-----------------------------------------------------------------------
-- Runtimepath + dependencies
-----------------------------------------------------------------------

vim.opt.runtimepath:append(vim.fn.getcwd())
require('scripts/init')

local minitest = require('mini.test')
if _G.MiniTest == nil then
    minitest.setup()
end
minitest.run()
