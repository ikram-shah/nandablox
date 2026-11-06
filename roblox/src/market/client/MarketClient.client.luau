-- NANDA Market client: draws the square and the crowd, shows the inbox and
-- the meter, and sends verdicts and settings. The server owns the sim; this
-- only renders what it is told (docs/market-design.md, "Architecture").
--
-- Keys: N / B  next / previous demo beat · H presenter view · V camera
-- (overview / street) · A auto-watch (rehearsal) · 1-4 traders 5/50/300/1000
-- · T switch team · R start/stop the 5:00 round
--
-- On join a player picks a team (Blue watchers / Red con artists); the HUD
-- follows the team.

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

local chooseTeam: (string) -> ()

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

-- your team: chosen in the picker on join, switched with T or the button
local teamPendingUntil = 0
chooseTeam = function(t: string)
	if t ~= "blue" and t ~= "red" then
		return
	end
	teamPendingUntil = os.clock() + 2.5 -- the server's echo catches up
	Cam.setRole(t)
	Hud.setTeam(t)
	send({ op = "role", role = t })
	if t == "blue" then
		if Cam.minding() then
			Cam.mind(nil)
		end
		Hud.toast("Team BLUE: watchers. Allow or block new stalls in your inbox (Z / X)", Theme.BLUE)
	else
		World.highlightSlot(nil)
		Cam.inspectSlot = nil
		Hud.toast("Team RED: con artists. Open a stall on the right; take the buyers' money", Theme.BAD)
	end
end

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
	onTeam = function(t)
		chooseTeam(t)
	end,
	onMind = function(slot, name)
		Cam.mind(slot, name)
		World.highlightSlot(nil)
		Hud.toast("Behind your counter at " .. tostring(name) .. " (WASD to walk away)", Theme.BAD)
	end,
})
Cam.onModeChange = function(m)
	Hud.setCameraMode(m)
end
Cam.init()
local myDefault = "blue"
if lastState and lastState.players then
	Cam.syncPlayers(lastState.players, me)
	Hud.status(lastState)
	for _, p in lastState.players do
		if p.id == me and (p.role == "blue" or p.role == "red") then
			myDefault = p.role
		end
	end
end
-- the server's guess is only the pre-selected card: the player decides
Cam.setRole(myDefault)
Hud.setTeam(myDefault)
Hud.pickTeam(myDefault, function(t)
	chooseTeam(t)
end)

local myStalls: { [string]: boolean } = {} -- the frauds you opened (seller ids)

local function onStall(s)
	World.setStall(s)
	Crowd.seller(s)
	if s.state == "gone" and Cam.minding() == s.slot and myStalls[s.id] then
		Cam.mind(nil)
		Hud.toast(tostring(s.name) .. " packed up: back to the square", Theme.MUTED)
	end
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
		local cSlot = c and (c.slot or (c.seller and World.slotOf(c.seller)))
		if cSlot and cSlot == Cam.inspectSlot then
			Cam.inspectSlot = nil
		end
		if cSlot and cSlot == World.focusedSlot() then
			World.highlightSlot(nil)
		end
		Hud.removeCase(e.id, e.verdict == "expired" and "expired" or nil)
		-- tell the watcher what their call did, once it is decided
		local what = e.truth == "impostor" and "an impostor" or (e.truth == "counterfeit" and "a counterfeit (prints)" or "a scam")
		if c and e.by == "watcher" and e.who == me then
			if e.verdict == "block" and e.truth ~= "honest" then
				Hud.toast("Caught: " .. c.stall .. " was " .. what, Theme.OK)
			elseif e.verdict == "block" then
				Hud.toast("False alarm: " .. c.stall .. " was honest, and packed up", Theme.WARN)
			elseif e.truth ~= "honest" then
				Hud.toast("You allowed " .. c.stall .. ": it was " .. what, Theme.BAD)
			end
		end
		-- red: news of your own stall
		if Hud.team() == "red" and myStalls[e.seller] then
			if e.verdict == "block" then
				Hud.toast((e.stall or "Your stall") .. ": BLOCKED by " .. (e.by == "monitor" and "the monitor" or "a watcher"), Theme.BAD)
			elseif e.verdict == "allow" or e.verdict == "expired" then
				Hud.toast((e.stall or "Your stall") .. ": " .. (e.verdict == "allow" and ("allowed by " .. (e.by == "monitor" and "the monitor" or "a watcher")) or "nobody decided in time") .. ". Wait for a buyer", Theme.GOLD)
			end
		end
	elseif k == "deal" then
		local slot = World.slotOf(e.seller)
		local stall = World.stallOf(e.seller)
		local good = stall and stall.seller and stall.seller.good
		if slot then
			Effects.deal(slot, Crowd.buyerPos(e.buyer), good, e.ok, e.counterfeit == true)
		end
		if not e.ok then
			local name = stall and stall.seller and stall.seller.name or "a stall"
			if e.owner == me then
				Hud.toast(string.format("+%s: %s %s", Theme.money(e.price or 0), name, e.counterfeit and ("sold a print of " .. tostring(good)) or "took a buyer's money"), Theme.GOLD)
			elseif Hud.team() == "blue" and (e.first ~= false) then
				Hud.toast("Escaped: " .. name .. (e.counterfeit and (" sold a picture of " .. tostring(good)) or " took a buyer's money"), Theme.BAD)
			end
		end
	elseif k == "prices" then
		prices = e.p
	elseif k == "manualFraud" then
		if e.by ~= me then
			-- someone else's: Blue only finds out from the inbox
			return
		end
		myStalls[e.seller] = true
		if e.kind == "impostor" and e.signatures then
			Hud.toast("Blocked at the gate! Signature check rejected impostor '" .. tostring(e.stall) .. "' (turn signatures OFF to let twins in)", Theme.OK)
		elseif e.slot then
			-- you stand behind its counter; the camera goes there
			Cam.mind(e.slot, e.stall)
			local msg = e.kind == "impostor" and ("You opened a twin of '" .. tostring(e.stall) .. "': same name, same look")
				or (e.kind == "counterfeit" and ("You opened '" .. tostring(e.stall) .. "': framed prints of " .. tostring(e.good) .. ", at a fair price")
				or ("You opened '" .. tostring(e.stall) .. "': half price, nothing behind the counter"))
			Hud.toast(msg, Theme.BAD)
		end
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
		if lastState.players then
			Cam.syncPlayers(lastState.players, me)
			-- the slots where a Red player stands behind the counter
			local minded = {}
			for _, p in lastState.players do
				if p.stallSlot and p.id ~= me then
					minded[p.stallSlot] = true
				end
			end
			local mine = Cam.minding()
			if mine then
				minded[mine] = true
			end
			Crowd.setMinded(minded)
			-- your team as the server has it (after a moment: our own switch may be in flight)
			if os.clock() > teamPendingUntil and not Hud.pickerOpen() then
				for _, p in lastState.players do
					if p.id == me and (p.role == "blue" or p.role == "red") and p.role ~= Hud.team() then
						Cam.setRole(p.role)
						Hud.setTeam(p.role)
					end
				end
			end
		end
	end
	if b.sb then
		Hud.scoreboard(b.sb)
	end
end)

------------------------------------------------------------------ keys

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	local kc = input.KeyCode
	if Hud.pickerOpen() then
		-- the team picker first: Enter takes the suggested team
		if kc == Enum.KeyCode.Return or kc == Enum.KeyCode.KeypadEnter then
			Hud.closePicker()
		end
		return
	end
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
	elseif kc == Enum.KeyCode.R then
		local active = lastState and lastState.round and lastState.round.active
		send({ op = "round", on = not active })
	elseif kc == Enum.KeyCode.Z and Hud.team() == "blue" then
		local c = Hud.decideTop("allow")
		if c then
			Hud.toast("Allowed top case: " .. tostring(c.stall), Theme.OK)
		end
	elseif kc == Enum.KeyCode.X and Hud.team() == "blue" then
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
	elseif kc == Enum.KeyCode.T then
		chooseTeam(Hud.team() == "blue" and "red" or "blue")
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
local poseAt = 0
local fpsN, fpsT, cpu, crowdCpu = 0, 0, 0, 0
RunService.RenderStepped:Connect(function(dt)
	local t0 = os.clock()
	local now = simNow()
	local cam = workspace.CurrentCamera
	-- (Red's camera never follows Blue's inbox)
	local topC = Hud.team() == "blue" and Hud.topCase() or nil
	local topSlot = topC and (topC.slot or (topC.seller and World.slotOf(topC.seller))) or nil
	Cam.topSlot = topSlot
	if Cam.mode() == "follow" then
		local focus = Cam.inspectSlot or topSlot
		if focus then
			World.highlightSlot(focus)
		end
	end
	Cam.update(dt, lastMeter and lastMeter.n or 5)
	poseAt -= dt
	if poseAt <= 0 then
		poseAt = 0.15
		local p = Cam.pose()
		send({ op = "pose", x = p.x, z = p.z, yaw = p.yaw, moving = p.moving, mind = p.mind })
	end
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
				-- (a Red player behind their counter stays there)
				if not Cam.minding() then
					Cam.set(shot)
				end
			end
			Cam.focusSlot = lastState.agentSlot
			-- the team, too (tests, screenshots): closes the picker like a click
			local extTeam = workspace:GetAttribute("MarketTeam")
			if extTeam ~= nil then
				workspace:SetAttribute("MarketTeam", nil)
				if Hud.pickerOpen() then
					Hud.closePicker(extTeam)
				else
					chooseTeam(extTeam)
				end
			end
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
			Hud.round(lastState)
			Hud.red(lastState, lastMeter, Cam.minding())
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
