-module(rabbit_fifo_dlx_SUITE).

-compile(nowarn_export_all).
-compile(export_all).

% -include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbit/src/rabbit_fifo.hrl").
-include_lib("rabbit/src/rabbit_fifo_dlx.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [
     {group, tests}
    ].


groups() ->
    [
     {tests, [], [handler_undefined,
                  handler_at_most_once,
                  discard_dlx_consumer,
                  purge,
                  switch_strategies,
                  last_consumer_wins]}
    ].

init_per_suite(Config) ->
    Config.

end_per_suite(_Config) ->
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

handler_undefined(_Config) ->
    S = rabbit_fifo_dlx:init(),
    Handler = undefined,
    ?assertEqual({S, []}, rabbit_fifo_dlx:discard([make_msg(1)], because, Handler, S)),
    ok.

handler_at_most_once(_Config) ->
    S = rabbit_fifo_dlx:init(),
    Handler = {at_most_once, {m, f, [a]}},
    {S, Effects} = rabbit_fifo_dlx:discard([make_msg(1),
                                            make_msg(2)], because, Handler, S),
    ?assertMatch([{log, [1, 2], _}], Effects),
    ok.

discard_dlx_consumer(_Config) ->
    Handler = at_least_once,
    S0 = rabbit_fifo_dlx:init(),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 0,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 0}, rabbit_fifo_dlx:overview(S0)),

    %% message without dlx consumer
    {S1, []} = rabbit_fifo_dlx:discard([make_msg(1)], because, Handler, S0),
    {S2, []} = rabbit_fifo_dlx:checkout(Handler, S1),
    ?assertEqual(#{num_discarded => 1,
                   num_discard_checked_out => 0,
                   discard_message_bytes => 1,
                   discard_checkout_message_bytes => 0}, rabbit_fifo_dlx:overview(S2)),

    %% with dlx consumer
    Checkout = rabbit_fifo_dlx:make_checkout(self(), 2),
    {S3, []} = rabbit_fifo_dlx:apply(meta(2), Checkout, Handler, S2),
    {S4, DeliveryEffects0} = rabbit_fifo_dlx:checkout(Handler, S3),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 1,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 1}, rabbit_fifo_dlx:overview(S4)),
    ?assertMatch([{log, [1], _}], DeliveryEffects0),

    %% more messages than dlx consumer's prefetch
    {S5, []} = rabbit_fifo_dlx:discard([make_msg(3), make_msg(4)], because, Handler, S4),
    {S6, DeliveryEffects1} = rabbit_fifo_dlx:checkout(Handler, S5),
    ?assertEqual(#{num_discarded => 1,
                   num_discard_checked_out => 2,
                   discard_message_bytes => 1,
                   discard_checkout_message_bytes => 2}, rabbit_fifo_dlx:overview(S6)),
    ?assertMatch([{log, [3], _}], DeliveryEffects1),
    ?assertEqual({3, 3}, rabbit_fifo_dlx:stat(S6)),

    %% dlx consumer acks messages
    Settle = rabbit_fifo_dlx:make_settle([0,1]),
    {S7, []} = rabbit_fifo_dlx:apply(meta(5), Settle, Handler, S6),
    {S8, DeliveryEffects2} = rabbit_fifo_dlx:checkout(Handler, S7),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 1,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 1}, rabbit_fifo_dlx:overview(S8)),
    ?assertMatch([{log, [4], _}], DeliveryEffects2),
    ?assertEqual({1, 1}, rabbit_fifo_dlx:stat(S8)),
    ok.

purge(_Config) ->
    Handler = at_least_once,
    S0 = rabbit_fifo_dlx:init(),
    Checkout = rabbit_fifo_dlx:make_checkout(self(), 1),
    {S1, _} = rabbit_fifo_dlx:apply(meta(1), Checkout, Handler, S0),
    Msgs = [make_msg(2), make_msg(3)],
    {S2, _} = rabbit_fifo_dlx:discard(Msgs, because, Handler, S1),
    {S3, _} = rabbit_fifo_dlx:checkout(Handler, S2),
    ?assertMatch(#{num_discarded := 1,
                   num_discard_checked_out := 1}, rabbit_fifo_dlx:overview(S3)),

    S4 = rabbit_fifo_dlx:purge(S3),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 0,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 0}, rabbit_fifo_dlx:overview(S4)),
    ok.

switch_strategies(_Config) ->
    QRes = #resource{virtual_host = <<"/">>,
                     kind = queue,
                     name = <<"blah">>},
    Handler0 = undefined,
    Handler1 = at_least_once,
    {ok, _} = rabbit_fifo_dlx_sup:start_link(),
    S0 = rabbit_fifo_dlx:init(),

    %% Switching from undefined to at_least_once should start dlx consumer.
    {S1, Effects} = rabbit_fifo_dlx:update_config(Handler0, Handler1, QRes, S0),
    ?assertEqual([{aux, {dlx, setup}}], Effects),
    rabbit_fifo_dlx:handle_aux(leader, {dlx, setup}, fake_aux, QRes, Handler1, S1),
    [{_, WorkerPid, worker, _}] = supervisor:which_children(rabbit_fifo_dlx_sup),
    {S2, _} = rabbit_fifo_dlx:discard([make_msg(1)], because, Handler1, S1),
    Checkout = rabbit_fifo_dlx:make_checkout(WorkerPid, 1),
    {S3, _} = rabbit_fifo_dlx:apply(meta(2), Checkout, Handler1, S2),
    {S4, _} = rabbit_fifo_dlx:checkout(Handler1, S3),
    ?assertMatch(#{num_discard_checked_out := 1}, rabbit_fifo_dlx:overview(S4)),

    %% Switching from at_least_once to undefined should terminate dlx consumer.
    {S5, []} = rabbit_fifo_dlx:update_config(Handler1, Handler0, QRes, S4),
    ?assertMatch([_, {active, 0}, _, _],
                 supervisor:count_children(rabbit_fifo_dlx_sup)),
    ?assertMatch(#{num_discarded := 0}, rabbit_fifo_dlx:overview(S5)),
    ok.

last_consumer_wins(_Config) ->
    S0 = rabbit_fifo_dlx:init(),
    Handler = at_least_once,
    Msgs = [make_msg(1), make_msg(2), make_msg(3), make_msg(4)],
    {S1, []} = rabbit_fifo_dlx:discard(Msgs, because, Handler, S0),
    Checkout = rabbit_fifo_dlx:make_checkout(self(), 10),
    {S2, []} = rabbit_fifo_dlx:apply(meta(5), Checkout, Handler, S1),
    {S3, DeliveryEffects0} = rabbit_fifo_dlx:checkout(Handler, S2),
    ?assertMatch([{log, [1, 2, 3, 4], _}], DeliveryEffects0),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 4,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 4}, rabbit_fifo_dlx:overview(S3)),

    %% When another (or the same) consumer (re)subscribes,
    %% we expect this new consumer to be checked out and delivered all messages
    %% from the previous consumer.
    {S4, []} = rabbit_fifo_dlx:apply(meta(6), Checkout, Handler, S3),
    {S5, DeliveryEffects1} = rabbit_fifo_dlx:checkout(Handler, S4),
    ?assertMatch([{log, [1, 2, 3, 4], _}], DeliveryEffects1),
    ?assertEqual(#{num_discarded => 0,
                   num_discard_checked_out => 4,
                   discard_message_bytes => 0,
                   discard_checkout_message_bytes => 4}, rabbit_fifo_dlx:overview(S5)),
    ok.

make_msg(RaftIdx) ->
    ?INDEX_MSG(RaftIdx, ?DISK_MSG(1)).

meta(Idx) ->
    #{index => Idx,
      term => 1,
      system_time => 0,
      from => {make_ref(), self()}}.