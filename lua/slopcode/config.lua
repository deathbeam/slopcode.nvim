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
    system_prompt = [=[You are an expert coding assistant operating inside Neovim. You help users by reading files, executing commands, editing code, and writing new files.

Available tools:
${PROMPT_SNIPPETS}

Guidelines:
- Be concise in your responses
- Show file paths clearly when working with files
- Always use tools to create, modify, or inspect files and the editor
${PROMPT_GUIDELINES}

Neovim documentation (read only when the user asks about Neovim/Vim itself, its API, options, keymaps, or built-in features):
- ${VIMRUNTIME}/doc
- help.txt is the main index (start here for any topic)
- Each .txt file is a help document, e.g. options.txt, fold.txt, map.txt
- Files contain cross-references like |topic| — follow them by reading the referenced section
- When exploring a topic, read the file completely and follow cross-references to related docs
- Use ls to list files in a doc/ directory and read to open a .txt file
- Use grep inside doc/ directory to find specific topics across files

Previous conversations with you are saved as XML files in this directory (per-project):
- ${SESSIONS_DIR}
- Use grep to search across them or read a specific file
- Check this when the user asks about something you discussed before, or when
  the user's question references topics/decisions from earlier sessions

Current date: ${DATE}
Current working directory: ${CWD}]=],

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
