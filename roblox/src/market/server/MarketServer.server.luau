-- NANDA Market server (docs/market-design.md, "Architecture").
--
-- Runs MarketSim at a fixed tick, streams its events to every client in one
-- batch per tick, takes verdicts, settings and lever votes over a RemoteEvent,
-- and (only if switched on) calls the gateway once per tick. No Humanoids, no
-- server-side parts: the clients draw everything.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Market = ReplicatedStorage:WaitForChild("Market")
local Config = require(Market.Config)
local MarketSim = require(Market.MarketSim)
local Gateway = require(Market.Gateway)

local TICK = 0.25 -- seconds of simulated (and real) time per step
local METER_EVERY = 0.5

------------------------------------------------------------------ remotes

local net = Instance.new("Folder")
net.Name = "MarketNet"
local batchEv = Instance.new("RemoteEvent")
batchEv.Name = "Batch"
batchEv.Parent = net
local cmdEv = Instance.new("RemoteEvent")
cmdEv.Name = "Cmd"
cmdEv.Parent = net
local hello = Instance.new("RemoteFunction")
hello.Name = "Hello"
hello.Parent = net
net.Parent = ReplicatedStorage

------------------------------------------------------------------ the crowd's rigs

-- One R15 template per outfit, made once from a HumanoidDescription, then
-- stripped to parts + Motor6Ds + an AnimationController (no Humanoid: no
-- physics, no state machine). Clients clone these into their pools.
task.spawn(function()
	local Outfits = require(Market.Outfits)
	local folder = Instance.new("Folder")
	folder.Name = "MarketRigs"
	local made = 0
	for i, o in Outfits.LIST do
		local ok, err = pcall(function()
			local d = Instance.new("HumanoidDescription")
			local skin = Outfits.SKIN[o.skin]
			d.HeadColor = skin
			d.LeftArmColor = skin
			d.RightArmColor = skin
			d.TorsoColor = o.top
			d.LeftLegColor = o.legs
			d.RightLegColor = o.legs
			local m = Players:CreateHumanoidModelFromDescriptionAsync(d, Enum.HumanoidRigType.R15)
			-- sleeves: colour the upper arms like the shirt
			for _, name in { "LeftUpperArm", "RightUpperArm" } do
				local p = m:FindFirstChild(name)
				if p and p:IsA("BasePart") then
					p.Color = o.top
				end
			end
			-- a face, so the nearest people read as people at eye level
			local head = m:FindFirstChild("Head")
			if head and not head:FindFirstChildOfClass("Decal") then
				local face = Instance.new("Decal")
				face.Name = "face"
				face.Face = Enum.NormalId.Front
				face.Texture = "rbxasset://textures/face.png"
				face.Parent = head
			end
			local hum = m:FindFirstChildOfClass("Humanoid")
			if hum then
				hum:Destroy()
			end
			for _, x in m:GetDescendants() do
				if x:IsA("Script") or x:IsA("LocalScript") or x:IsA("Sound") then
					x:Destroy()
				elseif x:IsA("BasePart") then
					x.Anchored = false
					x.CanCollide = false
					x.CanQuery = false
					x.CanTouch = false
					x.CastShadow = false
					x.Massless = true
				end
			end
			m.PrimaryPart.Anchored = true
			local ac = Instance.new("AnimationController")
			Instance.new("Animator").Parent = ac
			ac.Parent = m
			m.Name = "Outfit" .. i
			m.Parent = folder
			made += 1
		end)
		if not ok then
			warn("[market] outfit " .. i .. ": " .. tostring(err))
		end
	end
	folder:SetAttribute("Count", made)
	folder.Parent = ReplicatedStorage
	print(string.format("[market] %d R15 outfit templates ready", made))
end)

------------------------------------------------------------------ the sim

local seed = tonumber(workspace:GetAttribute("MarketSeed")) or 20261106
local sim = MarketSim.new({ seed = seed, n = 5 })
sim:setMonitor("off")
sim:setSignatures(true)
sim:drain()

local function watcherId(p: Player): string
	return "p" .. tostring(p.UserId)
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- state the whole room shares, beside the sim's own
local room = {
	caption = nil :: string?,
	beat = 0,
	cam = nil :: string?,
	votes = {} :: { [string]: boolean }, -- watcher id -> wants signatures on
	auto = {} :: { [string]: boolean },
	paused = false,
}

------------------------------------------------------------------ gateway

local auth: any = nil
local function authHeader()
	if auth ~= nil then
		return auth
	end
	auth = false
	local ok, secret = pcall(function()
		return (HttpService :: any):GetSecret(Config.GATEWAY_SECRET):AddPrefix("Bearer ")
	end)
	if ok and secret then
		auth = secret
		return auth
	end
	local box = ServerStorage:FindFirstChild("NandaSecrets")
	local mod = box and box:FindFirstChild("LlmToken")
	if mod and mod:IsA("ModuleScript") then
		local ok2, token = pcall(require, mod)
		if ok2 and type(token) == "string" and #token > 0 then
			auth = "Bearer " .. token
		end
	end
	return auth
end

local gateway = Gateway.new({
	config = Config,
	encode = function(t)
		return HttpService:JSONEncode(t)
	end,
	decode = function(s)
		return HttpService:JSONDecode(s)
	end,
	clock = os.clock,
	post = function(url, body, headers)
		local h = table.clone(headers)
		local a = authHeader()
		if a then
			h["Authorization"] = a
		end
		local res = HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = h,
			Body = body,
			Timeout = math.max(1, math.ceil(Config.GATEWAY_TIMEOUT_S)),
		} :: any)
		local retry = tonumber(res.Headers and (res.Headers["retry-after"] or res.Headers["Retry-After"]))
		return res.Success, res.StatusCode, res.Body, retry
	end,
})

------------------------------------------------------------------ settings

local function majorityLever()
	local on, off = 0, 0
	for _, p in Players:GetPlayers() do
		local v = room.votes[watcherId(p)]
		if v == true then
			on += 1
		elseif v == false then
			off += 1
		end
	end
	if on > off and not sim.signatures then
		sim:setSignatures(true)
		sim:mark("signatures on")
	elseif off > on and sim.signatures then
		sim:setSignatures(false)
		sim:mark("signatures off")
	end
end

local function setMonitor(mode: string)
	if mode == "external" then
		gateway:setEnabled(true)
		sim:setMonitor("external", Config.GATEWAY_MONITOR)
	else
		if sim.monitor == "external" then
			gateway:setEnabled(#(sim:gatewayRequest().decisions) > 0)
		end
		sim:setMonitor(mode)
	end
	sim:mark("monitor " .. mode)
end

-- the agent slot: hand one honest open stall to an outside agent (or back)
local agentSeller: string? = nil
local function setOutsideAgent(on: boolean)
	agentSeller = nil
	for _, s in sim.sellers do
		if s.policy == "external" then
			sim:setPolicy(s.id, "scripted")
		end
		-- re-entering the beat starts the badge over: "waiting" until the next real price
		s.labelled = nil
		s.extCount = nil
	end
	if on then
		local best
		for _, s in sim.sellers do
			if s.kind == "honest" and s.state == "open" and s.ratings >= 5 then
				if not best or s.slot < best.slot then
					best = s
				end
			end
		end
		if best then
			-- the gateway's gemini-seller prices it. Until its first action
			-- arrives the badge says it is waiting; with no token it says the
			-- slot fell back to the scripted seller
			local live = authHeader() ~= false and workspace:GetAttribute("MarketGateway") ~= false
			sim:setPolicy(best.id, "external", live and "Gemini (waiting for its first price)" or "the agent slot (scripted fallback)", "gemini-seller")
			gateway:setEnabled(live)
			agentSeller = best.id
			return best.id
		end
	elseif sim.monitor ~= "external" then
		gateway:setEnabled(false)
	end
	return nil
end

------------------------------------------------------------------ demo beats

-- The five beats (docs/market-design.md, "The demo"), plus the outside agent.
local BEATS = {
	{ caption = "Five traders. You can decide every case, and you keep up.  (biking)", n = 5, monitor = "off", sig = true, scam = true, quiet = true, cam = "street" },
	{ caption = "Now 300. The inbox overflows, the meter goes red, and frauds escape while their cases wait.", n = 300, monitor = "off", sig = true, cam = "street", thenCam = "overview" },
	{ caption = "Monitor on: four rules settle the obvious. Only the gray zone reaches you.  (paragliding)", n = 300, monitor = "rules", sig = true },
	{ caption = "Signatures off: trade speeds up, twins appear, the inbox floods again. The rule was doing oversight work.", n = 300, monitor = "rules", sig = false, burst = 8 },
	{ caption = "A second watcher joins, and the inbox splits between you.  (crewed sailing)", n = 300, monitor = "rules", sig = false, second = true, cam = "balcony" },
	{ caption = "An outside agent runs one stall through the agent slot: the seat your agents will fill.", n = 300, monitor = "rules", sig = true, agent = true, cam = "street" },
}

local SECOND = "helper"
local function applyBeat(i: number)
	local b = BEATS[i]
	if not b then
		room.caption = nil
		room.beat = 0
		return
	end
	room.beat = i
	room.caption = b.caption
	-- the shot: some beats start close and cut wide after a few seconds
	room.cam = b.cam or "auto"
	if b.thenCam then
		task.delay(10, function()
			if room.beat == i then
				room.cam = b.thenCam
			end
		end)
	end
	if sim.n ~= b.n then
		sim:setSize(b.n)
	end
	if sim.monitor ~= b.monitor then
		setMonitor(b.monitor)
	end
	if sim.signatures ~= b.sig then
		sim:setSignatures(b.sig)
	end
	room.votes = {}
	if b.second then
		sim:addWatcher(SECOND, { auto = true, label = "second watcher" })
	else
		sim:removeWatcher(SECOND)
	end
	setOutsideAgent(b.agent == true)
	-- beat 1 is the presenter's: the scripted fraud agents rest, so the only
	-- fraud is the one seeded case, which no buyer reaches for 30 s
	sim.fraudsPaused = b.quiet == true
	if b.quiet then
		-- and any fraud already on its way to a buyer packs up: beat 1 starts clean
		for _, s in sim.sellers do
			if s.kind ~= "honest" and (s.state == "setup" or s.state == "open" or s.state == "restock") then
				s.leaveAt = sim.now
			end
		end
	end
	sim:mark(b.caption)
	if b.scam then
		task.delay(3, function()
			if room.beat == i then
				sim:injectFraud("scam", { price = 0.45, window = 30 })
			end
		end)
	end
	if b.burst then
		-- the twins arrive together: the inbox fills within seconds
		task.delay(2, function()
			if room.beat == i then
				sim:fraudBurst(b.burst)
			end
		end)
	end
end

------------------------------------------------------------------ commands

local SIZES = {}
for _, n in Config.SIZES do
	SIZES[n] = true
end

local lastCmd: { [Player]: number } = {}

cmdEv.OnServerEvent:Connect(function(player: Player, msg: any)
	if type(msg) ~= "table" or type(msg.op) ~= "string" then
		return
	end
	local id = watcherId(player)
	local op = msg.op
	if op == "verdict" then
		if type(msg.case) == "string" and (msg.v == "allow" or msg.v == "block") then
			local ok = sim:verdict(id, msg.case, msg.v)
			if not ok then
				-- another watcher's case? let anyone answer a case they can see
				local c = sim.cases[msg.case]
				if c and c.stage == "inbox" and c.watcher ~= id then
					sim:verdict(c.watcher or id, msg.case, msg.v)
				end
			end
		end
		return
	end
	-- everything else is a setting: at most a few a second per player
	local t = os.clock()
	if lastCmd[player] and t - lastCmd[player] < 0.2 then
		return
	end
	lastCmd[player] = t
	if op == "size" and SIZES[msg.n] then
		sim:setSize(msg.n)
		sim:mark(msg.n .. " traders")
	elseif op == "monitor" and (msg.mode == "off" or msg.mode == "rules" or msg.mode == "external") then
		setMonitor(msg.mode)
	elseif op == "vote" and type(msg.on) == "boolean" then
		room.votes[id] = msg.on
		majorityLever()
	elseif op == "auto" and type(msg.on) == "boolean" then
		room.auto[id] = msg.on
		sim:setAuto(id, msg.on)
	elseif op == "fraud" and (msg.kind == "scam" or msg.kind == "impostor") then
		local opts = {}
		if msg.kind == "scam" and type(msg.price) == "number" then
			opts.price = math.clamp(msg.price, 0.2, 1)
		end
		if type(msg.good) == "string" and sim.goods[msg.good] then
			opts.good = msg.good
		end
		if type(msg.victim) == "string" then
			opts.victim = msg.victim
		end
		sim:injectFraud(msg.kind, opts)
	elseif op == "beat" and type(msg.i) == "number" then
		applyBeat(math.floor(msg.i))
	elseif op == "agent" and type(msg.on) == "boolean" then
		setOutsideAgent(msg.on)
	elseif op == "reset" then
		sim:mark("reset")
	end
end)

------------------------------------------------------------------ untrusted text

-- A `reason` written by outside code (an external monitor) is untrusted
-- (gateway decision 7). Players see only the verdict and the monitor's name;
-- the built-in rules' own words are ours and pass.
local function sanitize(events)
	for _, e in events do
		if e.untrusted then
			e.reason = nil
		end
		if e.c and e.c.untrusted then
			e.c.why = nil
		end
	end
	return events
end

------------------------------------------------------------------ players

local function state()
	return {
		t = sim.now,
		st = serverNow(),
		caption = room.caption,
		beat = room.beat,
		cam = room.cam,
		-- the stall the outside agent runs (the beat-6 camera looks at it)
		agentSlot = agentSeller and sim.byId[agentSeller] and sim.byId[agentSeller].slot or nil,
		beats = #BEATS,
		gateway = gateway:status(),
		watchers = (function()
			local w = {}
			for _, x in sim.watchers do
				table.insert(w, { id = x.id, label = x.label, auto = x.auto, queue = #x.queue, decided = x.decided })
			end
			return w
		end)(),
	}
end

hello.OnServerInvoke = function(player: Player)
	return {
		you = watcherId(player),
		snapshot = (function()
			local snap = sim:snapshot()
			for _, c in snap.cases do
				if c.untrusted then
					c.why = nil
				end
			end
			return snap
		end)(),
		meter = sim:meter(),
		state = state(),
		config = { budget = Config.BUDGET, sizes = Config.SIZES },
	}
end

Players.PlayerAdded:Connect(function(p)
	sim:addWatcher(watcherId(p), { label = "watcher" })
end)
for _, p in Players:GetPlayers() do
	sim:addWatcher(watcherId(p), { label = "watcher" })
end
Players.PlayerRemoving:Connect(function(p)
	sim:removeWatcher(watcherId(p))
	room.votes[watcherId(p)] = nil
	lastCmd[p] = nil
end)

------------------------------------------------------------------ the loop

local acc = 0
local meterAt = 0
local jobId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false):sub(1, 8))

RunService.Heartbeat:Connect(function(dt)
	acc += math.min(dt, 0.5)
	if acc < TICK then
		return
	end
	acc -= TICK
	if room.paused then
		return
	end
	sim:step(TICK)
	if gateway.enabled and not gateway.inflight then
		task.spawn(function()
			gateway:tick(sim, sim.now, jobId)
			-- once the outside agent has actually set a price, the badge says who
			local sel = agentSeller and sim.byId[agentSeller]
			if sel and sel.policy == "external" and (sel.extCount or 0) > 0 and not sel.labelled then
				sel.labelled = true
				local by = sel.extBy or "gemini-seller"
				sim:setPolicy(sel.id, "external", Config.AGENT_MODEL_LABEL .. " (" .. by .. ")", "gemini-seller")
				print(string.format("[market] agent slot: %s set %s's price to %d (by %s)", "gemini-seller", sel.name, math.floor(sel.price + 0.5), by))
			end
		end)
	end
	local events = sanitize(sim:drain())
	local out: any = { t = sim.now, st = serverNow(), ev = events }
	if sim.now >= meterAt then
		meterAt = sim.now + METER_EVERY
		out.m = sim:meter()
		out.s = state()
	end
	batchEv:FireAllClients(out)
end)

print(string.format("[market] server up: seed %d, %d traders, gateway %s", seed, sim.n, gateway.enabled and "on" or "off"))
