% Inspired by NervesTime.Ntpd from Nerves Project
-module(grisp_time_ntpd).
-module_doc """
GenServer that manages the ntpd daemon process for time synchronization.

This module is responsible for starting, monitoring, and restarting the ntpd
daemon process. It communicates with ntpd via a Unix domain socket to receive
synchronization status updates.
""".

-include_lib("kernel/include/logger.hrl").

%% API
-export([start_link/0]).
-export([synchronized/0]).
-export([clean_start/0]).
-export([set_ntp_servers/1]).
-export([ntp_servers/0]).
-export([restart_ntpd/0]).


-behaviour(gen_server).

%% gen_server callbacks
-export([init/1, handle_continue/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

%% If restarting ntpd due to a crash, delay its start to avoid pegging
%% ntp servers. This delay can be long since the clock has either been
%% set (i.e., it's not far off from the actual time) or there is a problem
%% setting the time that has a low probability of being fixed by trying
%% again immediately. Plus ntp server admins get annoyed by misbehaving
%% IoT devices pegging their servers and we don't want that.
-define(NTPD_RESTART_DELAY, 60000).
-define(NTPD_CLEAN_START_DELAY, 10).

-record(state, {
    socket :: port() | undefined,
    servers :: [string()],
    daemon :: port() | undefined,
    synchronized = false :: boolean(),
    clean_start = true :: boolean()
}).

%%%===================================================================
%%% API
%%%===================================================================

-doc false.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-doc "Return whether ntpd has synchronized with a time server".
-spec synchronized() -> boolean().
synchronized() ->
    gen_server:call(?SERVER, synchronized).

-doc """
Return whether ntpd was started cleanly.

If ntpd crashes or this GenServer crashes, then the run is considered
unclean and there's a delay in starting ntpd. This is intended to
prevent abusive polling of public ntpd servers.
""".
-spec clean_start() -> boolean().
clean_start() ->
    gen_server:call(?SERVER, clean_start).

-doc "Update the list of NTP servers to poll".
-spec set_ntp_servers([string()]) -> ok.
set_ntp_servers(Servers) when is_list(Servers) ->
    gen_server:call(?SERVER, {set_ntp_servers, Servers}).

-doc "Get the list of NTP servers".
-spec ntp_servers() -> [string()] | {error, term()}.
ntp_servers() ->
    gen_server:call(?SERVER, ntp_servers).

-doc "Manually restart ntpd".
-spec restart_ntpd() -> ok | {error, term()}.
restart_ntpd() ->
    gen_server:call(?SERVER, restart_ntpd).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(_Args) ->
    {ok, NtpServers} = application:get_env(grisp_time, servers),
    State = #state{servers = NtpServers},
    {ok, State, {continue, continue}}.

handle_continue(continue, State) ->
    NewState = schedule_ntpd_start(prep_ntpd_start(State)),
    {noreply, NewState}.

handle_call(synchronized, _From, State) ->
    {reply, State#state.synchronized, State};
handle_call(clean_start, _From, State) ->
    {reply, State#state.clean_start, State};
handle_call({set_ntp_servers, Servers}, _From, State) ->
    NewState = cleanup_and_restart(State#state{servers = Servers}),
    {reply, ok, NewState};
handle_call(ntp_servers, _From, State) ->
    {reply, State#state.servers, State};
handle_call(restart_ntpd, _From, State) ->
    {reply, ok, cleanup_and_restart(State)};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(start_ntpd, #state{daemon = undefined, servers = Servers} = State)
when Servers =/= [] ->
    NewState = start_ntpd(State),
    {noreply, NewState};
handle_info(start_ntpd, State) ->
    %% Ignore since ntpd is already running or no servers are configured
    {noreply, State};
handle_info({udp, Socket, _, 0, Data}, #state{socket = Socket} = State) ->
    Report = binary_to_term(Data),
    handle_ntpd_report(Report, State);
handle_info({Port, {data, Text}}, #state{daemon = Port} = State) ->
    ?LOG_DEBUG("GRiSP Time: \"~s\"", [Text]),
    {noreply, State};
handle_info({Port, {exit_status, Status}}, #state{daemon = Port} = State)
    when is_port(Port) ->
    case Status of
        0 ->
            %% Normal exit
            NewState = schedule_ntpd_start(State#state{daemon = undefined}),
            {noreply, NewState};
        _ ->
            %% Abnormal exit
            ?LOG_WARNING("ntpd daemon exited with status ~p, "
                         "restarting with delay", [Status]),
            NewState = schedule_ntpd_start(State#state{daemon = undefined,
                                                       clean_start = false}),
            {noreply, NewState}
    end;
handle_info(Info, State) ->
    ?LOG_WARNING("GRiSP Time: unexpected message ~p", [Info]),
    {noreply, State}.

terminate(_Reason, State) ->
    _ = stop_ntpd(State),
    ok.


%%%===================================================================
%%% Internal functions
%%%===================================================================

prep_ntpd_start(#state{servers = []} = State) ->
    %% Don't prep ntpd if no servers are configured.
    State;
prep_ntpd_start(State) ->
    Path = socket_path(),
    %% Cleanup the socket file in case of a restart
    CleanStart = case file:delete(Path) of
        {error, enoent} ->
            %% This is the expected case. There's no stale socket file sitting around
            true;
        ok ->
            ?LOG_WARNING("GRiSP Time: ntpd crash detected. "
                         "Delaying next start..."),
            false
    end,
    {ok, Socket} = gen_udp:open(0, [
        {ip, {local, Path}},
        binary,
        {active, true}
    ]),
    State#state{socket = Socket, clean_start = CleanStart}.

schedule_ntpd_start(#state{servers = []} = State) ->
    %% Don't schedule ntpd to start if no servers are configured.
    ?LOG_INFO("GRiSP Time: Not scheduling ntpd to start (no servers configured)"),
    State;
schedule_ntpd_start(State) ->
    Delay = ntpd_restart_delay(State),
    erlang:send_after(Delay, self(), start_ntpd),
    State.

cleanup_and_restart(State) ->
    schedule_ntpd_start(prep_ntpd_start(stop_ntpd(State))).

ntpd_restart_delay(#state{clean_start = false}) ->
    ?NTPD_RESTART_DELAY;
ntpd_restart_delay(#state{clean_start = true}) ->
    ?NTPD_CLEAN_START_DELAY.

stop_ntpd(#state{daemon = Port, socket = Socket} = State) ->
    case Port of
        undefined -> ok;
        _ when is_port(Port) -> port_close(Port)
    end,

    case Socket of
        undefined -> ok;
        _ -> gen_udp:close(Socket)
    end,

    %% Clean up socket file
    _ = (catch file:delete(socket_path())),

    State#state{daemon = undefined, socket = undefined, synchronized = false}.

handle_ntpd_report({ReportType, _FreqDriftPpm, _Offset,
                    Stratum, _PollInterval}, State)
when ReportType =:= <<"stratum">>; ReportType =:= <<"periodic">> ->
    {noreply, State#state{synchronized = maybe_update_rtc(Stratum)}};
handle_ntpd_report({<<"step">>, _FreqDriftPpm, _Offset,
                    _Stratum, _PollInterval}, State) ->
    %% Ignore
    {noreply, State};
handle_ntpd_report({<<"unsync">>, _FreqDriftPpm, _Offset,
                    _Stratum, _PollInterval}, State) ->
    ?LOG_ERROR("GRiSP Time: ntpd reports that it is unsynchronized; restarting"),

    %% According to the Busybox ntpd docs, if you get an `unsync` notification, then
    %% you should restart ntpd to be safe. This is stated to be due to name resolution
    %% only being done at initialization.
    NewState = schedule_ntpd_start(stop_ntpd(State)),
    {noreply, NewState};
handle_ntpd_report({error, _Reason}, State) ->
    %% Decode failure - already logged
    {noreply, State};
handle_ntpd_report(Report, State) ->
    ?LOG_ERROR("GRiSP Time: ntpd ignored unexpected report ~p", [Report]),
    {noreply, State}.

start_ntpd(#state{servers = Servers} = State) ->
    {ok, NtpdPath} = application:get_env(grisp_time, ntpd),
    NtpdScriptPath = filename:join([
        code:priv_dir(grisp_time),
        "ntpd_script"
    ]),

    ServerArgs = lists:flatmap(fun(S) -> ["-p", S] end, Servers),
    Args = ["-n", "-S", NtpdScriptPath | ServerArgs],

    %% Set socket file to receive updates from ntpd
    SocketPath = socket_path(),
    Env = [{"SOCKET_PATH", SocketPath}],

    ?LOG_DEBUG("GRiSP Time: starting ~s with: ~p, env: ~p", [NtpdPath, Args, Env]),

    case erlang:open_port({spawn_executable, NtpdPath}, [
        {args, Args},
        {env, Env},
        exit_status,
        stderr_to_stdout,
        hide
    ]) of
        Port when is_port(Port) ->
            State#state{daemon = Port, synchronized = false};
        {error, Reason} ->
            ?LOG_ERROR("failed to start ntpd: ~p", [Reason]),
            State
    end.

-doc false.
-spec maybe_update_rtc(integer()) -> boolean().
maybe_update_rtc(Stratum) when Stratum =< 4 ->
    %% Only update the RTC if synchronized. I.e., ignore stratum > 4
    %% TODO: Implement RTC update when grisp_time_system_time module exists
    %% grisp_time_system_time:update_rtc(),
    false;
maybe_update_rtc(_Stratum) ->
    false.

socket_path() ->
    TmpDir = case os:getenv("TMPDIR") of
        false -> "/tmp";
        Dir -> Dir
    end,
    filename:join(TmpDir, "grisp_time_comm").
