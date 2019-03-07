%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License at
%% http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%% License for the specific language governing rights and limitations
%% under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2019 Pivotal Software, Inc.  All rights reserved.
%%
-module(rabbit_prometheus_handler).

-export([init/2]).
-export([generate_response/2, content_types_provided/2, is_authorized/2]).
-export([setup/0]).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(SCRAPE_DURATION, telemetry_scrape_duration_seconds).
-define(SCRAPE_SIZE, telemetry_scrape_size_bytes).
-define(SCRAPE_ENCODED_SIZE, telemetry_scrape_encoded_size_bytes).

%% ===================================================================
%% Cowboy Handler Callbacks
%% ===================================================================

init(Req, _State) ->
  {cowboy_rest, Req, #{}}.

content_types_provided(ReqData, Context) ->
    %% Since Prometheus 2.0 Protobuf is no longer supported
    {[{<<"text/plain">>, generate_response}], ReqData, Context}.

is_authorized(ReqData, Context) ->
    {true, ReqData, Context}.

setup() ->
    TelemetryRegistry = telemetry_registry(),

    ScrapeDuration = [{name, ?SCRAPE_DURATION},
                      {help, "Scrape duration"},
                      {labels, ["registry", "content_type"]},
                      {registry, TelemetryRegistry}],
    ScrapeSize = [{name, ?SCRAPE_SIZE},
                  {help, "Scrape size, not encoded"},
                  {labels, ["registry", "content_type"]},
                  {registry, TelemetryRegistry}],
    ScrapeEncodedSize = [{name, ?SCRAPE_ENCODED_SIZE},
                         {help, "Scrape size, encoded"},
                         {labels, ["registry", "content_type", "encoding"]},
                         {registry, TelemetryRegistry}],

    prometheus_summary:declare(ScrapeDuration),
    prometheus_summary:declare(ScrapeSize),
    prometheus_summary:declare(ScrapeEncodedSize).

%% ===================================================================
%% Private functions
%% ===================================================================

generate_response(ReqData, Context) ->
    Method = cowboy_req:method(ReqData),
    Response = gen_response(Method, ReqData),
    {stop, Response, Context}.

gen_response(<<"GET">>, Request) ->
    Registry0 = cowboy_req:binding(registry, Request, <<"default">>),
    case prometheus_registry:exists(Registry0) of
        false ->
          cowboy_req:reply(404, #{}, <<"Unknown Registry">>, Request);
        Registry ->
            gen_metrics_response(Registry, Request)
    end;
gen_response(_, Request) ->
    Request.

gen_metrics_response(Registry, Request) ->
    {Code, RespHeaders, Body} = reply(Registry, Request),

    Headers = to_cowboy_headers(RespHeaders),
    cowboy_req:reply(Code, maps:from_list(Headers), Body, Request).

to_cowboy_headers(RespHeaders) ->
    lists:map(fun to_cowboy_headers_/1, RespHeaders).

to_cowboy_headers_({Name, Value}) ->
    {to_cowboy_name(Name), Value}.

to_cowboy_name(Name) ->
    binary:replace(atom_to_binary(Name, utf8), <<"_">>, <<"-">>).

reply(Registry, Request) ->
    case validate_registry(Registry, registry()) of
        {true, RealRegistry} ->
            format_metrics(Request, RealRegistry);
        {registry_conflict, _ReqR, _ConfR} ->
            {409, [], <<>>};
        {registry_not_found, _ReqR} ->
            {404, [], <<>>};
        false ->
            false
    end.

format_metrics(Request, Registry) ->
    AcceptEncoding = cowboy_req:header(<<"accept-encoding">>, Request, undefined),
    ContentType = prometheus_text_format:content_type(),
    Scrape = render_format(ContentType, Registry),
    Encoding = accept_encoding_header:negotiate(AcceptEncoding, [<<"identity">>,
                                                                 <<"gzip">>]),
    encode_format(ContentType, binary_to_list(Encoding), Scrape, Registry).

render_format(ContentType, Registry) ->
    TelemetryRegistry = telemetry_registry(),

    Scrape = prometheus_summary:observe_duration(
               TelemetryRegistry,
               ?SCRAPE_DURATION,
               [Registry, ContentType],
               fun () -> prometheus_text_format:format(Registry) end),
    prometheus_summary:observe(TelemetryRegistry,
                               ?SCRAPE_SIZE,
                               [Registry, ContentType],
                               iolist_size(Scrape)),
    Scrape.

validate_registry(undefined, auto) ->
    {true, default};
validate_registry(Registry, auto) ->
    {true, Registry};
validate_registry(Registry, Registry) ->
    {true, Registry};
validate_registry(Asked, Conf) ->
    {registry_conflict, Asked, Conf}.

telemetry_registry() ->
    application:get_env(rabbitmq_prometheus, telemetry_registry, default).

registry() ->
    application:get_env(rabbitmq_prometheus, registry, auto).

encode_format(ContentType, Encoding, Scrape, Registry) ->
    Encoded = encode_format_(Encoding, Scrape),
    prometheus_summary:observe(telemetry_registry(),
                               ?SCRAPE_ENCODED_SIZE,
                               [Registry, ContentType, Encoding],
                               iolist_size(Encoded)),
    {200, [{content_type, binary_to_list(ContentType)},
           {content_encoding, Encoding}], Encoded}.

encode_format_("gzip", Scrape) ->
    zlib:gzip(Scrape);
encode_format_("identity", Scrape) ->
    Scrape.
