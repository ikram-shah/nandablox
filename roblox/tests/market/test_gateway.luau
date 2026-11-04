-- Gateway: one POST /v1/tick per tick, the slot contract's shapes, off by
-- default, and every failure falls back without the market waiting.

local lib = require("./lib")
local serde = require("@lune/serde")

local function enc(t)
	return serde.encode("json", t)
end
local function dec(s)
	return serde.decode("json", s)
end

local function sim()
	local s = lib.MarketSim.new({ seed = 21, n = 300 })
	s:setMonitor("external", "gateway")
	s:addWatcher("me")
	s:runUntil(10)
	s:injectFraud("scam", { price = 0.7 })
	s:injectFraud("scam", { price = 0.6 })
	s:drain()
	return s
end

return function(t)
	t.case("off by default: no request at all", function(A)
		local calls = 0
		local gw = lib.Gateway.new({ config = lib.Config, encode = enc, decode = dec, post = function()
			calls += 1
			return true, 200, "{}"
		end })
		A.eq(gw.enabled, false)
		A.eq(gw:tick(sim(), 0), "off")
		A.eq(calls, 0)
	end)

	t.case("one call carries every case and decision, in the contract's shapes", function(A)
		local s = sim()
		local seller = s.sellers[1]
		s:setPolicy(seller.id, "external", "gemini")
		local seen
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function(url, body, headers)
			seen = { url = url, body = dec(body), headers = headers }
			local verdicts, actions = {}, {}
			for _, c in seen.body.cases do
				table.insert(verdicts, { case = c.id, verdict = "escalate", monitor = "team-a", reason = "test" })
			end
			for _, d in seen.body.decisions do
				table.insert(actions, { agent = d.agent, set_price = d.market })
			end
			return true, 200, enc({ verdicts = verdicts, actions = actions })
		end })
		A.eq(gw:tick(s, s.now, "job-1"), "ok")
		A.eq(seen.url, lib.Config.GATEWAY_URL .. "/v1/tick")
		local b = seen.body
		A.eq(b.server, "job-1")
		A.eq(seen.headers["X-Nanda-Server"], "job-1", "the per-server rate-limit key")
		A.eq(b.monitor, nil, "monitor named 'gateway': ask every registered monitor")
		A.ok(type(b.t) == "number" and type(b.market.bread) == "number", "t, market")
		A.eq(b.lever.signatures, true)
		A.ok(#b.cases > 0, "cases")
		local c = b.cases[1]
		for _, k in { "id", "stall", "good", "price", "market", "age_s", "ratings", "signature", "twin", "deadline_s" } do
			A.ok(c[k] ~= nil, "case field " .. k)
		end
		A.eq(c.truth, nil, "no ground truth on the wire")
		A.ok(c.price == math.floor(c.price), "integer cents")
		A.eq(#b.decisions, 1)
		A.eq(gw.stats.verdicts, #b.cases, "every verdict applied")
		A.eq(gw.stats.actions, 1)
		A.eq(gw:tick(s, s.now + 0.5), "wait", "one call per tick, not more")
	end)

	t.case("a failing gateway backs off and the market carries on with the rules", function(A)
		local s = sim()
		local calls = 0
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function()
			calls += 1
			error("HttpError: ConnectFail")
		end })
		A.eq(gw:tick(s, s.now), "error")
		A.eq(gw.backoff, 3)
		A.eq(gw:tick(s, s.now + 2.5), "wait", "backing off")
		A.eq(gw:tick(s, s.now + 3.1), "error")
		A.eq(gw.backoff, 6, "doubling")
		-- the market didn't wait: cases fell back to the rules
		s:runUntil(s.now + 10)
		A.ok(s.gatewayStats.fallbacks > 0, "rules decided")
		for _, c in s.caseList do
			A.ok(c.stage ~= "monitor" or s.now - c.created <= lib.Config.MONITOR_WAIT_S + 0.01, "nothing stuck in the monitor")
		end
	end)

	t.case("HTTP errors and junk JSON are failures, not crashes", function(A)
		local s = sim()
		local replies = { { true, 503, "busy" }, { true, 200, "not json" }, { false, 0, "" } }
		local i = 0
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function()
			i += 1
			return table.unpack(replies[i])
		end })
		local now = s.now
		for _ = 1, 3 do
			A.eq(gw:tick(s, now), "error")
			now += 31
		end
		A.eq(gw.stats.errors, 3)
	end)

	t.case("429 honours Retry-After; a named monitor is asked by name", function(A)
		local s = sim()
		s:setMonitor("external", "team-a")
		local body
		local gw = lib.Gateway.new({ config = lib.Config, enabled = true, encode = enc, decode = dec, post = function(_, b)
			body = dec(b)
			return true, 429, "", 20
		end })
		A.eq(gw:tick(s, 100), "error")
		A.eq(body.monitor, "team-a")
		A.eq(gw:tick(s, 110), "wait", "still waiting out Retry-After")
		A.ok(gw.nextAt >= 120, "Retry-After honoured")
	end)

	t.case("the per-minute ceiling holds whatever happens", function(A)
		local s = sim()
		local cfg = lib.config({ GATEWAY_EVERY_S = 0 })
		local gw = lib.Gateway.new({ config = cfg, enabled = true, encode = enc, decode = dec, post = function()
			return true, 200, "{}"
		end })
		local okN = 0
		for k = 1, 200 do
			s:injectFraud("scam")
			if gw:tick(s, k * 0.1) == "ok" then
				okN += 1
			end
		end
		A.eq(okN, cfg.GATEWAY_MAX_PER_MINUTE)
	end)
end
