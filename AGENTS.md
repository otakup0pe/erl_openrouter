# AGENTS.md

Context for AI agents working on this project.

## Project

erl_openrouter is a standalone Erlang/OTP client library for the
OpenRouter API. Apache 2.0 licensed.

## Build & Test

```bash
make test          # docker-based, runs eunit + ct (recommended, no API key needed)
make test-all      # test + integration (full suite)
make test-local    # local eunit + ct + dialyzer, requires OTP 27+
make test-eunit    # eunit only
make test-ct       # common test only (excludes integration/)
make test-dialyzer # dialyzer type analysis
make integration   # real API tests against OpenRouter (needs OPENROUTER_API_KEY)
make distclean     # nuke _build + docker volumes (fixes stale beam issues)
```

`warnings_as_errors` is enabled. All code must compile cleanly.

## Architecture

### Public API

These modules are the supported public interface:

- `openrouter` -- facade for all API calls (chat, embeddings, models, key_info, credits, generation)
- `openrouter_tools` -- tool definition encode/decode for chat tool_use
- `openrouter_auth` -- API key resolution (callback > app env > OS env)

### Internal modules

These are exported for inter-module use but not part of the public API.
All marked `@private` in edoc.

- `openrouter_client` -- gen_server, dispatches async workers per request. All API calls route through here for circuit breaker, rate limiting, and capacity control.
- `openrouter_chat` -- chat request building, response parsing, tool wiring
- `openrouter_embeddings` -- embedding request building, response parsing
- `openrouter_models` -- model list response parsing
- `openrouter_key` -- key info response parsing
- `openrouter_generation` -- generation stats response parsing
- `openrouter_credits` -- credits response parsing
- `openrouter_stream` -- SSE parser (parser only, transport not yet wired)
- `openrouter_http` -- httpc wrapper, returns `{ok, Status, Headers, Body}`
- `openrouter_error` -- error classification, `#api_error{}` construction
- `openrouter_json` -- OTP 27 json / jsx fallback wrapper
- `openrouter_backoff` -- exponential backoff with jitter (base * 2^n, capped, jittered)
- `openrouter_telemetry` -- optional telemetry event emission (no-ops when telemetry not loaded)

### OTP infrastructure

- `openrouter_app` -- application callback
- `openrouter_sup` -- supervisor (starts client, rate_limiter, circuit_breaker)
- `openrouter_rate_limiter` -- token bucket gen_server (fail-fast, no blocking)
- `openrouter_circuit_breaker` -- closed/open/half_open gen_server (fail-fast)

### Records

- `include/openrouter.hrl` -- chat_response, embedding_response, api_error, tool, tool_call, etc.

### Key design decisions

- Ensure all errors are returned as `{error, #api_error{}}` with `metadata => #{source => local | remote}`
- Rate limiter and circuit breaker are fail-fast (reject immediately, no blocking)
- Workers are spawned per-request via `spawn_monitor`; the client gen_server dispatches but does not block
- Route All API calls (including credits and generation) through `openrouter_client`
- `max_in_flight` (default 50) caps concurrent spawned workers
- `telemetry` is optional; `openrouter_telemetry` no-ops when not loaded
- cowboy is test-only (mock server)

### Test layout

- `test/mock_openrouter.erl` -- shared cowboy mock server for CT suites
- EUnit tests: `*_tests.erl` files test pure functions (parsing, encoding, error classification)
- CT suites: `*_SUITE.erl` files test integration through the mock HTTP server
- `test/integration/manual_integration_SUITE.erl` -- real API tests, skipped without OPENROUTER_API_KEY. Run via `make integration`, NOT via `make test`.

## Conventions

- No catch-all exception handling. Catch specific error types only (`error:badarg`, `error:{invalid_byte, _}`, etc). Never `catch _:_` or `catch error:Reason`.
- Only mock external resources in tests. Do not test third-party library behavior.
- `openrouter_json:maybe_set/4` is the shared helper for building JSON request maps from opts.
- HTTP return type is always `{ok, Status, Headers, Body} | {error, Reason}` (4-tuple on success).
