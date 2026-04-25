-module(openrouter_usage).
%% @private
%% Internal token usage tracker.
%%
%% Aggregates `prompt_tokens', `completion_tokens', and `total_tokens'
%% per-model from chat and embedding response usage fields. Data is
%% recorded in-process from responses.
%%
%% Cost computation is the caller's responsibility -- {@link
%% compute_cost/2} accepts a price table and produces per-model and
%% total dollar figures from a snapshot.
%%
%% Use via the {@link openrouter} facade (`usage_snapshot/0',
%% `usage_reset/0', `usage_compute_cost/2').

-behaviour(gen_server).

-export([start_link/0]).
-export([record/2, snapshot/0, snapshot/1, reset/0, reset/1]).
-export([compute_cost/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-type model() :: binary().
-type counts() :: #{requests := non_neg_integer(),
                    prompt_tokens := non_neg_integer(),
                    completion_tokens := non_neg_integer(),
                    total_tokens := non_neg_integer()}.
-type snapshot_map() :: #{model() => counts()}.
-type price_table() :: #{model() => #{prompt => float(),
                                      completion => float()}}.

-export_type([counts/0, snapshot_map/0, price_table/0]).

-record(state, {counters = #{} :: snapshot_map()}).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Record usage for a model.
%%
%% `Usage' is the raw `usage' map from a chat or embedding response,
%% e.g. `#{<<"prompt_tokens">> => 9, <<"completion_tokens">> => 12,
%% <<"total_tokens">> => 21}'. Missing fields default to 0.
%%
%% No-op when `Model' is `undefined' or `Usage' is not a map -- this
%% lets callers thread results through without pre-filtering.
-spec record(model() | undefined, map() | term()) -> ok.
record(undefined, _) -> ok;
record(_, Usage) when not is_map(Usage) -> ok;
record(Model, Usage) when is_binary(Model) ->
    gen_server:cast(?MODULE, {record, Model, Usage}).

%% @doc Snapshot all per-model counters.
-spec snapshot() -> snapshot_map().
snapshot() ->
    gen_server:call(?MODULE, snapshot).

%% @doc Snapshot a single model's counters, or `undefined' if not seen.
-spec snapshot(model()) -> counts() | undefined.
snapshot(Model) when is_binary(Model) ->
    gen_server:call(?MODULE, {snapshot, Model}).

%% @doc Clear all counters.
-spec reset() -> ok.
reset() ->
    gen_server:call(?MODULE, reset).

%% @doc Clear a single model's counters.
-spec reset(model()) -> ok.
reset(Model) when is_binary(Model) ->
    gen_server:call(?MODULE, {reset, Model}).

%% @doc Compute cost from a snapshot and a per-model price table.
%%
%% `PriceTable' maps `Model' to `#{prompt => Float, completion =>
%% Float}', where the float is dollars per token. Fetch authoritative
%% pricing from `openrouter:models/0' (each model entry includes a
%% `pricing' object with `prompt' and `completion' as USD-per-token
%% strings).
%%
%% Returns `#{models => #{Model => Float}, missing_prices => [Model],
%% total => Float}'. Models present in the snapshot but missing from
%% the price table are reported with cost `0.0' and listed under
%% `missing_prices'.
-spec compute_cost(snapshot_map(), price_table()) ->
    #{models := #{model() => float()},
      missing_prices := [model()],
      total := float()}.
compute_cost(Snapshot, PriceTable) when is_map(Snapshot), is_map(PriceTable) ->
    maps:fold(
      fun(Model, Counts, Acc = #{models := Models, missing_prices := Missing,
                                 total := Total}) ->
              case maps:find(Model, PriceTable) of
                  {ok, #{prompt := PP, completion := CP}}
                    when is_number(PP), is_number(CP) ->
                      Cost = (maps:get(prompt_tokens, Counts, 0) * PP)
                           + (maps:get(completion_tokens, Counts, 0) * CP),
                      Acc#{models := Models#{Model => Cost},
                           total := Total + Cost};
                  _ ->
                      Acc#{models := Models#{Model => 0.0},
                           missing_prices := [Model | Missing]}
              end
      end,
      #{models => #{}, missing_prices => [], total => 0.0},
      Snapshot).

%% gen_server callbacks

init([]) ->
    {ok, #state{}}.

handle_call(snapshot, _From, State) ->
    {reply, State#state.counters, State};
handle_call({snapshot, Model}, _From, State) ->
    {reply, maps:get(Model, State#state.counters, undefined), State};
handle_call(reset, _From, State) ->
    {reply, ok, State#state{counters = #{}}};
handle_call({reset, Model}, _From, State) ->
    {reply, ok, State#state{counters = maps:remove(Model, State#state.counters)}};
handle_call(_Req, _From, State) ->
    {reply, {error, unknown_request}, State}.

handle_cast({record, Model, Usage}, State) ->
    Prev = maps:get(Model, State#state.counters,
                    #{requests => 0, prompt_tokens => 0,
                      completion_tokens => 0, total_tokens => 0}),
    P = to_int(maps:get(<<"prompt_tokens">>, Usage, 0)),
    C = to_int(maps:get(<<"completion_tokens">>, Usage, 0)),
    T = to_int(maps:get(<<"total_tokens">>, Usage, P + C)),
    Updated = #{requests => maps:get(requests, Prev) + 1,
                prompt_tokens => maps:get(prompt_tokens, Prev) + P,
                completion_tokens => maps:get(completion_tokens, Prev) + C,
                total_tokens => maps:get(total_tokens, Prev) + T},
    {noreply, State#state{counters = maps:put(Model, Updated,
                                              State#state.counters)}};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

to_int(N) when is_integer(N), N >= 0 -> N;
to_int(_) -> 0.
