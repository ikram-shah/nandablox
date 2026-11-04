-- NANDA Market client: draws the square and the crowd, shows the inbox and
-- the meter, and sends verdicts and settings. The server owns the sim; this
-- only renders what it is told (docs/market-design.md, "Architecture").
--
-- Keys: N / B  next / previous demo beat · P presenter view · C camera
-- (overview / street) · A auto-watch (rehearsal) · 1-4 traders 5/50/300/1000

local Players = game:GetService("Players")
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

------------------------------------------------------------------ state

local me: string
local cases: { [string]: any } = {} -- every open case in any inbox
local lastMeter
local lastState
local prices = {}

local world = World.build()
Crowd.init(world, Figures)
Hud.build(send)
Cam.init()

local function onStall(s)
	World.setStall(s)
	Crowd.seller(s)
end

local VERDICT_TEXT = {
	block = "blocked",
	allow = "allowed",
	expired = "went unanswered",
}

local function onEvent(e)
	local k = e.k
	if k == "buyer" then
		Crowd.buyer(e)
	elseif k == "stall" then
		onStall(e.s)
	elseif k == "buyerGone" then
		Crowd.buyerGone(e.id)
	elseif k == "case" then
		cases[e.c.id] = e.c
	elseif k == "caseEnd" then
		local c = cases[e.id]
		cases[e.id] = nil
		-- tell the watcher what their call did, once it is decided
		if c and c.watcher == me and e.by == "watcher" then
			if e.verdict == "block" and e.truth ~= "honest" then
				Hud.toast("Caught: " .. c.stall .. " was a " .. (e.truth == "impostor" and "fake" or "scam"), Theme.OK)
			elseif e.verdict == "block" then
				Hud.toast("False alarm: " .. c.stall .. " was honest", Theme.WARN)
			end
		end
		if e.by == "monitor" and e.verdict == "block" then
			-- the monitor's catches are quiet: a flash of red on the stall
		end
	elseif k == "deal" then
		if not e.ok then
			local stall = World.stallOf(e.seller)
			local name = stall and stall.seller and stall.seller.name or "a stall"
			Hud.toast("Escaped: " .. name .. " took a buyer's money", Theme.BAD)
		end
	elseif k == "rejected" then
		-- signatures at work: quiet
	elseif k == "prices" then
		prices = e.p
	end
end

local function applySnapshot(snap)
	World.clearStalls()
	Crowd.clear()
	for _, s in snap.stalls do
		onStall(s)
	end
	for _, b in snap.buyers do
		Crowd.buyer(b)
	end
	cases = {}
	for _, c in snap.cases do
		cases[c.id] = c
	end
	prices = snap.prices
end

------------------------------------------------------------------ connect

local hello = Hello:InvokeServer()
me = hello.you
simAt, serverAt = hello.snapshot.t, workspace:GetServerTimeNow()
applySnapshot(hello.snapshot)
lastMeter = hello.meter
lastState = hello.state

Batch.OnClientEvent:Connect(function(b)
	simAt, serverAt = b.t, b.st
	for _, e in b.ev do
		onEvent(e)
	end
	if b.m then
		lastMeter = b.m
	end
	if b.s then
		lastState = b.s
	end
end)

------------------------------------------------------------------ keys

local beat = 0
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local kc = input.KeyCode
	if kc == Enum.KeyCode.N or kc == Enum.KeyCode.Right then
		beat = math.min((lastState and lastState.beats) or 6, (lastState and lastState.beat or beat) + 1)
		send({ op = "beat", i = beat })
	elseif kc == Enum.KeyCode.B or kc == Enum.KeyCode.Left then
		beat = math.max(1, (lastState and lastState.beat or beat) - 1)
		send({ op = "beat", i = beat })
	elseif kc == Enum.KeyCode.P then
		Hud.setPresenter(not Hud.isPresenter())
	elseif kc == Enum.KeyCode.C then
		Cam.toggle()
	elseif kc == Enum.KeyCode.A then
		Hud.setAuto(not Hud.auto)
		send({ op = "auto", on = Hud.auto })
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
local fpsN, fpsT, fps = 0, 0, 60
RunService.RenderStepped:Connect(function(dt)
	local now = simNow()
	local cam = workspace.CurrentCamera
	Cam.update(dt, lastMeter and lastMeter.n or 5)
	Crowd.update(now, cam.CFrame.Position, dt)
	fpsN += 1
	fpsT += dt
	if fpsT >= 1 then
		fps = fpsN / fpsT
		fpsN, fpsT = 0, 0
		workspace:SetAttribute("MarketFps", math.floor(fps + 0.5))
		local nb, ns = Crowd.count()
		workspace:SetAttribute("MarketFigures", nb + ns)
	end
	hudAt -= dt
	if hudAt <= 0 then
		hudAt = 0.1
		local mine = {}
		for _, c in cases do
			if c.watcher == me then
				table.insert(mine, c)
			end
		end
		local others = 0
		for _, c in cases do
			if c.watcher ~= me then
				others += 1
			end
		end
		local title = "Your inbox"
		if lastState and lastState.watchers and #lastState.watchers > 1 then
			title = string.format("Your inbox  ·  %d with the other watcher", others)
		end
		Hud.setInbox(mine, now, title)
		if lastMeter then
			Hud.setMeter(lastMeter)
		end
		if lastState then
			Hud.setCaption(lastState.caption, lastState.beat ~= 0 and lastState.beat or nil, lastState.beats)
		end
	end
end)

workspace:SetAttribute("MarketClientReady", true)
