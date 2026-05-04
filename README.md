<div align="center">
  
  <img src="logo.png" alt="slopcode.nvim logo" />

[![Neovix](https://img.shields.io/badge/Neovim-0.12+-blueviolet.svg?logo=neovim&style=flat-square)](https://neovim.io)
[![CI](https://img.shields.io/github/actions/workflow/status/deathbeam/slopcode.nvim/ci.yml?branch=main&label=CI&style=flat-square)](https://github.com/deathbeam/slopcode.nvim/actions)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)

</div>

streaming AI chat with tool use, inside neovim. talks to any OpenAI-compatible API. reads files, edits code, runs commands - the usual slop pipeline. inspired by [pi.dev](https://pi.dev/), this thing will happily run whatever the model tells it to. use at your own risk (or use [script like this](scripts/sandbox.sh))

<hr/>

<div align="center">

<a href="https://asciinema.org/a/328IPqnzL0Yu1wxR"><img width="960" height="627" alt="demo" src="https://github.com/user-attachments/assets/99279a5d-1828-4858-bc13-50f5cd5b7fb3" /></a>

</div>

<hr/>

## why

- **game-like main loop** - push events, drain on a 16ms tick. feels like a game engine for chat, because why not
- **hash-anchored edits** - stateless line hashing so the edit calls reference stable hashes instead of repeating code
- **minimal** - ~4k lines of Lua. roughly 10× smaller than other AI slop generators. no bloat, no opinions about your workflow. just a loop and some tools
- **native** - prompt buffer for input, folds for output, winbar for model name and spinner, busy indicator in the statusline, markdown for visuals, vim tool integration
- **memory compaction** - auto-summarizes old messages at 75% context window so long sessions don't explode
- **model catalog** - fetches models from [models.dev](https://models.dev) + bunch of extra in [filters](/lua/slopcode/filters/)
- **extensible** - tool registry ([but no MCP](https://mariozechner.at/posts/2025-11-02-what-if-you-dont-need-mcp/)), [agents.md](https://agents.md/) and [skills.sh](https://skills.sh/) support, plug in whatever you need

## how

needs neovim 0.12+, curl, lynx and ripgrep.

```lua
vim.pack.add({
  'https://github.com/lewis6991/async.nvim', -- pls merge async to core already thx
  'https://github.com/deathbeam/slopcode.nvim'
})
```

then just `:Slop <prompt>?` and away you go.

## keybindings

- `<C-c>` to abort
- `<Tab>` to switch model

use `@<path_or_buffer>` to reference files, `/<skill_name>` to manually activate skills

## configuration

```lua
local config = require('slopcode.config')

config.model = 'ollama-cloud/glm-5.1' -- default model
config.window.layout = 'vertical'     -- 'vertical' | 'horizontal' | 'float' | 'replace'
```

you can also pass window opts directly to `open()` or `toggle()`:

```lua
require('slopcode').open({ layout = 'float', width = 0.8, height = 0.6 })
require('slopcode').toggle({ layout = 'replace' })
```

- environment variables for API keys: `OPENAI_API_KEY`, `OLLAMA_API_KEY`, etc, see [models.dev](https://models.dev)
- for copilot, [copilot.vim](https://github.com/github/copilot.vim) or similar is needed for generating auth
- [full config is here](lua/slopcode/config.lua)

## standalone

you can make alias like this:

```bash
alias slop="nvim -c 'lua require(\"slopcode\").open({layout=\"replace\"})'"
```

or if you put [sandbox.sh](scripts/sandbox.sh) in your path:

```bash
alias slop="sandbox.sh nvim -c 'lua require(\"slopcode\").open({layout=\"replace\"})'"
```

## i have a problem

- `:h slopcode.txt`
- `:checkhealth slopcode`

## license

MIT
