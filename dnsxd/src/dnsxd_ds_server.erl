%% -------------------------------------------------------------------
%%
%% Copyright (c) 2011 Andrew Tunnell-Jones. All Rights Reserved.
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
%% -------------------------------------------------------------------
-module(dnsxd_ds_server).
-include("dnsxd.hrl").
-behaviour(gen_server).

%% API
-export([start_link/0, ets_memory/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

%% zone management
-export([load_zone/1, reload_zone/1, delete_zone/1, zone_loaded/1]).

%% querying
-export([zone_for_name/1, get_zone/1, find_zone/1, get_key/1]).

-define(SERVER, ?MODULE).

-define(TAB_INDEX, dnsxd_ds_index).
-define(TAB_CAT, dnsxd_ds_catalog).
-define(TAB_SW, dnsxd_ds_serials).

-record(state, {llq_count = 0}).
-record(index, {hash, soa = false, count = 1, domain}).
-record(sw, {zonename, ref, serials}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() -> gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

load_zone(#dnsxd_zone{} = Zone) -> gen_server:call(?SERVER, {load_zone, Zone}).

reload_zone(#dnsxd_zone{} = Zone) ->
    gen_server:call(?SERVER, {reload_zone, Zone}).

delete_zone(ZoneName) -> gen_server:call(?SERVER, {delete_zone, ZoneName}).

zone_for_name(Name) ->
    Labels = lists:reverse(dns:dname_to_labels(dns:dname_to_lower(Name))),
    zone_for_name(undefined, <<>>, Labels).

zone_for_name(undefined, _PrevHash, []) -> undefined;
zone_for_name(LastDom, _PrevHash, []) -> LastDom;
zone_for_name(LastDom, PrevHash, [Label|Labels]) ->
    Hash = crypto:sha([Label, PrevHash]),
    case ets:lookup(?TAB_INDEX, Hash) of
	[#index{hash = Hash, soa = false, count = Count}] when Count > 0 ->
	    zone_for_name(LastDom, Hash, Labels);
	[#index{hash = Hash, soa = true, count = Count, domain = Dom}]
	  when Count > 0 ->
	    zone_for_name(Dom, Hash, Labels);
	_ when LastDom =:= <<>> -> undefined;
	_ -> LastDom
    end.

get_zone(Name) ->
    case ets:lookup(?TAB_CAT, Name) of
	[Result] -> Result;
	[] -> undefined
    end.

find_zone(Name) ->
    case zone_for_name(Name) of
	undefined -> undefined;
	SOAName -> get_zone(SOAName)
    end.

get_key(KeyName) ->
    [KeyLabel|ZoneLabels] = dns:dname_to_labels(dns:dname_to_lower(KeyName)),
    ZoneName = join_labels(ZoneLabels),
    case ets:lookup(?TAB_CAT, ZoneName) of
	[#dnsxd_zone{tsig_keys = Keys}] ->
	    case lists:keyfind(KeyLabel, #dnsxd_tsig_key.name, Keys) of
		#dnsxd_tsig_key{} = Key -> {ZoneName, Key};
		false -> undefined
	    end;
	[] -> undefined
    end.

ets_memory() ->
    Tabs = [?TAB_INDEX, ?TAB_CAT, ?TAB_SW],
    WordSize = erlang:system_info(wordsize),
    Fun = fun(Tab, Acc) ->
		  TabSize = ets:info(Tab, memory) * WordSize,
		  {{Tab, TabSize}, TabSize + Acc}
	  end,
    {TabSizes, Total} = lists:mapfoldl(Fun, 0, Tabs),
    [{total, Total}|TabSizes].

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ?TAB_INDEX = ets:new(?TAB_INDEX, [named_table, {keypos, #index.hash}]),
    ?TAB_CAT = ets:new(?TAB_CAT, [named_table, {keypos, #dnsxd_zone.name}]),
    ?TAB_SW = ets:new(?TAB_SW, [named_table, {keypos, #sw.zonename}]),
    {ok, #state{}}.

handle_call({load_zone, #dnsxd_zone{name = ZoneName} = Zone}, _From, State) ->
    Reply = case zone_loaded(ZoneName) of
		true -> {error, loaded};
		false -> insert_zone(Zone)
	    end,
    {reply, Reply, State};
handle_call({reload_zone, #dnsxd_zone{} = Zone}, _From, State) ->
    Reply =  insert_zone(Zone),
    {reply, Reply, State};
handle_call({delete_zone, ZoneName}, _From, State) ->
    Reply = case zone_loaded(ZoneName) of
		true ->
		    ok = remove_from_index(ZoneName),
		    true = ets:delete(?TAB_CAT, ZoneName),
		    ok = cancel_serial_change(ZoneName);
		false ->
		    {error, not_loaded}
	    end,
    {reply, Reply, State};
handle_call(Request, _From, State) ->
    ?DNSXD_ERR("Stray call:~n~p~nState:~n~p~n", [Request, State]),
    {noreply, State}.

handle_cast(Msg, State) ->
    ?DNSXD_ERR("Stray cast:~n~p~nState:~n~p~n", [Msg, State]),
    {noreply, State}.

handle_info({serial_change, ZoneName}, #state{} = State) ->
    case ets:lookup(?TAB_SW, ZoneName) of
	[#sw{zonename = ZoneName, serials = Serials}] ->
	    ok = dnsxd_llq_manager:zone_changed(ZoneName),
	    ok = setup_serial_change(ZoneName, Serials);
	[] -> ok
    end,
    {noreply, State};
handle_info(Info, State) ->
    ?DNSXD_ERR("Stray message:~n~p~nState:~n~p~n", [Info, State]),
    {noreply, State}.

terminate(_Reason, _State) -> ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

zone_loaded(ZoneName) -> ets:member(?TAB_CAT, ZoneName).

insert_zone(#dnsxd_zone{name = ZoneName} = Zone) ->
    AlreadyLoaded = zone_loaded(ZoneName),
    true = ets:insert(?TAB_CAT, dnsxd_zone:prepare(Zone)),
    case AlreadyLoaded of
	true -> ok;
	false -> ok = add_to_index(ZoneName)
    end,
    ok = setup_serial_change(Zone),
    ok = dnsxd_llq_manager:zone_changed(ZoneName).

setup_serial_change(#dnsxd_zone{name = ZoneName, serials = Serials}) ->
    setup_serial_change(ZoneName, Serials).

setup_serial_change(ZoneName, Serials) ->
    case ets:lookup(?TAB_SW, ZoneName) of
	[#sw{ref = OldRef}] when is_reference(OldRef) ->
	    ok = dnsxd_lib:cancel_timer(OldRef);
	_ -> ok
    end,
    Now = dns:unix_time(),
    FutureSerials = [ Serial || Serial <- lists:sort(Serials), Serial > Now ],
    case FutureSerials of
	[NextSerial|_] when NextSerial > 4294967295 ->
	    %% Some folks set their DNSSEC keys (particularly KSKs) to expire
	    %% well into the future so that for all intents, they never expire.
	    Delay = (NextSerial - Now) * 1000,
	    Ref = erlang:send_after(Delay, self(), {serial_change, ZoneName}),
	    ets:insert(?TAB_SW, #sw{zonename = ZoneName, ref = Ref,
				    serials = FutureSerials}),
	    ok;
	_ -> ok
    end.

cancel_serial_change(ZoneName) ->
    case ets:lookup(?TAB_SW, ZoneName) of
	[#sw{ref = Ref}] when is_reference(Ref) ->
	    ok = dnsxd_lib:cancel_timer(Ref);
	_ -> ok
    end.

add_to_index(Name) ->
    [SOAHash|AscHashes] = index_hashes(Name),
    Index = case ets:lookup(?TAB_INDEX, SOAHash) of
		[#index{hash = SOAHash, count = Count} = OldIndex] ->
		    OldIndex#index{soa = true, count = Count + 1,
				   domain = Name};
		[] ->
		    #index{hash = SOAHash, soa = true, domain = Name}
	    end,
    true = ets:insert(?TAB_INDEX, Index),
    lists:foreach(
      fun(<<>>) -> ok;
	 (Hash) ->
	      case ets:lookup(?TAB_INDEX, Hash) of
		  [#index{hash = Hash}] ->
		      ets:update_counter(?TAB_INDEX, Hash, {#index.count, 1});
		  [] ->
		      ets:insert(?TAB_INDEX, #index{hash = Hash})
	      end
      end, AscHashes).

remove_from_index(ZoneName) ->
    [SOAHash|AscHashes] = index_hashes(ZoneName),
    case ets:lookup(?TAB_INDEX, SOAHash) of
	[#index{soa = true, hash = SOAHash, count = Count} = OldIndex]
	  when Count > 1 ->
	    NewIndex = OldIndex#index{count = Count - 1, soa = false},
	    true = ets:insert(?TAB_INDEX, NewIndex);
	[_] -> true = ets:delete(?TAB_INDEX, SOAHash)
    end,
    lists:foreach(
      fun(<<>>) -> ok;
	 (Hash) ->
	      case ets:update_counter(?TAB_INDEX, Hash, {#index.count, -1}) of
		  0 -> true = ets:delete(?TAB_INDEX, Hash);
		  _ -> ok
	      end
      end, AscHashes).

index_hashes(Name) ->
    Labels = lists:reverse(dns:dname_to_labels(dns:dname_to_lower(Name))),
    lists:foldl(
      fun(Label, [PrevHash|_] = Hashes) ->
	      Hash = crypto:sha([Label, PrevHash]),
	      [Hash|Hashes]
      end, [<<>>], Labels).

join_labels([]) -> <<>>;
join_labels(Labels) ->
    <<$., Dname/binary>> = << <<$., L/binary>> || L <- Labels >>,
    Dname.