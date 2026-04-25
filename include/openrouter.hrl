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
          | malformed_response | worker_crashed | overloaded | circuit_open,
    code :: integer() | undefined,
    message :: binary(),
    metadata :: map()
}).

-endif.
