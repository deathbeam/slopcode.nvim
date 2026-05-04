-- SPDX-License-Identifier: MIT

--- Tests for slopcode parsers (openai_completions and openai_responses)
---
--- These are pure-function tests — no child Neovim needed since
--- parsers have no vim.api / buffer / async dependencies.

local buf = require('vim._core.stringbuffer')
local completions = require('slopcode.parsers.openai_completions')
local responses = require('slopcode.parsers.openai_responses')

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

--- Create a fresh state table for process_chunk tests.
local function new_state()
    return { content = buf.new(), reasoning = buf.new(), tool_calls = {} }
end

-----------------------------------------------------------------------
-- Tests: openai_completions
-----------------------------------------------------------------------

describe('openai_completions.suffix', function()
    it('is /chat/completions', function()
        MiniTest.expect.equality(completions.suffix, '/chat/completions')
    end)
end)

describe('openai_completions.build_body', function()
    it('includes model, messages, stream, temperature, max_tokens', function()
        local body = completions.build_body('gpt-4o', {
            { role = 'user', content = 'hi' },
        }, {}, { temperature = 0.1, max_tokens = 4096, stream = true })
        MiniTest.expect.equality(body.model, 'gpt-4o')
        MiniTest.expect.equality(body.stream, true)
        MiniTest.expect.equality(body.temperature, 0.1)
        MiniTest.expect.equality(body.max_tokens, 4096)
        MiniTest.expect.equality(#body.messages, 1)
    end)

    it('includes stream_options with include_usage', function()
        local body = completions.build_body('gpt-4o', {}, {}, { temperature = 0.1, max_tokens = 4096, stream = true })
        MiniTest.expect.equality(body.stream_options.include_usage, true)
    end)

    it('adds tools and tool_choice when tool_defs provided', function()
        local defs = {
            { name = 'read', description = 'Read file', parameters = { type = 'object' } },
        }
        local body = completions.build_body('gpt-4o', {}, defs, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.no_equality(body.tools, nil)
        MiniTest.expect.equality(#body.tools, 1)
        MiniTest.expect.equality(body.tools[1].type, 'function')
        MiniTest.expect.equality(body.tools[1]['function'].name, 'read')
        MiniTest.expect.equality(body.tool_choice, 'auto')
    end)

    it('omits tools key when no tool_defs', function()
        local body = completions.build_body('gpt-4o', {}, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.tools, nil)
        MiniTest.expect.equality(body.tool_choice, nil)
    end)

    it('sets empty content on assistant messages with tool_calls and nil content', function()
        local msgs = {
            { role = 'assistant', tool_calls = { { id = 'tc1' } }, content = nil },
        }
        completions.build_body('gpt-4o', msgs, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(msgs[1].content, '')
    end)

    it('does not overwrite existing content on assistant messages', function()
        local msgs = {
            { role = 'assistant', tool_calls = { { id = 'tc1' } }, content = 'hello' },
        }
        completions.build_body('gpt-4o', msgs, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(msgs[1].content, 'hello')
    end)
end)

describe('openai_completions.process_chunk', function()
    it('accumulates content deltas', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { delta = { content = 'Hello' } } },
        }, state)
        completions.process_chunk({
            choices = { { delta = { content = ' world' } } },
        }, state)
        MiniTest.expect.equality(state.content:tostring(), 'Hello world')
    end)

    it('returns kind=content and payload for content delta', function()
        local kind, payload = completions.process_chunk({
            choices = { { delta = { content = 'Hi' } } },
        }, new_state())
        MiniTest.expect.equality(kind, 'content')
        MiniTest.expect.equality(payload, 'Hi')
    end)

    it('accumulates reasoning from reasoning_content field', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { delta = { reasoning_content = 'thinking' } } },
        }, state)
        MiniTest.expect.equality(state.reasoning:tostring(), 'thinking')
    end)

    it('accumulates reasoning from reasoning field', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { delta = { reasoning = 'hmm' } } },
        }, state)
        MiniTest.expect.equality(state.reasoning:tostring(), 'hmm')
    end)

    it('accumulates reasoning from reasoning_text field', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { delta = { reasoning_text = 'ponder' } } },
        }, state)
        MiniTest.expect.equality(state.reasoning:tostring(), 'ponder')
    end)

    it('returns kind=reasoning for reasoning delta', function()
        local kind, payload = completions.process_chunk({
            choices = { { delta = { reasoning_content = 'hmm' } } },
        }, new_state())
        MiniTest.expect.equality(kind, 'reasoning')
        MiniTest.expect.equality(payload, 'hmm')
    end)

    it('accumulates tool calls incrementally', function()
        local state = new_state()
        -- First chunk: id + name start
        completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 0, id = 'call_1', ['function'] = { name = 'read', arguments = '' } },
                        },
                    },
                },
            },
        }, state)
        -- Second chunk: arguments delta
        completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 0, ['function'] = { arguments = '{"path":' } },
                        },
                    },
                },
            },
        }, state)
        -- Third chunk: more arguments
        completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 0, ['function'] = { arguments = '"foo.lua"}' } },
                        },
                    },
                },
            },
        }, state)

        MiniTest.expect.equality(#state.tool_calls, 1)
        MiniTest.expect.equality(state.tool_calls[1].id, 'call_1')
        MiniTest.expect.equality(state.tool_calls[1]['function'].name, 'read')
        MiniTest.expect.equality(state.tool_calls[1]['function'].arguments, '{"path":"foo.lua"}')
    end)

    it('returns kind=tool_calls for tool call chunk', function()
        local kind = completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 0, id = 'call_1', ['function'] = { name = 'bash' } },
                        },
                    },
                },
            },
        }, new_state())
        MiniTest.expect.equality(kind, 'tool_calls')
    end)

    it('handles multiple tool calls via index', function()
        local state = new_state()
        completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 0, id = 'c1', ['function'] = { name = 'read' } },
                        },
                    },
                },
            },
        }, state)
        completions.process_chunk({
            choices = {
                {
                    delta = {
                        tool_calls = {
                            { index = 1, id = 'c2', ['function'] = { name = 'bash' } },
                        },
                    },
                },
            },
        }, state)
        MiniTest.expect.equality(#state.tool_calls, 2)
        MiniTest.expect.equality(state.tool_calls[1]['function'].name, 'read')
        MiniTest.expect.equality(state.tool_calls[2]['function'].name, 'bash')
    end)

    it('maps finish_reason stop to done', function()
        local state = new_state()
        local kind = completions.process_chunk({
            choices = { { finish_reason = 'stop' } },
        }, state)
        MiniTest.expect.equality(state.finish_reason, 'done')
        MiniTest.expect.equality(kind, 'done')
    end)

    it('maps finish_reason tool_calls to done', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { finish_reason = 'tool_calls' } },
        }, state)
        MiniTest.expect.equality(state.finish_reason, 'done')
    end)

    it('maps finish_reason length to incomplete', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { finish_reason = 'length' } },
        }, state)
        MiniTest.expect.equality(state.finish_reason, 'incomplete')
    end)

    it('maps unknown finish_reason to error', function()
        local state = new_state()
        completions.process_chunk({
            choices = { { finish_reason = 'content_filter' } },
        }, state)
        MiniTest.expect.no_equality(state.finish_reason:find('error:'), nil)
    end)

    it('captures usage from chunk.usage', function()
        local state = new_state()
        local usage = { prompt_tokens = 10, completion_tokens = 20 }
        completions.process_chunk({ usage = usage }, state)
        MiniTest.expect.equality(state.usage.prompt_tokens, 10)
    end)

    it('captures usage from choice.usage as fallback', function()
        local state = new_state()
        local usage = { prompt_tokens = 5, completion_tokens = 15 }
        completions.process_chunk({
            choices = { { delta = {}, usage = usage } },
        }, state)
        MiniTest.expect.equality(state.usage.prompt_tokens, 5)
    end)

    it('returns nil for chunk with no choices', function()
        local kind = completions.process_chunk({}, new_state())
        MiniTest.expect.equality(kind, nil)
    end)

    it('returns nil for empty choices array', function()
        local kind = completions.process_chunk({ choices = {} }, new_state())
        MiniTest.expect.equality(kind, nil)
    end)

    it('skips empty content delta', function()
        local state = new_state()
        local kind = completions.process_chunk({
            choices = { { delta = { content = '' } } },
        }, state)
        MiniTest.expect.equality(kind, nil)
        MiniTest.expect.equality(state.content:tostring(), '')
    end)
end)

describe('openai_completions.extract_content', function()
    it('extracts content from response.choices[1].message', function()
        local resp = { choices = { { message = { content = 'Hello!' } } } }
        MiniTest.expect.equality(completions.extract_content(resp), 'Hello!')
    end)

    it('returns empty string when no choices', function()
        MiniTest.expect.equality(completions.extract_content({}), '')
    end)

    it('returns empty string when no message', function()
        MiniTest.expect.equality(completions.extract_content({ choices = { {} } }), '')
    end)
end)

-----------------------------------------------------------------------
-- Tests: openai_responses
-----------------------------------------------------------------------

describe('openai_responses.suffix', function()
    it('is /responses', function()
        MiniTest.expect.equality(responses.suffix, '/responses')
    end)
end)

describe('openai_responses.build_body', function()
    it('extracts first system message as instructions', function()
        local body = responses.build_body('gpt-4o', {
            { role = 'system', content = 'You are helpful.' },
            { role = 'user', content = 'hi' },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.instructions, 'You are helpful.')
        MiniTest.expect.equality(body.model, 'gpt-4o')
        MiniTest.expect.equality(body.max_output_tokens, 4096)
    end)

    it('converts second system message to developer role', function()
        local body = responses.build_body('gpt-4o', {
            { role = 'system', content = 'First' },
            { role = 'system', content = 'Second' },
            { role = 'user', content = 'hi' },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.instructions, 'First')
        MiniTest.expect.equality(body.input[1].role, 'developer')
        MiniTest.expect.equality(body.input[1].content, 'Second')
    end)

    it('converts user messages to input', function()
        local body = responses.build_body('gpt-4o', {
            { role = 'user', content = 'hello' },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.input[1].role, 'user')
        MiniTest.expect.equality(body.input[1].content, 'hello')
    end)

    it('converts assistant messages with tool_calls to function_call items', function()
        local body = responses.build_body('gpt-4o', {
            {
                role = 'assistant',
                content = 'text',
                tool_calls = {
                    { id = 'fc_1', call_id = 'call_1', ['function'] = { name = 'read', arguments = '{"path":"x"}' } },
                },
            },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        -- assistant content
        MiniTest.expect.equality(body.input[1].role, 'assistant')
        MiniTest.expect.equality(body.input[1].content, 'text')
        -- function_call
        MiniTest.expect.equality(body.input[2].type, 'function_call')
        MiniTest.expect.equality(body.input[2].name, 'read')
        MiniTest.expect.equality(body.input[2].arguments, '{"path":"x"}')
        MiniTest.expect.equality(body.input[2].call_id, 'call_1')
    end)

    it('converts tool messages to function_call_output', function()
        local body = responses.build_body('gpt-4o', {
            { role = 'tool', tool_call_id = 'call_1', content = 'result' },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.input[1].type, 'function_call_output')
        MiniTest.expect.equality(body.input[1].call_id, 'call_1')
        MiniTest.expect.equality(body.input[1].output, 'result')
    end)

    it('includes tools when tool_defs provided', function()
        local defs = {
            { name = 'read', description = 'Read file', parameters = { type = 'object' } },
        }
        local body = responses.build_body('gpt-4o', {}, defs, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(#body.tools, 1)
        MiniTest.expect.equality(body.tools[1].type, 'function')
        MiniTest.expect.equality(body.tools[1].name, 'read')
    end)

    it('omits tools when no tool_defs', function()
        local body = responses.build_body('gpt-4o', {}, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.tools, nil)
    end)

    it('omits instructions when no system message', function()
        local body = responses.build_body('gpt-4o', {
            { role = 'user', content = 'hi' },
        }, {}, { temperature = 0.1, max_tokens = 4096 })
        MiniTest.expect.equality(body.instructions, nil)
    end)

    it('omits temperature when nil', function()
        local body = responses.build_body('gpt-4o', {}, {}, { temperature = nil, max_tokens = 4096 })
        MiniTest.expect.equality(body.temperature, nil)
    end)

    it('sets temperature when provided', function()
        local body = responses.build_body('gpt-4o', {}, {}, { temperature = 0.5, max_tokens = 4096 })
        MiniTest.expect.equality(body.temperature, 0.5)
    end)
end)

describe('openai_responses.process_chunk', function()
    it('captures response_id from response.created', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.created',
            response = { id = 'resp_abc' },
        }, state)
        MiniTest.expect.equality(state.response_id, 'resp_abc')
    end)

    it('sets error finish_reason on response.failed', function()
        local state = new_state()
        local kind = responses.process_chunk({
            type = 'response.failed',
            response = { error = { code = 'rate_limit', message = 'Too many requests' } },
        }, state)
        MiniTest.expect.equality(kind, 'done')
        MiniTest.expect.no_equality(state.finish_reason:find('error:'), nil)
        MiniTest.expect.no_equality(state.finish_reason:find('rate_limit'), nil)
    end)

    it('sets error finish_reason on error event', function()
        local state = new_state()
        local kind = responses.process_chunk({
            type = 'error',
            message = 'Server error',
        }, state)
        MiniTest.expect.equality(kind, 'done')
        MiniTest.expect.no_equality(state.finish_reason:find('Server error'), nil)
    end)

    it('creates tool_call entry on function_call item added', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '' },
        }, state)
        MiniTest.expect.equality(#state.tool_calls, 1)
        MiniTest.expect.equality(state.tool_calls[1].id, 'fc_1')
        MiniTest.expect.equality(state.tool_calls[1].call_id, 'call_1')
        MiniTest.expect.equality(state.tool_calls[1]['function'].name, 'read')
    end)

    it('accumulates function_call_arguments.delta', function()
        local state = new_state()
        -- Add the function_call item first
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '' },
        }, state)
        -- Stream argument deltas
        responses.process_chunk({
            type = 'response.function_call_arguments.delta',
            delta = '{"path":',
        }, state)
        responses.process_chunk({
            type = 'response.function_call_arguments.delta',
            delta = '"foo.lua"}',
        }, state)
        MiniTest.expect.equality(state.tool_calls[1]['function'].arguments, '{"path":"foo.lua"}')
    end)

    it('finalizes arguments from function_call_arguments.done', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '' },
        }, state)
        -- Partial delta
        responses.process_chunk({
            type = 'response.function_call_arguments.delta',
            delta = 'partial',
        }, state)
        -- Done overrides with complete arguments
        responses.process_chunk({
            type = 'response.function_call_arguments.done',
            arguments = '{"path":"final.lua"}',
        }, state)
        MiniTest.expect.equality(state.tool_calls[1]['function'].arguments, '{"path":"final.lua"}')
    end)

    it('accumulates content from output_text.delta', function()
        local state = new_state()
        local kind, payload = responses.process_chunk({
            type = 'response.output_text.delta',
            delta = 'Hello',
        }, state)
        MiniTest.expect.equality(kind, 'content')
        MiniTest.expect.equality(payload, 'Hello')
        MiniTest.expect.equality(state.content:tostring(), 'Hello')
    end)

    it('accumulates content from refusal.delta', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.refusal.delta',
            delta = 'I cannot',
        }, state)
        MiniTest.expect.equality(state.content:tostring(), 'I cannot')
    end)

    it('accumulates reasoning from reasoning_summary_text.delta', function()
        local state = new_state()
        local kind, payload = responses.process_chunk({
            type = 'response.reasoning_summary_text.delta',
            delta = 'thinking...',
        }, state)
        MiniTest.expect.equality(kind, 'reasoning')
        MiniTest.expect.equality(payload, 'thinking...')
        MiniTest.expect.equality(state.reasoning:tostring(), 'thinking...')
    end)

    it('skips empty delta in output_text.delta', function()
        local state = new_state()
        local kind = responses.process_chunk({
            type = 'response.output_text.delta',
            delta = '',
        }, state)
        MiniTest.expect.equality(kind, nil)
        MiniTest.expect.equality(state.content:tostring(), '')
    end)

    it('maps completed status to done', function()
        local state = new_state()
        local kind = responses.process_chunk({
            type = 'response.completed',
            response = { status = 'completed', usage = { prompt_tokens = 10 } },
        }, state)
        MiniTest.expect.equality(state.finish_reason, 'done')
        MiniTest.expect.equality(kind, 'done')
        MiniTest.expect.equality(state.usage.prompt_tokens, 10)
    end)

    it('maps incomplete status to incomplete', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.completed',
            response = { status = 'incomplete' },
        }, state)
        MiniTest.expect.equality(state.finish_reason, 'incomplete')
    end)

    it('maps unknown status to error', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.completed',
            response = { status = 'failed' },
        }, state)
        MiniTest.expect.no_equality(state.finish_reason:find('error:'), nil)
    end)

    it('returns tool_calls kind when completed with tool calls', function()
        local state = new_state()
        -- Add a tool call first
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '{}' },
        }, state)
        local kind = responses.process_chunk({
            type = 'response.completed',
            response = { status = 'completed' },
        }, state)
        MiniTest.expect.equality(kind, 'tool_calls')
    end)

    it('captures response_id from response.completed', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.completed',
            response = { status = 'completed', id = 'resp_xyz' },
        }, state)
        MiniTest.expect.equality(state.response_id, 'resp_xyz')
    end)

    it('collects function_calls from response.output on completed', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.completed',
            response = {
                status = 'completed',
                output = {
                    {
                        type = 'function_call',
                        id = 'fc_1',
                        call_id = 'call_1',
                        name = 'bash',
                        arguments = '{"command":"ls"}',
                    },
                },
            },
        }, state)
        MiniTest.expect.equality(#state.tool_calls, 1)
        MiniTest.expect.equality(state.tool_calls[1]['function'].name, 'bash')
    end)

    it('deduplicates function_calls from streaming and completed output', function()
        local state = new_state()
        -- Streaming adds the call
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '{}' },
        }, state)
        -- Completed also has it in output
        responses.process_chunk({
            type = 'response.completed',
            response = {
                status = 'completed',
                output = {
                    { type = 'function_call', id = 'fc_1', call_id = 'call_1', name = 'read', arguments = '{}' },
                },
            },
        }, state)
        MiniTest.expect.equality(#state.tool_calls, 1)
    end)

    it('finalizes function_call from output_item.done', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'function_call', id = '', call_id = 'call_1', name = 'read', arguments = '' },
        }, state)
        -- Stream some arguments
        responses.process_chunk({
            type = 'response.function_call_arguments.delta',
            delta = 'partial',
        }, state)
        -- Finalize with complete data
        responses.process_chunk({
            type = 'response.output_item.done',
            item = {
                type = 'function_call',
                id = 'fc_final',
                call_id = 'call_1',
                name = 'read',
                arguments = '{"path":"x"}',
            },
        }, state)
        MiniTest.expect.equality(state.tool_calls[1].id, 'fc_final')
        MiniTest.expect.equality(state.tool_calls[1]['function'].arguments, '{"path":"x"}')
    end)

    it('overrides reasoning with final summary from output_item.done', function()
        local state = new_state()
        -- Start reasoning item
        responses.process_chunk({
            type = 'response.output_item.added',
            item = { type = 'reasoning' },
        }, state)
        -- Stream some reasoning
        responses.process_chunk({
            type = 'response.reasoning_summary_text.delta',
            delta = 'intermediate',
        }, state)
        -- Finalize with summary
        responses.process_chunk({
            type = 'response.output_item.done',
            item = {
                type = 'reasoning',
                summary = {
                    { text = 'Final summary part 1' },
                    { text = 'Final summary part 2' },
                },
            },
        }, state)
        MiniTest.expect.equality(state.reasoning:tostring(), 'Final summary part 1\n\nFinal summary part 2')
    end)

    it('returns nil for unknown event type', function()
        local kind = responses.process_chunk({ type = 'unknown_event' }, new_state())
        MiniTest.expect.equality(kind, nil)
    end)

    it('handles response.failed with incomplete_details', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.failed',
            response = { incomplete_details = { reason = 'max_output_tokens' } },
        }, state)
        MiniTest.expect.no_equality(state.finish_reason:find('incomplete'), nil)
    end)

    it('handles response.failed with no details', function()
        local state = new_state()
        responses.process_chunk({
            type = 'response.failed',
            response = {},
        }, state)
        MiniTest.expect.no_equality(state.finish_reason:find('error:'), nil)
    end)
end)

describe('openai_responses.extract_content', function()
    it('extracts text from output items', function()
        local resp = {
            output = {
                { content = { { text = 'Hello' }, { text = ' world' } } },
            },
        }
        MiniTest.expect.equality(responses.extract_content(resp), 'Hello world')
    end)

    it('returns empty string when no output', function()
        MiniTest.expect.equality(responses.extract_content({}), '')
    end)

    it('skips items without content', function()
        local resp = {
            output = {
                { type = 'function_call', name = 'read' },
                { content = { { text = 'Hi' } } },
            },
        }
        MiniTest.expect.equality(responses.extract_content(resp), 'Hi')
    end)
end)
