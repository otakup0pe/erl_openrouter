-module(openrouter).

%% @doc Public API for the OpenRouter client.
%%
%% Convenience wrappers around {@link openrouter_client} for chat completions,
%% embeddings, model listing, key introspection, generation stats, and credits.

%% Public API - convenience wrappers around openrouter_client
-export([chat/1, chat/2]).
-export([chat_stream/1, chat_stream/2, cancel_stream/1]).
-export([embeddings/1, embeddings/2]).
-export([models/0]).
-export([key_info/0]).
-export([generation/1]).
-export([credits/0]).

-include("openrouter.hrl").

%% @doc Send a chat completion request with default options.
%% @equiv chat(Messages, #{})
-spec chat(Messages :: [map()]) -> {ok, #chat_response{}} | {error, term()}.
chat(Messages) ->
    chat(Messages, #{}).

%% @doc Send a chat completion request.
%%
%% Messages is a list of maps with `<<"role">>' and `<<"content">>' keys.
%% Opts may include `model', `temperature', `max_tokens', `tools', etc.
-spec chat(Messages :: [map()], Opts :: map()) -> {ok, #chat_response{}} | {error, term()}.
chat(Messages, Opts) ->
    openrouter_client:chat(Messages, Opts).

%% @doc Start a streaming chat completion with default options.
%% @equiv chat_stream(Messages, #{})
-spec chat_stream(Messages :: [map()]) -> {ok, reference()} | {error, term()}.
chat_stream(Messages) ->
    chat_stream(Messages, #{}).

%% @doc Start a streaming chat completion.
%%
%% Returns `{ok, StreamRef}' immediately. Events are delivered as messages
%% to the calling process in the form `{stream_event, StreamRef, Event}'.
%%
%% Event types:
%% <ul>
%%   <li>`{content, Text}' -- a content text delta</li>
%%   <li>`{tool_call_delta, Index}' -- a tool call delta at the given index</li>
%%   <li>`{finish, Reason}' -- the stream finished (stop, length, tool_calls, etc.)</li>
%%   <li>`done' -- the server sent the [DONE] sentinel</li>
%%   <li>`{error, Reason}' -- an error occurred</li>
%% </ul>
%% @doc Start a streaming chat completion.
%%
%% Returns `{ok, StreamRef, WorkerPid}' immediately. Events are
%% delivered as messages to the calling process:
%% `{stream_event, StreamRef, Event}'.
%%
%% Events:
%% <ul>
%%   <li>`{content, Text}' -- a content chunk</li>
%%   <li>`{tool_call_delta, Index}' -- a tool call update</li>
%%   <li>`{finish, Reason}' -- stream finishing (stop, length, tool_calls)</li>
%%   <li>`done' -- server sent [DONE] sentinel</li>
%%   <li>`{error, Reason}' -- an error occurred</li>
%% </ul>
%%
%% Use {@link cancel_stream/1} with the WorkerPid to stop a stream early.
-spec chat_stream(Messages :: [map()], Opts :: map()) ->
    {ok, reference(), pid()} | {error, term()}.
chat_stream(Messages, Opts) ->
    openrouter_client:chat_stream(Messages, Opts).

%% @doc Cancel an active stream.
%%
%% Sends a cancel signal to the stream worker, which will cancel the
%% underlying HTTP request and deliver `{stream_event, StreamRef,
%% {error, cancelled}}' to the caller.
-spec cancel_stream(pid()) -> ok.
cancel_stream(WorkerPid) when is_pid(WorkerPid) ->
    WorkerPid ! cancel,
    ok.

%% @doc Generate embeddings using the default model.
%%
%% Uses the `embedding_model' app env key if set, otherwise returns
%% an error. Set a default via:
%% `application:set_env(erl_openrouter, embedding_model, <<"openai/text-embedding-3-small">>)'
-spec embeddings(Input :: binary() | [binary()]) ->
    {ok, #embedding_response{}} | {error, term()}.
embeddings(Input) ->
    case application:get_env(erl_openrouter, embedding_model) of
        {ok, Model} when is_binary(Model) ->
            embeddings(Input, #{model => Model});
        undefined ->
            {error, {config_error, <<"No embedding model configured. "
                "Set erl_openrouter app env embedding_model or pass "
                "model in opts.">>}}
    end.

%% @doc Generate embeddings for one or more input texts.
%%
%% Opts MUST include `model' -- OpenRouter requires an explicit embedding
%% model (e.g. `<<"openai/text-embedding-3-small">>').
%% Other opts: `dimensions'.
-spec embeddings(Input :: binary() | [binary()], Opts :: map()) ->
    {ok, #embedding_response{}} | {error, term()}.
embeddings(Input, Opts) ->
    openrouter_client:embeddings(Input, Opts).

%% @doc List all models available on OpenRouter.
-spec models() -> {ok, [map()]} | {error, term()}.
models() ->
    openrouter_client:models().

%% @doc Retrieve metadata about the currently configured API key.
-spec key_info() -> {ok, map()} | {error, term()}.
key_info() ->
    openrouter_client:key_info().

%% @doc Fetch server-side generation stats for a completed request.
-spec generation(GenId :: binary()) -> {ok, map()} | {error, term()}.
generation(GenId) ->
    openrouter_client:generation(GenId).

%% @doc Fetch the current credit balance for the configured API key.
-spec credits() -> {ok, map()} | {error, term()}.
credits() ->
    openrouter_client:credits().
