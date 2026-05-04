-- SPDX-License-Identifier: MIT

return {
    open = function(opts)
        require('slopcode.chat').open(opts)
    end,

    close = function()
        require('slopcode.chat').close()
    end,

    toggle = function(opts)
        require('slopcode.chat').toggle(opts)
    end,

    send = function(text)
        require('slopcode.chat').send(text)
    end,

    reset = function()
        require('slopcode.chat').reset()
    end,

    abort = function()
        require('slopcode.chat').abort()
    end,

    model = function()
        require('slopcode.chat').model()
    end,
}
