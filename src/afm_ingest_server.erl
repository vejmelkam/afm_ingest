-module(afm_ingest_server).
-behaviour(gen_server).
-define(SERVER, ?MODULE).
-include("afm_detection.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/2,update_detections_now/0,last_updated/0]).
-export([subscribe/1,unsubscribe/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(SatList,TimeoutMin) ->
  gen_server:start_link({local, ?SERVER}, ?MODULE, [SatList,[],TimeoutMin,unknown,gb_sets:new()], []).

update_detections_now() ->
  gen_server:call(?SERVER,update_detections_now).

subscribe(Pid) ->
  gen_server:call(?SERVER,{subscribe,Pid}).

unsubscribe(Pid) ->
  gen_server:call(?SERVER,{unsubscribe,Pid}).

last_updated() ->
  gen_server:call(?SERVER,last_updated).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Args) ->
  % kick off the ingest of satellite detections
  ?SERVER ! update_detections_timeout,
  {ok, Args}.

handle_call(Request, _From, State=[Sats,Monitors,TimeoutMins,LastUpdate,LastFDs]) ->
  case Request of
    {subscribe,Pid} ->
      case lists:member(Pid,Monitors) of
        true ->
          {reply,ok,State};
        false ->
          {reply,ok,[Sats,[Pid|Monitors],TimeoutMins,LastUpdate,LastFDs]}
      end;
    {unsubscribe,Pid} ->
      {reply,ok,[Sats,lists:delete(Pid,Monitors),TimeoutMins,LastUpdate,LastFDs]};
    last_updated ->
      {reply, LastUpdate, State};
    update_detections_now ->
      NewFDs = update_detections_int(Sats,Monitors,LastFDs),
      {reply, ok, [Sats,Monitors,TimeoutMins,calendar:local_time(),NewFDs]};
    _ ->
      {reply, invalid_request, State}
  end.

handle_cast(_Msg, State) ->
  {noreply,State}.

handle_info(update_detections_timeout, [Sats,Monitors,TimeoutMins,_LastUpdate,LastFDs]) ->
  FDset = update_detections_int(Sats,Monitors,LastFDs),
  timer:send_after(TimeoutMins * 60 * 1000, update_detections_timeout),
  {noreply, [Sats,Monitors,TimeoutMins,calendar:local_time(),FDset]};
handle_info(_Info,State) ->
  {noreply,State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------


update_detections_int(Sats,Monitors,FDSet) ->
  FDs = lists:flatten(lists:map(fun afm_ingest_kml:retrieve_detections/1, Sats)),
  New = case gb_sets:is_empty(FDSet) of
    true ->
      % no previous result set in memory, must use dbase
      find_detections_not_in_table(FDs);
    false ->
      % we already have a previous result set in memory
      lists:filter(fun (FD) -> not gb_sets:is_member(FD,FDSet) end, FDs)
  end,
  notify_monitors(New,Monitors),
  mnesia:transaction(fun() -> lists:foreach(fun mnesia:write/1, FDs) end, [], 3),
  gb_sets:from_list(FDs).

notify_monitors([],_Monitors) ->
  ok;
notify_monitors(NewFDs,Monitors) ->
  lists:map(fun (X) -> X ! {afm_new_detections,NewFDs} end, Monitors).

find_detections_not_in_table(FDs) ->
  {atomic, New} = mnesia:transaction(
    fun() ->
      lists:filter(fun (FD=#afm_detection{timestamp=T}) ->
            not lists:member(FD, mnesia:read(afm_detection,T)) end, FDs) end),
  New.



