-module(openrouter).

%% Public API - convenience wrappers around openrouter_client
-export([chat/1, chat/2]).
-export([models/0]).
-export([key_info/0]).

-include("openrouter.hrl").

-spec chat(Messages :: [map()]) -> {ok, #chat_response{}} | {error, term()}.
chat(Messages) ->
    chat(Messages, #{}).

-spec chat(Messages :: [map()], Opts :: map()) -> {ok, #chat_response{}} | {error, term()}.
chat(Messages, Opts) ->
    openrouter_client:chat(Messages, Opts).

-spec models() -> {ok, [map()]} | {error, term()}.
models() ->
    openrouter_client:models().

-spec key_info() -> {ok, map()} | {error, term()}.
key_info() ->
    openrouter_client:key_info().
