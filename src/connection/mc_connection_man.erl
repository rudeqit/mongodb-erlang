%%%-------------------------------------------------------------------
%%% @author tihon
%%% @copyright (C) 2014, <COMPANY>
%%% @doc  mongo client connection manager
%%% processes request and response to|from database
%%% @end
%%% Created : 28. май 2014 18:37
%%%-------------------------------------------------------------------
-module(mc_connection_man).
-author("tihon").

-include("mongo_protocol.hrl").

-define(NOT_MASTER_ERROR, 13435).
-define(UNAUTHORIZED_ERROR, 10057).

%% API
-export([reply/1, request_async/2, process_reply/2, request_sync/3]).

-spec request_async(pid(), bson:document()) -> ok | {non_neg_integer(), [bson:document()]}.
request_async(Connection, Request) ->  %request to worker
  Timeout = mc_utils:get_timeout(),
  reply(gen_server:call(Connection, Request, Timeout)).

-spec request_sync(port(), mongo:database(), bson:document()) -> ok | {non_neg_integer(), [bson:document()]}.
request_sync(Socket, Database, Request) ->
  Timeout = mc_utils:get_timeout(),
  inet:setopts(Socket, [{active, false}]),
  {ok, _} = mc_worker_logic:make_request(Socket, Database, Request),
  {ok, Packet} = gen_tcp:recv(Socket, 0, Timeout),
  inet:setopts(Socket, [{active, true}]),
  {Responses, _} = mc_worker_logic:decode_responses(Packet),
  {_, Reply} = hd(Responses),
  reply(Reply).

reply(ok) -> ok;
reply(#reply{cursornotfound = false, queryerror = false} = Reply) ->
  {Reply#reply.cursorid, Reply#reply.documents};
reply(#reply{cursornotfound = false, queryerror = true} = Reply) ->
  [Doc | _] = Reply#reply.documents,
  process_error(maps:get(<<"code">>, Doc), Doc);
reply(#reply{cursornotfound = true, queryerror = false} = Reply) ->
  erlang:error({bad_cursor, Reply#reply.cursorid});
reply({error, Error}) ->
  process_error(error, Error).

process_reply(Doc = #{<<"ok">> := N}, _) when is_number(N) ->   %command succeed | failed
  {N == 1, maps:remove(<<"ok">>, Doc)};
process_reply(Doc, Command) -> %unknown result
  erlang:error({bad_command, Doc}, [Command]).

%% @private
process_error(?NOT_MASTER_ERROR, _) ->
  erlang:error(not_master);
process_error(?UNAUTHORIZED_ERROR, _) ->
  erlang:error(unauthorized);
process_error(_, Doc) ->
  erlang:error({bad_query, Doc}).
