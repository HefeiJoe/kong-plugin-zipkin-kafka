local kafka_producers = require "kong.plugins.zipkin-kafka.producers".new
local to_hex = require "resty.string".to_hex
local cjson = require "cjson".new()
cjson.encode_number_precision(16)
local config = {}
local mt_cache = { __mode = "k" }
local producers_cache = setmetatable({}, mt_cache)

local zipkin_reporter_methods = {}
local zipkin_reporter_mt = {
	__name = "kong.plugins.zipkin-kafka.reporter";
	__index = zipkin_reporter_methods;
}

local function new_zipkin_reporter(conf)
	--local http_endpoint = conf.http_endpoint
  config = conf
  local bootstrap_servers = conf.bootstrap_servers
  local default_service_name = conf.default_service_name

return setmetatable({
                default_service_name = default_service_name;
		--http_endpoint = http_endpoint;
                bootstrap_servers = bootstrap_servers;
		pending_spans = {};
		pending_spans_n = 0;
	}, zipkin_reporter_mt)
end

--[[ --- Computes a cache key for a given configuration.
local function cache_key(conf)
  -- here we rely on validation logic in schema that automatically assigns a unique id
  -- on every configuartion update
  return conf.uuid
end]]

local span_kind_map = {
	client = "CLIENT";
	server = "SERVER";
	producer = "PRODUCER";
	consumer = "CONSUMER";
}
function zipkin_reporter_methods:report(span)
	local span_context = span:context()

	local zipkin_tags = {}
	for k, v in span:each_tag() do
		-- Zipkin tag values should be strings
		-- see https://zipkin.io/zipkin-api/#/default/post_spans
		-- and https://github.com/Kong/kong-plugin-zipkin/pull/13#issuecomment-402389342
		zipkin_tags[k] = tostring(v)
	end

	local span_kind = zipkin_tags["span.kind"]
	zipkin_tags["span.kind"] = nil

	local localEndpoint do
		local serviceName = zipkin_tags["peer.service"]
		if serviceName then
			zipkin_tags["peer.service"] = nil
			localEndpoint = {
				serviceName = serviceName;
				-- TODO: ip/port from ngx.var.server_name/ngx.var.server_port?
			}
		else
                        -- configurable override of the unknown-service-name spans
                        if self.default_service_name then
                                localEndpoint = {
                                        serviceName = self.default_service_name;
                                }
                        -- needs to be null; not the empty object
                        else
                                localEndpoint = cjson.null
                        end
		end
	end

	local remoteEndpoint do
		local peer_port = span:get_tag "peer.port" -- get as number
		if peer_port then
			zipkin_tags["peer.port"] = nil
			remoteEndpoint = {
				ipv4 = zipkin_tags["peer.ipv4"];
				ipv6 = zipkin_tags["peer.ipv6"];
				port = peer_port; -- port is *not* optional
			}
			zipkin_tags["peer.ipv4"] = nil
			zipkin_tags["peer.ipv6"] = nil
		else
			remoteEndpoint = cjson.null
		end
	end

	local zipkin_span = {
		traceId = to_hex(span_context.trace_id);
		name = span.name;
		parentId = span_context.parent_id and to_hex(span_context.parent_id) or nil;
		id = to_hex(span_context.span_id);
		kind = span_kind_map[span_kind];
		timestamp = span.timestamp * 1000000;
		duration = math.floor(span.duration * 1000000); -- zipkin wants integer
		-- shared = nil; -- We don't use shared spans (server reuses client generated spanId)
		-- TODO: debug?
		localEndpoint = localEndpoint;
		remoteEndpoint = remoteEndpoint;
		tags = zipkin_tags;
		annotations = span.logs -- XXX: not guaranteed by documented opentracing-lua API to be in correct format
	}

	local i = self.pending_spans_n + 1
	self.pending_spans[i] = zipkin_span
	self.pending_spans_n = i
end

function zipkin_reporter_methods:flush(conf)
	if self.pending_spans_n == 0 then
		return true
	end

	local pending_spans = cjson.encode(self.pending_spans)
	self.pending_spans = {}
	self.pending_spans_n = 0

  --[[ local cache_key = cache_key(conf)
  if not cache_key then
    ngx.log(ngx.ERR, "[zipkin-kafka] cannot log a given request because configuration has no uuid")
    return
  end

  local producer = producers_cache[cache_key]
  if not producer then
    kong.log.notice("creating a new Kafka Producer for cache key: ", cache_key)
]]
    local err
    producer, err = kafka_producers(config)
    if not producer then
      ngx.log(ngx.ERR, "[zipkin-kafka] failed to create a Kafka Producer for a given configuration: ", err)
      return
    end
  --[[
    producers_cache[cache_key] = producer
  end]]

  local ok, err = producer:send(config.topic, nil, pending_spans)
  if not ok then
    ngx.log(ngx.ERR, "[zipkin-kafka] failed to send a message on topic ", config.topic, ": ", err)
    return nil
  end
  return true
end

return {
	new = new_zipkin_reporter;
}
