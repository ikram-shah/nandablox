-- NANDA Market client: draws the square and the crowd, shows the inbox and
-- the meter, and sends verdicts and settings. The server owns the sim; this
-- only renders what it is told (docs/market-design.md, "Architecture").
--
-- Keys: N / B  next / previous demo beat · H presenter view · V camera
-- (overview / street) · A auto-watch (rehearsal) · 1-4 traders 5/50/300/1000

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local UI = script.Parent:WaitForChild("MarketUI")
local Theme = require(UI.Theme)
local World = require(UI.World)
local Crowd = require(UI.Crowd)
local Hud = require(UI.Hud)
local Figures = require(UI.SimpleFigures)
local Rigs = require(UI.RigFigures)
local Cam = require(UI.Camera)
local Landmarks = require(UI.Landmarks)
local Effects = require(UI.Effects)

local net = ReplicatedStorage:WaitForChild("MarketNet")
local Batch = net:WaitForChild("Batch")
local Cmd = net:WaitForChild("Cmd")
local Hello = net:WaitForChild("Hello")

local function send(msg)
	Cmd:FireServer(msg)
end

------------------------------------------------------------------ clock

-- the sim's time, extrapolated between batches from the server clock
local simAt, serverAt = 0, 0
local function simNow(): number
	return simAt + (workspace:GetServerTimeNow() - serverAt)
end

------------------------------------------------------------------ connect

local hello = Hello:InvokeServer()
local me: string = hello.you
local lastMeter = hello.meter
local lastState = hello.state
local prices = hello.snapshot.prices
local auto = false
local lastShot = nil
local lastPrices, prevPrices, lastPricesAt = nil, nil, 0

local world = World.build()
Landmarks.build(world)
Cam.balconyCF = Landmarks.balconyCF
Effects.init(world)
Crowd.init(world, Figures, Rigs)
Hud.build({
	send = send,
	you = me,
	sizes = hello.config.sizes,
	onFocus = function(c)
		local slot = c and (c.slot or (c.seller and World.slotOf(c.seller)))
		World.highlightSlot(slot)
	end,
	onVisit = function(c)
		local slot = c and (c.slot or (c.seller and World.slotOf(c.seller)))
		if slot then
			World.highlightSlot(slot)
			Cam.visitStall(slot)
			Hud.toast("3rd-person walk at " .. tostring(c.stall) .. " (WASD / Arrows to walk, V to change camera)", Theme.BLUE)
		end
	end,
	onCamera = function(m)
		Cam.set(m)
		Hud.toast("Camera: " .. m, Theme.BLUE)
	end,
})
Cam.onModeChange = function(m)
	Hud.setCameraMode(m)
end
Cam.init()

local function onStall(s)
	World.setStall(s)
	Crowd.seller(s)
end

local cases: { [string]: any } = {}

local function onEvent(e, now: number)
	local k = e.k
	if k == "buyer" then
		Crowd.buyer(e)
	elseif k == "stall" then
		onStall(e.s)
	elseif k == "buyerGone" then
		Crowd.buyerGone(e.id)
	elseif k == "case" then
		cases[e.c.id] = e.c
		Hud.addCase(e.c, now)
	elseif k == "caseEnd" then
		local c = cases[e.id]
		cases[e.id] = nil
		if c and (c.slot == World.focusedSlot() or (c.seller and World.slotOf(c.seller) == World.focusedSlot())) then
			World.highlightSlot(nil)
		end
		Hud.removeCase(e.id, e.verdict == "expired" and "expired" or nil)
		-- tell the watcher what their call did, once it is decided
		if c and e.by == "watcher" and e.who == me then
			if e.verdict == "block" and e.truth ~= "honest" then
				Hud.toast("Caught: " .. c.stall .. " was " .. (e.truth == "impostor" and "an impostor" or "a scam"), Theme.OK)
			elseif e.verdict == "block" then
				Hud.toast("False alarm: " .. c.stall .. " was honest, and packed up", Theme.WARN)
			elseif e.truth ~= "honest" then
				Hud.toast("You allowed " .. c.stall .. ": it was " .. (e.truth == "impostor" and "an impostor" or "a scam"), Theme.BAD)
			end
		end
	elseif k == "deal" then
		local slot = World.slotOf(e.seller)
		if slot then
			local stall = World.stallOf(e.seller)
			Effects.deal(slot, Crowd.buyerPos(e.buyer), stall and stall.seller and stall.seller.good, e.ok)
		end
		if not e.ok then
			local stall = World.stallOf(e.seller)
			local name = stall and stall.seller and stall.seller.name or "a stall"
			Hud.toast("Escaped: " .. name .. " took a buyer's money", Theme.BAD)
		end
	elseif k == "prices" then
		prices = e.p
	end
end

local function applySnapshot(snap)
	World.clearStalls()
	Crowd.clear()
	Hud.clearCases()
	for _, s in snap.stalls do
		onStall(s)
	end
	for _, b in snap.buyers do
		Crowd.buyer(b)
	end
	cases = {}
	for _, c in snap.cases do
		cases[c.id] = c
		Hud.addCase(c, snap.t)
	end
	prices = snap.prices
end

simAt, serverAt = hello.snapshot.t, workspace:GetServerTimeNow()
applySnapshot(hello.snapshot)

Batch.OnClientEvent:Connect(function(b)
	simAt, serverAt = b.t, b.st
	for _, e in b.ev do
		onEvent(e, b.t)
	end
	if b.m then
		lastMeter = b.m
	end
	if b.s then
		lastState = b.s
	end
end)

------------------------------------------------------------------ keys

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local kc = input.KeyCode
	local beat = lastState and lastState.beat or 0
	local beats = lastState and lastState.beats or 6
	if kc == Enum.KeyCode.N then
		send({ op = "beat", i = math.min(beats, beat + 1) })
	elseif kc == Enum.KeyCode.B then
		send({ op = "beat", i = math.max(1, beat - 1) })
	elseif kc == Enum.KeyCode.H then
		local nextPres = not Hud.isPresenter()
		workspace:SetAttribute("MarketPresenter", nil)
		Hud.presenter(nextPres)
	elseif kc == Enum.KeyCode.V then
		local m = Cam.toggle()
		Hud.toast("Camera: " .. m .. (m == "walk" and " (3rd-person · WASD / Arrows)" or (m == "follow" and " (follows top inbox case)" or "")), Theme.BLUE)
	elseif kc == Enum.KeyCode.Z then
		local c = Hud.decideTop("allow")
		if c then
			Hud.toast("Allowed top case: " .. tostring(c.stall), Theme.OK)
		end
	elseif kc == Enum.KeyCode.X then
		local c = Hud.decideTop("block")
		if c then
			Hud.toast("Blocked top case: " .. tostring(c.stall), Theme.BAD)
		end
	elseif kc == Enum.KeyCode.M then
		local cur = lastMeter and lastMeter.monitor or "off"
		local nextMon = cur == "off" and "rules" or (cur == "rules" and "external" or "off")
		send({ op = "monitor", mode = nextMon })
		Hud.toast("Monitor: " .. nextMon, Theme.BLUE)
	elseif kc == Enum.KeyCode.G then
		local cur = not (lastMeter and lastMeter.signatures == false)
		send({ op = "vote", on = not cur })
		Hud.toast("Signature checks: " .. (not cur and "ON" or "OFF"), Theme.BLUE)
	elseif kc == Enum.KeyCode.K or kc == Enum.KeyCode.Slash then
		Hud.toggleShortcuts()
	elseif kc == Enum.KeyCode.L then
		local nextAgent = not (lastState and lastState.agentOn == true)
		send({ op = "agent", on = nextAgent })
		Hud.toast(nextAgent and "Outside agent (Gemini) ON" or "Outside agent OFF (scripted)", Theme.BLUE)
	elseif kc == Enum.KeyCode.A then
		auto = not auto
		send({ op = "auto", on = auto })
		Hud.toast(auto and "Auto-watch on: a modelled watcher answers your cases" or "Auto-watch off", Theme.BLUE)
	elseif kc == Enum.KeyCode.One then
		send({ op = "size", n = 5 })
	elseif kc == Enum.KeyCode.Two then
		send({ op = "size", n = 50 })
	elseif kc == Enum.KeyCode.Three then
		send({ op = "size", n = 300 })
	elseif kc == Enum.KeyCode.Four then
		send({ op = "size", n = 1000 })
	end
end)

------------------------------------------------------------------ frame

local hudAt = 0
local fpsN, fpsT, cpu, crowdCpu = 0, 0, 0, 0
RunService.RenderStepped:Connect(function(dt)
	local t0 = os.clock()
	local now = simNow()
	local cam = workspace.CurrentCamera
	local topC = Hud.topCase()
	local topSlot = topC and (topC.slot or (topC.seller and World.slotOf(topC.seller))) or nil
	Cam.topSlot = topSlot
	if Cam.mode() == "follow" and topSlot then
		World.highlightSlot(topSlot)
	end
	Cam.update(dt, lastMeter and lastMeter.n or 5)
	local tc = os.clock()
	Crowd.update(now, cam.CFrame.Position, dt)
	crowdCpu += os.clock() - tc
	Hud.tickCards(now)
	Landmarks.clock(now)
	Effects.update(cam.CFrame.Position)
	fpsN += 1
	fpsT += dt
	cpu += os.clock() - t0
	if fpsT >= 1 then
		-- measured, for the fps report: frames per second, and the ms this script spends per frame
		workspace:SetAttribute("MarketFps", math.floor(fpsN / fpsT + 0.5))
		workspace:SetAttribute("MarketScriptMs", math.floor(cpu / fpsN * 1000 * 10 + 0.5) / 10)
		workspace:SetAttribute("MarketCrowdMs", math.floor(crowdCpu / fpsN * 1000 * 10 + 0.5) / 10)
		local pr = Crowd.prof
		if pr and pr.n > 0 then
			local k = 1000 / pr.n
			workspace:SetAttribute("MarketCrowdProfile", string.format("choose %.2f place %.2f simple %.2f rigs %.2f", pr.choose * k, pr.place * k, pr.simple * k, pr.rigs * k)
				.. string.format(" | parts/frame %.0f, near/frame %.0f", Figures.moved / pr.n, (pr.near or 0) / pr.n))
			Figures.moved = 0
			pr.near = 0
			pr.choose, pr.place, pr.simple, pr.rigs, pr.n = 0, 0, 0, 0, 0
		end
		local nb, ns, nr = Crowd.count()
		workspace:SetAttribute("MarketFigures", nb + ns)
		workspace:SetAttribute("MarketRigs", nr)
		fpsN, fpsT, cpu, crowdCpu = 0, 0, 0, 0
	end
	hudAt -= dt
	if hudAt <= 0 then
		hudAt = 0.5
		if lastMeter then
			Hud.meter(lastMeter)
		end
		if lastState then
			local extCam = workspace:GetAttribute("MarketCam")
			if extCam ~= nil then
				workspace:SetAttribute("MarketCam", nil)
				Cam.set(extCam)
			end
			-- the beat's shot (V or panel overrides it until the next beat)
			local shot = lastState.cam or "follow"
			if shot ~= lastShot then
				lastShot = shot
				Cam.set(shot)
			end
			Cam.focusSlot = lastState.agentSlot
			-- presenter view can be switched from outside too (tests, screenshots)
			local pres = workspace:GetAttribute("MarketPresenter")
			if pres ~= nil then
				workspace:SetAttribute("MarketPresenter", nil)
				if pres ~= Hud.isPresenter() then
					Hud.presenter(pres)
				end
			end
			Hud.caption(lastState.caption, lastState.beat, lastState.beats)
			Hud.status(lastState)
		end
		if prices then
			Hud.prices(prices)
			-- arrows compare with the price ~30 s ago
			if not lastPrices or now - lastPricesAt > 30 then
				lastPrices, lastPricesAt = prevPrices or prices, now
				prevPrices = prices
			end
			Landmarks.prices(prices, lastPrices)
		end
	end
end)

workspace:SetAttribute("MarketClientReady", true)
