-module(openrouter_circuit_breaker).
%% @private

%% @doc Circuit breaker for upstream API calls.
%%
%% Tracks consecutive failures and trips open when a threshold is reached,
%% preventing further requests until a cooldown period expires.
%%
%% States:
%% <ul>
%%   <li>`closed' -- normal operation; requests are allowed.</li>
%%   <li>`open' -- tripped after `failure_threshold' consecutive failures;
%%       all requests are rejected with `{error, circuit_open}'.</li>
%%   <li>`half_open' -- entered after `reset_timeout' ms in the open state;
%%       one probe request is allowed. A success returns to closed; a
%%       failure re-opens the circuit.</li>
%% </ul>
%%
%% Defaults (overridable via the opts map passed to {@link start_link/1}):
%% <ul>
%%   <li>`failure_threshold' -- 5</li>
%%   <li>`reset_timeout' -- 30000 ms</li>
%% </ul>

-behaviour(gen_server).

-export([start_link/1, start_link/2]).
-export([allow/1, state/1, record_success/1, record_failure/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    cb_state :: closed | open | half_open,
    failure_count :: non_neg_integer(),
    failure_threshold :: pos_integer(),
    reset_timeout :: pos_integer(),
    timer_ref :: reference() | undefined
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

-spec record_success(pid() | atom()) -> ok.
record_success(Server) ->
    gen_server:cast(Server, success).

-spec record_failure(pid() | atom()) -> ok.
record_failure(Pid) ->
    gen_server:cast(Pid, failure).

%% gen_server callbacks

init(Opts) ->
    Threshold = maps:get(failure_threshold, Opts, 5),
    ResetTimeout = maps:get(reset_timeout, Opts, 30000),
    {ok, #state{
        cb_state = closed,
        failure_count = 0,
        failure_threshold = Threshold,
        reset_timeout = ResetTimeout,
        timer_ref = undefined
    }}.

handle_call(allow, _From, #state{cb_state = closed} = State) ->
    {reply, ok, State};
handle_call(allow, _From, #state{cb_state = half_open} = State) ->
    {reply, ok, State};
handle_call(allow, _From, #state{cb_state = open} = State) ->
    {reply, {error, circuit_open}, State};
handle_call(state, _From, #state{cb_state = CbState} = State) ->
    {reply, CbState, State};
handle_call(Request, _From, State) ->
    logger:warning("openrouter_circuit_breaker: unexpected call ~p",
                   [Request]),
    {reply, {error, unknown}, State}.

handle_cast(success, #state{cb_state = half_open} = State) ->
    openrouter_telemetry:event(
        [erl_openrouter, circuit_breaker, state_change],
        #{}, #{from => half_open, to => closed}),
    {noreply, State#state{cb_state = closed, failure_count = 0, timer_ref = undefined}};
handle_cast(success, #state{cb_state = closed} = State) ->
    {noreply, State#state{failure_count = 0}};
handle_cast(success, State) ->
    {noreply, State};

handle_cast(failure, #state{cb_state = half_open, reset_timeout = RT} = State) ->
    %% Half-open failure reopens the circuit
    openrouter_telemetry:event(
        [erl_openrouter, circuit_breaker, state_change],
        #{}, #{from => half_open, to => open}),
    cancel_timer(State#state.timer_ref),
    TimerRef = erlang:send_after(RT, self(), reset_timeout),
    {noreply, State#state{cb_state = open, timer_ref = TimerRef}};
handle_cast(failure, #state{cb_state = closed, failure_count = FC,
                            failure_threshold = FT, reset_timeout = RT} = State) ->
    NewCount = FC + 1,
    case NewCount >= FT of
        true ->
            openrouter_telemetry:event(
                [erl_openrouter, circuit_breaker, state_change],
                #{}, #{from => closed, to => open}),
            cancel_timer(State#state.timer_ref),
            TimerRef = erlang:send_after(RT, self(), reset_timeout),
            {noreply, State#state{cb_state = open, failure_count = NewCount, timer_ref = TimerRef}};
        false ->
            {noreply, State#state{failure_count = NewCount}}
    end;
handle_cast(failure, State) ->
    %% Already open, ignore additional failures
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(reset_timeout, #state{cb_state = open} = State) ->
    openrouter_telemetry:event(
        [erl_openrouter, circuit_breaker, state_change],
        #{}, #{from => open, to => half_open}),
    {noreply, State#state{cb_state = half_open, timer_ref = undefined}};
handle_info(reset_timeout, State) ->
    %% Stray timer from a previous cycle; already transitioned. Ignore.
    {noreply, State};
handle_info(Info, State) ->
    logger:warning("openrouter_circuit_breaker: unexpected info ~p",
                   [Info]),
    {noreply, State}.

cancel_timer(undefined) -> ok;
cancel_timer(Ref) ->
    _ = erlang:cancel_timer(Ref),
    %% Flush any already-delivered message
    receive reset_timeout -> ok after 0 -> ok end.
