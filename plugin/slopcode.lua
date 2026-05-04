-- SPDX-License-Identifier: MIT

if vim.g.loaded_slopcode then
    return
end
vim.g.loaded_slopcode = 1

vim.treesitter.language.register('markdown', 'slopcode')

vim.api.nvim_create_user_command('Slopcode', function(opts)
    local slop = require('slopcode')
    if opts.args and opts.args ~= '' then
        slop.open()
        slop.send(opts.args)
    else
        slop.toggle()
    end
end, { nargs = '?' })
