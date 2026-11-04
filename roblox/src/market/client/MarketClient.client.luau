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
local Cam = require(UI.Camera)

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

local world = World.build()
Crowd.init(world, Figures)
Hud.build({ send = send, you = me, sizes = hello.config.sizes })
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
	if kc == Enum.KeyCode.N or kc == Enum.KeyCode.Right then
		send({ op = "beat", i = math.min(beats, beat + 1) })
	elseif kc == Enum.KeyCode.B or kc == Enum.KeyCode.Left then
		send({ op = "beat", i = math.max(1, beat - 1) })
	elseif kc == Enum.KeyCode.H then
		Hud.presenter(not Hud.isPresenter())
	elseif kc == Enum.KeyCode.V then
		Cam.toggle()
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
local fpsN, fpsT, cpu = 0, 0, 0
RunService.RenderStepped:Connect(function(dt)
	local t0 = os.clock()
	local now = simNow()
	local cam = workspace.CurrentCamera
	Cam.update(dt, lastMeter and lastMeter.n or 5)
	Crowd.update(now, cam.CFrame.Position, dt)
	Hud.tickCards(now)
	fpsN += 1
	fpsT += dt
	cpu += os.clock() - t0
	if fpsT >= 1 then
		-- measured, for the fps report: frames per second, and the ms this script spends per frame
		workspace:SetAttribute("MarketFps", math.floor(fpsN / fpsT + 0.5))
		workspace:SetAttribute("MarketScriptMs", math.floor(cpu / fpsN * 1000 * 10 + 0.5) / 10)
		local nb, ns = Crowd.count()
		workspace:SetAttribute("MarketFigures", nb + ns)
		fpsN, fpsT, cpu = 0, 0, 0
	end
	hudAt -= dt
	if hudAt <= 0 then
		hudAt = 0.5
		if lastMeter then
			Hud.meter(lastMeter)
		end
		if lastState then
			Hud.caption(lastState.caption, lastState.beat, lastState.beats)
			Hud.status(lastState)
		end
		if prices then
			Hud.prices(prices)
		end
	end
end)

workspace:SetAttribute("MarketClientReady", true)
