%%  This Source Code Form is subject to the terms of the Mozilla Public
%%  License, v. 2.0. If a copy of the MPL was not distributed with this
%%  file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
-module(presence_exchange).
-include_lib("rabbit_common/include/rabbit.hrl").

-define(EXCHANGE_TYPE_BIN, <<"x-presence">>).
-define(LISTENER_KEY, <<"">>).

-behaviour(rabbit_exchange_type).

-rabbit_boot_step({?MODULE,
                   [{description, "exchange type x-presence"},
		    {mfa,         {rabbit_registry, register,
				   [exchange, ?EXCHANGE_TYPE_BIN, ?MODULE]}},
                    {requires,    rabbit_registry},
                    {enables,     kernel_ready}]}).

-export([description/0, serialise_events/0, route/2, route/3]).
-export([validate/1, validate_binding/2, create/2, delete/2,
         policy_changed/2,
         add_binding/3, remove_bindings/3, assert_args_equivalence/2]).
-export([info/1, info/2]).

info(_X) -> [].
info(_X, _) -> [].

encode_binding_delivery(DeliveryXName,
                        Action,
                        #binding{source = #resource{name = XName},
                                 key = BindingKey,
                                 destination = #resource{name = QName}}) ->
    Headers = [{<<"action">>, longstr, list_to_binary(atom_to_list(Action))},
               {<<"exchange">>, longstr, XName},
               {<<"queue">>, longstr, QName},
               {<<"key">>, longstr, BindingKey}],
    rabbit_basic:delivery(false,
                          rabbit_basic:message(
			    DeliveryXName, ?LISTENER_KEY,
			    [{headers, Headers}], <<>>),
			  undefined).

description() ->
    [{name, ?EXCHANGE_TYPE_BIN},
     {description, <<"Experimental Presence exchange">>}].

serialise_events() -> false.

route(_Exchange, _Delivery) ->
    [].
route(_Exchange, _Delivery, _X) ->
    [].

validate(_X) -> ok.
validate_binding(_X, _B) -> ok.
create(_Serial, _X) -> ok.
delete(_Serial, _X) -> ok.
policy_changed(_X1, _X2) -> ok.

%% This code is based on the publish/2 code in rabbit_basic.erl, with
%% the middle step of going through the exchange-type's route/2
%% callback (which in our case always returns []) eliminated.
%%
%% Essentially we're avoiding publishing through ourselves "from the
%% outside", and instead emitting messages as if they originated
%% within the exchange.
deliver(Delivery = #delivery{message = #basic_message{exchange_name = XName,
                                                      routing_keys = RoutingKeys}}) ->
    QueueNames = rabbit_router:match_routing_key(XName, RoutingKeys),
    Queues = rabbit_amqqueue:lookup_many(QueueNames),
    rabbit_amqqueue:deliver(Queues, Delivery).

announce_initial_bindings(XName, Dest) ->
    {ok, DestQueue} = rabbit_amqqueue:lookup(Dest),
    announce_initial_bindings(rabbit_binding:list_for_source(XName), XName, DestQueue).

announce_initial_bindings([], _XName, _Dest) ->
    ok;
announce_initial_bindings([#binding{key = <<>>} | Bs], XName, Dest) ->
    announce_initial_bindings(Bs, XName, Dest);
announce_initial_bindings([B | Bs], XName, Dest) ->
    Delivery = encode_binding_delivery(XName, bind, B),
    rabbit_amqqueue:deliver([Dest], Delivery),
    announce_initial_bindings(Bs, XName, Dest).

add_binding(none, #exchange{name = XName}, #binding{key = ?LISTENER_KEY,
                                                    destination = Dest,
                                                    args = ArgsTable}) ->
    case rabbit_misc:table_lookup(ArgsTable, <<"x-presence-exchange-summary">>) of
        {bool, false} -> ok;
        {_, 0} -> ok;
        _ -> %% either undefined or anything non-false and non-zero
            announce_initial_bindings(XName, Dest)
    end,
    ok;
add_binding(none, #exchange{name = XName}, B) ->
    deliver(encode_binding_delivery(XName, bind, B)),
    ok;
add_binding(transaction, _Exchange, _Binding) ->
    ok.

remove_bindings(Tx, X, Bs) ->
    [ok = remove_binding(Tx, X, B) || B <- Bs],
    ok.

remove_binding(none, _X, #binding{key = ?LISTENER_KEY}) ->
    ok;
remove_binding(none, #exchange{name = XName}, B) ->
    deliver(encode_binding_delivery(XName, unbind, B)),
    ok;
remove_binding(transaction, _X, _B) ->
    ok.

assert_args_equivalence(X, Args) ->
    rabbit_exchange:assert_args_equivalence(X, Args).
