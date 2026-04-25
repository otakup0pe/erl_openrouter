# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-04-22

### Added

First Post woo hoo!

- Core chat completions API (POST /api/v1/chat/completions)
- Tool use support (function calling, tool_choice, parallel tool calls)
- Thinking model content block normalization
- Embeddings API (POST /api/v1/embeddings)
- Model listing (GET /api/v1/models)
- Key info (GET /api/v1/auth/key) and Credits (GET /api/v1/credits)
- Token bucket rate limiter with configurable rate
- Circuit breaker (closed/open/half-open states)
- Exponential backoff with jitter, Retry-After header respect
- Async worker pattern for concurrent requests
- In-flight request backpressure (max_in_flight cap)
- Normalized error handling (#api_error{} with source metadata)
- Auth fail-fast on missing API key
- SSE stream parser (transport planned for 0.2.0)
- OTP 27 json module with jsx optional fallback

[0.1.0]: https://github.com/otakup0pe/erl_openrouter/releases/tag/0.1.0
