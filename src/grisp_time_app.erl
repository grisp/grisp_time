%%%-------------------------------------------------------------------
%% @doc grisp_time public API
%% @end
%%%-------------------------------------------------------------------

-module(grisp_time_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    grisp_time_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
