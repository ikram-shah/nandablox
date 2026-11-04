-- Gateway: the Roblox side of the slot contract (docs/market-design.md, "The
-- slot contract"). Off by default; the market works fully without it.
--
-- A Roblox server may make about 500 outbound HTTP requests a minute, so it
-- never calls agents one by one: every GATEWAY_EVERY_S it makes ONE
-- `POST /v1/tick` carrying every case an outside monitor must decide and every
-- decision an outside agent must make. Only one request is ever in flight, a
-- sliding-window ceiling refuses the rest, and failures back off (doubling to
-- 30 s). Anything late or missing falls back to the built-in policy inside
-- MarketSim (the rule monitor after MONITOR_WAIT_S; the scripted seller after
-- AGENT_HOLD_S), so the market never waits on the network.
--
-- Pure Luau: the HTTP call and JSON are injected, so Lune tests drive it with
-- a fake gateway.
--
--   local gw = Gateway.new({ config = Config, post = post, encode = enc, decode = dec })
--   -- every server tick:
--   gw:tick(sim, now, jobId)            -- returns at once; post runs in the caller's coroutine
--
-- `post(url, bodyString, headers) -> (ok: boolean, status: number, body: string)`
-- may yield (HttpService:RequestAsync does); the server calls gw:tick inside
-- task.spawn so nothing else waits for it.

local Gateway = {}
Gateway.__index = Gateway

-- opts = { config, post, encode, decode, enabled?, url?, headers? }
function Gateway.new(opts)
	local cfg = opts.config
	local self = setmetatable({
		cfg = cfg,
		post = opts.post,
		encode = opts.encode,
		decode = opts.decode,
		clock = opts.clock,
		enabled = if opts.enabled == nil then cfg.GATEWAY_ENABLED else opts.enabled,
		url = opts.url or (cfg.GATEWAY_URL .. cfg.GATEWAY_PATH),
		headers = opts.headers or { ["Content-Type"] = "application/json" },
		inflight = false,
		nextAt = 0,
		backoff = 0,
		window = {},
		stats = { requests = 0, ok = 0, errors = 0, refused = 0, verdicts = 0, actions = 0, empty = 0 },
		health = "off",
		lastError = nil :: string?,
		lastRoundTrip = nil :: number?,
	}, Gateway)
	return self
end

function Gateway:setEnabled(on: boolean)
	self.enabled = on and true or false
	self.health = self.enabled and "idle" or "off"
	self.backoff = 0
	self.nextAt = 0
end

local function allowed(self, now: number): boolean
	local cut = now - 60
	local keep = {}
	for _, t in self.window do
		if t > cut then
			table.insert(keep, t)
		end
	end
	self.window = keep
	return #keep < self.cfg.GATEWAY_MAX_PER_MINUTE
end

-- Is there anything outside code must decide?
local function worthAsking(body): boolean
	return #body.cases > 0 or #body.decisions > 0
end

-- One tick of the conversation. Returns what happened: "off", "busy", "wait",
-- "idle" (nothing to ask), "refused" (over the ceiling), "ok", or "error".
function Gateway:tick(sim, now: number, serverId: string?): string
	if not self.enabled then
		return "off"
	end
	if self.inflight then
		return "busy"
	end
	if now < self.nextAt then
		return "wait"
	end
	self.nextAt = now + self.cfg.GATEWAY_EVERY_S
	local body = sim:gatewayRequest(serverId)
	if not worthAsking(body) then
		self.stats.empty += 1
		return "idle"
	end
	if not allowed(self, now) then
		self.stats.refused += 1
		return "refused"
	end
	table.insert(self.window, now)
	self.inflight = true
	self.stats.requests += 1
	local sentAt = self.clock and self.clock() or now
	local okEnc, text = pcall(self.encode, body)
	if not okEnc then
		self.inflight = false
		return self:fail(now, "encode: " .. tostring(text))
	end
	local okCall, ok, status, respText = pcall(self.post, self.url, text, self.headers)
	self.inflight = false
	if not okCall then
		return self:fail(now, tostring(ok))
	end
	if not ok or (status and (status < 200 or status >= 300)) then
		return self:fail(now, "HTTP " .. tostring(status))
	end
	local okDec, resp = pcall(self.decode, respText)
	if not okDec or type(resp) ~= "table" then
		return self:fail(now, "bad JSON")
	end
	local nv, na = sim:applyGateway(resp)
	self.stats.ok += 1
	self.stats.verdicts += nv
	self.stats.actions += na
	self.backoff = 0
	self.health = "ok"
	self.lastError = nil
	self.lastRoundTrip = (self.clock and self.clock() or now) - sentAt
	return "ok"
end

function Gateway:fail(now: number, why: string): string
	self.stats.errors += 1
	self.health = "error"
	self.lastError = string.sub(why, 1, 120)
	self.backoff = math.min(30, self.backoff == 0 and 3 or self.backoff * 2)
	self.nextAt = now + self.backoff
	return "error"
end

function Gateway:status()
	return {
		enabled = self.enabled,
		health = self.health,
		lastError = self.lastError,
		requests = self.stats.requests,
		ok = self.stats.ok,
		errors = self.stats.errors,
		verdicts = self.stats.verdicts,
		actions = self.stats.actions,
	}
end

return Gateway
