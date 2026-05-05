-- SPDX-License-Identifier: MIT

return {
    --- @type string provider/model identifier, e.g. 'openai/gpt-4' or 'ollama-cloud/glm-5.1'
    model = 'ollama-cloud/glm-5.1',

    --- @type decimal?
    temperature = nil,

    --- @type 'none' | 'low' | 'medium' | 'high'
    reasoning_effort = 'medium',

    --- @type boolean whether to hide reasoning tokens in the UI
    hide_reasoning = false,

    --- @type integer clamp for maximum tokens in model output
    clamp_output_tokens = 32000,

    --- @type table window options for the chat panel
    window = {
        --- @type 'vertical' | 'horizontal' | 'float' | 'replace'
        layout = 'vertical',
        --- @type number fractional (0-1) or absolute (>1) width
        width = 0.5,
        --- @type number fractional (0-1) or absolute (>1) height
        height = 0.5,
        --- @type 'editor' | 'win' | 'cursor' | 'mouse' only for 'float' layout
        relative = 'editor',
        --- @type 'none' | 'single' | 'double' | 'rounded' | 'solid' | 'shadow'
        border = 'single',
        --- @type integer? row position (centered if nil)
        row = nil,
        --- @type integer? column position (centered if nil)
        col = nil,
        --- @type string title shown in the floating window border
        title = 'slopcode',
        --- @type string? footer shown in the floating window border
        footer = nil,
        --- @type integer z-index for float stacking
        zindex = 1,
        --- @type integer window transparency 0-100 (0 = opaque)
        blend = 0,
    },

    --- @type string system prompt
    system_prompt = [[You are an expert coding assistant operating inside Neovim. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
${PROMPT_SNIPPETS}

Guidelines:
- Be concise in your responses
- Show file paths clearly when working with files
- Always use tools to create, modify, or inspect files and the editor
${PROMPT_GUIDELINES}

Current date: ${DATE}
Current working directory: ${CWD}]],

    --- @type table<string, table> parsers for various response formats
    parsers = {
        openai_completions = require('slopcode.parsers.openai_completions'),
        openai_responses = require('slopcode.parsers.openai_responses'),
    },

    --- @type table<string, function> takes list of models as input, returns list of models
    filters = {
        copilot = require('slopcode.filters.copilot'),
        ollama = require('slopcode.filters.ollama'),
        crofai = require('slopcode.filters.crofai'),
        anthropic = require('slopcode.filters.anthropic'),
        google = require('slopcode.filters.google'),
    },

    --- @type string[] list of file paths to include in the system prompt context
    context = {
        'AGENTS.md',
        '~/.agents/AGENTS.md',
    },

    --- @type string[] list of skill directories
    skills = {
        '.agents/skills',
        '~/.agents/skills',
    },

    --- @type table<string, table> tool implementations that can be called by the model
    tools = {
        read = require('slopcode.tools.read'),
        write = require('slopcode.tools.write'),
        edit = require('slopcode.tools.edit'),
        bash = require('slopcode.tools.bash'),
        vim = require('slopcode.tools.vim'),
        fetch = require('slopcode.tools.fetch'),
        grep = require('slopcode.tools.grep'),
        ls = require('slopcode.tools.ls'),
        find = require('slopcode.tools.find'),
    },
}
