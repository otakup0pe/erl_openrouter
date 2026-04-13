-module(openrouter_circuit_breaker).
-behaviour(gen_server).

-export([start_link/1]).
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

-spec allow(pid()) -> ok | {error, circuit_open}.
allow(Pid) ->
    gen_server:call(Pid, allow).

-spec state(pid()) -> closed | open | half_open.
state(Pid) ->
    gen_server:call(Pid, state).

-spec record_success(pid()) -> ok.
record_success(Pid) ->
    gen_server:cast(Pid, success).

-spec record_failure(pid()) -> ok.
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
    {noreply, State#state{cb_state = closed, failure_count = 0, timer_ref = undefined}};
handle_cast(success, #state{cb_state = closed} = State) ->
    {noreply, State#state{failure_count = 0}};
handle_cast(success, State) ->
    {noreply, State};

handle_cast(failure, #state{cb_state = half_open, reset_timeout = RT} = State) ->
    %% Half-open failure reopens the circuit
    TimerRef = erlang:send_after(RT, self(), reset_timeout),
    {noreply, State#state{cb_state = open, timer_ref = TimerRef}};
handle_cast(failure, #state{cb_state = closed, failure_count = FC,
                            failure_threshold = FT, reset_timeout = RT} = State) ->
    NewCount = FC + 1,
    case NewCount >= FT of
        true ->
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
    {noreply, State#state{cb_state = half_open, timer_ref = undefined}};
handle_info(Info, State) ->
    logger:warning("openrouter_circuit_breaker: unexpected info ~p",
                   [Info]),
    {noreply, State}.
