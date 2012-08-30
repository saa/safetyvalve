%%%-------------------------------------------------------------------
%%% @author Jesper Louis Andersen <>
%%% @copyright (C) 2012, Jesper Louis Andersen
%%% @doc
%%%
%%% @end
%%% Created : 30 Aug 2012 by Jesper Louis Andersen <>
%%%-------------------------------------------------------------------
-module(sv_queue).

-behaviour(gen_server).

%% API
-export([start_link/2]).

-export([parse_configuration/1]).

-export([ask/1, done/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SERVER, ?MODULE). 

-record(conf, { hz, rate, token_limit, size, concurrency }).
-record(state, { conf,
                 queue,
                 tokens,
                 tasks }).

%%%===================================================================
%%% API
%%%===================================================================

%% @doc
%% Starts the server
%% @end
start_link(Name, Conf) ->
    gen_server:start_link({local, Name}, ?MODULE, [Conf], []).

parse_configuration(Conf) ->
    #conf { hz          = proplists:get_value(hz, Conf),
            rate        = proplists:get_value(rate, Conf),
            token_limit = proplists:get_value(token_limit, Conf),
            size        = proplists:get_value(size, Conf),
            concurrency = proplists:get_value(concurrency, Conf) }.

ask(Name) ->
    gen_server:call(Name, ask).

done(Name, Ref) ->
    gen_server:call(Name, {done, Ref}).

%%%===================================================================

%% @private
init([Conf]) ->
    case Conf#conf.hz of
        undefined -> ok;
        K when is_integer(K) ->
            repoll(Conf)
    end,
    {ok, #state{ conf = Conf,
                 queue = queue:new(),
                 tokens = Conf#conf.rate,
                 tasks = gb_sets:empty() }}.

%% @private
handle_call(ask, {Pid, _Tag}, #state { tokens = K,
                                       tasks = Tasks } = State) when K > 0 ->
    %% Let the guy run, since we have excess tokens:
    Ref = erlang:monitor(process, Pid),
    {reply, {go, Ref}, State#state { tokens = K-1,
                                     tasks  = gb_sets:add_element(Ref, Tasks) }};
handle_call(ask, From, #state { tokens = 0,
                                queue = Q } = State) ->
    %% No more tokens, queue the guy
    {noreply, State#state { queue = queue:in(From, Q) }};
handle_call({done, Ref}, _From, #state { tasks = Tasks } = State) ->
    erlang:demonitor(process, Ref),
    {reply, ok, State#state { tasks = gb_trees:del_element(Ref, Tasks)}};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', Ref, _, _, _}, #state { tasks = TS } = State) ->
    {noreply, State#state { tasks = gb_trees:del_element(Ref, TS) }};
handle_info(poll, #state { conf = C } = State) ->
    lager:debug("Poll invoked"),
    NewState = process_queue(refill_tokens(State)),
    repoll(C),
    {noreply, NewState};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%% @private
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================

%% @doc Try to use up tokens for queued items
%% @end
process_queue(#state { queue = Q, tokens = K, tasks = Ts } = State) ->
    {NK, NQ, NTs} = process_queue(K, Q, Ts),
    State#state { queue = NQ, tokens = NK, tasks = NTs }.

process_queue(0, Q, TS) -> {0, Q, TS};
process_queue(K, Q, TS) ->
    case queue:out(Q) of
        {value, {Pid, _} = From, Q2} ->
            Ref = erlang:monitor(process, Pid),
            gen_server:reply(From, {go, Ref}),
            process_queue(K-1, Q2, gb_sets:add_element(Ref, TS));
        {empty, Q2} ->
            {K, Q2, TS}
    end.

%% @doc Refill the tokens in the bucket
%% @end
refill_tokens(#state { tokens = K,
                       conf = #conf { rate = Rate,
                                      token_limit = TL }} = State) ->
    TokenCount = min(K + Rate, TL),
    State#state { tokens = TokenCount }.
    
repoll(#conf { hz = Hz }) ->
    erlang:send_after(Hz, self(), poll).