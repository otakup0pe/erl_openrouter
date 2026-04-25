-module(stream_tests).
-include_lib("eunit/include/eunit.hrl").
-include("openrouter.hrl").

%% Unit tests for openrouter_stream: incremental SSE parsing,
%% content accumulation, tool-call delta merging (single + parallel),
%% finish reasons, [DONE] terminator. No HTTP.

empty_feed_noop_test() ->
    S0 = openrouter_stream:new(),
    {Events, S1} = openrouter_stream:feed(<<>>, S0),
    ?assertEqual([], Events),
    ?assertEqual(<<>>, openrouter_stream:content(S1)),
    ?assertEqual([], openrouter_stream:tool_calls(S1)).

content_delta_single_chunk_test() ->
    S0 = openrouter_stream:new(),
    Chunk = <<"data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n">>,
    {Events, S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([{content, <<"Hello">>}], Events),
    ?assertEqual(<<"Hello">>, openrouter_stream:content(S1)).

content_delta_accumulates_test() ->
    S0 = openrouter_stream:new(),
    C1 = <<"data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\n">>,
    C2 = <<"data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n">>,
    {_, S1} = openrouter_stream:feed(C1, S0),
    {_, S2} = openrouter_stream:feed(C2, S1),
    ?assertEqual(<<"Hello">>, openrouter_stream:content(S2)).

partial_line_buffered_test() ->
    %% Feed a chunk that ends mid-line; the parser must buffer.
    S0 = openrouter_stream:new(),
    Part1 = <<"data: {\"choices\":[{\"delta\":{\"conte">>,
    Part2 = <<"nt\":\"X\"}}]}\n\n">>,
    {E1, S1} = openrouter_stream:feed(Part1, S0),
    ?assertEqual([], E1),
    {E2, S2} = openrouter_stream:feed(Part2, S1),
    ?assertEqual([{content, <<"X">>}], E2),
    ?assertEqual(<<"X">>, openrouter_stream:content(S2)).

done_marker_test() ->
    S0 = openrouter_stream:new(),
    {Events, S1} = openrouter_stream:feed(<<"data: [DONE]\n\n">>, S0),
    ?assertEqual([done], Events),
    ?assert(openrouter_stream:done(S1)).

finish_reason_atomised_test() ->
    S0 = openrouter_stream:new(),
    Chunk = <<"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n">>,
    {Events, S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([{finish, stop}], Events),
    ?assertEqual(stop, openrouter_stream:finish_reason(S1)).

comment_and_blank_lines_ignored_test() ->
    S0 = openrouter_stream:new(),
    Chunk = <<": keepalive\n\nevent: foo\n\ndata: {\"choices\":[]}\n\n">>,
    {Events, _S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([], Events).

tool_call_single_delta_merged_test() ->
    %% Two deltas for index 0: first sets id+name+partial args;
    %% second appends the rest of args.
    S0 = openrouter_stream:new(),
    C1 = <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[",
           "{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",",
           "\"function\":{\"name\":\"get_weather\",",
           "\"arguments\":\"{\\\"city\\\":\"}}]}}]}\n\n">>,
    C2 = <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[",
           "{\"index\":0,\"function\":{\"arguments\":\"\\\"NYC\\\"}\"}}]}}]}\n\n">>,
    {E1, S1} = openrouter_stream:feed(C1, S0),
    ?assertMatch([{tool_call_delta, 0}], E1),
    {E2, S2} = openrouter_stream:feed(C2, S1),
    ?assertMatch([{tool_call_delta, 0}], E2),
    [TC] = openrouter_stream:tool_calls(S2),
    ?assertEqual(<<"call_1">>, TC#tool_call.id),
    ?assertEqual(<<"get_weather">>, TC#tool_call.function_name),
    ?assertEqual(<<"{\"city\":\"NYC\"}">>, TC#tool_call.function_arguments).

tool_call_parallel_merged_test() ->
    %% Two parallel tool calls (indices 0 and 1). The parser must
    %% keep them separate and yield both on close, correlated by id.
    S0 = openrouter_stream:new(),
    C1 = <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[",
           "{\"index\":0,\"id\":\"a\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}},",
           "{\"index\":1,\"id\":\"b\",\"function\":{\"name\":\"g\",\"arguments\":\"{\"}}",
           "]}}]}\n\n">>,
    C2 = <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[",
           "{\"index\":1,\"function\":{\"arguments\":\"}\"}}",
           "]}}]}\n\n">>,
    {_, S1} = openrouter_stream:feed(C1, S0),
    {_, S2} = openrouter_stream:feed(C2, S1),
    TCs = openrouter_stream:tool_calls(S2),
    ?assertEqual(2, length(TCs)),
    ById = maps:from_list([{TC#tool_call.id, TC} || TC <- TCs]),
    ?assertEqual(<<"f">>, (maps:get(<<"a">>, ById))#tool_call.function_name),
    ?assertEqual(<<"{}">>, (maps:get(<<"a">>, ById))#tool_call.function_arguments),
    ?assertEqual(<<"g">>, (maps:get(<<"b">>, ById))#tool_call.function_name),
    ?assertEqual(<<"{}">>, (maps:get(<<"b">>, ById))#tool_call.function_arguments).

tool_call_and_content_interleaved_test() ->
    S0 = openrouter_stream:new(),
    Chunks = [
        <<"data: {\"choices\":[{\"delta\":{\"content\":\"pre\"}}]}\n\n">>,
        <<"data: {\"choices\":[{\"delta\":{\"tool_calls\":[",
          "{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"t\",\"arguments\":\"{}\"}}]}}]}\n\n">>,
        <<"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n">>,
        <<"data: [DONE]\n\n">>
    ],
    Final = lists:foldl(fun(C, S) ->
                                {_, S1} = openrouter_stream:feed(C, S), S1
                        end, S0, Chunks),
    ?assertEqual(<<"pre">>, openrouter_stream:content(Final)),
    ?assertEqual(tool_calls, openrouter_stream:finish_reason(Final)),
    ?assert(openrouter_stream:done(Final)),
    [TC] = openrouter_stream:tool_calls(Final),
    ?assertEqual(<<"c1">>, TC#tool_call.id).

malformed_json_emits_parse_error_test() ->
    S0 = openrouter_stream:new(),
    Chunk = <<"data: {not json}\n\n",
              "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n">>,
    {Events, S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([{parse_error, <<"{not json}">>}, {content, <<"ok">>}], Events),
    ?assertEqual(<<"ok">>, openrouter_stream:content(S1)).

non_map_json_emits_parse_error_test() ->
    S0 = openrouter_stream:new(),
    Chunk = <<"data: [1,2,3]\n\n">>,
    {Events, _S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([{parse_error, <<"[1,2,3]">>}], Events).

crlf_line_endings_test() ->
    %% SSE traditionally uses \r\n; ensure we strip CR.
    S0 = openrouter_stream:new(),
    Chunk = <<"data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\r\n\r\n">>,
    {Events, S1} = openrouter_stream:feed(Chunk, S0),
    ?assertEqual([{content, <<"ok">>}], Events),
    ?assertEqual(<<"ok">>, openrouter_stream:content(S1)).
