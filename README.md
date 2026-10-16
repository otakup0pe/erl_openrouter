## erl_openrouter

[![CI Status](https://img.shields.io/github/actions/workflow/status/otakup0pe/erl_openrouter/test.yml)](https://github.com/otakup0pe/erl_openrouter/actions/workflows/test.yml)
[![Maintenance](https://img.shields.io/maintenance/yes/2026.svg)](https://github.com/otakup0pe/erl_openrouter)
[![License](https://img.shields.io/github/license/otakup0pe/erl_openrouter)](https://github.com/otakup0pe/erl_openrouter/blob/mainline/LICENSE)

Erlang/OTP client for the [OpenRouter API](https://openrouter.ai/). Chat completions, tool use, embeddings, rate limiting, circuit breaking, and telemetry.

## Requirements

* OTP 27+ (uses built-in `json` module; `jsx` as optional fallback for OTP < 27)
* rebar3

## Quick Start

Add to `rebar.config`:

```erlang
{deps, [
    {erl_openrouter, {git, "https://github.com/otakup0pe/erl_openrouter.git", {tag, "0.4.0"}}}
]}.
```

Set your API key and make a request:

```erlang
%% export OPENROUTER_API_KEY="sk-or-..." in your shell, then:
application:ensure_all_started(erl_openrouter),
{ok, Response} = openrouter:chat([
    #{<<"role">> => <<"user">>, <<"content">> => <<"Hello">>}
], #{model => <<"openai/gpt-4o">>}).
```

Auth can also be set via application env (`api_key`) or per-request callback (`auth_callback` in opts).

## Configuration

Two commonly adjusted settings. See [`erl_openrouter.app.src`](src/erl_openrouter.app.src) and `openrouter_client:init/1` for the full set.

* `timeout` (default `30000`) -- HTTP request timeout in milliseconds.
* `max_in_flight` (default `50`) -- Maximum concurrent requests before backpressure kicks in.

Rate limiter and circuit breaker start with sensible defaults (60 req/min token bucket, 5-failure circuit breaker with 30s reset). Override via `rate_limiter_opts` and `circuit_breaker_opts` in application env.

## Features

* Chat completions with tool use (function calling, parallel tool calls, tool_choice)
* Thinking model content block normalization
* Embeddings, model listing, key info, credits
* API fault tolerance via token bucket rate limiter, circuit breaker, retries, and exponential backoff
* Generation stats endpoint for server-side request diagnostics
* Optional telemetry events

See [docs/usage.md](docs/usage.md) for detailed examples (chat, tool use, error handling, telemetry, generation stats).

## Testing

Tests run in Docker via `make test`, or locally with `make local-test` (requires OTP 27+). Integration tests against the live OpenRouter API run with `OPENROUTER_API_KEY=sk-or-... make integration`. Note that integration tests make use of a non-free model.

## Note on AI Usage

This project has been developed with AI assistance. Contributions making use of AI generated content are welcome, however they _must_ be human reviewed prior to submission as pull requests, or issues. All contributors must be able to fully explain and defend any AI generated code, documentation, issues, or tests they submit. Contributions making use of AI must have this explicitly declared in the pull request or issue. This also applies to utilization of AI for reviewing of pull requests.

## Feedback, bug-reports, requests, ...

Are all [welcome](https://github.com/otakup0pe/erl_openrouter/issues)!

## License

Apache License 2.0. See [LICENSE](LICENSE).
