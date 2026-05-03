-- SPDX-License-Identifier: MIT

local M = {}

local async = require('async')
local sync = require('slopcode.utils.vim').sync

--- Get tool definitions for the API request.
--- @return table[]
function M.get_definitions()
    local config = require('slopcode.config')
    local result = {}
    for name, tool in pairs(config.tools) do
        result[#result + 1] = {
            name = name,
            description = tool.description or '',
            parameters = tool.parameters or { type = 'object', properties = {} },
        }
    end
    return result
end

--- @async
--- @param tool_calls table[]
--- @return table[]
function M.execute_all(tool_calls)
    local config = require('slopcode.config')
    local tasks = {}
    local meta = {}

    for i, tc in ipairs(tool_calls) do
        local fn = tc['function']
        local name = fn.name
        local args_json = fn.arguments or '{}'
        local call_id = tc.call_id or tc.id or ''
        local ok, args_decoded = pcall(vim.json.decode, args_json, { luanil = { object = true, array = true } })

        meta[i] = {
            name = name,
            label = ok and args_decoded.label,
            args = args_json,
            call_id = call_id,
        }

        local tool = config.tools[name]
        local handler = tool and tool.handler
        tasks[i] = async.run(function()
            if not handler then
                return 'Error: unknown tool: ' .. name
            end
            local ok2, args = pcall(vim.json.decode, args_json, { luanil = { object = true, array = true } })
            if not ok2 then
                return 'Error: invalid arguments: ' .. args
            end

            sync()
            local ok3, result = pcall(handler, args)
            if not ok3 then
                return 'Error: ' .. tostring(result)
            end
            return result or ''
        end)
    end

    local results = async.await_all(tasks)
    local output = {}

    for i, res in ipairs(results) do
        local content = res[1] or ''
        local m = meta[i]
        output[i] = {
            name = m.name,
            tool_call_id = m.call_id,
            label = m.label,
            args = m.args,
            content = content,
        }
    end

    return output
end

return M
