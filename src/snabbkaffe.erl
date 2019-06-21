-module(snabbkaffe).

%% API exports
-export([ start_trace/0
        , collect_trace/0
        , tp/2
        , start_stats_collection/0
        , analyse_statistics/0
        ]).

-export([ events_of_kind/2
        , projection/2
        , erase_timestamps/1
        , find_pairs/5
        , causality/5
        , unique/1
        , field_complete/3
        , inc_counters/2
        , dec_counters/2
        ]).

-export([ mk_all/1
        ]).

%%====================================================================
%% Types
%%====================================================================

-type kind() :: atom().

-type timestamp() :: integer().

-type event() ::
        #{ kind := kind()
         , _ => _
         }.

-type timed_event() ::
        #{ kind := kind()
         , ts   := timestamp()
         , _ => _
         }.

-type trace() :: [event()].

-type maybe_pair() :: {pair, event(), event()}
                    | {singleton, event()}.

-type maybe(A) :: {just, A} | nothing.

-export_type([ kind/0, timestamp/0, event/0, timed_event/0, trace/0
             , maybe_pair/0, maybe/1
             ]).

-define(STATS_TABLE, snabbkaffe_stats_table).

%%====================================================================
%% API functions
%%====================================================================

-spec tp(atom(), map()) -> ok.
tp(Kind, Event) ->
  Event1 = Event #{ ts   => os:system_time()
                  , kind => Kind
                  },
  gen_server:cast(snabbkaffe_collector, Event1).

-spec collect_trace() -> trace().
collect_trace() ->
  snabbkaffe_collector:get_trace().

-spec start_trace() -> ok.
start_trace() ->
  {ok, _} = snabbkaffe_collector:start_link(),
  ok.

%% @doc Extract events of certain kind(s) from the trace
-spec events_of_kind(kind() | [kind()], trace()) -> trace().
events_of_kind(Kind, Events) when is_atom(Kind) ->
  events_of_kind([Kind], Events);
events_of_kind(Kinds, Events) ->
  [E || E = #{kind := Kind} <- Events, lists:member(Kind, Kinds)].

-spec projection([atom()] | all, trace()) -> trace().
projection(all, Trace) ->
  Trace;
projection(Fields, Trace) ->
  [maps:with(Fields, I) || I <- Trace].

-spec erase_timestamps(trace()) -> trace().
erase_timestamps(Trace) ->
  [maps:without([ts], I) || I <- Trace].

%% @doc Find pairs of complimentary events
-spec find_pairs( boolean()
                , fun((event()) -> boolean())
                , fun((event()) -> boolean())
                , fun((event(), event()) -> boolean())
                , trace()
                ) -> [maybe_pair()].
find_pairs(Strict, CauseP, EffectP, Guard, L) ->
  Fun = fun(A) ->
            C = fun_matches1(CauseP, A),
            E = fun_matches1(EffectP, A),
            if C orelse E ->
                {true, {A, C, E}};
               true ->
                false
            end
        end,
  L1 = lists:filtermap(Fun, L),
  do_find_pairs(Strict, Guard, L1).

%%====================================================================
%% CT overhauls
%%====================================================================

%% @doc Implement `all/0' callback for Common Test
-spec mk_all(module()) -> [atom() | {group, atom()}].
mk_all(Module) ->
  io:format(user, "Module: ~p", [Module]),
  Groups = try Module:groups()
           catch
             error:undef -> []
           end,
  [{group, element(1, I)} || I <- Groups] ++
  [F || {F, _A} <- Module:module_info(exports),
        case atom_to_list(F) of
          "t_" ++ _ -> true;
          _         -> false
        end].

%%====================================================================
%% Statistical functions
%%====================================================================

-spec start_stats_collection() -> ok.
start_stats_collection() ->
  catch ets:delete(?STATS_TABLE),
  ets:new(?STATS_TABLE, [named_table, public]),
  ok.

analyse_statistics() ->
  ok.
   %% Kinds = lists:append(ets:lookup(?STATS_TABLE, '$kinds')),
   %% Stats = ets:tab2list(?STATS_TABLE),
   %% Kinds =
   %% case ets:first(?STATS_TABLE) of
   %%    '$end_of_table' ->
   %%       io:format(user, "No statistics.~n", []),
   %%       ok;
   %%    _ ->
   %%       io:format(user, "Scheduling:~n", []),
   %%       analyse_statistics(?SHEDULE_STATS_TABLE),
   %%       io:format(user, "Extention:~n", []),
   %%       analyse_statistics(?EXPAND_STATS_TABLE)
   %% end.

%%====================================================================
%% Checks
%%====================================================================

-spec causality( boolean()
               , fun((event()) -> ok)
               , fun((event()) -> ok)
               , fun((event(), event()) -> boolean())
               , trace()
               ) -> ok.
causality(Strict, CauseP, EffectP, Guard, Trace) ->
  Pairs = find_pairs(true, CauseP, EffectP, Guard, Trace),
  if Strict ->
      [panic("Cause without effect: ~p", [I])
       || {singleton, I} <- Pairs];
     true ->
      ok
  end,
  ok.

-spec unique(trace()) -> ok.
unique(Trace) ->
  Trace1 = erase_timestamps(Trace),
  Fun = fun(A, Acc) -> inc_counters([A], Acc) end,
  Counters = lists:foldl(Fun, #{}, Trace1),
  Dupes = [E || E = {_, Val} <- maps:to_list(Counters), Val > 1],
  case Dupes of
    [] ->
      ok;
    _ ->
      panic("Duplicate elements found: ~p", [Dupes])
  end.

-spec field_complete(atom(), trace(), [term()]) -> ok.
field_complete(Field, Trace, Expected) ->
  Got = ordsets:from_list([Val || #{Field := Val} <- Trace]),
  Expected1 = ordsets:from_list(Expected),
  case ordsets:subtract(Expected1, Got) of
    [] ->
      ok;
    Missing ->
      panic("Trace is missing elements: ~p", [Missing])
  end.

%%====================================================================
%% Internal functions
%%====================================================================

-spec panic(string(), [term()]) -> no_return().
panic(FmtString, Args) ->
  throw({panic, FmtString, Args}).

-spec do_find_pairs( boolean()
                   , fun((event(), event()) -> boolean())
                   , [{event(), boolean(), boolean()}]
                   ) -> [maybe_pair()].
do_find_pairs(_Strict, _Guard, []) ->
  [];
do_find_pairs(Strict, Guard, [{A, C, E}|T]) ->
  FindEffect = fun({B, _, true}) ->
                   fun_matches2(Guard, A, B);
                  (_) ->
                   false
               end,
  case {C, E} of
    {true, _} ->
      case take(FindEffect, T) of
        {{B, _, _}, T1} ->
          [{pair, A, B}|do_find_pairs(Strict, Guard, T1)];
        T1 ->
          [{singleton, A}|do_find_pairs(Strict, Guard, T1)]
      end;
    {false, true} when Strict ->
      panic("Effect occures before cause: ~p", [A]);
    _ ->
      do_find_pairs(Strict, Guard, T)
  end.

-spec inc_counters([Key], Map) -> Map
        when Map :: #{Key => integer()}.
inc_counters(Keys, Map) ->
  Inc = fun(V) -> V + 1 end,
  lists:foldl( fun(Key, Acc) ->
                   maps:update_with(Key, Inc, 1, Acc)
               end
             , Map
             , Keys
             ).

-spec dec_counters([Key], Map) -> Map
        when Map :: #{Key => integer()}.
dec_counters(Keys, Map) ->
  Dec = fun(V) -> V - 1 end,
  lists:foldl( fun(Key, Acc) ->
                   maps:update_with(Key, Dec, -1, Acc)
               end
             , Map
             , Keys
             ).

-spec fun_matches1(fun((A) -> boolean()), A) -> boolean().
fun_matches1(Fun, A) ->
  try Fun(A)
  catch
    error:function_clause -> false
  end.

-spec fun_matches2(fun((A, B) -> boolean()), A, B) -> boolean().
fun_matches2(Fun, A, B) ->
  try Fun(A, B)
  catch
    error:function_clause -> false
  end.

-spec take(fun((A) -> boolean()), [A]) -> {A, [A]} | [A].
take(Pred, L) ->
  take(Pred, L, []).

take(_Pred, [], Acc) ->
  lists:reverse(Acc);
take(Pred, [A|T], Acc) ->
  case Pred(A) of
    true ->
      {A, lists:reverse(Acc) ++ T};
    false ->
      take(Pred, T, [A|Acc])
  end.

%% analyse_statistics(Table) ->
%%   Stats0 = [{Key, bear:get_statistics(Vals)}
%%             || {Key, Vals} <- lists:keysort(1, ets:tab2list(Table))
%%            ],
%%   Stats = lists:filter( fun({_, Val}) ->
%%                             proplists:get_value(n, Val) > 0
%%                         end
%%                       , Stats0
%%                       ),
%%   io:format(user, "     N    min      max       avg~n", []),
%%   lists:foreach( fun({Key, Stats}) ->
%%                      io:format(user, "~6b ~f ~f ~f~n",
%%                                [ Key
%%                                , proplists:get_value(min, Stats) * 1.0
%%                                , proplists:get_value(max, Stats) * 1.0
%%                                , proplists:get_value(arithmetic_mean, Stats) * 1.0
%%                                ])
%%                  end
%%                , Stats
%%                ),
%%   {_, Last} = lists:last(Stats),
%%   io:format(user, "Stats:~n~p~n", [Last]).
