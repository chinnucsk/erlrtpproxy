%%%----------------------------------------------------------------------
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 3 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(media).
-author('lemenkov@gmail.com').

-behaviour(gen_server).
-export([start/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-include("../include/common.hrl").

% Milliseconds
-define(RTP_TIME_TO_LIVE, 150000).

% Microseconds
-define(RTCP_TIME_TO_LIVE, 10000000).

% Milliseconds
-define(INTERIM_UPDATE, 30000).

%-include("rtcp.hrl").

% description of media:
% * fd - our fd, where we will receive messages from other side
% * ip - real client's ip
% * port - real client's port
-record(media, {fd=null, ip=null, port=null, rtpstate=nortp, lastseen, ssrc=null}).
-record(state, {
		callid,
		mediaid,
		tag_f,
		tag_t,
		tref,
		tref2,
		from,
		fromrtcp,
		to,
		tortcp,
		hold=false,
		send_fun=send_locked,
		started=false
	}
).

start(Cmd) ->
	% TODO run under supervisor maybe?
	gen_server:start(?MODULE, Cmd, []).

init (
	#cmd{
		type = ?CMD_U,
		origin = #origin{pid = Pid},
		callid = CallId,
		mediaid = MediaId,
		from = #party{tag = TagFrom, addr = {GuessIp, GuessPort}},
		params = Params} = Cmd
	) ->
	% TODO just choose the first IP address for now
	[MainIp | _Rest ]  = rtpproxy_utils:get_ipaddrs(),
	{ok, TRef} = timer:send_interval(?RTP_TIME_TO_LIVE, ping),
%	{ok, TRef} = timer:send_interval(?CALL_TIME_TO_LIVE*5, timeout),
	{ok, TRef2} = timer:send_interval(?INTERIM_UPDATE, interim_update),

	{Fd0, Fd1, Fd2, Fd3} = rtpproxy_utils:get_fd_quadruple(MainIp),

	[P0, P1, P2, P3]  = lists:map(fun(X) -> {ok, {_I, P}} = inet:sockname(X), P end, [Fd0, Fd1, Fd2, Fd3]),
	?INFO("started at ~s, with  F {~p,~p} T {~p,~p}", [inet_parse:ntoa(MainIp), P0, P1, P2, P3]),

	% Register at the rtpproxy
	gen_server:cast({global, rtpproxy}, {created, self(), {CallId, MediaId}}),

	SendFun = case proplists:get_value(weak, Params) of
		true -> fun send_simple/5;
		_ -> fun send_locked/5
	end,

	{ok, {I0, P0}} = inet:sockname(Fd0),
	{ok, {I2, P2}} = inet:sockname(Fd2),
	gen_server:cast(Pid, {reply, Cmd, {I0, P0}, {I2, P2}}),

	FromRtp = case rtpproxy_utils:is_rfc1918(GuessIp) of
		true ->
			% FIXME check for bridging between internal (RFC 1918) and public networks
			#media{fd=Fd0};
		_ ->
			#media{fd=Fd0, ip=GuessIp, port=GuessPort}
	end,

	{ok,
		#state{
			callid	= CallId,
			mediaid = MediaId,
			tag_f	= TagFrom,
			tag_t	= null,
			tref	= TRef,
			tref2	= TRef2,
			from	= FromRtp,
			fromrtcp= #media{fd=Fd1},
			to	= #media{fd=Fd2},
			tortcp	= #media{fd=Fd3},
			send_fun= SendFun
		}
	}.

handle_call(?CMD_Q, _From, #state{started = Started} = State) ->
	% TODO (acquire information about call state)
%-record(media, {fd=null, ip=null, port=null, rtpstate=rtp, lastseen}).
%-record(state, {parent, tref, from, fromrtcp, to, tortcp, hold=false, started}).
	% sprintf(buf, "%s %d %lu %lu %lu %lu\n", cookie, spa->ttl, spa->pcount[idx], spa->pcount[NOT(idx)], spa->pcount[2], spa->pcount[3]);
	Reply = io_lib:format("CallDuration: ~w", [case Started of false -> "<not started yet>"; _ -> trunc(0.5 + timer:now_diff(erlang:now(), Started) / 1000000) end]),
	{reply, {ok, Reply}, State}.

% FIXME move some logic into frontend - leave here only common part
handle_cast(
		#cmd{
			type = Type,
			origin = #origin{pid = Pid},
			callid = CallId,
			mediaid = MediaId,
			from = CmdFrom,
			to = CmdTo,
			params = Params} = Cmd,
		#state{
			callid = CallId,
			mediaid = MediaId,
			from = #media{fd=FdF} = From,
			to = #media{fd=FdT} = To,
			tag_f = TagF,
			tag_t = TagT} = State
	) when Type == ?CMD_U; Type == ?CMD_L ->
	{Tag, {GuessIp, GuessPort}} = case Type of
		?CMD_U -> {CmdFrom#party.tag, CmdFrom#party.addr};
		?CMD_L -> {CmdTo#party.tag, CmdTo#party.addr}
	end,
	{Dir, Fd} = case Tag of
		TagF -> {from, FdF};
		TagT -> {to, FdT};
		% Initial set up of a tag_t
		_ when TagT == null, Type == ?CMD_L -> {to, FdT};
		_ -> {notfound, notfound}
	end,
	case Dir of
		notfound ->
			gen_server:cast(Pid, {reply, Cmd, {error, notfound}}),
			{noreply, State};
		_ ->
			{ok, {I, P}} = inet:sockname(Fd),
			gen_server:cast(Pid, {reply, Cmd, {I, P}}),
			case rtpproxy_utils:is_rfc1918(GuessIp) of
				true ->
					% FIXME check for bridging between internal (RFC 1918) and public networks
					{noreply, State};
				_ ->
					case Dir of
						from -> {noreply, State#state{from = From#media{ip=GuessIp, port=GuessPort}}};
						to -> {noreply, State#state{to = To#media{ip=GuessIp, port=GuessPort}, tag_t = Tag}}
					end
			end
	end;

handle_cast(
		#cmd{
			type = ?CMD_D,
			origin = #origin{pid = Pid},
			callid = CallId,
			mediaid = 0,
			from = #party{tag = TagFrom},
			to = To} = Cmd,
		#state{callid = CallId, tag_f = TagF, tag_t = TagT} = State
	) ->
	% FIXME consider checking for direction (is TagFrom  equals to TagF or not?)
	case To of
		null -> {stop, cancel, State};
		_ -> {stop, bye, State}
	end;

handle_cast(Other, State) ->
	?WARN("Other cast [~p], State [~p]", [Other, State]),
	{noreply, State}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

terminate(Reason, #state{callid = CallId, mediaid = MediaId, tref = TimerRef, tref2 = TimerRef2, from = From, fromrtcp = FromRtcp, to = To, tortcp = ToRtcp}) ->
	timer:cancel(TimerRef),
	timer:cancel(TimerRef2),
	% TODO we should send RTCP BYE here
	lists:map(fun (X) -> gen_udp:close(X#media.fd) end, [From, FromRtcp, To, ToRtcp]),

	gen_server:cast({global, rtpproxy}, {'EXIT', self(), Reason}),
	gen_server:cast(rtpproxy_radius, {stop, CallId, MediaId}),

	?ERR("terminated due to reason [~p]", [Reason]).

handle_info({udp, Fd, Ip, Port, Msg}, #state{tortcp = #media{fd = Fd}, send_fun = SendFun} = State) ->
	inet:setopts(Fd, [{active, once}]),
	% First, we'll try do decode our RCP packet(s)
	try
		{ok, Rtcps} = rtcp:decode(Msg),
		?INFO("RTCP from ~s: ~s", [State#state.callid, lists:map (fun rtp_utils:pp/1, Rtcps)]),
		Msg2 = rtcp_process (Rtcps),
		{noreply, State#state{fromrtcp=SendFun(State#state.fromrtcp, State#state.tortcp, Ip, Port, Msg2)}}
	catch
		E:C ->
			rtp_utils:dump_packet(node(), self(), Msg),
			?ERR("rtcp:decode(...) error ~p:~p", [E,C]),
			{noreply, State}
	end;

handle_info({udp, Fd, Ip, Port, Msg}, #state{fromrtcp = #media{fd = Fd}, send_fun = SendFun} = State) ->
	inet:setopts(Fd, [{active, once}]),
	% First, we'll try do decode our RCP packet(s)
	try
		{ok, Rtcps} = rtcp:decode(Msg),
		?INFO("RTCP from ~s: ~s", [State#state.callid, lists:map (fun rtp_utils:pp/1, Rtcps)]),
		Msg2 = rtcp_process (Rtcps),
		{noreply, State#state{tortcp=SendFun(State#state.tortcp, State#state.fromrtcp, Ip, Port, Msg2)}}
	catch
		E:C ->
			rtp_utils:dump_packet(node(), self(), Msg),
			?ERR("rtcp:decode(...) error ~p:~p", [E,C]),
			{noreply, State}
	end;

% We received UDP-data on From or To socket, so we must send in from To or From socket respectively
% (if we not in HOLD state)
% (symmetric NAT from the client's PoV)
% We must ignore previous state ('rtp' or 'nortp') and set it to 'rtp'
% We use Ip and Port as address for future messages to FdTo or FdFrom

% TODO check that message was arrived from valid {Ip, Port}
% TODO check whether message is valid rtp stream
handle_info({udp, Fd, Ip, Port, Msg}, #state{from = #media{fd = Fd}, send_fun = SendFun} = State) ->
	inet:setopts(Fd, [{active, once}]),
	{noreply, State#state{to = SendFun(State#state.to, State#state.from, Ip, Port, Msg), started=start_acc(State)}};

handle_info({udp, Fd, Ip, Port, Msg}, #state{to = #media{fd = Fd}, send_fun = SendFun} = State) ->
	inet:setopts(Fd, [{active, once}]),
	{noreply, State#state{from = SendFun(State#state.from, State#state.to, Ip, Port, Msg), started=start_acc(State)}};

% Ping message
handle_info(ping, #state{from = #media{rtpstate = rtp}, to = #media{rtpstate = rtp}} =  State) ->
	% Both sides are active, so we just set state to 'nortp' and continue
	{noreply, State#state{from=(State#state.from)#media{rtpstate=nortp}, to=(State#state.to)#media{rtpstate=nortp}}};

handle_info(interim_update, #state{callid = CallId, mediaid = MediaId, from = #media{rtpstate = rtp}, to = #media{rtpstate = rtp}} =  State) ->
	% Both sides are active, so we need to send interim update here
	gen_server:cast(rtpproxy_radius, {interim_update, CallId, MediaId}),
	{noreply, State};

handle_info(ping, State) ->
	% We didn't get new RTP messages since last ping - we should close this mediastream
	% we should rely on rtcp
%	case (timer:now_diff(now(),(State#state.fromrtcp)#media.lastseen) > ?RTCP_TIME_TO_LIVE) and (timer:now_diff(now(),(State#state.tortcp)#media.lastseen) > ?RTCP_TIME_TO_LIVE) of
%		true ->
%			{stop, nortp, State};
%		false ->
%			{noreply, State}
%	end
	{stop, nortp, State};

handle_info(Other, State) ->
	?WARN("Other Info [~p], State [~p]", [Other, State]),
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%
%% Internal functions %%
%%%%%%%%%%%%%%%%%%%%%%%%

% Define functions for sending RTP/RTCP and updating state
send_simple (Var1, #media{ip = null, port = null}, Ip, Port, _Msg) ->
	% Probably RTP or RTCP, but we CANNOT send yet.
	Var1#media{ip=Ip, port=Port, rtpstate=rtp, lastseen=now()};
send_simple (Var1, Var2, Ip, Port, Msg) ->
	gen_udp:send(Var1#media.fd, Var2#media.ip, Var2#media.port, Msg),
	Var1#media{ip=Ip, port=Port, rtpstate=rtp, lastseen=now()}.

send_locked (Var1, #media{ip = null, port = null}, Ip, Port, _Msg) ->
	% Probably RTP or RTCP, but we CANNOT send yet.
	Var1#media{ip=Ip, port=Port, rtpstate=rtp, lastseen=now()};
send_locked (#media{fd = Fd, ip = Ip, port = Port} = Var1, Var2, Ip, Port, Msg) ->
	gen_udp:send(Fd, Var2#media.ip, Var2#media.port, Msg),
	Var1#media{rtpstate=rtp, lastseen=now()};
send_locked (Var1, _, _, _, _) ->
	Var1.

% Define function for safe determinin of starting media
start_acc (#state{started = false, callid = CallId, mediaid = MediaId, from = #media{rtpstate = rtp}, to = #media{rtpstate = rtp}}) ->
	% FIXME perhaps this should be optional
	gen_server:cast(rtpproxy_radius, {start, CallId, MediaId}),
	now();
start_acc (S) ->
	S#state.started.

rtcp_process (Rtcps) ->
	rtcp_process (Rtcps, []).
rtcp_process ([], Rtcps) ->
	rtcp:encode(Rtcps);
rtcp_process ([Rtcp | Rest], Processed) ->
	NewRtcp = case rtp_utils:get_type(Rtcp) of
		sr -> Rtcp;
		rr -> Rtcp;
		sdes -> Rtcp;
		bye ->
			?ERR("We SHOULD terminate this stream due to RTCP BYE", []),
			% Unfortunately, it's not possible due to issues in Asterisk configs
			% which users are unwilling to fix. So we just warn about it.
			% Maybe, in the future, we'll reconsider this behaviour.
			Rtcp;
		app -> Rtcp;
		xr -> Rtcp;
		_ -> Rtcp
	end,
	rtcp_process (Rest, Processed ++ [NewRtcp]).

