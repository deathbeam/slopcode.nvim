<div align="center">
  <img src="logo.png" alt="slopcode.nvim logo" />

  *(font is [terminus](https://terminus-font.sourceforge.net/) as other fonts suck, made in [gimp](https://www.gimp.org/))*
</div>

## what

streaming AI chat with tool use, inside neovim. talks to any OpenAI-compatible API. reads files, edits code, runs commands - the usual slop pipeline.  
inspired by [pi.dev](https://pi.dev/), this thing will happily run whatever the model tells it to. use at your own risk (or use [script like this](scripts/sandbox.sh))

## why

- **game-like main loop** - push events, drain on a 16ms tick. feels like a game engine for chat, because why not
- **hash-anchored edits** - stateless line hashing so the edit calls reference stable hashes instead of repeating code
- **minimal** - ~4k lines of Lua. roughly 10× smaller than other AI slop generators. no bloat, no opinions about your workflow. just a loop and some tools
- **native** - prompt buffer for input, folds for output, winbar for model name and spinner, busy indicator in the statusline, markdown for visuals, vim tool integration
- **memory compaction** - auto-summarizes old messages at 75% context window so long sessions don't explode
- **model catalog** - fetches models from [models.dev](https://models.dev) + bunch of extra in [filters](/lua/slopcode/filters/)
- **extensible** - tool registry (but no mcp as it sucks), [agents.md](https://agents.md/) and [skills.sh](https://skills.sh/) support, plug in whatever you need

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
config.display.layout = 'vsplit'              -- 'vsplit' | 'hsplit' | 'replace'
```

- environment variables for API keys: `OPENAI_API_KEY`, `OLLAMA_API_KEY`, etc, see [models.dev](https://models.dev)
- for copilot, [copilot.vim](https://github.com/github/copilot.vim) or similar is needed for generating auth
- [full config is here](lua/slopcode/config.lua)

## i have a problem

- `:h slopcode.txt`
- `:checkhealth slopcode`

## license

MIT

## image

<img width="1290" height="1054" alt="image" src="https://github.com/user-attachments/assets/0c4b8c77-bf07-4b5a-a2b2-9bf084b425aa" />
