-ifndef(OPENROUTER_HRL).
-define(OPENROUTER_HRL, true).

-record(tool_function, {
    name :: binary(),
    description = <<>> :: binary(),
    parameters = #{} :: map(),
    strict = false :: boolean()
}).

-record(tool, {
    type = <<"function">> :: binary(),
    function :: #tool_function{} | undefined
}).

-record(tool_call, {
    id :: binary() | undefined,
    type = <<"function">> :: binary(),
    function_name :: binary() | undefined,
    function_arguments = <<>> :: binary()
}).

-record(message, {
    role :: binary() | undefined,
    content :: binary() | null | undefined,
    name :: binary() | undefined,
    tool_calls = [] :: [#tool_call{}],
    tool_call_id :: binary() | undefined
}).

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
    tools = [] :: [#tool{}] | [map()] | undefined,
    tool_choice :: undefined | auto | none | {function, binary()} | binary() | map()
}).

-record(chat_response, {
    id :: binary(),
    model :: binary(),
    choices :: [map()],
    usage :: map(),
    cost :: float() | undefined
}).

-record(embedding_response, {
    model :: binary(),
    data :: [#{index := non_neg_integer(), embedding := [float()]}],
    usage :: map()
}).

-record(api_error, {
    type :: auth_error | rate_limited | insufficient_credits
          | forbidden | server_error | timeout | connect_failed | parse_error
          | malformed_response,
    code :: integer() | undefined,
    message :: binary(),
    metadata :: map()
}).

-endif.
