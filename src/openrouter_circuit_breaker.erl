-module(openrouter_circuit_breaker).
%% @private

%% @doc Circuit breaker for upstream API calls.
%%
%% Tracks failures and trips open when configured criteria are met,
%% preventing further requests until a cooldown period expires.
%%
%% States:
%% <ul>
%%   <li>`closed' -- normal operation; requests are allowed.</li>
%%   <li>`open' -- tripped; all requests are rejected with
%%       `{error, circuit_open}'.</li>
%%   <li>`half_open' -- entered after `reset_timeout' ms in the open
%%       state; one probe request is allowed. A success returns to
%%       closed; a failure re-opens the circuit.</li>
%% </ul>
%%
%% Two trip algorithms, selected per breaker:
%%
%% `failure_threshold' (default) -- consecutive-failure counter. The
%% counter resets to 0 on any success in the closed state. Trips on
%% the Nth consecutive failure.
%%
%% `failure_ratio' -- sliding-window ratio. Tracks the last
%% `window_max_size' attempts within a `window_max_ms' window and
%% trips when `min_attempts' have accumulated and the failure ratio
%% meets or exceeds `failure_ratio'. Survives interleaved successes
%% from sibling ops.
%%
%% Defaults (overridable via the opts map passed to {@link start_link/1}):
%% <ul>
%%   <li>`failure_threshold' -- 5 (consecutive)</li>
%%   <li>`reset_timeout' -- 30000 ms</li>
%%   <li>`failure_ratio' -- absent (consecutive path)</li>
%%   <li>`window_max_ms' -- 60000</li>
%%   <li>`window_max_size' -- 50</li>
%%   <li>`min_attempts' -- 5</li>
%% </ul>

-behaviour(gen_server).

-export([start_link/1, start_link/2]).
-export([allow/1, state/1, model/1, op/1, record_success/1, record_failure/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

%% Test-only exports for eunit coverage of pure functions.
-ifdef(TEST).
-export([prune_window/3, should_trip_ratio/4, failure_ratio_of/1]).
-endif.

-record(state, {
    cb_state :: closed | open | half_open,
    %% Consecutive-count algorithm
    failure_count :: non_neg_integer(),
    failure_threshold :: pos_integer() | undefined,
    %% Sliding-window ratio algorithm. window holds {monotonic_ms,
    %% success | failure} entries with newest at the back.
    window :: queue:queue({integer(), success | failure}),
    window_max_ms :: pos_integer(),
    window_max_size :: pos_integer(),
    min_attempts :: pos_integer(),
    failure_ratio :: float() | undefined,
    %% Common
    reset_timeout :: pos_integer(),
    timer_ref :: reference() | undefined,
    model :: binary() | undefined,
    op :: atom() | undefined
}).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

start_link(Name, Opts) ->
    gen_server:start_link({local, Name}, ?MODULE, Opts, []).

-spec allow(pid() | atom()) -> ok | {error, circuit_open}.
allow(Server) ->
    gen_server:call(Server, allow).

-spec state(pid() | atom()) -> closed | open | half_open.
state(Server) ->
    gen_server:call(Server, state).

-spec model(pid() | atom()) -> binary() | undefined.
model(Server) ->
    gen_server:call(Server, model).

-spec op(pid() | atom()) -> atom() | undefined.
op(Server) ->
    gen_server:call(Server, op).

-spec record_success(pid() | atom()) -> ok.
record_success(Server) ->
    gen_server:cast(Server, success).

-spec record_failure(pid() | atom()) -> ok.
record_failure(Pid) ->
    gen_server:cast(Pid, failure).

init(Opts) ->
    Threshold = maps:get(failure_threshold, Opts, 5),
    ResetTimeout = maps:get(reset_timeout, Opts, 30000),
    Model = maps:get(model, Opts, undefined),
    Op = maps:get(op, Opts, undefined),
    Ratio = maps:get(failure_ratio, Opts, undefined),
    WindowMaxMs = maps:get(window_max_ms, Opts, 60000),
    WindowMaxSize = maps:get(window_max_size, Opts, 50),
    MinAttempts = maps:get(min_attempts, Opts, 5),
    {ok, #state{
        cb_state = closed,
        failure_count = 0,
        failure_threshold = Threshold,
        window = queue:new(),
        window_max_ms = WindowMaxMs,
        window_max_size = WindowMaxSize,
        min_attempts = MinAttempts,
        failure_ratio = Ratio,
        reset_timeout = ResetTimeout,
        timer_ref = undefined,
        model = Model,
        op = Op
    }}.

handle_call(allow, _From, #state{cb_state = closed} = State) ->
    {reply, ok, State};
handle_call(allow, _From, #state{cb_state = half_open} = State) ->
    {reply, ok, State};
handle_call(allow, _From, #state{cb_state = open} = State) ->
    {reply, {error, circuit_open}, State};
handle_call(state, _From, #state{cb_state = CbState} = State) ->
    {reply, CbState, State};
handle_call(model, _From, #state{model = Model} = State) ->
    {reply, Model, State};
handle_call(op, _From, #state{op = Op} = State) ->
    {reply, Op, State};
handle_call(Request, _From, State) ->
    logger:warning("openrouter_circuit_breaker: unexpected call ~p",
                   [Request]),
    {reply, {error, unknown}, State}.

handle_cast(success, #state{cb_state = half_open} = State) ->
    emit_transition(half_open, closed, State),
    {noreply, State#state{cb_state = closed,
                          failure_count = 0,
                          window = queue:new(),
                          timer_ref = undefined}};
handle_cast(success, #state{cb_state = closed} = State) ->
    State1 = record_outcome(success, State),
    {noreply, State1};
handle_cast(success, State) ->
    {noreply, State};

handle_cast(failure, #state{cb_state = half_open} = State) ->
    emit_transition(half_open, open, State),
    cancel_timer(State#state.timer_ref),
    TimerRef = erlang:send_after(State#state.reset_timeout, self(),
                                 reset_timeout),
    {noreply, State#state{cb_state = open, timer_ref = TimerRef}};
handle_cast(failure, #state{cb_state = closed} = State) ->
    State1 = record_outcome(failure, State),
    case should_trip(State1) of
        true ->
            emit_transition(closed, open, State1),
            cancel_timer(State1#state.timer_ref),
            TimerRef = erlang:send_after(State1#state.reset_timeout, self(),
                                         reset_timeout),
            {noreply, State1#state{cb_state = open,
                                   window = queue:new(),
                                   timer_ref = TimerRef}};
        false ->
            {noreply, State1}
    end;
handle_cast(failure, State) ->
    %% Already open, ignore additional failures
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reset_timeout, #state{cb_state = open} = State) ->
    emit_transition(open, half_open, State),
    {noreply, State#state{cb_state = half_open, timer_ref = undefined}};
handle_info(reset_timeout, State) ->
    %% Stray timer from a previous cycle; already transitioned. Ignore.
    {noreply, State};
handle_info(Info, State) ->
    logger:warning("openrouter_circuit_breaker: unexpected info ~p",
                   [Info]),
    {noreply, State}.

record_outcome(Outcome, #state{window = W,
                               window_max_ms = MaxMs,
                               window_max_size = MaxSize,
                               failure_count = FC} = State) ->
    Now = erlang:monotonic_time(millisecond),
    W1 = queue:in({Now, Outcome}, W),
    W2 = prune_window(W1, Now - MaxMs, MaxSize),
    NewFC = case Outcome of
        success -> 0;
        failure -> FC + 1
    end,
    State#state{window = W2, failure_count = NewFC}.

prune_window(Q, MinTs, MaxSize) ->
    Q1 = drop_older_than(Q, MinTs),
    cap_size(Q1, MaxSize).

drop_older_than(Q, MinTs) ->
    case queue:peek(Q) of
        {value, {Ts, _}} when Ts < MinTs ->
            drop_older_than(queue:drop(Q), MinTs);
        _ ->
            Q
    end.

cap_size(Q, MaxSize) ->
    case queue:len(Q) > MaxSize of
        true -> cap_size(queue:drop(Q), MaxSize);
        false -> Q
    end.

should_trip(#state{failure_ratio = undefined,
                   failure_count = FC,
                   failure_threshold = FT}) when is_integer(FT), FT > 0 ->
    FC >= FT;
should_trip(#state{failure_ratio = Ratio,
                   min_attempts = Min,
                   window = W}) when is_float(Ratio); is_integer(Ratio) ->
    should_trip_ratio(W, Min, Ratio, queue:len(W));
should_trip(_) ->
    false.

should_trip_ratio(_W, Min, _Ratio, Total) when Total < Min ->
    false;
should_trip_ratio(W, _Min, Ratio, Total) ->
    failure_ratio_of(W, Total) >= Ratio.

failure_ratio_of(_W, 0) ->
    0.0;
failure_ratio_of(W, Total) ->
    Failures = lists:foldl(
        fun({_, failure}, Acc) -> Acc + 1;
           ({_, success}, Acc) -> Acc end,
        0, queue:to_list(W)),
    Failures / Total.

-ifdef(TEST).
%% Convenience wrapper used by eunit tests; production callers always
%% pass an already-known total.
failure_ratio_of(W) ->
    failure_ratio_of(W, queue:len(W)).
-endif.

emit_transition(From, To, #state{model = Model, op = Op}) ->
    openrouter_telemetry:event(
        [erl_openrouter, circuit_breaker, state_change],
        #{},
        #{from => From, to => To, model => Model, op => Op}).

cancel_timer(undefined) -> ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    %% Flush any already-delivered message
    receive reset_timeout -> ok after 0 -> ok end.
