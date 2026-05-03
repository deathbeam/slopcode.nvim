-- SPDX-License-Identifier: GPL-2.0-only

return {
    --- @type string provider/model identifier, e.g. 'openai/gpt-4' or 'ollama-cloud/glm-5.1'
    model = 'ollama-cloud/glm-5.1',

    display = {
        --- @type 'vsplit' | 'hsplit' | 'replace'
        layout = 'vsplit',
        --- @type boolean show reasoning tokens
        thinking = true,
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
