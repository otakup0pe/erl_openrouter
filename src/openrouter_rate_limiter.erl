-module(openrouter_rate_limiter).
-behaviour(gen_server).

-export([start_link/1]).
-export([acquire/1, acquire/2, available/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    max_tokens :: pos_integer(),
    tokens :: non_neg_integer(),
    refill_interval :: pos_integer(),
    timer_ref :: reference() | undefined
}).

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

-spec acquire(pid()) -> ok | {error, rate_limited}.
acquire(Pid) ->
    acquire(Pid, 1).

-spec acquire(pid(), pos_integer()) -> ok | {error, rate_limited}.
acquire(Pid, Count) ->
    gen_server:call(Pid, {acquire, Count}).

-spec available(pid()) -> non_neg_integer().
available(Pid) ->
    gen_server:call(Pid, available).

%% gen_server callbacks

init(Opts) ->
    MaxTokens = maps:get(max_tokens, Opts, 10),
    RefillInterval = maps:get(refill_interval, Opts, 1000),
    TimerRef = erlang:send_after(RefillInterval, self(), refill),
    {ok, #state{
        max_tokens = MaxTokens,
        tokens = MaxTokens,
        refill_interval = RefillInterval,
        timer_ref = TimerRef
    }}.

handle_call({acquire, Count}, _From, #state{tokens = Tokens} = State) when Tokens >= Count ->
    {reply, ok, State#state{tokens = Tokens - Count}};
handle_call({acquire, _Count}, _From, State) ->
    {reply, {error, rate_limited}, State};
handle_call(available, _From, #state{tokens = Tokens} = State) ->
    {reply, Tokens, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(refill, #state{max_tokens = Max, refill_interval = Interval} = State) ->
    TimerRef = erlang:send_after(Interval, self(), refill),
    {noreply, State#state{tokens = Max, timer_ref = TimerRef}};
handle_info(_Info, State) ->
    {noreply, State}.
