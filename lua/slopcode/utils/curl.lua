-- SPDX-License-Identifier: GPL-2.0-only

local async = require('async')

--- Write content to a temporary file and return its path.
--- @param content string
--- @param suffix? string
--- @return string? path
local function write_temp(content, suffix)
    local path = os.tmpname() .. (suffix or '.json')
    local f = io.open(path, 'w')
    if not f then
        return nil
    end
    f:write(content)
    f:close()
    return path
end

--- Build curl command arguments for an HTTP request.
--- @param method string
--- @param url string
--- @param opts? table
--- @return string[] args, string? body_file
local function build_cmd(method, url, opts)
    opts = opts or {}
    local args = { 'curl', '-sS' }
    if opts.stream then
        args[#args + 1] = '-N'
    end
    if opts.max_time then
        args[#args + 1] = '--max-time'
        args[#args + 1] = tostring(opts.max_time)
    end
    args[#args + 1] = '--url'
    args[#args + 1] = url
    if opts.headers then
        for k, v in pairs(opts.headers) do
            args[#args + 1] = '-H'
            args[#args + 1] = k .. ': ' .. v
        end
    end
    if method == 'POST' then
        args[#args + 1] = '-X'
        args[#args + 1] = 'POST'
    end
    local body_file
    if opts.body then
        local raw = type(opts.body) == 'table' and vim.json.encode(opts.body) or opts.body
        body_file = write_temp(raw)
        local has_ct = false
        if opts.headers then
            for k, _ in pairs(opts.headers) do
                if k:lower() == 'content-type' then
                    has_ct = true
                    break
                end
            end
        end
        if not has_ct then
            args[#args + 1] = '-H'
            args[#args + 1] = 'Content-Type: application/json'
        end
        args[#args + 1] = '--data-binary'
        args[#args + 1] = '@' .. body_file
    end
    return args, body_file
end

--- Execute curl asynchronously and call on_exit with the result.
--- @param args string[]
--- @param body_file? string
--- @param on_exit fun(body: string?, err: string?)
local function exec_async(args, body_file, on_exit)
    vim.system(args, { text = true }, function(result)
        if body_file then
            os.remove(body_file)
        end
        if result.code ~= 0 then
            local stderr = vim.trim(result.stderr or '')
            on_exit(nil, 'curl exited ' .. result.code .. (stderr ~= '' and (': ' .. stderr) or ''))
            return
        end
        on_exit(result.stdout, nil)
    end)
end

--- Decode a JSON response body and pass the result to on_exit.
--- @param body string
--- @param on_exit fun(data: table?, err: string?)
local function decode_json(body, on_exit)
    local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
    if not ok or type(data) ~= 'table' then
        on_exit(nil, 'Invalid JSON response')
        return
    end
    on_exit(data, nil)
end

return {
    --- @param method string
    --- @param url string
    --- @param opts? table
    --- @return { args: string[], _body_file: string?, cleanup: fun(self: table) }
    cmd = function(method, url, opts)
        local args, body_file = build_cmd(method, url, opts)
        return {
            args = args,
            _body_file = body_file,
            cleanup = function(self)
                if self._body_file then
                    os.remove(self._body_file)
                    self._body_file = nil
                end
            end,
        }
    end,

    --- @async
    --- @param url string
    --- @param opts? table
    --- @return string body, string? err
    get = async.wrap(3, function(url, opts, on_exit)
        local args, body_file = build_cmd('GET', url, opts)
        exec_async(args, body_file, on_exit)
    end),

    --- @async
    --- @param url string
    --- @param opts? table
    --- @return string body, string? err
    post = async.wrap(3, function(url, opts, on_exit)
        local args, body_file = build_cmd('POST', url, opts)
        exec_async(args, body_file, on_exit)
    end),

    --- @async
    --- @param url string
    --- @param opts? table
    --- @return table data, string? err
    json_get = async.wrap(3, function(url, opts, on_exit)
        local args, body_file = build_cmd('GET', url, opts)
        exec_async(args, body_file, function(body, err)
            if err then
                return on_exit(nil, err)
            end
            decode_json(body, on_exit)
        end)
    end),

    --- @async
    --- @param url string
    --- @param opts? table
    --- @return table data, string? err
    json_post = async.wrap(3, function(url, opts, on_exit)
        local args, body_file = build_cmd('POST', url, opts)
        exec_async(args, body_file, function(body, err)
            if err then
                return on_exit(nil, err)
            end
            decode_json(body, on_exit)
        end)
    end),
}
