# Usage Guide

Detailed examples for erl_openrouter. For quick start, see the [README](../README.md).

## Basic Chat

```erlang
-include_lib("erl_openrouter/include/openrouter.hrl").

{ok, #chat_response{choices = Choices, usage = Usage}} =
    openrouter:chat([
        #{<<"role">> => <<"system">>, <<"content">> => <<"You know about Erlang.">>},
        #{<<"role">> => <<"user">>, <<"content">> => <<"What is OTP?">>}
    ], #{model => <<"anthropic/claude-sonnet-4">>}).
```

## Chat with Tool Use

```erlang
Tools = [#{
    <<"type">> => <<"function">>,
    <<"function">> => #{
        <<"name">> => <<"get_weather">>,
        <<"description">> => <<"Get current weather">>,
        <<"parameters">> => #{
            <<"type">> => <<"object">>,
            <<"properties">> => #{
                <<"location">> => #{<<"type">> => <<"string">>}
            },
            <<"required">> => [<<"location">>]
        }
    }
}],

{ok, #chat_response{choices = [#{<<"message">> := Msg} | _]}} =
    openrouter:chat([
        #{<<"role">> => <<"user">>, <<"content">> => <<"Weather in Black Rock City, Nevada?">>}
    ], #{model => <<"openai/gpt-4o">>, tools => Tools, tool_choice => auto}).
```

When the model returns `tool_calls`, build the follow-up with `openrouter_tools:encode_tool_result_message/2`:

```erlang
ToolResult = openrouter_tools:encode_tool_result_message(
    ToolCallId,
    <<"{\"temperature\": \"28C\", \"condition\": \"sunny\"}">>),
{ok, Resp2} = openrouter:chat(
    OriginalMessages ++ [AssistantMsg, ToolResult],
    #{model => <<"openai/gpt-4o">>, tools => Tools}).
```

## Error Handling

All errors return `{error, #api_error{}}` with a `type` atom and `metadata` map. Local rejections (rate limiter, circuit breaker, missing auth) carry `source => local` in metadata; server errors carry `source => remote`.

```erlang
case openrouter:chat(Messages, Opts) of
    {ok, #chat_response{} = Resp} ->
        handle_response(Resp);
    {error, #api_error{type = auth_error}} ->
        io:format("Bad API key~n");
    {error, #api_error{type = rate_limited, metadata = #{source := local}}} ->
        io:format("Local rate limiter exhausted~n");
    {error, #api_error{type = rate_limited, metadata = #{source := remote}}} ->
        io:format("OpenRouter rate limit hit~n");
    {error, #api_error{type = circuit_open}} ->
        io:format("Circuit breaker open -- upstream unhealthy~n");
    {error, #api_error{type = overloaded}} ->
        io:format("Too many in-flight requests~n");
    {error, #api_error{type = timeout}} ->
        io:format("Request timed out~n");
    {error, #api_error{type = Type, code = Code, message = Msg}} ->
        io:format("Error ~p (~p): ~s~n", [Type, Code, Msg])
end.
```

## Generation Stats

Fetch server-side diagnostics for any completed request using the generation ID:

```erlang
{ok, #chat_response{id = GenId}} = openrouter:chat(Messages, Opts),
{ok, Stats} = openrouter:generation(GenId).
```

The `Stats` map includes:

* `latency` / `generation_time` / `moderation_latency` -- timing in milliseconds
* `provider_name` -- which provider served the request
* `provider_responses` -- all provider attempts including fallbacks, each with individual latency and HTTP status
* `tokens_prompt` / `tokens_completion` -- token counts
* `total_cost` / `usage` -- cost in USD

The `provider_responses` field is especially useful for diagnosing timeouts -- it shows whether the delay was at the model, provider, or routing level.

## Telemetry

If the optional `telemetry` dependency is included, erl_openrouter emits events on every request and resilience action. Attach handlers in your application to route to your preferred backend.

### Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[erl_openrouter, request, start]` | `system_time` | `model`, `operation` |
| `[erl_openrouter, request, stop]` | `duration` | `model`, `operation`, `status`, `error_type`, `status_code`, `tokens_prompt`, `tokens_completion` |
| `[erl_openrouter, request, exception]` | `duration` | `kind`, `reason`, `stacktrace`, `model`, `operation` |
| `[erl_openrouter, rate_limiter, rejected]` | `#{}` | `#{}` |
| `[erl_openrouter, circuit_breaker, state_change]` | `#{}` | `from`, `to` |

Start/stop/exception events are emitted via `telemetry:span/3`. Error metadata fields (`error_type`, `status_code`, token counts) are only present when applicable.

The `operation` metadata defaults to `chat` for chat requests and `embeddings` for embedding requests. Callers can override this by passing `operation => my_op` in the opts map to `openrouter:chat/2`, allowing per-call telemetry classification.

### Example Handler

```erlang
telemetry:attach(
    <<"my-openrouter-handler">>,
    [erl_openrouter, request, stop],
    fun(_Event, #{duration := Duration}, #{model := Model, status := Status}, _Config) ->
        Ms = erlang:convert_time_unit(Duration, native, millisecond),
        logger:info("openrouter ~s ~s ~pms", [Model, Status, Ms])
    end,
    #{}
).
```

When `telemetry` is not in your dependency tree, all event emission is a no-op with zero overhead.

## Configuration Reference

All settings are optional application env keys under `erl_openrouter`.

| Key | Default | Description |
|-----|---------|-------------|
| `base_url` | `"https://openrouter.ai/api/v1"` | API base URL |
| `timeout` | `30000` | HTTP request timeout (ms) |
| `api_key` | `undefined` | API key (binary or string). Falls back to `OPENROUTER_API_KEY` env var |
| `max_in_flight` | `50` | Maximum concurrent in-flight requests |
| `call_timeout` | `90000` | gen_server call timeout (ms) |
| `rate_limiter_opts` | `#{max_tokens => 60, refill_interval => 60000}` | Token bucket config |
| `circuit_breaker_opts` | `#{failure_threshold => 5, reset_timeout => 30000}` | Circuit breaker config |

Set via `sys.config`:

```erlang
[
    {erl_openrouter, [
        {api_key, <<"sk-or-...">>},
        {timeout, 60000},
        {max_in_flight, 100}
    ]}
].
```

## Streaming

SSE stream parsing is implemented (`openrouter_stream` module) but the HTTP transport is not yet wired. Streaming support is Coming Soon, and attempting tou se it will return a clear error.
