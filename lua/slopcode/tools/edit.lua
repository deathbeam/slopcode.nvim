-- SPDX-License-Identifier: GPL-2.0-only

local fs = require('slopcode.utils.fs')
local anchors = require('slopcode.anchors')

local CONTEXT_LINES = 2
local MAX_OUTPUT_LINES = 12

--- @param new_lines string[]  1-indexed new file lines
--- @param first_changed integer?
--- @param last_changed integer?
--- @return string? response
local function edit_response(new_lines, first_changed, last_changed)
    if not first_changed or not last_changed then
        return nil
    end
    if #new_lines == 0 then
        return 'File is empty. Use write to insert new content.'
    end

    local start = math.max(1, first_changed - CONTEXT_LINES)
    local end_line = math.min(#new_lines, last_changed + CONTEXT_LINES)
    if end_line - start + 1 > MAX_OUTPUT_LINES then
        return 'Anchors omitted; use read for subsequent edits.'
    end

    local out = {}
    for i = start, end_line do
        out[#out + 1] = anchors.format(i, new_lines[i])
    end
    return '--- Anchors ' .. start .. '-' .. end_line .. ' ---\n' .. table.concat(out, '\n')
end

return {
    promptSnippet = 'Edit a text file via hashline anchors from read',

    description = 'Edit a file using anchor-based line targeting. Each edit specifies start_anchor and end_anchor (from the read output, e.g. "5ab") and a replacement array of lines. Lines from start_anchor to end_anchor (inclusive) are replaced. This is more token-efficient than repeating old code — you only emit the new content.',

    parameters = {
        type = 'object',
        properties = {
            label = { type = 'string', description = 'Short summary of what this tool call does (shown to user)' },
            path = { type = 'string', description = 'Path to the file' },
            edits = {
                type = 'array',
                description = 'One or more anchor-based replacements. Each edit targets a range of lines by their anchors from the most recent read output.',
                items = {
                    type = 'object',
                    properties = {
                        start_anchor = {
                            type = 'string',
                            description = 'Anchor of the first line to replace (from read output, e.g. "5ab")',
                        },
                        end_anchor = {
                            type = 'string',
                            description = 'Anchor of the last line to replace (from read output, e.g. "10vr")',
                        },
                        replacement = {
                            type = 'array',
                            items = {
                                type = 'string',
                            },
                            description = 'Replacement lines for the line range. Use empty array to delete lines.',
                        },
                    },
                    required = { 'start_anchor', 'end_anchor', 'replacement' },
                },
            },
        },
        required = { 'label', 'path', 'edits' },
    },

    --- @async
    --- @return string
    handler = function(args)
        local path = vim.fs.abspath(args.path)
        local edits = args.edits

        -- Read raw file content from filesystem
        fs.assert_file(path)
        local fd = fs.open(path, fs.O_RDONLY, tonumber('0644', 8))
        local stat = fs.fstat(fd)
        local data = fs.read(fd, stat.size, 0)
        fs.close(fd)
        local file_text = data

        -- Normalize edits: convert replacement to repl_lines arrays and strip hashline prefixes
        if type(edits) == 'string' then
            local ok, args_decoded = pcall(vim.json.decode, edits, { luanil = { object = true, array = true } })
            if ok then
                edits = args_decoded
            end
        end
        if type(edits) ~= 'table' then
            error('edits must be a table, got: ' .. type(edits), 0)
        end
        local normalized_edits = {}
        for _, edit in ipairs(edits) do
            local repl_lines
            if type(edit.replacement) == 'string' then
                repl_lines = {}
                if edit.replacement ~= '' then
                    for line in edit.replacement:gmatch('[^\n]+') do
                        repl_lines[#repl_lines + 1] = line
                    end
                end
            elseif type(edit.replacement) == 'table' then
                repl_lines = {}
                for _, line in ipairs(edit.replacement) do
                    repl_lines[#repl_lines + 1] = line
                end
            else
                repl_lines = {}
            end

            -- Strip hashline display prefixes from replacement lines (LLM mistake)
            repl_lines = anchors.strip_hashline(repl_lines)
            normalized_edits[#normalized_edits + 1] = {
                start_anchor = edit.start_anchor,
                end_anchor = edit.end_anchor,
                repl_lines = repl_lines,
            }
        end

        -- Apply edits (handles validate, apply, restore internally)
        local result = anchors.apply_edits(file_text, normalized_edits)

        -- Noop detection
        if not result.first_changed then
            return 'No changes made to: ' .. path
        end

        -- Check for unsaved buffer changes before writing
        local modified, mod_buf = fs.is_modified_buf(path)
        if modified then
            error(
                'File has unsaved changes in buffer ' .. mod_buf .. ': ' .. path .. '. Save or discard changes first.',
                0
            )
        end

        -- Write to filesystem
        local wfd = fs.open(path, bit.bor(fs.O_WRONLY, fs.O_CREAT, fs.O_TRUNC), tonumber('0644', 8))
        fs.write(wfd, result.text)
        fs.close(wfd)

        -- Refresh any loaded buffer from disk
        fs.refresh_buf(path)

        -- Build response
        local msg = 'Replaced ' .. #edits .. ' range(s) in: ' .. path
        local anchor_response = edit_response(result.lines, result.first_changed, result.last_changed)
        if anchor_response then
            msg = msg .. '\n' .. anchor_response
        end
        if #result.warnings > 0 then
            msg = msg .. '\nWarnings, ' .. table.concat(result.warnings, '; ')
        end
        return msg
    end,
}
