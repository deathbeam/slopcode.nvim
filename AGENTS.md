# AGENTS.md — slopcode

Neovim plugin: streaming AI chat with tool-use via OpenAI-compatible `/chat/completions` and `/responses` endpoints.

## Commands

```sh
make lint          # check formatting with stylua (--check mode)
make test          # run full test suite (custom mini.test runner, headless Neovim)
make format        # format all Lua files with stylua
```

## Testing

Tests use [mini.test](https://github.com/nvim-mini/mini.test) with busted-style `describe`/`it`/`before_each`. Dependencies (mini.test, async.nvim) auto-clone into `.deps/` on first run.

- **All tests use child Neovim**: `local child = MiniTest.new_child_neovim()` then `child.restart({ "-u", "scripts/init.lua" })` in `before_each`. The `-u` flag is required — it sets up runtimepath + deps.
- Assertions: `MiniTest.expect.equality(a, b)` / `MiniTest.expect.no_equality(a, b)`

## Critical Architecture Rules

**Only `renderer.lua` touches the buffer.** All buffer writes flow through the event bus: `events.push()` → `events.drain()` (16ms batch timer) notifies subscribers, and the default `renderer.lua` subscriber writes to the buffer. Never call `nvim_buf_set_lines`, `append`, or any buffer API from agent, tools, callbacks, or streaming handlers.

**All I/O is async** via [async.nvim](https://github.com/nvim-lua/async.nvim) coroutines. If you're in a fast event (check `vim.in_fast_event()`), call `sync()` (from `utils.vim` or `tools.lua`) to yield before any vim.fn/vim.api calls. Blocking APIs will freeze Neovim.

**Singleton modules, not instances.** `agent.lua`, `events.lua`, `renderer.lua`, `status.lua` store state in module-level locals (prefixed `_`). No `M.new()` pattern. Lifecycle is `attach`/`detach`.

**Shared references use in-place mutation.** `agent.messages` is a reference to the internal `_messages` table. Reset and compact use `for k in pairs(t) do t[k] = nil end` — never reassign the table, or external references break.

**Notifications go through `status.notify()`**, `status.notify` renders in the winbar AND calls `vim.notify`

**Event bus architecture.** `events.lua` is a pure event bus with no buffer knowledge. It queues events and notifies subscribers on `drain()`. `renderer.lua` is the default subscriber — it draws rendered events to a buffer and can be swapped out. `agent.lua` only talks to `events.lua` (push/drain), never directly to the renderer.