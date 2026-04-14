-module(openrouter_tools).

%% Encode/decode helpers for the OpenRouter tool-use API surface.
%%
%% Design notes:
%%
%% - We treat `arguments` (on tool_calls) and `content` (on tool
%%   result messages) as opaque binaries. Callers know the tool
%%   schema; we do not JSON-decode on their behalf.
%% - Parallel tool calls are correlated by `id` / `tool_call_id`;
%%   we do not expose an array index to the caller.
%% - The primary `tool_choice` surface is restricted to OpenRouter's
%%   documented ToolChoice shape: auto | none | {function, Name}.
%%   We also pass through raw binary/map values so a caller can
%%   reach providers' undocumented extensions if they know what
%%   they're doing.

-include("openrouter.hrl").

-export([encode_tool/1,
         encode_tools/1,
         encode_tool_choice/1,
         decode_tool_call/1,
         decode_tool_calls/1,
         encode_tool_result_message/2,
         validate_tools/1]).

-export_type([tool_choice/0]).

-type tool_choice() :: undefined | auto | none | {function, binary()} | binary() | map().

%% ---- Encoding -------------------------------------------------------

-spec encode_tools([#tool{} | map()]) -> [map()].
encode_tools(Tools) when is_list(Tools) ->
    [encode_tool(T) || T <- Tools].

-spec encode_tool(#tool{} | map()) -> map().
encode_tool(#tool{type = Type, function = #tool_function{} = Fun}) ->
    #{<<"type">> => Type,
      <<"function">> => encode_tool_function(Fun)};
encode_tool(Map) when is_map(Map) ->
    %% Accept caller-supplied raw maps as-is.
    Map.

encode_tool_function(#tool_function{name = Name,
                                    description = Desc,
                                    parameters = Params,
                                    strict = Strict}) when is_map(Params) ->
    Base = #{<<"name">> => Name,
             <<"parameters">> => Params},
    WithDesc = case Desc of
                   undefined -> Base;
                   <<>> -> Base;
                   _ -> Base#{<<"description">> => Desc}
               end,
    case Strict of
        true -> WithDesc#{<<"strict">> => true};
        false -> WithDesc
    end.

-spec encode_tool_choice(tool_choice()) -> undefined | binary() | map().
encode_tool_choice(undefined) -> undefined;
encode_tool_choice(auto) -> <<"auto">>;
encode_tool_choice(none) -> <<"none">>;
encode_tool_choice({function, Name}) when is_binary(Name) ->
    #{<<"type">> => <<"function">>,
      <<"function">> => #{<<"name">> => Name}};
encode_tool_choice(Bin) when is_binary(Bin) -> Bin;
encode_tool_choice(Map) when is_map(Map) -> Map;
encode_tool_choice(Other) ->
    erlang:error({badarg, {tool_choice, Other}}).

%% ---- Decoding -------------------------------------------------------

-spec decode_tool_calls(list()) -> [#tool_call{}].
decode_tool_calls(List) when is_list(List) ->
    [decode_tool_call(Item) || Item <- List].

-spec decode_tool_call(map()) -> #tool_call{}.
decode_tool_call(Map) when is_map(Map) ->
    Fun = maps:get(<<"function">>, Map, #{}),
    #tool_call{
        id = maps:get(<<"id">>, Map, undefined),
        type = maps:get(<<"type">>, Map, <<"function">>),
        function_name = maps:get(<<"name">>, Fun, undefined),
        function_arguments = maps:get(<<"arguments">>, Fun, <<>>)
    }.

%% ---- Follow-up messages ---------------------------------------------

%% Build a role=tool follow-up message carrying the result of one
%% tool call. Content is passed through as an opaque binary; the
%% caller decides how to serialise the tool's return value.
-spec encode_tool_result_message(binary(), binary()) -> map().
encode_tool_result_message(ToolCallId, Content)
  when is_binary(ToolCallId), is_binary(Content) ->
    #{<<"role">> => <<"tool">>,
      <<"tool_call_id">> => ToolCallId,
      <<"content">> => Content}.

%% ---- Validation -----------------------------------------------------

%% Validate a tools list: each tool must have a function definition
%% with a binary name and a map parameters field; names must be
%% unique across the list.
-spec validate_tools([#tool{} | map()]) ->
    ok | {error, {duplicate_tool_name, binary()}}
       | {error, {invalid_tool, term()}}.
validate_tools(Tools) when is_list(Tools) ->
    case collect_names(Tools, []) of
        {error, _} = Err -> Err;
        {ok, Names} -> check_unique(Names)
    end.

collect_names([], Acc) ->
    {ok, lists:reverse(Acc)};
collect_names([#tool{function = #tool_function{name = Name, parameters = P}} | Rest], Acc)
  when is_binary(Name), is_map(P) ->
    collect_names(Rest, [Name | Acc]);
collect_names([#{<<"function">> := #{<<"name">> := Name}} | Rest], Acc)
  when is_binary(Name) ->
    collect_names(Rest, [Name | Acc]);
collect_names([Bad | _], _Acc) ->
    {error, {invalid_tool, Bad}}.

check_unique(Names) ->
    check_unique(Names, #{}).

check_unique([], _Seen) ->
    ok;
check_unique([Name | Rest], Seen) ->
    case maps:is_key(Name, Seen) of
        true -> {error, {duplicate_tool_name, Name}};
        false -> check_unique(Rest, Seen#{Name => true})
    end.
