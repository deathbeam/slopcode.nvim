-- SPDX-License-Identifier: MIT

--- Event bus: queue, debounce, subscriber notification.
local M = {}

--- @type table[]
local _queue = {}
--- @type vim.uv.Timer?
local _timer = nil
--- @type function[]
local _listeners = {}

--- Push an event onto the queue; schedules a drain if not pending.
--- @param event table
function M.push(event)
    _queue[#_queue + 1] = event
    if not _timer then
        _timer = vim.defer_fn(function()
            M.drain()
        end, 16)
    end
end

--- Process all queued events and notify subscribers.
function M.drain()
    _timer = nil
    local batch = _queue
    _queue = {}
    if #batch == 0 then
        return
    end

    for i = #_listeners, 1, -1 do
        local listener = _listeners[i]
        if listener then
            listener(batch)
        end
    end
end

--- Subscribe a batch listener. Receives a table of events on each drain.
--- @param listener fun(events: table[])
--- @return function unsubscribe
function M.subscribe(listener)
    _listeners[#_listeners + 1] = listener
    return function()
        for i = 1, #_listeners do
            if _listeners[i] == listener then
                table.remove(_listeners, i)
                return
            end
        end
    end
end

return M
