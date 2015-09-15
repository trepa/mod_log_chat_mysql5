%%%----------------------------------------------------------------------
%%% File    : mod_log_chat_mysql5.erl
%%% Author  : Michael Weibel <michael.weibel@amiadogroup.com>
%%% Original Author  : Jérôme Sautret <jerome.sautret@process-one.net>
%%% Purpose : Log chat messages to a mysql db
%%%----------------------------------------------------------------------

-module(mod_log_chat_mysql5).
-author('michael.weibel@amiadogroup.com').

-behaviour(gen_mod).
-behaviour(gen_server).

%% gen_mod callbacks
-export([start/2, start_link/2,
		stop/1,
		log_packet_send/3,
		log_packet_receive/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
		terminate/2, code_change/3]).

%%-define(ejabberd_debug, true).
%-define(LAGER, true).
-include("ejabberd.hrl").
-include("logger.hrl").
-include("jlib.hrl").

-define(PROCNAME, ?MODULE).

table_name() ->
	"mod_log_chat".

table_image() ->
	"mod_log_image".

%% start db connection
start_link(Host, Opts) ->
	Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
	gen_server:start_link({local, Proc}, ?MODULE, [Host, Opts], []).

%% Start module & start gen_server as a child for the db connection
start(Host, Opts) ->
	ejabberd_hooks:add(user_send_packet, Host, ?MODULE, log_packet_send, 55),
	ejabberd_hooks:add(user_receive_packet, Host, ?MODULE, log_packet_receive, 55),
	Proc = gen_mod:get_module_proc(Host, ?PROCNAME),

	ChildSpec =
			{Proc,
				{?MODULE, start_link, [Host, Opts]},
				transient,
				50,
				worker,
				[?MODULE]},
	supervisor:start_child(ejabberd_sup, ChildSpec).

%% stop module (remove hooks) & stop gen server
stop(Host) ->
	ejabberd_hooks:delete(user_send_packet, Host, ?MODULE, log_packet_send, 55),
	ejabberd_hooks:delete(user_receive_packet, Host, ?MODULE, log_packet_receive, 55),
	Proc = gen_mod:get_module_proc(Host, ?PROCNAME),
	gen_server:call(Proc, stop),
	supervisor:delete_child(ejabberd_sup, Proc).

%% called from start_link/2 and sets up the db connection
init([_Host, Opts]) ->
	error_logger:info_msg("Starting ~p", [?MODULE]),

	inets:start(), 

	crypto:start(),
	application:start(emysql),

	Server = gen_mod:get_opt(server, Opts, fun(Val) -> binary_to_list(Val) end, "localhost"),
	Port = gen_mod:get_opt(port, Opts, fun(Val) -> Val end, 3306),
	DB = gen_mod:get_opt(db, Opts, fun(Val) -> binary_to_list(Val) end, "logdb"),
	User = gen_mod:get_opt(user, Opts, fun(Val) -> binary_to_list(Val) end, "root"),
	Password = gen_mod:get_opt(password, Opts, fun(Val) -> binary_to_list(Val) end, ""),
	PoolSize = gen_mod:get_opt(pool_size, Opts, fun(Val) -> Val end, 1),
	Encoding = gen_mod:get_opt(encoding, Opts, fun(Val) -> Val end, utf8),

	error_logger:info_msg("Opening mysql connection ~s@~s:~p/~s ~p ~p ~p", [User, Server, Port, DB, Password, PoolSize, Encoding]),
	emysql:add_pool(mod_log_chat_mysql5_db, PoolSize, User, Password, Server, Port, DB, Encoding),

	prepare_query(insert_row),
	prepare_query(insert_image),

	{ok, undefined}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
	error_logger:info_msg("Terminate called", []),
	emysql:remove_pool(mod_log_chat_mysql5_db),
	emysql:stop(),
	ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call(stop, _From, State) ->
	{stop, normal, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({insert_row, FromJid, ToJid, Body, Type, Id}, State) ->
	Timestamp = now_to_microseconds(erlang:now()),
	sql_query(insert_row, [FromJid, ToJid, Body, Type, Id, Timestamp]),
	{noreply, State};
handle_cast({insert_image, Id, Image}, State) ->
	sql_query(insert_image, [Id, Image]),
	{noreply, State};
handle_cast({receive_message, Jid, Type, Id}, State) ->
	error_logger:info_msg("log_packet_receive message ~p ~p ~p", [Id, Jid, Type]),
	{noreply, State}.

%% handle module infos
handle_info({'DOWN', _MonitorRef, process, _Pid, _Info}, State) ->
	{stop, connection_dropped, State};
handle_info(Info, State) ->
	error_logger:info_msg("Got Info:~p, State:~p", [Info, State]),
	{noreply, State}.

%% ejabberd hook
log_packet_send(From, To, Packet) ->
	log_packet(From, To, Packet).

log_packet(From, To, Packet = #xmlel{name = <<"message">>, attrs = Attrs}) ->
	Type = xml:get_attr_s(<<"type">>, Attrs),
	case Type of
		<<"error">> -> %% we don't log errors
			ok;
		_ ->
			write_packet(From, To, Packet, Type, xml:get_attr_s(<<"id">>, Attrs))
	end;
log_packet(_From, _To, _Packet) ->
	ok.

%% parse message and send to db connection gen_server
write_packet(From, To, Packet, Type, Id) ->
	Body = xml:get_path_s(Packet, [{elem, <<"body">>}, cdata]),
	case Body of
		<<"">> -> %% don't log empty messages
			%%?DEBUG("not logging empty message from ~s",[jlib:jid_to_string(From)]),
			ok;
		_ ->
			Proc = gen_mod:get_module_proc(From#jid.server, ?PROCNAME),
			gen_server:cast(Proc, {insert_row, From#jid.luser, To#jid.luser, Body, Type, Id}),
			Image = xml:get_path_s(Packet, [{elem, <<"image">>}, {attr, <<"URL">>}]),
			case Image of
				<<"">> ->
					ok;
				_ ->
					gen_server:cast(Proc, {insert_image, Id, Image})
			end
			
	end.

log_packet_receive(_JID, From, _To, #xmlel{name = <<"message">>, attrs = Attrs} = _Packet) ->
	Type = xml:get_attr_s(<<"type">>, Attrs),
	case Type of
		<<"error">> -> %% we don't log errors
			%%error_logger:info_msg("dropping error: ~s", [xml:element_to_string(Packet)]),
			ok;
		_ ->
			error_logger:info_msg("dropping error: ~s", [xml:element_to_string(Packet)]),
			Id = xml:get_attr_s(<<"id">>, Attrs),
			Proc = gen_mod:get_module_proc(From#jid.server, ?PROCNAME),
			gen_server:cast(Proc, {receive_message, From#jid.luser, Type, Id}),
			ok
    end;
log_packet_receive(_, _, _, _) ->
	error_logger:info_msg("log_packet_receive empty", []),
    ok.

%% ==================
%% SQL Query API
%% ==================

prepare_query(insert_row) ->
	Query = ["INSERT INTO ", table_name(), " (fromJid, toJid, sentDate, body, type, msg_id, time) VALUES", "(?, ?, NOW(), ?, ?, ?, ?)"],
	emysql:prepare(mod_log_chat_mysql5_stmt, Query);
prepare_query(insert_image) ->
	Query = ["INSERT INTO ", table_image(), " (msg_id, image) VALUES", "(?, ?)"],
	emysql:prepare(mod_log_image_mysql5_stmt, Query);
prepare_query(_) ->
	ok.

sql_query(Type, Params) ->
	case sql_query_internal_silent(Type, Params) of
		{error, Reason} ->
			error_logger:info_msg("~p", [Reason]),
			{error, Reason};
		Rez -> Rez
	end.

sql_query_internal_silent(insert_row, Params) ->
	emysql:execute(mod_log_chat_mysql5_db, mod_log_chat_mysql5_stmt, Params);
sql_query_internal_silent(insert_image, Params) ->
	emysql:execute(mod_log_chat_mysql5_db, mod_log_image_mysql5_stmt, Params);
sql_query_internal_silent(_, _) ->
	ok.

now_to_microseconds({Mega, Sec, Micro}) ->
    %%Epoch time in milliseconds from 1 Jan 1970
    (Mega*1000000 + Sec)*1000000 + Micro. 