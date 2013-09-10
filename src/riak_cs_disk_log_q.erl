%% ---------------------------------------------------------------------
%%
%% Copyright (c) 2013 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------

-module(riak_cs_disk_log_q).

-ifdef(TEST).
-compile(export_all).
-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-endif.
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(QC_OUT(P),
        eqc:on_output(fun(Str, Args) -> io:format(user, Str, Args) end, P)).

-export([new/1, in/2, out/1, is_empty/1]).

-type disk_log() :: term().

-record(dlq, {
          dir :: string(),
          past :: disk_log(),
          past_n :: non_neg_integer(),
          past_terms = [] :: list(term()),
          past_cont = start :: term(),
          future :: disk_log(),
          future_n :: non_neg_integer()
         }).

new(ParentDir) ->
    filelib:ensure_dir(ParentDir ++ "/ignored"),
    
    {ok, Future} = open_future(ParentDir),
    Q = #dlq{dir = ParentDir,
             past = undefined, past_n = 0,
             future = Future,  future_n = 0},
    {ok, Q}.

in(Item, #dlq{future=F, future_n=FN}=Q) ->
    if FN rem 500 == 0 ->
            ok = disk_log:log(F, Item);
       true ->
            ok = disk_log:alog(F, Item)
    end,
    Q#dlq{future_n=FN + 1}.

out(#dlq{past_n=0, future_n=0} = Q) ->
    {empty, Q};
out(#dlq{past_n=0} = Q) ->
    out(past_to_present(Q));
out(#dlq{past=Past, past_terms=[], past_cont=Cont} = Q) ->
    %% io:format(user, "c", []),    % Useful to watch during QuickCheck tests
    case disk_log:chunk(Past, Cont) of
        eof ->
            io:format("TODO HEY, unexpected eof when past_n is ~p\n", [Q#dlq.past_n]),
            throw({todo, ?MODULE, ?LINE});
        T ->
            Cont2 = element(1, T),
            Terms = element(2, T),
            out(Q#dlq{past_terms=Terms, past_cont=Cont2})
    end;
out(#dlq{past_terms=[H|T], past_n=N}=Q) ->
    {{value, H}, Q#dlq{past_terms=T, past_n=N - 1}}.

is_empty(#dlq{past_n=0, future_n=0}) ->
    true;
is_empty(#dlq{}) ->
    false.

%%% Internal

name_past(ParentDir) ->
    ParentDir ++ "/past".

name_future(ParentDir) ->
    ParentDir ++ "/future".

open_past(ParentDir) ->
    open_disk_log(name_past(ParentDir), read_only).
    
open_future(ParentDir) ->
    open_disk_log(name_future(ParentDir), read_write).
    
past_to_present(#dlq{dir=ParentDir,
                     past=Past, past_n=PastN,
                     future=Future, future_n=FutureN} = Q) ->
    if PastN == 0 ->
            ok;
       true ->
            io:format("TODO HEY HEY, past_to_present: PastN is ~p\n", [PastN]),
            throw({todo, ?MODULE, ?LINE})
    end,
    %% io:format(user, "p", []),    % Useful to watch during QuickCheck tests
    NewPastN = FutureN,
    disk_log:close(Past),
    disk_log:close(Future),
    ok = file:rename(name_future(ParentDir), name_past(ParentDir)),
    {ok, NewPast} = open_past(ParentDir),
    {ok, NewFuture} = open_future(ParentDir),
    Q#dlq{past=NewPast, past_n=NewPastN, past_terms=[], past_cont=start,
          future=NewFuture, future_n=0}.

open_disk_log(Path, RWorRO) ->
    disk_log:open([{name, now()},
                   {file, Path},
                   {mode, RWorRO},
                   {type, halt},
                   {format, internal}]).

-ifdef(TEST).

smoke_test() ->
    Dir = "/tmp/" ++ atom_to_list(?MODULE),
    os:cmd("rm -rf " ++ Dir),
    {ok, Q0} = new(Dir),
    true = is_empty(Q0),

    Q10 = in(x, Q0),
    false = is_empty(Q10),
    {{value, x}, Q20} = out(Q10),
    true = is_empty(Q20),

    L_1 = [a,b,c,d,e],
    Q30 = lists:foldl(fun(X, Q) -> in(X, Q) end, Q20, L_1),
    {{value, a}, Q40} = out(Q30),
    L_2 = [f,g,h],
    Q50 = lists:foldl(fun(X, Q) -> in(X, Q) end, Q40, L_2),
    {Q60, SomeL} = lists:foldl(fun(_, {Q, Acc}) ->
                                       {{value, X}, Q2} = out(Q),
                                       {Q2, [X|Acc]}
                               end, {Q50, []}, [z,z,z,z,z,z,z]), % for b-h
    true = is_empty(Q60),
    true = (tl(L_1 ++ L_2) == lists:reverse(SomeL)),
    {empty, Q61} = out(Q60),                    % Q60 =/perhaps/= Q61
    true = is_empty(Q61),

    ok.

%% This is about 17 seconds on my laptop:
%% eqc:quickcheck(riak_cs_disk_log_q:prop_queue()).
%%
%% This is about 35 seconds on my laptop:
%% eqc:quickcheck(eqc_gen:resize(40, riak_cs_disk_log_q:prop_queue())).
%%
%% This is about 5 minutes on my laptop:
%% eqc:quickcheck(eqc:numtests(500, eqc_gen:resize(60, riak_cs_disk_log_q:prop_queue()))).

-ifdef(EQC).

quickcheck_test_() ->
    Time = 20,
    {spawn,
     [
      {timeout, Time*4,
       ?_assertEqual(
          true,
          eqc:quickcheck(
            ?QC_OUT(eqc:testing_time(
                      Time, eqc_gen:resize(
                              40, riak_cs_disk_log_q:prop_queue())))))}
     ]}.

prop_queue() ->
    ?FORALL(Cmds,
            gen_queue_commands(),
            true = run_qs_in_lockstep(Cmds)).

gen_queue_commands() ->
    list(frequency([{1,  is_empty},
                    {10, {in, gen_term()}},
                    {5,  out}])).

gen_term() ->
    X_bytes = 50*1024,
    X_int = 8*1000,
    X_bigint = 2*1000,
    oneof([?LET(Bytes,
                choose(0, X_bytes),
                list_to_binary(lists:duplicate(Bytes, $x))),
           ?LET(Size,
                choose(1, X_int),
                vector(Size, int())),
           ?LET(Size,
                choose(1, X_bigint),
                vector(Size, largeint()))]).

run_qs_in_lockstep(Cmds) ->
    Dir = "./delete-me.quickcheck-" ++ atom_to_list(?MODULE),
    os:cmd("rm -rf " ++ Dir),
    {ok, DLQ} = new(Dir),
    run_qs_in_lockstep(Cmds, queue:new(), DLQ).

run_qs_in_lockstep([], Q, DLQ) ->
    drain(Q, queue) == drain(DLQ, ?MODULE);
run_qs_in_lockstep([is_empty|Rest], Q, DLQ) ->
    case queue:is_empty(Q) == is_empty(DLQ) of
        true ->
            run_qs_in_lockstep(Rest, Q, DLQ);
        Else ->
            {bummer, is_empty, Else}
    end;
run_qs_in_lockstep([out|Rest], Q, DLQ) ->
    {Q_res, NewQ} = queue:out(Q),
    {DLQ_res, NewDLQ} = out(DLQ),
    if Q_res == DLQ_res ->
            run_qs_in_lockstep(Rest, NewQ, NewDLQ);
       true ->
            {bummer, out, Q_res, vs, DLQ_res}
    end;
run_qs_in_lockstep([{in, Term}|Rest], Q, DLQ) ->
    run_qs_in_lockstep(Rest, queue:in(Term, Q), in(Term, DLQ)).

drain(Q, Mod) ->
    case Mod:out(Q) of
        {empty, _} ->
            [];
        {{value, X}, NewQ} ->
            [X|drain(NewQ, Mod)]
    end.

-endif. %EQC

-endif. %TEST