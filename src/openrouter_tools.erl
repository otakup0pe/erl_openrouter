-module(openrouter_tools).

%% @doc Encode/decode helpers for the OpenRouter tool-use API surface.
%%
%% Handles conversion between Erlang `#tool{}' / `#tool_call{}' records and
%% the JSON wire format expected by the OpenRouter API. Tool-call arguments
%% and tool-result content are treated as opaque binaries -- callers own
%% the schema and are responsible for their own JSON encoding/decoding.

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

%% @doc Encode a list of tool definitions for the API request body.
-spec encode_tools([#tool{} | map()]) -> [map()].
encode_tools(Tools) when is_list(Tools) ->
    [encode_tool(T) || T <- Tools].

%% @doc Encode a single `#tool{}' record (or pass through a raw map).
-spec encode_tool(#tool{} | map()) -> map().
encode_tool(#tool{type = Type, function = #tool_function{} = Fun}) ->
    #{<<"type">> => Type,
      <<"function">> => encode_tool_function(Fun)};
encode_tool(Map) when is_map(Map) ->
    Map.

encode_tool_function(#tool_function{name = Name,
                                    description = Desc,
                                    parameters = Params,
                                    strict = Strict}) when is_map(Params) ->
    Base = #{<<"name">> => Name,
             <<"parameters">> => Params},
    WithDesc = case Desc of
                   <<>> -> Base;
                   _ -> Base#{<<"description">> => Desc}
               end,
    case Strict of
        true -> WithDesc#{<<"strict">> => true};
        false -> WithDesc
    end.

%% @doc Encode a `tool_choice()' value for the API request body.
%%
%% Accepts `auto', `none', `{function, Name}', or a raw binary/map passthrough.
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

%% @doc Decode a list of tool-call maps from an API response into `#tool_call{}' records.
-spec decode_tool_calls([map()]) -> [#tool_call{}].
decode_tool_calls(List) when is_list(List) ->
    [decode_tool_call(Item) || Item <- List].

%% @doc Decode a single tool-call map into a `#tool_call{}' record.
-spec decode_tool_call(map()) -> #tool_call{}.
decode_tool_call(Map) when is_map(Map) ->
    Fun = maps:get(<<"function">>, Map, #{}),
    #tool_call{
        id = maps:get(<<"id">>, Map, undefined),
        type = maps:get(<<"type">>, Map, <<"function">>),
        function_name = maps:get(<<"name">>, Fun, undefined),
        function_arguments = maps:get(<<"arguments">>, Fun, <<>>)
    }.

%% @doc Build a `role=tool' follow-up message for a completed tool call.
%%
%% Content is passed through as an opaque binary; the caller is responsible
%% for serialising the tool's return value.
-spec encode_tool_result_message(binary(), binary()) ->
    #{<<_:32, _:_*8>> => binary()}.
encode_tool_result_message(ToolCallId, Content)
  when is_binary(ToolCallId), is_binary(Content) ->
    #{<<"role">> => <<"tool">>,
      <<"tool_call_id">> => ToolCallId,
      <<"content">> => Content}.

%% @doc Validate a tools list before sending it to the API.
%%
%% Each tool must have a function definition with a binary name and a map
%% parameters field. Names must be unique across the list.
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
