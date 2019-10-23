%%%-------------------------------------------------------------------
%%%
%%% Copyright (C) 2002-2019 ProcessOne, SARL. All Rights Reserved.
%%%
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%%-------------------------------------------------------------------
-module(xmpp_socket).
-author('alexey@process-one.net').
-dialyzer({no_match, [send/2, parse/2]}).

%% API
-export([new/3,
	 connect/3,
	 connect/4,
	 connect/5,
	 reset_stream/1,
	 send_element/2,
	 send_header/2,
	 send_trailer/1,
	 send/2,
	 send_xml/2,
	 recv/2,
	 activate/1,
	 change_shaper/2,
	 monitor/1,
	 get_sockmod/1,
	 get_transport/1,
	 close/1,
	 pp/1,
	 sockname/1,
	 peername/1,
	 send_ws_ping/1]).

-include("xmpp.hrl").

-type sockmod() :: gen_tcp | ext_mod().
-type socket() :: inet:socket() | ext_socket().
-type ext_mod() :: module().
-type ext_socket() :: any().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
-type stream_element() :: {xmlstreamelement, fxml:xmlel()} |
			  {xmlstreamstart, binary(), [{binary(), binary()}]} |
			  {xmlstreamend, binary()} |
			  {xmlstreamraw, iodata()}.

-record(socket_state, {sockmod           :: sockmod(),
                       socket            :: socket(),
		       max_stanza_size   :: timeout(),
		       xml_stream :: undefined | fxml_stream:xml_stream_state(),
		       shaper = none :: none | p1_shaper:state(),
		       sock_peer_name = none :: none | {endpoint(), endpoint()}}).

-type socket_state() :: #socket_state{}.

-export_type([socket/0, socket_state/0, sockmod/0]).

-callback send_xml(ext_socket(), stream_element()) -> ok | {error, inet:posix()}.
-callback get_owner(ext_socket()) -> pid().
-callback get_transport(ext_socket()) -> atom().
-callback change_shaper(ext_socket(), none | p1_shaper:state()) -> ok.
-callback controlling_process(ext_socket(), pid()) -> ok | {error, inet:posix()}.
-callback close(ext_socket()) -> ok | {error, inet:posix()}.
-callback sockname(ext_socket()) -> {ok, endpoint()} | {error, inet:posix()}.
-callback peername(ext_socket()) -> {ok, endpoint()} | {error, inet:posix()}.
-callback setopts(ext_socket(), [{active, once}]) -> ok | {error, inet:posix()}.

-define(dbg(Fmt, Args),
	case xmpp_config:debug(global) of
	    {ok, true} -> error_logger:info_msg(Fmt, Args);
	    _ -> false
	end).

%%====================================================================
%% API
%%====================================================================
-spec new(sockmod(), socket(), [proplists:property()]) -> socket_state().
new(SockMod, Socket, Opts) ->
    MaxStanzaSize = proplists:get_value(max_stanza_size, Opts, infinity),
    SockPeer =  proplists:get_value(sock_peer_name, Opts, none),
    XMLStream = case get_owner(SockMod, Socket) of
		    Pid when Pid == self() ->
			fxml_stream:new(self(), MaxStanzaSize);
		    _ ->
			undefined
		end,
    #socket_state{sockmod = SockMod,
		  socket = Socket,
		  xml_stream = XMLStream,
		  max_stanza_size = MaxStanzaSize,
		  sock_peer_name = SockPeer}.

connect(Addr, Port, Opts) ->
    connect(Addr, Port, Opts, infinity, self()).

connect(Addr, Port, Opts, Timeout) ->
    connect(Addr, Port, Opts, Timeout, self()).

connect(Addr, Port, Opts, Timeout, Owner) ->
    case gen_tcp:connect(Addr, Port, Opts, Timeout) of
	{ok, Socket} ->
	    SocketData = new(gen_tcp, Socket, []),
	    case controlling_process(SocketData, Owner) of
		ok ->
		    activate_after(Socket, Owner, 0),
		    {ok, SocketData};
		{error, _Reason} = Error ->
		    gen_tcp:close(Socket),
		    Error
	    end;
	{error, _Reason} = Error ->
	    Error
    end.

reset_stream(#socket_state{xml_stream = XMLStream,
			   sockmod = SockMod, socket = Socket,
			   max_stanza_size = MaxStanzaSize} = SocketData) ->
    if XMLStream /= undefined ->
	    XMLStream1 = try fxml_stream:reset(XMLStream)
			 catch error:_ ->
				 fxml_stream:close(XMLStream),
				 fxml_stream:new(self(), MaxStanzaSize)
			 end,
	    SocketData#socket_state{xml_stream = XMLStream1};
       true ->
	    Socket1 = SockMod:reset_stream(Socket),
	    SocketData#socket_state{socket = Socket1}
    end.

-spec send_element(socket_state(), fxml:xmlel()) -> ok | {error, inet:posix()}.
send_element(#socket_state{xml_stream = undefined} = SocketData, El) ->
    send_xml(SocketData, {xmlstreamelement, El});
send_element(SocketData, El) ->
    send(SocketData, fxml:element_to_binary(El)).

-spec send_header(socket_state(), fxml:xmlel()) -> ok | {error, inet:posix()}.
send_header(#socket_state{xml_stream = undefined} = SocketData, El) ->
    send_xml(SocketData, {xmlstreamstart, El#xmlel.name, El#xmlel.attrs});
send_header(SocketData, El) ->
    send(SocketData, fxml:element_to_header(El)).

-spec send_trailer(socket_state()) -> ok | {error, inet:posix()}.
send_trailer(#socket_state{xml_stream = undefined} = SocketData) ->
    send_xml(SocketData, {xmlstreamend, <<"stream:stream">>});
send_trailer(SocketData) ->
    send(SocketData, <<"</stream:stream>">>).

-spec send_ws_ping(socket_state()) -> ok | {error, inet:posix()}.
send_ws_ping(#socket_state{xml_stream = undefined}) ->
    ok;
send_ws_ping(SocketData) ->
    send(SocketData, <<"\r\n\r\n">>).

-spec send(socket_state(), iodata()) -> ok | {error, closed | inet:posix()}.
send(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, Data) ->
    ?dbg("(~s) Send XML on stream = ~p", [pp(SocketData), Data]),
    try SockMod:send(Socket, Data) of
	{error, einval} -> {error, closed};
	Result -> Result
    catch _:badarg ->
	    %% Some modules throw badarg exceptions on closed sockets
	    %% TODO: their code should be improved
	    {error, closed}
    end.

-spec send_xml(socket_state(), stream_element()) -> ok | {error, any()}.
send_xml(#socket_state{sockmod = SockMod, socket = Socket} = SocketData, El) ->
    ?dbg("(~s) Send XML on stream = ~p", [pp(SocketData),
					  stringify_stream_element(El)]),
    SockMod:send_xml(Socket, El).

stringify_stream_element({xmlstreamstart, Name, Attrs}) ->
    fxml:element_to_header(#xmlel{name = Name, attrs = Attrs});
stringify_stream_element({xmlstreamend, Name}) ->
    <<"</",Name/binary,">">>;
stringify_stream_element({xmlstreamelement, El}) ->
    fxml:element_to_binary(El);
stringify_stream_element({xmlstreamerror, Data}) ->
    Err = iolist_to_binary(io_lib:format("~p", [Data])),
    <<"!StreamError: ", Err/binary>>;
stringify_stream_element({xmlstreamraw, Data}) ->
    Data.

recv(SocketData, Data) -> parse(SocketData, Data).

-spec change_shaper(socket_state(), none | p1_shaper:state()) -> socket_state().
change_shaper(#socket_state{xml_stream = XMLStream,
			    sockmod = SockMod,
			    socket = Socket} = SocketData, Shaper) ->
    if XMLStream /= undefined ->
	    SocketData#socket_state{shaper = Shaper};
       true ->
	    SockMod:change_shaper(Socket, Shaper),
	    SocketData
    end.

monitor(#socket_state{xml_stream = undefined,
		      sockmod = SockMod, socket = Socket}) ->
    erlang:monitor(process, SockMod:get_owner(Socket));
monitor(_) ->
    make_ref().

controlling_process(#socket_state{sockmod = SockMod,
				  socket = Socket}, Pid) ->
    SockMod:controlling_process(Socket, Pid).

get_sockmod(SocketData) ->
    SocketData#socket_state.sockmod.

get_transport(#socket_state{sockmod = ranch_tcp}) -> tcp;
get_transport(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:get_transport(Socket).

get_owner(ranch_tcp, _) ->  self();
get_owner(SockMod, Socket) -> SockMod:get_owner(Socket).

close(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:close(Socket).

-spec sockname(socket_state()) -> {ok, endpoint()} | {error, inet:posix()}.
sockname(#socket_state{sock_peer_name = {SN, _}}) ->
    {ok, SN};
sockname(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:sockname(Socket).

-spec peername(socket_state()) -> {ok, endpoint()} | {error, inet:posix()}.
peername(#socket_state{sock_peer_name = {_, PN}}) ->
    {ok, PN};
peername(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:peername(Socket).

activate(#socket_state{sockmod = SockMod, socket = Socket}) ->
    SockMod:setopts(Socket, [{active, once}]).

activate_after(Socket, Pid, Pause) ->
    if Pause > 0 ->
	    erlang:send_after(Pause, Pid, {tcp, Socket, <<>>});
       true ->
	    Pid ! {tcp, Socket, <<>>}
    end,
    ok.

pp(#socket_state{sockmod = SockMod, socket = Socket} = State) ->
    Transport = get_transport(State),
    Receiver = get_owner(SockMod, Socket),
    io_lib:format("~s|~w", [Transport, Receiver]).

parse(SocketData, Data) when Data == <<>>; Data == [] ->
    case activate(SocketData) of
	ok ->
	    {ok, SocketData};
	{error, _} = Err ->
	    Err
    end;
parse(SocketData, [El | Els]) when is_record(El, xmlel) ->
    ?dbg("(~s) Received XML on stream = ~p", [pp(SocketData),
					      fxml:element_to_binary(El)]),
    self() ! {'$gen_event', {xmlstreamelement, El}},
    parse(SocketData, Els);
parse(SocketData, [El | Els]) when
      element(1, El) == xmlstreamstart;
      element(1, El) == xmlstreamelement;
      element(1, El) == xmlstreamend;
      element(1, El) == xmlstreamerror ->
    ?dbg("(~s) Received XML on stream = ~p", [pp(SocketData),
					      stringify_stream_element(El)]),
    self() ! {'$gen_event', El},
    parse(SocketData, Els);
parse(#socket_state{xml_stream = XMLStream,
		    socket = Socket,
		    shaper = ShaperState} = SocketData, Data)
  when is_binary(Data) ->
    ?dbg("(~s) Received XML on stream = ~p", [pp(SocketData), Data]),
    XMLStream1 = fxml_stream:parse(XMLStream, Data),
    {ShaperState1, Pause} = shaper_update(ShaperState, byte_size(Data)),
    Ret = if Pause > 0 ->
		  activate_after(Socket, self(), Pause);
	     true ->
		  activate(SocketData)
	  end,
    case Ret of
	ok ->
	    {ok, SocketData#socket_state{xml_stream = XMLStream1,
					 shaper = ShaperState1}};
	{error, _} = Err ->
	    Err
    end.

shaper_update(none, _) ->
    {none, 0};
shaper_update(Shaper, Size) ->
    p1_shaper:update(Shaper, Size).
