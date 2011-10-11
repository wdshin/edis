%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @author Chad DePue <chad@inakanetworks.com>
%%% @copyright (C) 2011 InakaLabs SRL
%%% @doc edis Database
%%% @todo It's currently delivering all operations to the leveldb instance, i.e. no in-memory management
%%%       Therefore, operations like save/1 are not really implemented
%%% @todo We need to evaluate which calls should in fact be casts
%%% @todo We need to add info to INFO
%%% @end
%%%-------------------------------------------------------------------
-module(edis_db).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').
-author('Chad DePue <chad@inakanetworks.com>').

-behaviour(gen_server).

-include("edis.hrl").
-define(DEFAULT_TIMEOUT, 5000).
-define(RANDOM_THRESHOLD, 500).

-type item_type() :: string | hash | list | set | zset.
-type item_encoding() :: raw | int | ziplist | linkedlist | intset | hashtable | zipmap | skiplist.
-export_type([item_encoding/0, item_type/0]).

-record(state, {index               :: non_neg_integer(),
                db                  :: eleveldb:db_ref(),
                start_time          :: pos_integer(),
                accesses            :: dict(),
                last_save           :: float()}).
-opaque state() :: #state{}.

%% Administrative functions
-export([start_link/1, process/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Commands ========================================================================================
-export([ping/1, save/1, last_save/1, info/1, flush/0, flush/1, size/1]).
-export([append/3, decr/3, get/2, get_bit/3, get_range/4, get_and_set/3, incr/3, set/2, set/3,
         set_nx/2, set_nx/3, set_bit/4, set_ex/4, set_range/4, str_len/2]).
-export([del/2, exists/2, expire/3, expire_at/3, keys/2, move/3, encoding/2, idle_time/2, persist/2,
         random_key/1, rename/3, rename_nx/3]).

%% =================================================================================================
%% External functions
%% =================================================================================================
-spec start_link(non_neg_integer()) -> {ok, pid()}.
start_link(Index) ->
  gen_server:start_link({local, process(Index)}, ?MODULE, Index, []).

-spec process(non_neg_integer()) -> atom().
process(Index) ->
  list_to_atom("edis-db-" ++ integer_to_list(Index)).

%% =================================================================================================
%% Commands
%% =================================================================================================
-spec size(atom()) -> non_neg_integer().
size(Db) ->
  make_call(Db, size).

-spec flush() -> ok.
flush() ->
  lists:foreach(
    fun flush/1, [process(Index) || Index <- lists:seq(0, edis_config:get(databases) - 1)]).

-spec flush(atom()) -> ok.
flush(Db) ->
  make_call(Db, flush).

-spec ping(atom()) -> pong.
ping(Db) ->
  make_call(Db, ping).

-spec save(atom()) -> ok.
save(Db) ->
  make_call(Db, save).

-spec last_save(atom()) -> ok.
last_save(Db) ->
  make_call(Db, last_save).

-spec info(atom()) -> [{atom(), term()}].
info(Db) ->
  make_call(Db, info).

-spec append(atom(), binary(), binary()) -> pos_integer().
append(Db, Key, Value) ->
  make_call(Db, {append, Key, Value}).

-spec decr(atom(), binary(), integer()) -> integer().
decr(Db, Key, Decrement) ->
  make_call(Db, {decr, Key, Decrement}).

-spec get(atom(), binary()|[binary()]) -> undefined | binary().
get(Db, Key) when is_binary(Key) ->
  [Value] = get(Db, [Key]),
  Value;
get(Db, Keys) ->
  make_call(Db, {get, Keys}).

-spec get_bit(atom(), binary(), non_neg_integer()) -> 1|0.
get_bit(Db, Key, Offset) ->
  make_call(Db, {get_bit, Key, Offset}).

-spec get_range(atom(), binary(), integer(), integer()) -> binary().
get_range(Db, Key, Start, End) ->
  make_call(Db, {get_range, Key, Start, End}).

-spec get_and_set(atom(), binary(), binary()) -> undefined | binary().
get_and_set(Db, Key, Value) ->
  make_call(Db, {get_and_set, Key, Value}).

-spec incr(atom(), binary(), integer()) -> integer().
incr(Db, Key, Increment) ->
  make_call(Db, {incr, Key, Increment}).

-spec set(atom(), binary(), binary()) -> ok.
set(Db, Key, Value) ->
  set(Db, [{Key, Value}]).

-spec set(atom(), [{binary(), binary()}]) -> ok.
set(Db, KVs) ->
  make_call(Db, {set, KVs}).

-spec set_nx(atom(), binary(), binary()) -> ok.
set_nx(Db, Key, Value) ->
  set_nx(Db, [{Key, Value}]).

-spec set_nx(atom(), [{binary(), binary()}]) -> ok.
set_nx(Db, KVs) ->
  make_call(Db, {set_nx, KVs}).

-spec set_bit(atom(), binary(), non_neg_integer(), 1|0) -> 1|0.
set_bit(Db, Key, Offset, Bit) ->
  make_call(Db, {set_bit, Key, Offset, Bit}).

-spec set_ex(atom(), binary(), pos_integer(), binary()) -> ok.
set_ex(Db, Key, Seconds, Value) ->
  make_call(Db, {set_ex, Key, Seconds, Value}).

-spec set_range(atom(), binary(), pos_integer(), binary()) -> non_neg_integer().
set_range(Db, Key, Offset, Value) ->
  make_call(Db, {set_range, Key, Offset, Value}).

-spec str_len(atom(), binary()) -> non_neg_integer().
str_len(Db, Key) ->
  make_call(Db, {str_len, Key}).

-spec del(atom(), binary()) -> non_neg_integer().
del(Db, Keys) ->
  make_call(Db, {del, Keys}).

-spec exists(atom(), binary()) -> boolean().
exists(Db, Key) ->
  make_call(Db, {exists, Key}).

-spec expire(atom(), binary(), pos_integer()) -> boolean().
expire(Db, Key, Seconds) ->
  expire_at(Db, Key, edis_util:now() + Seconds).

-spec expire_at(atom(), binary(), pos_integer()) -> boolean().
expire_at(Db, Key, Timestamp) ->
  make_call(Db, {expire_at, Key, Timestamp}).

-spec keys(atom(), binary()) -> [binary()].
keys(Db, Pattern) ->
  make_call(Db, {keys, Pattern}).

-spec move(atom(), binary(), atom()) -> boolean().
move(Db, Key, NewDb) ->
  make_call(Db, {move, Key, NewDb}).

-spec encoding(atom(), binary()) -> undefined | item_encoding().
encoding(Db, Key) ->
  make_call(Db, {encoding, Key}).

-spec idle_time(atom(), binary()) -> undefined | non_neg_integer().
idle_time(Db, Key) ->
  make_call(Db, {idle_time, Key}).

-spec persist(atom(), binary()) -> boolean().
persist(Db, Key) ->
  make_call(Db, {persist, Key}).

-spec random_key(atom()) -> undefined | binary().
random_key(Db) ->
  make_call(Db, random_key).

-spec rename(atom(), binary(), binary()) -> ok.
rename(Db, Key, NewKey) ->
  make_call(Db, {rename, Key, NewKey}).

-spec rename_nx(atom(), binary(), binary()) -> ok.
rename_nx(Db, Key, NewKey) ->
  make_call(Db, {rename_nx, Key, NewKey}).

%% =================================================================================================
%% Server functions
%% =================================================================================================
%% @hidden
-spec init(non_neg_integer()) -> {ok, state()} | {stop, any()}.
init(Index) ->
  _ = random:seed(erlang:now()),
  case eleveldb:open("db/edis-" ++ integer_to_list(Index), [{create_if_missing, true}]) of
    {ok, Ref} ->
      {ok, #state{index = Index, db = Ref, last_save = edis_util:timestamp(),
                  start_time = edis_util:now(), accesses = dict:new()}};
    {error, Reason} ->
      ?THROW("Couldn't start level db #~p:~b\t~p~n", [Index, Reason]),
      {stop, Reason}
  end.

%% @hidden
-spec handle_call(term(), reference(), state()) -> {reply, ok | {ok, term()} | {error, term()}, state()} | {stop, {unexpected_request, term()}, {unexpected_request, term()}, state()}.
handle_call(save, _From, State) ->
  {reply, ok, State#state{last_save = edis_util:timestamp()}};
handle_call(last_save, _From, State) ->
  {reply, {ok, State#state.last_save}, State};
handle_call(ping, _From, State) ->
  {reply, {ok, pong}, State};
handle_call(info, _From, State) ->
  Version =
    case lists:keyfind(edis, 1, application:loaded_applications()) of
      false -> "0";
      {edis, _Desc, V} -> V
    end,
  {ok, Stats} = eleveldb:status(State#state.db, <<"leveldb.stats">>),
  {reply, {ok, [{edis_version, Version},
                {last_save, State#state.last_save},
                {db_stats, Stats}]}, %%TODO: add info
   State};
handle_call(flush, _From, State) ->
  ok = eleveldb:destroy("db/edis-" ++ integer_to_list(State#state.index), []),
  case init(State#state.index) of
    {ok, NewState} ->
      {reply, ok, NewState};
    {stop, Reason} ->
      {reply, {error, Reason}, State}
  end;
handle_call(size, _From, State) ->
  %%TODO: We need to 
  Now = edis_util:now(),
  Size = eleveldb:fold(
           State#state.db,
           fun({_Key, Bin}, Acc) ->
                   case erlang:binary_to_term(Bin) of
                     #edis_item{expire = Expire} when Expire >= Now ->
                       Acc + 1;
                     _ ->
                       Acc
                   end
           end, 0, [{fill_cache, false}]),
  {reply, {ok, Size}, State};
handle_call({append, Key, Value}, _From, State) ->
  Reply =
    update(State#state.db, Key, string, raw,
           fun(Item = #edis_item{value = OldV}) ->
                   NewV = <<OldV/binary, Value/binary>>,
                   {erlang:size(NewV), Item#edis_item{value = NewV}}
           end, <<>>),
  {reply, Reply, stamp(Key, State)};
handle_call({decr, Key, Decrement}, _From, State) ->
  Reply =
    update(State#state.db, Key, string, raw,
           fun(Item = #edis_item{value = OldV}) ->
                   try edis_util:binary_to_integer(OldV) of
                     OldInt ->
                       Res = OldInt - Decrement,
                       {Res, Item#edis_item{value = edis_util:integer_to_binary(Res)}}
                   catch
                     _:badarg ->
                       throw(bad_item_type)
                   end
           end, <<"0">>),
  {reply, Reply, stamp(Key, State)};
handle_call({get, Keys}, _From, State) ->
  Reply =
    lists:foldr(
      fun(Key, {ok, AccValues}) ->
              case get_item(State#state.db, string, Key) of
                #edis_item{type = string, value = Value} -> {ok, [Value | AccValues]};
                not_found -> {ok, [undefined | AccValues]};
                {error, bad_item_type} -> {ok, [undefined | AccValues]};
                {error, Reason} -> {error, Reason}
              end;
         (_, AccErr) -> AccErr
      end, {ok, []}, Keys),
  {reply, Reply, stamp(Keys, State)};
handle_call({get_bit, Key, Offset}, _From, State) ->
  Reply =
    case get_item(State#state.db, string, Key) of
      #edis_item{value =
                   <<_:Offset/unit:1, Bit:1/unit:1, _Rest/bitstring>>} -> {ok, Bit};
      #edis_item{} -> {ok, 0}; %% Value is shorter than offset
      not_found -> {ok, 0};
      {error, Reason} -> {error, Reason}
    end,
  {reply, Reply, stamp(Key, State)};
handle_call({get_range, Key, Start, End}, _From, State) ->
  Reply =
    try
      case get_item(State#state.db, string, Key) of
        #edis_item{value = Value} ->
          L = erlang:size(Value),
          StartPos =
            case Start of
              Start when Start >= L -> throw(empty);
              Start when Start >= 0 -> Start;
              Start when Start < (-1)*L -> 0;
              Start -> L + Start
            end,
          EndPos =
            case End of
              End when End >= 0, End >= L -> L - 1;
              End when End >= 0 -> End;
              End when End < (-1)*L -> 0;
              End -> L + End
            end,
          case EndPos - StartPos + 1 of
            Len when Len =< 0 -> {ok, <<>>};
            Len -> {ok, binary:part(Value, StartPos, Len)}
          end;
        not_found -> {ok, <<>>};
        {error, Reason} -> {error, Reason}
      end
    catch
      _:empty -> {ok, <<>>}
    end,
  {reply, Reply, stamp(Key, State)};
handle_call({get_and_set, Key, Value}, _From, State) ->
  Reply =
    update(State#state.db, Key, string, raw,
           fun(Item = #edis_item{value = OldV}) ->
                   {OldV, Item#edis_item{value = Value}}
           end, undefined),
  {reply, Reply, stamp(Key, State)};
handle_call({incr, Key, Increment}, _From, State) ->
  Reply =
    update(State#state.db, Key, string, raw,
           fun(Item = #edis_item{value = OldV}) ->
                   try edis_util:binary_to_integer(OldV) of
                     OldInt ->
                       Res = OldInt + Increment,
                       {Res, Item#edis_item{value = edis_util:integer_to_binary(Res)}}
                   catch
                     _:badarg ->
                       throw(bad_item_type)
                   end
           end, <<"0">>),
  {reply, Reply, stamp(Key, State)};
handle_call({set, KVs}, _From, State) ->
  Reply =
    eleveldb:write(State#state.db,
                   [{put, Key,
                     erlang:term_to_binary(
                       #edis_item{key = Key, encoding = raw,
                                  type = string, value = Value})} || {Key, Value} <- KVs],
                    []),
  {reply, Reply, stamp([K || {K, _} <- KVs], State)};
handle_call({set_nx, KVs}, _From, State) ->
  Reply =
    case lists:any(
           fun({Key, _}) ->
                   exists_item(State#state.db, Key)
           end, KVs) of
      true ->
        {reply, {error, already_exists}, State};
      false ->
        eleveldb:write(State#state.db,
                       [{put, Key,
                         erlang:term_to_binary(
                           #edis_item{key = Key, encoding = raw,
                                      type = string, value = Value})} || {Key, Value} <- KVs],
                       [])
    end,
  {reply, Reply, stamp([K || {K, _} <- KVs], State)};
handle_call({set_bit, Key, Offset, Bit}, _From, State) ->
  Reply =
    update(State#state.db, Key, string, raw,
           fun(Item = #edis_item{value = <<Prefix:Offset/unit:1, OldBit:1/unit:1, _Rest/bitstring>>}) ->
                   {OldBit,
                    Item#edis_item{value = <<Prefix:Offset/unit:1, Bit:1/unit:1, _Rest/bitstring>>}};
              (Item) when Bit == 0 -> %% Value is shorter than offset
                   {0, Item};
              (Item = #edis_item{value = Value}) when Bit == 1 -> %% Value is shorter than offset
                   BitsBefore = Offset - (erlang:size(Value) * 8),
                   BitsAfter = 7 - (Offset rem 8),
                   {0, Item#edis_item{value = <<Value/bitstring, 
                                                0:BitsBefore/unit:1,
                                                1:1/unit:1,
                                                0:BitsAfter/unit:1>>}}
           end, <<>>),
  {reply, Reply, stamp(Key, State)};
handle_call({set_ex, Key, Seconds, Value}, _From, State) ->
  Reply =
    eleveldb:put(
      State#state.db, Key,
      erlang:term_to_binary(
        #edis_item{key = Key, type = string, encoding = raw,
                   expire = edis_util:now() + Seconds,
                   value = Value}), []),
  {reply, Reply, stamp(Key, State)};
handle_call({set_range, Key, Offset, Value}, _From, State) ->
  Reply =
    case erlang:size(Value) of
      0 -> {ok, 0}; %% Copying redis behaviour even when documentation said different
      Length ->
        update(State#state.db, Key, string, raw,
               fun(Item = #edis_item{value = <<Prefix:Offset/binary, _:Length/binary, Suffix/binary>>}) ->
                       NewV = <<Prefix/binary, Value/binary, Suffix/binary>>,
                       {erlang:size(NewV), Item#edis_item{value = NewV}};
                  (Item = #edis_item{value = <<Prefix:Offset/binary, _/binary>>}) ->
                       NewV = <<Prefix/binary, Value/binary>>,
                       {erlang:size(NewV), Item#edis_item{value = NewV}};
                  (Item = #edis_item{value = Prefix}) ->
                       Pad = Offset - erlang:size(Prefix),
                       NewV = <<Prefix/binary, 0:Pad/unit:8, Value/binary>>,
                       {erlang:size(NewV), Item#edis_item{value = NewV}}
               end, <<>>)
    end,
  {reply, Reply, stamp(Key, State)};
handle_call({str_len, Key}, _From, State) ->
  Reply =
    case get_item(State#state.db, string, Key) of
      #edis_item{value = Value} -> {ok, erlang:size(Value)};
      not_found -> {ok, 0};
      {error, Reason} -> {error, Reason}
    end,
  {reply, Reply, stamp(Key, State)};
handle_call({del, Keys}, _From, State) ->
  DeleteActions =
      [{delete, Key} || Key <- Keys, exists_item(State#state.db, Key)],
  Reply =
    case eleveldb:write(State#state.db, DeleteActions, []) of
      ok -> {ok, length(DeleteActions)};
      {error, Reason} -> {error, Reason}
    end,
  {reply, Reply, stamp(Keys, State)};
handle_call({exists, Key}, _From, State) ->
  Reply =
      case exists_item(State#state.db, Key) of
        true -> {ok, true};
        false -> {ok, false};
        {error, Reason} -> {error, Reason}
      end,
  {reply, Reply, stamp(Key, State)};
handle_call({expire_at, Key, Timestamp}, _From, State) ->
  Reply =
      case edis_util:now() of
        Now when Timestamp =< Now -> %% It's a delete (it already expired)
          case exists_item(State#state.db, Key) of
            true ->
              case eleveldb:delete(State#state.db, Key, []) of
                ok ->
                  {ok, true};
                {error, Reason} ->
                  {error, Reason}
              end;
            false ->
              {ok, false}
          end;
        _ ->
          case update(State#state.db, Key, any,
                      fun(Item) ->
                              {ok, Item#edis_item{expire = Timestamp}}
                      end) of
            {ok, ok} ->
              {ok, true};
            {error, not_found} ->
              {ok, false};
            {error, Reason} ->
              {error, Reason}
          end
      end,
  {reply, Reply, stamp(Key, State)};
handle_call({keys, Pattern}, _From, State) ->
  Reply =
    case re:compile(Pattern) of
      {ok, Compiled} ->
        Now = edis_util:now(),
        Keys = eleveldb:fold(
                 State#state.db,
                 fun({Key, Bin}, Acc) ->
                         case re:run(Key, Compiled) of
                           nomatch ->
                             Acc;
                           _ ->
                             case erlang:binary_to_term(Bin) of
                               #edis_item{expire = Expire} when Expire >= Now ->
                                 [Key | Acc];
                               _ ->
                                 Acc
                             end
                         end
                 end, [], [{fill_cache, false}]),
        {ok, lists:reverse(Keys)};
      {error, {Reason, _Line}} when is_list(Reason) ->
        {error, "Invalid pattern: " ++ Reason};
      {error, Reason} ->
        {error, Reason}
    end,
  {reply, Reply, State};
handle_call({move, Key, NewDb}, _From, State) ->
  Reply =
    case get_item(State#state.db, string, Key) of
      not_found ->
        {ok, false};
      {error, Reason} ->
        {error, Reason};
      Item ->
        try make_call(NewDb, {recv, Item}) of
          ok ->
            case eleveldb:delete(State#state.db, Key, []) of
              ok ->
                {ok, true};
              {error, Reason} ->
                _ = make_call(NewDb, {del, [Key]}),
                {error, Reason}
            end
        catch
          _:found -> {ok, false};
          _:{error, Reason} -> {error, Reason}
        end
    end,
  {reply, Reply, stamp(Key, State)};
handle_call({recv, Item}, _From, State) ->
  Reply =
    case exists_item(State#state.db, Item#edis_item.key) of
      true -> {error, found};
      false -> eleveldb:put(State#state.db, Item#edis_item.key, erlang:term_to_binary(Item), [])
    end,
  {reply, Reply, stamp(Item#edis_item.key, State)};
handle_call({encoding, Key}, _From, State) ->
  Reply =
    case get_item(State#state.db, any, Key) of
      #edis_item{encoding = Encoding} -> {ok, Encoding};
      not_found -> {ok, undefined};
      {error, Reason} -> {error, Reason}
    end,
  {reply, Reply, State};
handle_call({idle_time, Key}, _From, State) ->
  Reply =
    case exists_item(State#state.db, Key) of
      true ->
        Offset =
          case dict:find(Key, State#state.accesses) of
            {ok, O} -> O;
            error -> 0
          end,
        {ok, edis_util:now() - Offset - State#state.start_time};
      false -> {ok, undefined};
      {error, Reason} -> {error, Reason}
    end,
  {reply, Reply, State};
handle_call({persist, Key}, _From, State) ->
  Reply =
    case update(State#state.db, Key, any,
                fun(Item) ->
                        {ok, Item#edis_item{expire = infinity}}
                end) of
      {ok, ok} ->
        {ok, true};
      {error, not_found} ->
        {ok, false};
      {error, Reason} ->
        {error, Reason}
    end,
  {reply, Reply, stamp(Key, State)};
handle_call(random_key, _From, State) ->
  Reply =
    case eleveldb:is_empty(State#state.db) of
      true -> undefined;
      false ->
        %%TODO: Make it really random... not just on the first xx tops
        %%      BUT we need to keep it O(1)
        RandomIndex = random:uniform(?RANDOM_THRESHOLD),
        key_at(State#state.db, RandomIndex)
    end,
  {reply, Reply, State};
handle_call({rename, Key, NewKey}, _From, State) ->
  Reply =
    case get_item(State#state.db, any, Key) of
      not_found ->
        {error, not_found};
      {error, Reason} ->
        {error, Reason};
      Item ->
        eleveldb:write(State#state.db,
                       [{delete, Key},
                        {put, NewKey,
                         erlang:term_to_binary(Item#edis_item{key = NewKey})}],
                       [])
    end,
  {reply, Reply, State};
handle_call({rename_nx, Key, NewKey}, _From, State) ->
  Reply =
    case get_item(State#state.db, any, Key) of
      not_found ->
        {error, not_found};
      {error, Reason} ->
        {error, Reason};
      Item ->
        case exists_item(State#state.db, NewKey) of
          true ->
            {error, already_exists};
          false ->
            eleveldb:write(State#state.db,
                           [{delete, Key},
                            {put, NewKey,
                             erlang:term_to_binary(Item#edis_item{key = NewKey})}],
                           [])
        end
    end,
  {reply, Reply, State};
handle_call(X, _From, State) ->
  {stop, {unexpected_request, X}, {unexpected_request, X}, State}.

%% @hidden
-spec handle_cast(X, state()) -> {stop, {unexpected_request, X}, state()}.
handle_cast(X, State) -> {stop, {unexpected_request, X}, State}.

%% @hidden
-spec handle_info(term(), state()) -> {noreply, state(), hibernate}.
handle_info(_, State) -> {noreply, State, hibernate}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_, _) -> ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% =================================================================================================
%% Private functions
%% =================================================================================================
%% @private
stamp([], State) -> State;
stamp([Key|Keys], State) ->
  stamp(Keys, stamp(Key, State));
stamp(Key, State) ->
  State#state{accesses =
                dict:store(Key, edis_util:now() -
                             State#state.start_time, State#state.accesses)}.

%% @private
exists_item(Db, Key) ->
  case eleveldb:get(Db, Key, []) of
    {ok, _} -> true;
    not_found -> false;
    {error, Reason} -> {error, Reason}
  end.

%% @private
get_item(Db, Type, Key) ->
  case eleveldb:get(Db, Key, []) of
    {ok, Bin} ->
      Now = edis_util:now(),
      case erlang:binary_to_term(Bin) of
        Item = #edis_item{type = T, expire = Expire}
          when Type =:= any orelse T =:= Type ->
          case Expire of
            Expire when Expire >= Now ->
              Item;
            _ ->
              _ = eleveldb:delete(Db, Key, []),
              not_found
          end;
        _Other -> {error, bad_item_type}
      end;
    not_found ->
      not_found;
    {error, Reason} ->
      {error, Reason}
  end.

%% @private
update(Db, Key, Type, Fun) ->
  try
    {Res, NewItem} =
      case get_item(Db, Type, Key) of
        not_found ->
          throw(not_found);
        {error, Reason} ->
          throw(Reason);
        Item ->
          Fun(Item)
      end,
    case eleveldb:put(Db, Key, erlang:term_to_binary(NewItem), []) of
      ok -> {ok, Res};
      {error, Reason2} -> {error, Reason2}
    end
  catch
    _:Error ->
      {error, Error}
  end.

%% @private
update(Db, Key, Type, Encoding, Fun, Default) ->
  try
    {Res, NewItem} =
      case get_item(Db, Type, Key) of
        not_found ->
          Fun(#edis_item{key = Key, type = Type, encoding = Encoding, value = Default});
        {error, Reason} ->
          throw(Reason);
        Item ->
          Fun(Item)
      end,
    case eleveldb:put(Db, Key, erlang:term_to_binary(NewItem), []) of
      ok -> {ok, Res};
      {error, Reason2} -> {error, Reason2}
    end
  catch
    _:Error ->
      {error, Error}
  end.

%% @private
key_at(Db, 0) ->
  try
    Now = edis_util:now(),
    eleveldb:fold(
      Db, fun({_Key, Bin}, Acc) ->
                  case erlang:binary_to_term(Bin) of
                    #edis_item{key = Key, expire = Expire} when Expire >= Now ->
                      throw({ok, Key});
                    _ ->
                      Acc
                  end
      end, {ok, undefined}, [{fill_cache, false}])
  catch
    _:{ok, Key} -> {ok, Key}
  end;
key_at(Db, Index) when Index > 0 ->
  try
    Now = edis_util:now(),
    NextIndex =
      eleveldb:fold(
        Db, fun({_Key, Bin}, 0) ->
                    case erlang:binary_to_term(Bin) of
                      #edis_item{key = Key, expire = Expire} when Expire >= Now ->
                        throw({ok, Key});
                      _ ->
                        0
                    end;
               (_, AccIndex) ->
                    AccIndex - 1
        end, Index, [{fill_cache, false}]),
    key_at(Db, NextIndex)
  catch
    _:{ok, Key} -> {ok, Key}
  end.

%% @private
make_call(Process, Request) ->
  make_call(Process, Request, ?DEFAULT_TIMEOUT).

%% @private
make_call(Process, Request, Timeout) ->
  ?DEBUG("CALL for ~p: ~p~n", [Process, Request]),
  ok = edis_db_monitor:notify(Process, Request),
  case gen_server:call(Process, Request, Timeout) of
    ok -> ok;
    {ok, Reply} -> Reply;
    {error, Error} ->
      ?THROW("Error trying ~p on ~p:~n\t~p~n", [Request, Process, Error]),
      throw(Error)
  end.