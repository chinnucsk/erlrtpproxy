-module(rtpproxy_notifier_backend_notify).

-behaviour(gen_server).

-export([start_link/1]).
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

start_link(Args) ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

init([[{tcp, IpStr, Port}|Rest]]) ->
	{ok, Ip} = inet_parse:address(IpStr),
	{ok, Fd} = gen_udp:open(0, [binary, {active, true}, {packet, raw}]),
	error_logger:info_msg("Started rtpproxy notify protocol backend at ~p~n", [node()]),
	{ok, Fd}.

handle_call(Message, From, State) ->
	error_logger:warning_msg("Bogus call: ~p from ~p at ~p~n", [Message, From, node()]),
	{reply, {error, unknown_call}, State}.

handle_cast({_, _, _, [{addr,{Ip,Port}},{tag,NotifyTag}]}, Fd) ->
	gen_udp:send(Fd, Ip, Port, NotifyTag),
	{noreply, Fd};

handle_cast(Other, State) ->
	error_logger:warning_msg("Bogus cast: ~p at ~p~n", [Other, node()]),
	{noreply, State}.

handle_info(Other, State) ->
	error_logger:warning_msg("Bogus info: ~p at ~p~n", [Other, node()]),
	{noreply, State}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

terminate(Reason, Fd) ->
	gen_udp:close(Fd),
	error_logger:error_msg("Terminated: ~p at ~p~n", [Reason, node()]),
	ok.
