-module(afm_ingest_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, Args) ->
    afm_ingest_sup:start_link(Args).

stop(_State) ->
    ok.
