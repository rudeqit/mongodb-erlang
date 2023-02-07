-module(mc_worker).
-behaviour(gen_server).

-include("mongo_protocol.hrl").

-export([start_link/1, disconnect/1, hibernate/1]).
-export([
  init/1,
  handle_call/3,
  handle_cast/2,
  handle_info/2,
  terminate/2,
  code_change/3
]).

-record(state, {
  socket :: gen_tcp:socket(),
  request_storage = dict:new(),  %dict:dict()
  buffer = <<>> :: binary(),
  conn_state
}).

-spec start_link(proplists:proplist()) -> {ok, pid()}.
start_link(Options) ->
  proc_lib:start_link(?MODULE, init, [Options]).

%% Make worker to go into hibernate. Any next call will wake it.
%% It should be done if you have problems with memory while fetching > 64B binaries from db.
-spec hibernate(pid()) -> ok.
hibernate(Worker) ->
  gen_server:cast(Worker, hibernate).

%% halt worker, close tcp connection
disconnect(Worker) ->
  gen_server:cast(Worker, halt).

init(Options) ->
  {ok, Socket} = mc_auth:connect_to_database(Options),
  ConnState = form_state(Options),
  try_register(Options),
  proc_lib:init_ack({ok, self()}),
  mc_auth:auth(Socket, Options, ConnState#conn_state.database),
  gen_server:enter_loop(?MODULE, [], #state{socket = Socket, conn_state = ConnState}).


handle_call(NewState = #conn_state{}, _, State = #state{conn_state = OldState}) ->  % update state, return old
  {reply, {ok, OldState}, State#state{conn_state = NewState}};
handle_call(#ensure_index{collection = Coll, index_spec = IndexSpec}, _, State = #state{conn_state = ConnState, socket = Socket}) -> % ensure index request with insert request
  Key = maps:get(<<"key">>, IndexSpec),
  Defaults = {<<"name">>, mc_worker_logic:gen_index_name(Key), <<"unique">>, false, <<"dropDups">>, false},
  Index = bson:update(<<"ns">>, mongo_protocol:dbcoll(ConnState#conn_state.database, Coll), bson:merge(IndexSpec, Defaults)),
  {ok, _} = mc_worker_logic:make_request(Socket, ConnState#conn_state.database,
    #insert{collection = <<"system.indexes">>, documents = [Index]}),
  {reply, ok, State};
handle_call({sync, Request}, _, State = #state{socket = Socket, conn_state = ConnState = #conn_state{}})
  when is_record(Request, insert); is_record(Request, update); is_record(Request, delete) -> % write requests
  Params = {},
  ConfirmWrite = #'query'{ % check-write read request
    batchsize = -1,
    collection = <<"$cmd">>,
    selector = bson:append({<<"getlasterror">>, 1}, Params)
  },
  inet:setopts(Socket, [{active, false}]),
  {ok, Id} = mc_worker_logic:make_request(Socket, ConnState#conn_state.database, [Request, ConfirmWrite]), % ordinary write request
  Response = receive_response(Id, Socket),
  inet:setopts(Socket, [{active, true}]),
  {reply, Response, State};
handle_call(Request, From, State = #state{socket = Socket, conn_state = ConnState = #conn_state{}, request_storage = ReqStor})
  when is_record(Request, insert); is_record(Request, update); is_record(Request, delete) -> % write requests
  case ConnState#conn_state.write_mode of
    unsafe ->   %unsafe (just write)
      {ok, _} = mc_worker_logic:make_request(Socket, ConnState#conn_state.database, Request),
      {reply, ok, State};
    SafeMode -> %safe (write and check)
      Params = case SafeMode of safe -> {}; {safe, Param} -> Param end,
      ConfirmWrite = #'query'{ % check-write read request
        batchsize = -1,
        collection = <<"$cmd">>,
        selector = bson:append({<<"getlasterror">>, 1}, Params)
      },
      {ok, Id} = mc_worker_logic:make_request(Socket, ConnState#conn_state.database, [Request, ConfirmWrite]), % ordinary write request
      RespFun = mc_worker_logic:get_resp_fun(Request, From),
      UReqStor = dict:store(Id, RespFun, ReqStor),  % save function, which will be called on response
      {noreply, State#state{request_storage = UReqStor}}
  end;
handle_call(Request, From, State = #state{socket = Socket, request_storage = RequestStorage, conn_state = CS}) % read requests
  when is_record(Request, 'query'); is_record(Request, getmore) ->
  UpdReq = case is_record(Request, 'query') of
             true -> Request#'query'{slaveok = CS#conn_state.read_mode =:= slave_ok};
             false -> Request
           end,
  {ok, Id} = mc_worker_logic:make_request(Socket, CS#conn_state.database, UpdReq),
  RespFun = mc_worker_logic:get_resp_fun(UpdReq, From),  % save function, which will be called on response
  URStorage = dict:store(Id, RespFun, RequestStorage),
  {noreply, State#state{request_storage = URStorage}};
handle_call(Request = #killcursor{}, _, State = #state{socket = Socket, conn_state = ConnState}) ->
  {ok, _} = mc_worker_logic:make_request(Socket, ConnState#conn_state.database, Request),
  {reply, ok, State};
handle_call({stop, _}, _From, State) -> % stop request
  {stop, normal, ok, State}.

%% @hidden
handle_cast(halt, State) ->
  {stop, normal, State};
handle_cast(hibernate, State) ->
  {noreply, State, hibernate};
handle_cast(_, State) ->
  {noreply, State}.

%% @hidden
handle_info({tcp, _Socket, Data}, State = #state{request_storage = RequestStorage}) ->
  Buffer = <<(State#state.buffer)/binary, Data/binary>>,
  {Responses, Pending} = mc_worker_logic:decode_responses(Buffer),
  UReqStor = mc_worker_logic:process_responses(Responses, RequestStorage),
  {noreply, State#state{buffer = Pending, request_storage = UReqStor}};
handle_info({tcp_closed, _Socket}, State) ->
  {stop, tcp_closed, State};
handle_info({tcp_error, _Socket, Reason}, State) ->
  {stop, Reason, State}.

%% @hidden
terminate(_, State) ->
  catch gen_tcp:close(State#state.socket).

%% @hidden
code_change(_Old, State, _Extra) ->
  {ok, State}.

%% @private
%% Parses proplist to record
form_state(Options) ->
  Database = mc_utils:get_value(database, Options, <<"admin">>),
  RMode = mc_utils:get_value(r_mode, Options, master),
  WMode = mc_utils:get_value(w_mode, Options, unsafe),
  #conn_state{database = Database, read_mode = RMode, write_mode = WMode}.

%% @private
%% Register this process if needed
try_register(Options) ->
  case lists:keyfind(register, 1, Options) of
    false -> ok;
    {_, Name} when is_atom(Name) -> register(Name, self());
    {_, RegFun} when is_function(RegFun) -> RegFun(self())
  end.

receive_response(Id, Socket) ->
  Timeout = mc_utils:get_timeout(),
  {ok, Packet} = gen_tcp:recv(Socket, 0, Timeout),

  {Responses, _} = mc_worker_logic:decode_responses(Packet),
  {ReqestId, Reply} = hd(Responses),

  case ReqestId of
    Id ->
      Reply;
    _ ->
      receive_response(Id, Socket)
  end.
