-ifndef(OPENROUTER_HRL).
-define(OPENROUTER_HRL, true).

-record(chat_request, {
    messages :: [map()],
    model :: binary() | undefined,
    temperature :: float() | undefined,
    top_p :: float() | undefined,
    top_k :: integer() | undefined,
    frequency_penalty :: float() | undefined,
    presence_penalty :: float() | undefined,
    repetition_penalty :: float() | undefined,
    min_p :: float() | undefined,
    top_a :: float() | undefined,
    seed :: integer() | undefined,
    max_tokens :: integer() | undefined,
    stop :: [binary()] | undefined,
    response_format :: map() | undefined,
    tools :: [map()] | undefined,
    tool_choice :: binary() | map() | undefined
}).

-record(chat_response, {
    id :: binary(),
    model :: binary(),
    choices :: [map()],
    usage :: map(),
    cost :: float() | undefined
}).

-record(api_error, {
    type :: auth_error | rate_limited | insufficient_credits
          | forbidden | server_error | timeout | parse_error,
    code :: integer() | undefined,
    message :: binary(),
    metadata :: map()
}).

-endif.
