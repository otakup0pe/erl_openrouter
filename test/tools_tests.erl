-module(tools_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Unit tests for openrouter_tools: encode/decode round-trips for
%% tools, tool_choice, tool_calls, tool result messages, and
%% request-time validation. No HTTP calls; no JSON library stressing.

encode_single_tool_test() ->
    Tool = #tool{
        function = #tool_function{
            name = <<"get_weather">>,
            description = <<"Look up current weather">>,
            parameters = #{<<"type">> => <<"object">>}
        }
    },
    [Encoded] = openrouter_tools:encode_tools([Tool]),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Encoded)),
    Fun = maps:get(<<"function">>, Encoded),
    ?assertEqual(<<"get_weather">>, maps:get(<<"name">>, Fun)),
    ?assertEqual(<<"Look up current weather">>, maps:get(<<"description">>, Fun)),
    ?assertEqual(#{<<"type">> => <<"object">>}, maps:get(<<"parameters">>, Fun)),
    %% strict defaults off; should be absent
    ?assertNot(maps:is_key(<<"strict">>, Fun)).

encode_tool_with_strict_test() ->
    Tool = #tool{
        function = #tool_function{
            name = <<"foo">>,
            parameters = #{},
            strict = true
        }
    },
    [Encoded] = openrouter_tools:encode_tools([Tool]),
    Fun = maps:get(<<"function">>, Encoded),
    ?assertEqual(true, maps:get(<<"strict">>, Fun)).

encode_tool_without_description_test() ->
    Tool = #tool{
        function = #tool_function{name = <<"x">>, parameters = #{}}
    },
    [Encoded] = openrouter_tools:encode_tools([Tool]),
    Fun = maps:get(<<"function">>, Encoded),
    ?assertNot(maps:is_key(<<"description">>, Fun)).

encode_raw_map_tool_passthrough_test() ->
    %% Caller-supplied raw maps are accepted as-is.
    Raw = #{<<"type">> => <<"function">>,
            <<"function">> => #{<<"name">> => <<"raw">>, <<"parameters">> => #{}}},
    [Encoded] = openrouter_tools:encode_tools([Raw]),
    ?assertEqual(Raw, Encoded).

encode_tool_choice_variants_test() ->
    ?assertEqual(undefined, openrouter_tools:encode_tool_choice(undefined)),
    ?assertEqual(<<"auto">>, openrouter_tools:encode_tool_choice(auto)),
    ?assertEqual(<<"none">>, openrouter_tools:encode_tool_choice(none)),
    Specific = openrouter_tools:encode_tool_choice({function, <<"my_tool">>}),
    ?assertEqual(<<"function">>, maps:get(<<"type">>, Specific)),
    ?assertEqual(<<"my_tool">>,
                 maps:get(<<"name">>, maps:get(<<"function">>, Specific))).

encode_tool_choice_passthrough_test() ->
    ?assertEqual(<<"custom">>, openrouter_tools:encode_tool_choice(<<"custom">>)),
    Map = #{<<"type">> => <<"function">>},
    ?assertEqual(Map, openrouter_tools:encode_tool_choice(Map)).

encode_tool_choice_bad_atom_raises_test() ->
    ?assertError({badarg, {tool_choice, required}},
                 openrouter_tools:encode_tool_choice(required)).

decode_tool_call_test() ->
    Raw = #{<<"id">> => <<"call_1">>,
            <<"type">> => <<"function">>,
            <<"function">> => #{
                <<"name">> => <<"get_weather">>,
                <<"arguments">> => <<"{\"city\":\"NYC\"}">>
            }},
    TC = openrouter_tools:decode_tool_call(Raw),
    ?assertEqual(<<"call_1">>, TC#tool_call.id),
    ?assertEqual(<<"function">>, TC#tool_call.type),
    ?assertEqual(<<"get_weather">>, TC#tool_call.function_name),
    %% arguments preserved as raw binary; NOT auto JSON-decoded
    ?assertEqual(<<"{\"city\":\"NYC\"}">>, TC#tool_call.function_arguments),
    ?assert(is_binary(TC#tool_call.function_arguments)).

decode_tool_calls_list_test() ->
    Raw = [
        #{<<"id">> => <<"a">>, <<"type">> => <<"function">>,
          <<"function">> => #{<<"name">> => <<"f">>, <<"arguments">> => <<"{}">>}},
        #{<<"id">> => <<"b">>, <<"type">> => <<"function">>,
          <<"function">> => #{<<"name">> => <<"g">>, <<"arguments">> => <<"{}">>}}
    ],
    [A, B] = openrouter_tools:decode_tool_calls(Raw),
    ?assertEqual(<<"a">>, A#tool_call.id),
    ?assertEqual(<<"b">>, B#tool_call.id).

decode_tool_call_missing_fields_test() ->
    %% Partial deltas during streaming may omit name/arguments.
    TC = openrouter_tools:decode_tool_call(#{<<"id">> => <<"x">>}),
    ?assertEqual(<<"x">>, TC#tool_call.id),
    ?assertEqual(undefined, TC#tool_call.function_name),
    ?assertEqual(<<>>, TC#tool_call.function_arguments).

encode_tool_result_message_test() ->
    Msg = openrouter_tools:encode_tool_result_message(
        <<"call_abc">>, <<"{\"temp\":72}">>),
    ?assertEqual(<<"tool">>, maps:get(<<"role">>, Msg)),
    ?assertEqual(<<"call_abc">>, maps:get(<<"tool_call_id">>, Msg)),
    %% content passed through as raw binary
    ?assertEqual(<<"{\"temp\":72}">>, maps:get(<<"content">>, Msg)).

validate_tools_ok_test() ->
    Tools = [
        #tool{function = #tool_function{name = <<"a">>, parameters = #{}}},
        #tool{function = #tool_function{name = <<"b">>, parameters = #{}}}
    ],
    ?assertEqual(ok, openrouter_tools:validate_tools(Tools)).

validate_tools_duplicate_test() ->
    Tools = [
        #tool{function = #tool_function{name = <<"dup">>, parameters = #{}}},
        #tool{function = #tool_function{name = <<"dup">>, parameters = #{}}}
    ],
    ?assertEqual({error, {duplicate_tool_name, <<"dup">>}},
                 openrouter_tools:validate_tools(Tools)).

validate_tools_raw_map_ok_test() ->
    Tools = [
        #{<<"function">> => #{<<"name">> => <<"r1">>, <<"parameters">> => #{}}},
        #{<<"function">> => #{<<"name">> => <<"r2">>, <<"parameters">> => #{}}}
    ],
    ?assertEqual(ok, openrouter_tools:validate_tools(Tools)).

validate_tools_invalid_test() ->
    ?assertMatch({error, {invalid_tool, _}},
                 openrouter_tools:validate_tools([not_a_tool])).

%% ---- Header extension (extra-headers mechanism) --------------------

headers_no_extras_test() ->
    Hs = openrouter_http:headers({ok, <<"k">>}, []),
    ?assert(lists:member({"Authorization", "Bearer k"}, Hs)),
    ?assert(lists:member({"Content-Type", "application/json"}, Hs)).

headers_with_extra_test() ->
    Hs = openrouter_http:headers({ok, <<"k">>},
                                 [{"X-Anthropic-Beta", "structured-outputs-2025-11-13"}]),
    ?assert(lists:member({"Authorization", "Bearer k"}, Hs)),
    ?assert(lists:member({"X-Anthropic-Beta", "structured-outputs-2025-11-13"}, Hs)).

headers_caller_override_wins_test() ->
    %% Caller supplies Content-Type; should override the auth-derived one.
    Hs = openrouter_http:headers({ok, <<"k">>},
                                 [{"Content-Type", "text/event-stream"}]),
    CT = [V || {N, V} <- Hs, string:to_lower(N) =:= "content-type"],
    ?assertEqual(["text/event-stream"], CT).

headers_override_case_insensitive_test() ->
    %% Different casing on the caller header still overrides.
    Hs = openrouter_http:headers({ok, <<"k">>},
                                 [{"authorization", "Bearer override"}]),
    Auths = [V || {N, V} <- Hs, string:to_lower(N) =:= "authorization"],
    ?assertEqual(["Bearer override"], Auths).

headers_extras_dedupe_amongst_themselves_test() ->
    Hs = openrouter_http:headers({error, no_api_key},
                                 [{"X-Foo", "one"}, {"X-Foo", "two"}]),
    Foos = [V || {N, V} <- Hs, string:to_lower(N) =:= "x-foo"],
    ?assertEqual(["two"], Foos).

headers_arity_1_still_works_test() ->
    %% Backward compatibility: old headers/1 still returns auth-only.
    Hs = openrouter_http:headers({ok, <<"k">>}),
    ?assert(lists:member({"Authorization", "Bearer k"}, Hs)),
    ?assert(lists:member({"Content-Type", "application/json"}, Hs)).
