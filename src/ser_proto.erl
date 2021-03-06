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

-module(ser_proto).
-author('lemenkov@gmail.com').

-export([decode/1]).
-export([encode/1]).

-include("common.hrl").

-define(SAFE_PARTY(Val0), case Val0 of null -> null; _ -> [Val, _] = ensure_mediaid(binary_split(Val0, $;)), #party{tag = Val} end).

decode(Msg) when is_binary(Msg) ->
	% Cut last \n (if exist) and drop accidental zeroes - OpenSIPs inserts
	% them sometimes (bug in OpenSIPS)
	[Cookie,C|Rest] = binary_split(<< <<X>> || <<X>> <= Msg, X /= 0, X /= $\n>>, $ ),
	case parse_splitted([binary_to_upper(C)|Rest]) of
		#cmd{} = Cmd ->
			Cmd#cmd{
				cookie=Cookie,
				origin=#origin{
					type=ser,
					pid=self()
				}
			};
		#response{} = Response ->
			case  Response#response.type of
				stats ->
					Response#response{
						cookie = Cookie,
						data = binary_to_list(Msg) % I contains it's own formatting
					};
				_ ->
					Response#response{
						cookie=Cookie
					}
			end
	end.

encode({error, syntax, Msg}) when is_binary(Msg) ->
	[Cookie|_] = binary_split(Msg, $ ),
	<<Cookie/binary, " E1\n">>;
encode({error, software, Msg}) when is_binary(Msg) ->
	[Cookie|_] = binary_split(Msg, $ ),
	<<Cookie/binary, " E7\n">>;
encode(#response{cookie = Cookie, type = reply, data = ok}) ->
	<<Cookie/binary, " 0\n">>;
encode(#response{cookie = Cookie, type = reply, data = {ok, {stats, Number}}}) when is_integer(Number) ->
	N = list_to_binary(integer_to_list(Number)),
	<<Cookie/binary, " active sessions: ", N/binary, "\n">>;
encode(#response{cookie = Cookie, type = reply, data = {ok, {stats, NumberTotal, NumberActive}}}) when is_integer(NumberTotal), is_integer(NumberActive) ->
	Nt = list_to_binary(integer_to_list(NumberTotal)),
	Na = list_to_binary(integer_to_list(NumberActive)),
	<<Cookie/binary, " sessions created: ", Nt/binary, " active sessions: ", Na/binary, "\n">>;
encode(#response{cookie = Cookie, type = reply, data = supported}) ->
	<<Cookie/binary, " 1\n">>;
encode(#response{cookie = Cookie, type = reply, data = {version, Version}}) when is_binary(Version) ->
	<<Cookie/binary, " ", Version/binary, "\n">>;
encode(#response{cookie = Cookie, type = reply, data = {{{I0,I1,I2,I3} = IPv4, Port}, _}}) when
	is_integer(I0), I0 >= 0, I0 < 256,
	is_integer(I1), I1 >= 0, I1 < 256,
	is_integer(I2), I2 >= 0, I2 < 256,
	is_integer(I3), I3 >= 0, I3 < 256 ->
	I = list_to_binary(inet_parse:ntoa(IPv4)),
	P = list_to_binary(integer_to_list(Port)),
	<<Cookie/binary, " ", P/binary, " ", I/binary, "\n">>;
encode(#response{cookie = Cookie, type = reply, data = {{{I0,I1,I2,I3,I4,I5,I6,I7} = IPv6, Port}, _}}) when
	is_integer(I0), I0 >= 0, I0 < 65535,
	is_integer(I1), I1 >= 0, I1 < 65535,
	is_integer(I2), I2 >= 0, I2 < 65535,
	is_integer(I3), I3 >= 0, I3 < 65535,
	is_integer(I4), I4 >= 0, I4 < 65535,
	is_integer(I5), I5 >= 0, I5 < 65535,
	is_integer(I6), I6 >= 0, I6 < 65535,
	is_integer(I7), I7 >= 0, I7 < 65535 ->
	I = list_to_binary(inet_parse:ntoa(IPv6)),
	P = list_to_binary(integer_to_list(Port)),
	<<Cookie/binary, " ", P/binary, " ", I/binary, "\n">>;
encode(#response{cookie = Cookie, type = error, data = syntax}) ->
	<<Cookie/binary, " E1\n">>;
encode(#response{cookie = Cookie, type = error, data = software}) ->
	<<Cookie/binary, " E7\n">>;
encode(#response{cookie = Cookie, type = error, data = notfound}) ->
	<<Cookie/binary, " E8\n">>;
encode(#response{} = Unknown) ->
	error_logger:error_msg("Unknown response: ~p~n", [Unknown]),
	throw({error_syntax, "Unknown (or unsupported) #response"});

encode(#cmd{cookie = Cookie, type = ?CMD_V}) ->
	<<Cookie/binary, " V\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_VF, params = Version}) ->
	<<Cookie/binary, " VF ", Version/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_U, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag, addr = {GuessIp, GuessPort}}, to = null, params = Params}) ->
	ParamsBin = encode_params(Params),
	Ip = list_to_binary(inet_parse:ntoa(GuessIp)),
	Port = list_to_binary(io_lib:format("~b", [GuessPort])),
	FT = print_tag_mediaid(FromTag, MediaId),
	<<Cookie/binary, " U", ParamsBin/binary, " ", CallId/binary, " ", Ip/binary, " ", Port/binary, " ", FT/binary, "\n">>;
encode(#cmd{cookie = Cookie, type = ?CMD_U, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag, addr = Addr}, to = #party{tag = ToTag}, params = Params}) ->
	ParamsBin = encode_params(Params),
	BinAddr = binary_print_addr(Addr),
	FT = print_tag_mediaid(FromTag, MediaId),
	TT = print_tag_mediaid(ToTag, MediaId),
	<<Cookie/binary, " U", ParamsBin/binary, " ", CallId/binary, " ", BinAddr/binary, " ", FT/binary, " ", TT/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_L, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag, addr = Addr}, to = #party{tag = ToTag}, params = Params}) ->
	ParamsBin = encode_params(Params),
	BinAddr = binary_print_addr(Addr),
	FT = print_tag_mediaid(FromTag, MediaId),
	TT = print_tag_mediaid(ToTag, MediaId),
	<<Cookie/binary, <<" L">>/binary, ParamsBin/binary, " ", CallId/binary, " ", BinAddr/binary, " ", TT/binary, " ", FT/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_D, callid = CallId, from = #party{tag = FromTag}, to = null}) ->
	<<Cookie/binary, <<" D ">>/binary, CallId/binary, " ", FromTag/binary, "\n">>;
encode(#cmd{cookie = Cookie, type = ?CMD_D, callid = CallId, from = #party{tag = FromTag}, to = #party{tag = ToTag}}) ->
	<<Cookie/binary, <<" D ">>/binary, CallId/binary, " ", FromTag/binary, " ", ToTag/binary, "\n">>;

encode(
	#cmd{
		cookie = Cookie,
		type = ?CMD_P,
		callid = CallId,
		mediaid = MediaId,
		from = #party{tag = FromTag},
		to = null,
		params = [
				{codecs, Codecs},
				{filename, Filename},
				{playcount, Playcount}
			]
		}) ->
	P = list_to_binary(io_lib:format("~b", [Playcount])),
	C = list_to_binary(print_codecs(Codecs)),
	FT = print_tag_mediaid(FromTag, MediaId),
	<<Cookie/binary, <<" P">>/binary, P/binary, " ", CallId/binary, " ", Filename/binary, " ", C/binary, " ", FT/binary, "\n">>;
encode(
	#cmd{
		cookie = Cookie,
		type = ?CMD_P,
		callid = CallId,
		mediaid = MediaId,
		from = #party{tag = FromTag},
		to = #party{tag = ToTag},
		params = [
				{codecs, Codecs},
				{filename, Filename},
				{playcount, Playcount}
			]
		}) ->
	P = list_to_binary(io_lib:format("~b", [Playcount])),
	C = list_to_binary(print_codecs(Codecs)),
	FT = print_tag_mediaid(FromTag, MediaId),
	TT = print_tag_mediaid(ToTag, MediaId),
	<<Cookie/binary, <<" P">>/binary, P/binary, " ", CallId/binary, " ", Filename/binary, " ", C/binary, " ", FT/binary, " ", TT/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_S, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag}, to = null}) ->
	FT = print_tag_mediaid(FromTag, MediaId),
	<<Cookie/binary, <<" S ">>/binary, CallId/binary, " ", FT/binary, "\n">>;
encode(#cmd{cookie = Cookie, type = ?CMD_S, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag}, to = #party{tag = ToTag}}) ->
	FT = print_tag_mediaid(FromTag, MediaId),
	TT = print_tag_mediaid(ToTag, MediaId),
	<<Cookie/binary, <<" S ">>/binary, CallId/binary, " ", FT/binary, " ", TT/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_R, callid = CallId, from = #party{tag = FromTag}, to = null}) ->
	<<Cookie/binary, <<" R ">>/binary, CallId/binary, " ", FromTag/binary, "\n">>;
encode(#cmd{cookie = Cookie, type = ?CMD_R, callid = CallId, from = #party{tag = FromTag}, to = #party{tag = ToTag}}) ->
	<<Cookie/binary, <<" R ">>/binary, CallId/binary, " ", FromTag/binary, " ", ToTag/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_Q, callid = CallId, mediaid = MediaId, from = #party{tag = FromTag}, to = #party{tag = ToTag}}) ->
	FT = print_tag_mediaid(FromTag, MediaId),
	TT = print_tag_mediaid(ToTag, MediaId),
	<<Cookie/binary, <<" Q ">>/binary, CallId/binary, " ", FT/binary, " ", TT/binary, "\n">>;

encode(#cmd{cookie = Cookie, type = ?CMD_X}) ->
	<<Cookie/binary, <<" X\n">>/binary>>;

encode(#cmd{cookie = Cookie, type = ?CMD_I, params = []}) ->
	<<Cookie/binary, <<" I\n">>/binary>>;
encode(#cmd{cookie = Cookie, type = ?CMD_I, params = [brief]}) ->
	<<Cookie/binary, <<" IB\n">>/binary>>;

encode(#cmd{} = Unknown) ->
	error_logger:error_msg("Unknown command: ~p~n", [Unknown]),
	throw({error_syntax, "Unknown (or unsupported) #cmd"}).

%%
%% Private functions
%%

%%
%% Requests
%%

% Request basic supported rtpproxy protocol version
parse_splitted([<<"V">>]) ->
	#cmd{
		type=?CMD_V
	};

% Request additional rtpproxy protocol extensions
parse_splitted([<<"VF">>, Version]) when
	Version == <<"20040107">>; % Basic RTP proxy functionality
	Version == <<"20050322">>; % Support for multiple RTP streams and MOH
	Version == <<"20060704">>; % Support for extra parameter in the V command
	Version == <<"20071116">>; % Support for RTP re-packetization
	Version == <<"20071218">>; % Support for forking (copying) RTP stream
	Version == <<"20080403">>; % Support for RTP statistics querying
	Version == <<"20081102">>; % Support for setting codecs in the update/lookup command
	Version == <<"20081224">>; % Support for session timeout notifications
	Version == <<"20090810">> -> % Support for automatic bridging
	#cmd{type=?CMD_VF, params = Version};
parse_splitted([<<"VF">>, Unknown]) ->
	throw({error_syntax, "Unknown version: " ++ binary_to_list(Unknown)});

% Create session (no ToTag, no Notify extension)
parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag]) ->
	parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag, null, null, null]);
% Reinvite, Hold and Resume (no Notify extension)
parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag, ToTag]) ->
	parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag, ToTag, null, null]);
parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag0, ToTag, NotifyAddr, NotifyTag]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	{GuessIp, GuessPort} = parse_addr(binary_to_list(ProbableIp), binary_to_list(ProbablePort)),
	Params0 = case {NotifyAddr, NotifyTag} of
		{null, null} -> decode_params(Args);
		_ -> decode_params(Args) ++ [{notify, [{addr, parse_notify_addr(NotifyAddr)}, {tag, NotifyTag}]}]
	end,

	% Discard address if it's not consistent with direction
	Addr = case {proplists:get_value(direction, Params0), utils:is_rfc1918(GuessIp)} of
		{{external, _}, true} -> null;
		{{internal, _}, true} -> {GuessIp, GuessPort};
		{{internal, _}, false} -> null;
		{{external, _}, false} -> {GuessIp, GuessPort};
		{_, ipv6} -> {GuessIp, GuessPort}
	end,

	Params1 = case utils:is_rfc1918(GuessIp) of
		ipv6 -> ensure_alone(Params0, ipv6);
		_ -> Params0
	end,

	% Try to guess RTCP address
	RtcpAddr = case Addr of
		null -> null;
		{GuessIp, GuessPort} -> {GuessIp, GuessPort + 1}
	end,

	#cmd{
		type = ?CMD_U,
		callid = CallId,
		mediaid	= MediaId,
		from = #party{tag=FromTag, addr=Addr, rtcpaddr=RtcpAddr, proto=proplists:get_value(proto, Params1, udp)},
		to = ?SAFE_PARTY(ToTag),
		params = lists:sort(proplists:delete(proto, Params1))
	};

% Lookup existing session
% In fact it differs from CMD_U only by the order of tags
parse_splitted([<<$L:8,Args/binary>>, CallId, ProbableIp, ProbablePort, FromTag, ToTag]) ->
	Cmd = parse_splitted([<<$U:8,Args/binary>>, CallId, ProbableIp, ProbablePort, ToTag, FromTag]),
	Cmd#cmd{type = ?CMD_L};

% delete session (no MediaIds and no ToTag) - Cancel
parse_splitted([<<"D">>, CallId, FromTag]) ->
	parse_splitted([<<"D">>, CallId, FromTag, null]);
% delete session (no MediaIds) - Bye
parse_splitted([<<"D">>, CallId, FromTag, ToTag]) ->
	#cmd{
		type=?CMD_D,
		callid=CallId,
		from=#party{tag=FromTag},
		to = case ToTag of null -> null; _ -> #party{tag=ToTag} end
	};

% Playback pre-recorded audio (Music-on-hold and resume, no ToTag)
parse_splitted([<<$P:8,Args/binary>>, CallId, PlayName, Codecs, FromTag0]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	#cmd{
		type=?CMD_P,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		params=lists:sort(parse_playcount(Args) ++ [{filename, PlayName}, {codecs, parse_codecs(Codecs)}])
	};
% Playback pre-recorded audio (Music-on-hold and resume)
parse_splitted([<<$P:8,Args/binary>>, CallId, PlayName, Codecs, FromTag0, ToTag]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	#cmd{
		type=?CMD_P,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		to = ?SAFE_PARTY(ToTag),
		params=lists:sort(parse_playcount(Args) ++ [{filename, PlayName}, {codecs, parse_codecs(Codecs)}])
	};
% Playback pre-recorded audio (Music-on-hold and resume)
parse_splitted([<<$P:8,Args/binary>>, CallId, PlayName, Codecs, FromTag0, ToTag, ProbableIp, ProbablePort]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	{GuessIp, GuessPort} = parse_addr(binary_to_list(ProbableIp), binary_to_list(ProbablePort)),
	#cmd{
		type=?CMD_P,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		to = ?SAFE_PARTY(ToTag),
		params=lists:sort(parse_playcount(Args) ++ [{filename, PlayName}, {codecs, parse_codecs(Codecs)}, {addr, {GuessIp, GuessPort}}])
	};

% Stop playback or record (no ToTag)
parse_splitted([<<"S">>, CallId, FromTag]) ->
	parse_splitted([<<"S">>, CallId, FromTag, null]);
% Stop playback or record
parse_splitted([<<"S">>, CallId, FromTag0, ToTag]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	#cmd{
		type=?CMD_S,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		to = ?SAFE_PARTY(ToTag)
	};

% Record (obsoleted in favor of Copy)
% No MediaIds and no ToTag
parse_splitted([<<"R">>, CallId, FromTag]) ->
	Cmd = parse_splitted([<<"C">>, CallId, default, <<FromTag/binary, <<";0">>/binary>>, null]),
	Cmd#cmd{type = ?CMD_R};
% Record (obsoleted in favor of Copy)
% No MediaIds
parse_splitted([<<"R">>, CallId, FromTag, ToTag]) ->
	Cmd = parse_splitted([<<"C">>, CallId, default, <<FromTag/binary, <<";0">>/binary>>, <<ToTag/binary, <<";0">>/binary>>]),
	Cmd#cmd{type = ?CMD_R};
% Copy session (same as record, which is now obsolete)
parse_splitted([<<"C">>, CallId, RecordName, FromTag0, ToTag]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	#cmd{
		type=?CMD_C,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		to = ?SAFE_PARTY(ToTag),
		params=[{filename, RecordName}]
	};

% Query information about one particular session
parse_splitted([<<"Q">>, CallId, FromTag0, ToTag0]) ->
	[FromTag, MediaId] = ensure_mediaid(binary_split(FromTag0, $;)),
	[ToTag, _] = binary_split(ToTag0, $;),
	#cmd{
		type=?CMD_Q,
		callid=CallId,
		mediaid=MediaId,
		from=#party{tag=FromTag},
		to=#party{tag=ToTag}
	};

% Stop all active sessions
parse_splitted([<<"X">>]) ->
	#cmd{
		type=?CMD_X
	};

% Get overall statistics
parse_splitted([<<"I">>]) ->
	#cmd{
		type=?CMD_I,
		params=[]
	};
parse_splitted([<<"IB">>]) ->
	#cmd{
		type=?CMD_I,
		params=[brief]
	};

%%
%% Replies
%%

parse_splitted([<<"0">>]) ->
	#response{type = reply, data = ok};

parse_splitted([<<"1">>]) ->
	% This really should be ok - that's another one shortcoming
	#response{type = reply, data = supported};

parse_splitted([<<"20040107">>]) ->
	#response{type = reply, data = {version, <<"20040107">>}};
parse_splitted([<<"20050322">>]) ->
	#response{type = reply, data = {version, <<"20050322">>}};
parse_splitted([<<"20060704">>]) ->
	#response{type = reply, data = {version, <<"20060704">>}};
parse_splitted([<<"20071116">>]) ->
	#response{type = reply, data = {version, <<"20071116">>}};
parse_splitted([<<"20071218">>]) ->
	#response{type = reply, data = {version, <<"20071218">>}};
parse_splitted([<<"20080403">>]) ->
	#response{type = reply, data = {version, <<"20080403">>}};
parse_splitted([<<"20081102">>]) ->
	#response{type = reply, data = {version, <<"20081102">>}};
parse_splitted([<<"20081224">>]) ->
	#response{type = reply, data = {version, <<"20081224">>}};
parse_splitted([<<"20090810">>]) ->
	#response{type = reply, data = {version, <<"20090810">>}};

parse_splitted([<<"E1">>]) ->
	#response{type = error, data = syntax};

parse_splitted([<<"E7">>]) ->
	#response{type = error, data = software};

parse_splitted([<<"E8">>]) ->
	#response{type = error, data = notfound};

parse_splitted([P, I]) ->
	{Ip, Port} = parse_addr(binary_to_list(I), binary_to_list(P)),
	#response{type = reply, data = {{Ip, Port}, {Ip, Port+1}}};

% FIXME Special case - stats
parse_splitted(["SESSIONS", "created:" | Rest]) ->
	#response{type = stats};

%%
%% Error / Unknown request or reply
%%

parse_splitted(Unknown) ->
	error_logger:error_msg("Unknown command: ~p~n", [Unknown]),
	throw({error_syntax, "Unknown command"}).

%%
%% Internal functions
%%

parse_addr(ProbableIp, ProbablePort) ->
	try inet_parse:address(ProbableIp) of
		{ok, GuessIp} ->
			try list_to_integer(ProbablePort) of
				GuessPort when GuessPort >= 0, GuessPort < 65536 ->
					{GuessIp, GuessPort};
				_ ->
					throw({error_syntax, {"Wrong port", ProbablePort}})
			catch
				_:_ ->
					throw({error_syntax, {"Wrong port", ProbablePort}})
			end;
		_ ->
			throw({error_syntax, {"Wrong IP", ProbableIp}})
	catch
		_:_ ->
			throw({error_syntax, {"Wrong IP", ProbableIp}})
	end.

parse_playcount(ProbablePlayCount) ->
	try [{playcount, list_to_integer (binary_to_list(ProbablePlayCount))}]
	catch
		_:_ ->
			throw({error_syntax, {"Wrong PlayCount", ProbablePlayCount}})
	end.

parse_notify_addr(NotifyAddr) ->
	case binary_split(NotifyAddr, $:) of
		[Port] ->
			list_to_integer(binary_to_list(Port));
		[IP, Port] ->
			parse_addr(binary_to_list(IP), binary_to_list(Port));
		List when is_list(List) -> % IPv6 probably FIXME
			throw({error, ipv6notsupported})
	end.

parse_codecs(CodecBin) when is_binary(CodecBin) ->
	parse_codecs(binary_to_list(CodecBin));
parse_codecs("session") ->
	% A very special case - we don't know what codec is used so rtpproxy must use the same as client uses
	[session];
parse_codecs(CodecStr) ->
	[ begin {Y, []} = string:to_integer(X), rtp_utils:get_codec_from_payload(Y) end || X <- string:tokens(CodecStr, ",")].

decode_params(A) ->
	decode_params(binary_to_list(A), []).

decode_params([], Result) ->
	% Default parameters are - symmetric NAT, non-RFC1918 IPv4 network
	R1 = case proplists:get_value(direction, Result) of
		undefined ->
			Result ++ [{direction, {external, external}}];
		_ ->
			Result
	end,
	R2 = case {proplists:get_value(asymmetric, R1), proplists:get_value(symmetric, R1)} of
		{true, true} ->
			throw({error_syntax, "Both symmetric and asymmetric modifiers are defined"});
		{true, _} ->
			proplists:delete(asymmetric, R1) ++ [{symmetric, false}];
		_ ->
			proplists:delete(symmetric, R1) ++ [{symmetric, true}]
	end,
	lists:sort(R2);
% IPv6
decode_params([$6|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, ipv6));
% Asymmetric
decode_params([$A|Rest], Result) ->
	decode_params(Rest, ensure_alone(proplists:delete(symmetric, Result), asymmetric));
% c0,101,100 - Codecs (a bit tricky)
decode_params([$C|Rest], Result) ->
	case string:span(Rest, "0123456789,") of
		0 ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found C parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		Ret ->
			Rest1 = string:substr(Rest, Ret + 1),
			Codecs = parse_codecs(string:substr(Rest, 1, Ret)),
			decode_params(Rest1, ensure_alone(Result, codecs, Codecs))
	end;
% Direction:
% External (non-RFC1918) network
% Internal (RFC1918) network
% External to External
decode_params([$E, $E|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {external, external}));
% External to Internal
decode_params([$E, $I|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {external, internal}));
% External to External (single E)
decode_params([$E|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {external, external}));
% Internal to External
decode_params([$I, $E|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {internal, external}));
% Internal to Internal
decode_params([$I, $I|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {internal, internal}));
% Internal to Internal (single I)
decode_params([$I|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, direction, {internal, internal}));
% l - local address
decode_params([$L|Rest], Result) ->
	case string:span(Rest, "0123456789.") of
		0 ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found L parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		Ret ->
			Rest1 = string:substr(Rest, Ret + 1),
			{IpAddr, _} = parse_addr(string:substr(Rest, 1, Ret), "0"),
			decode_params(Rest1, ensure_alone(Result, local, IpAddr))
	end;
% r - remote address
decode_params([$R|Rest], Result) ->
	case string:span(Rest, "0123456789.") of
		0 ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found R parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		Ret ->
			Rest1 = string:substr(Rest, Ret + 1),
			{IpAddr, _} = parse_addr(string:substr(Rest, 1, Ret), "0"),
			decode_params(Rest1, ensure_alone(Result, remote, IpAddr))
	end;
% Symmetric
decode_params([$S|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, symmetric));
% Weak
decode_params([$W|Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, weak));
% zNN - repacketization, NN in msec, for the most codecs its value should be
%       in 10ms increments, however for some codecs the increment could differ
%       (e.g. 30ms for GSM or 20ms for G.723).
decode_params([$Z|Rest], Result) ->
	case cut_number(Rest) of
		{error, _} ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found Z parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		{Value, Rest1} ->
			decode_params(Rest1, ensure_alone(Result, repacketize, Value))
	end;

%% Extensions

% Protocol - unofficial extension
decode_params([$P, $0 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, proto, udp));
decode_params([$P, $1 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, proto, tcp));
decode_params([$P, $2 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, proto, sctp));
% Transcode - unofficial extension
decode_params([$T|Rest], Result) ->
	case cut_number(Rest) of
		{error, _} ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found T parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		{Value, Rest1} ->
			decode_params(Rest1, ensure_alone(Result, transcode, rtp_utils:get_codec_from_payload(Value)))
	end;
% Accounting - unofficial extension
decode_params([$V, $0 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, acc, start));
decode_params([$V, $1 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, acc, interim_update));
decode_params([$V, $2 |Rest], Result) ->
	decode_params(Rest, ensure_alone(Result, acc, stop));
% DTMF mapping
decode_params([$D|Rest], Result) ->
	case cut_number(Rest) of
		{error, _} ->
			% Bogus - skip incomplete modifier
			error_logger:warning_msg("Found D parameter w/o necessary values - skipping~n"),
			decode_params(Rest, Result);
		{Value, Rest1} ->
			decode_params(Rest1, ensure_alone(Result, dtmf, Value))
	end;
% Codec mapping
% M<RTP payload ID>=<internal type>
decode_params([$M|Rest], Result) ->
	{ok, KV, Rest1} = cut_kv(Rest),
	KV1 = lists:map(fun
			({K,0}) -> {K, {'ILBC',8000,1}};
			({K,10}) -> {K, {'OPUS',8000,1}};
			({K,20}) -> {K, {'SPEEX',8000,1}};
			({K,V}) -> {K,V}
		end, KV),
	decode_params(Rest1, ensure_alone(Result, cmap, KV1));

% Unknown parameter - just skip it
decode_params([Unknown|Rest], Result) ->
	error_logger:warning_msg("Unsupported parameter while encoding: [~p]~n", [Unknown]),
	decode_params(Rest, Result).

encode_params(Params) ->
	encode_params(Params, []).

encode_params([], Result) ->
	list_to_binary(Result);
encode_params([ipv6|Rest], Result) ->
	encode_params(Rest, Result ++ [$6]);
encode_params([{direction, {external, external}}|Rest], Result) ->
	% FIXME
%	encode_params(Rest, Result ++ "ee");
	encode_params(Rest, Result);
encode_params([{direction, {external, internal}}|Rest], Result) ->
	encode_params(Rest, Result ++ "ei");
encode_params([{direction, {internal, external}}|Rest], Result) ->
	encode_params(Rest, Result ++ "ie");
encode_params([{direction, {internal, internal}}|Rest], Result) ->
	encode_params(Rest, Result ++ "ii");
encode_params([local|Rest], Result) ->
	encode_params(Rest, Result ++ [$l]);
encode_params([remote|Rest], Result) ->
	encode_params(Rest, Result ++ [$r]);
encode_params([{symmetric, true}|Rest], Result) ->
	% FIXME
%	encode_params(Rest, Result ++ [$s]);
	encode_params(Rest, Result);
encode_params([{symmetric, false}|Rest], Result) ->
	encode_params(Rest, Result ++ [$a]);
encode_params([weak|Rest], Result) ->
	encode_params(Rest, Result ++ [$w]);
encode_params([{codecs, Codecs}|[]], Result) ->
	% Codecs must be placed at the end of the parameters' list
	encode_params([], Result ++ [$c] ++ print_codecs(Codecs));
encode_params([{codecs, Codecs}|Rest], Result) ->
	encode_params(Rest ++ [{codecs, Codecs}], Result);
encode_params([Unknown|Rest], Result) ->
	error_logger:warning_msg("Unsupported parameter while encoding: [~p]~n", [Unknown]),
	encode_params(Rest, Result).

print_codecs([session]) ->
	"session";
print_codecs(Codecs) ->
	print_codecs(Codecs, []).
print_codecs([], Result) ->
	Result;
print_codecs([Codec|[]], Result) ->
	print_codecs([], Result ++ print_codec(Codec));
print_codecs([Codec|Rest], Result) ->
		print_codecs(Rest, Result ++ print_codec(Codec) ++ ",").

ensure_alone(Proplist, Param) ->
	proplists:delete(Param, Proplist) ++ [Param].
ensure_alone(Proplist, Param, Value) ->
	proplists:delete(Param, Proplist) ++ [{Param, Value}].

ensure_mediaid([Tag, MediaId]) -> [Tag, MediaId];
ensure_mediaid([Tag]) -> [Tag, <<"0">>].

print_tag_mediaid(Tag, <<"0">>) ->
	Tag;
print_tag_mediaid(Tag, MediaId) ->
	<<Tag/binary, ";", MediaId/binary>>.

print_codec(Codec) ->
	Num = rtp_utils:get_payload_from_codec(Codec),
	[Str] = io_lib:format("~b", [Num]),
	Str.

%%
%% Binary helper functions
%%

binary_to_upper(Binary) when is_binary(Binary) ->
	binary_to_upper(<<>>, Binary).
binary_to_upper(Result, <<>>) ->
	Result;
binary_to_upper(Result, <<C:8, Rest/binary>>) when $a =< C, C =< $z ->
	Symbol = C - 32,
	binary_to_upper(<<Result/binary, Symbol:8>>, Rest);
binary_to_upper(Result, <<C:8, Rest/binary>>) ->
	binary_to_upper(<<Result/binary, C:8>>, Rest).

binary_split(Binary, Val) when is_binary(Binary) ->
	binary_split(<<>>, Binary, Val, []).

binary_split(Head, <<>>, _Val, Result) ->
	lists:reverse([Head | Result]);
binary_split(Head, <<Val:8, Rest/binary>>, Val, Result) ->
	binary_split(<<>>, Rest, Val, [Head | Result]);
binary_split(Head, <<OtherVal:8, Rest/binary>>, Val, Result) ->
	binary_split(<<Head/binary, OtherVal:8>>, Rest, Val, Result).

binary_print_addr({Ip, Port}) ->
	BinIp = list_to_binary(inet_parse:ntoa(Ip)),
	BinPort = list_to_binary(io_lib:format("~b", [Port])),
	<<BinIp/binary, " ", BinPort/binary>>;
binary_print_addr(null) ->
	<<"127.0.0.1 10000">>.

cut(String, Span) ->
	Ret = string:span(String, "0123456789"),
	Rest = string:substr(String, Ret + 1),
	Value = string:substr(String, 1, Ret),
	{Value, Rest}.

cut_number(String) ->
	{V, Rest} = cut(String, "0123456789"),
	{Value, _} = string:to_integer(V),
	{Value, Rest}.

cut_kv(String) ->
	cut_kv(String, []).
cut_kv(String, Ret) ->
	{Key, [ $= | Rest0]} = cut_number(String),
	case cut_number(Rest0) of
		{Val, [ $, | Rest1]} ->
			cut_kv(Rest1, Ret ++ [{Key, Val}]);
		{Val, Rest2} ->
			{ok, Ret ++ [{Key, Val}], Rest2}
	end.
