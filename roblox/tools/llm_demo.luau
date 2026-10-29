-- The server's LLM loop, outside Roblox: the same Game, TownSim, LlmPolicy
-- and Harness modules the place runs, driven by Lune at wall-clock speed and
-- talking to the real harness over HTTP. It is how the plumbing is rehearsed
-- without opening Studio, and it is a demo in its own right: the decisions
-- scroll past with the model's reason for each one.
--
--   tools/llm_demo.sh                  # 90 s with seller-b model-driven
--   tools/llm_demo.sh 60 scripted      # the same round, nobody model-driven
--
-- Needs the harness running (harness/run.sh). Without it every request fails
-- and the round plays exactly as a scripted one, which is the point.

local net = require("@lune/net")
local serde = require("@lune/serde")
local process = require("@lune/process")
local task = require("@lune/task")

local base = "../src/shared/NandaTown/RedBlue/"
local Config = (require :: any)(base .. "Config")
local Game = (require :: any)(base .. "Game")
local LlmPolicy = (require :: any)(base .. "LlmPolicy")
local Harness = (require :: any)(base .. "Harness")

local seconds = tonumber(process.args[1]) or 90
local scripted = process.args[2] == "scripted"
local agents = scripted and {} or Config.LLM_PRESETS[2]

local cfg = {}
for k, v in Config do
	cfg[k] = v
end
cfg.ROUND_SECONDS = seconds

-- Lune's os.clock() is CPU time, not the wall clock a sleeping loop needs,
-- so the seconds task.wait() returns are accumulated instead. (In Roblox
-- os.clock() is the wall clock, which is what the server uses.)
local elapsed = 0
local function clock(): number
	return elapsed
end

local store = LlmPolicy.new({ config = cfg, clock = clock })
store:setAgents(agents)
local harness = Harness.new({ config = cfg, store = store, clock = clock })
local game = Game.new({ config = cfg, seed = os.time() % 100000, policies = store:policies(), sink = function() end })

print(string.format("NANDA Town, %d s, %s", seconds, #store:agents() == 0 and "every trader scripted" or ("model-driven: " .. table.concat(store:agents(), ", "))))
print(string.format("harness: %s", harness.url))
print("")

game:start(0)
local polls, latencies, lastSeq = 0, {}, {}

local function poll()
	if not harness:due() then
		return
	end
	local body = serde.encode("json", harness:observation(game))
	if not harness:begin() then
		return
	end
	local ok, res = pcall(net.request, {
		url = harness.url,
		method = "POST",
		headers = { ["Content-Type"] = "application/json" },
		body = body,
	})
	if not ok then
		harness:fail(tostring(res))
	elseif not res.ok then
		harness:fail(string.format("HTTP %d", res.statusCode))
	else
		local okJson, decoded = pcall(serde.decode, "json", res.body)
		if okJson then
			harness:finish(decoded)
			polls += 1
			for _, a in store:report() do
				if a.seq and a.seq ~= lastSeq[a.name] then
					lastSeq[a.name] = a.seq
					table.insert(latencies, a.latency or 0)
					print(string.format("  %5.1fs  %s  [%s, %d ms]", game:rt(), a.line, a.model or "?", a.latency or 0))
				end
			end
		else
			harness:fail("not JSON")
		end
	end
end

while elapsed < seconds do
	local now = elapsed
	local evs = game:tick(now)
	harness:note(evs)
	for _, e in evs do
		if e.kind == "payment_settled" and e.detail.via == "escrow" then
			print(string.format("  %5.1fs  %s paid %s %dc", now, tostring(e.detail.from), tostring(e.detail.to), e.detail.cents))
		end
	end
	poll()
	elapsed += task.wait(0.1)
end

local sum = 0
for _, l in latencies do
	sum += l
end
local st = harness:status()
print("")
print(string.format("deals settled          %d", game.sim and game.sim.stats.dealsSettled or 0))
print(string.format("cents settled          %d", game.sim and game.sim.stats.centsSettled or 0))
print(string.format("harness requests       %d ok, %d failed (%s)", st.ok, st.errors, st.error or "-"))
print(string.format("model decisions        %d", #latencies))
if #latencies > 0 then
	print(string.format("mean decision latency  %d ms", math.floor(sum / #latencies + 0.5)))
end
print(string.format("decisions taken        %d by the model, %d fell back to the script", store.used["seller-b"] or 0, store.fell_back))
