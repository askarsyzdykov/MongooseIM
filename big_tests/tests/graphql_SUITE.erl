-module(graphql_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("exml/include/exml.hrl").

-compile([export_all, nowarn_export_all]).

-import(distributed_helper, [mim/0, require_rpc_nodes/1, rpc/4]).
-import(graphql_helper, [execute/3, execute_auth/2, execute_user/3,
                         get_value/2, get_bad_request/1]).

-define(assertAdminAuth(Domain, Type, Auth, Data),
        assert_auth(#{<<"domain">> => Domain,
                      <<"authStatus">> => atom_to_binary(Auth),
                      <<"authType">> => maybe_atom_to_bin(Type)}, Data)).
-define(assertUserAuth(Username, Auth, Data),
        assert_auth(#{<<"username">> => Username,
                      <<"authStatus">> => atom_to_binary(Auth)}, Data)).

suite() ->
    require_rpc_nodes([mim]) ++ escalus:suite().

all() ->
    [{group, cowboy_handler},
     {group, admin_handler},
     {group, domain_admin_handler},
     {group, user_handler},
     {group, categories_disabled}].

groups() ->
    [{cowboy_handler, [parallel], cowboy_handler()},
     {user_handler, [parallel], user_handler()},
     {domain_admin_handler, [parallel], domain_admin_handler()},
     {admin_handler, [parallel], admin_handler()},
     {categories_disabled, [parallel], categories_disabled_tests()}].

cowboy_handler() ->
    [can_connect_to_admin,
     can_connect_to_domain_admin,
     can_connect_to_user].

user_handler() ->
    [user_checks_auth,
     auth_user_checks_auth | common_tests()].
admin_handler() ->
    [admin_checks_auth,
     auth_admin_checks_auth | common_tests()].
domain_admin_handler() ->
    [domain_admin_checks_auth,
     auth_domain_admin_checks_auth | common_tests()].

common_tests() ->
    [can_load_graphiql].

categories_disabled_tests() ->
    [category_disabled_error_test,
     admin_checks_auth,
     category_does_not_exist_error,
     listener_reply_with_validation_error,
     multiple_categories_query_test].

init_per_suite(Config) ->
    Config1 = escalus:init_per_suite(Config),
    dynamic_modules:save_modules(domain_helper:host_type(), Config1).

end_per_suite(Config) ->
    dynamic_modules:restore_modules(Config),
    escalus_fresh:clean(),
    escalus:end_per_suite(Config).

init_per_group(admin_handler, Config) ->
    graphql_helper:init_admin_handler(Config);
init_per_group(domain_admin_handler, Config) ->
    case mongoose_helper:is_rdbms_enabled(domain_helper:host_type()) of
        true ->
            graphql_helper:init_domain_admin_handler(Config);
        false ->
            {skip, require_rdbms}
    end;
init_per_group(user_handler, Config) ->
    Config1 = escalus:create_users(Config, escalus:get_users([alice])),
    [{schema_endpoint, user} | Config1];
init_per_group(categories_disabled, Config) ->
    #{node := Node} = mim(),
    CowboyGraphqlListenerConfig = graphql_helper:get_listener_config(Node, admin),
    #{handlers := [SchemaConfig]} = CowboyGraphqlListenerConfig,
    UpdatedSchemaConfig = maps:put(allowed_categories, [<<"vcard">>, <<"checkAuth">>], SchemaConfig),
    UpdatedListenerConfig = maps:put(handlers, [UpdatedSchemaConfig], CowboyGraphqlListenerConfig),
    mongoose_helper:restart_listener(mim(), UpdatedListenerConfig),
    Config1 = [{admin_listener_config, CowboyGraphqlListenerConfig} | Config],
    graphql_helper:init_admin_handler(Config1);
init_per_group(cowboy_handler, Config) ->
    Config.

end_per_group(user_handler, Config) ->
    escalus:delete_users(Config, escalus:get_users([alice]));
end_per_group(domain_admin_handler, Config) ->
    graphql_helper:end_domain_admin_handler(Config);
end_per_group(categories_disabled, Config) ->
    ListenerConfig = ?config(admin_listener_config, Config),
    mongoose_helper:restart_listener(mim(), ListenerConfig),
    Config;
end_per_group(_, _Config) ->
    ok.

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

can_connect_to_admin(_Config) ->
    ?assertMatch({{<<"400">>, <<"Bad Request">>}, _}, execute(admin, #{}, undefined)).

can_connect_to_domain_admin(_Config) ->
    ?assertMatch({{<<"400">>, <<"Bad Request">>}, _}, execute(domain_admin, #{}, undefined)).

can_connect_to_user(_Config) ->
    ?assertMatch({{<<"400">>, <<"Bad Request">>}, _}, execute(user, #{}, undefined)).

can_load_graphiql(Config) ->
    Ep = ?config(schema_endpoint, Config),
    {Status, Html} = get_graphiql_website(Ep),
    ?assertEqual({<<"200">>, <<"OK">>}, Status),
    ?assertNotEqual(nomatch, binary:match(Html, <<"Loading...">>)).

user_checks_auth(Config) ->
    Ep = ?config(schema_endpoint, Config),
    StatusData = execute(Ep, user_check_auth_body(), undefined),
    ?assertUserAuth(null, 'UNAUTHORIZED', StatusData).

auth_user_checks_auth(Config) ->
    escalus:fresh_story(
        Config, [{alice, 1}],
        fun(Alice) ->
            AliceJID = escalus_utils:jid_to_lower(escalus_client:short_jid(Alice)),
            StatusData = execute_user(user_check_auth_body(), Alice, Config),
            ?assertUserAuth(AliceJID, 'AUTHORIZED', StatusData)
        end).

admin_checks_auth(Config) ->
    Ep = ?config(schema_endpoint, Config),
    StatusData = execute(Ep, admin_check_auth_body(), undefined),
    ?assertAdminAuth(null, null, 'UNAUTHORIZED', StatusData).

auth_admin_checks_auth(Config) ->
    StatusData = execute_auth(admin_check_auth_body(), Config),
    ?assertAdminAuth(null, 'ADMIN', 'AUTHORIZED', StatusData).

domain_admin_checks_auth(Config) ->
    Ep = ?config(schema_endpoint, Config),
    Res = execute(Ep, admin_check_auth_body(), undefined),
    ?assertAdminAuth(null, null, 'UNAUTHORIZED', Res).

auth_domain_admin_checks_auth(Config) ->
    {Username, _} = ?config(domain_admin, Config),
    Domain = escalus_utils:get_server(Username),
    Res = execute_auth(admin_check_auth_body(), Config),
    ?assertAdminAuth(Domain, 'DOMAIN_ADMIN', 'AUTHORIZED', Res).

category_disabled_error_test(Config) ->
    Status = execute_auth(admin_server_get_loglevel_body(), Config),
    {_Code, #{<<"errors">> := [Msg]}} = Status,
    ?assertEqual(<<"category_disabled">>, get_value([extensions, code], Msg)),
    ?assertEqual([<<"server">>], get_value([path], Msg)).

category_does_not_exist_error(Config) ->
    Ep = ?config(schema_endpoint, Config),
    Status = execute(Ep, #{<<"query">> => <<"{ field ">>}, undefined),
    get_bad_request(Status),
    {_Code, #{<<"errors">> := [Msg]}} = Status,
    ?assertEqual(<<"parser_error">>, get_value([extensions, code], Msg)).

listener_reply_with_validation_error(Config) ->
    Ep = ?config(schema_endpoint, Config),
    Body = #{<<"query">> => <<"query Q1 { field } query Q1 { field }">>,
             <<"operationName">> => <<"Q1">>},
    {Status, Data} = execute(Ep, Body, undefined).

multiple_categories_query_test(Config) ->
    Status = execute_auth(user_check_auth_multiple(), Config),
    {_Code, #{<<"errors">> := [ErrorMsg], <<"data">> := DataMsg}} = Status,
    ?assertEqual(<<"category_disabled">>, get_value([extensions, code], ErrorMsg)),
    ?assertEqual([<<"server">>], get_value([path], ErrorMsg)),
    ?assertEqual(<<"AUTHORIZED">>, get_value([checkAuth, authStatus], DataMsg)).

%% Helpers

assert_auth(Auth, {Status, Data}) ->
    ?assertEqual({<<"200">>, <<"OK">>}, Status),
    ?assertMatch(#{<<"data">> := #{<<"checkAuth">> := Auth}}, Data).

get_graphiql_website(EpName) ->
    Request =
      #{port => graphql_helper:get_listener_port(EpName),
        role => {graphql, atom_to_binary(EpName)},
        method => <<"GET">>,
        headers => [{<<"Accept">>, <<"text/html">>}],
        return_maps => true,
        path => "/graphql"},
    rest_helper:make_request(Request).

maybe_atom_to_bin(null) -> null;
maybe_atom_to_bin(X) -> atom_to_binary(X).

admin_check_auth_body() ->
    #{query => "{ checkAuth { domain authType authStatus } }"}.

admin_server_get_loglevel_body() ->
    #{query => "{ server { getLoglevel } }"}.

user_check_auth_body() ->
    #{query => "{ checkAuth { username authStatus } }"}.

user_check_auth_multiple() ->
    #{query => "{ checkAuth { authStatus } server { getLoglevel } }"}.
