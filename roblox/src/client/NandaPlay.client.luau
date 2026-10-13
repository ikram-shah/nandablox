-- The play place's client (StarterPlayerScripts): walk around NANDA Town while
-- the replay plays on the shared clock, so everyone on the server sees the
-- same moment of the same run.
--
--   walk      the default: your own character, the normal Roblox camera
--   V         overview: the fixed camera from the replay (you can still walk)
--   F         fly / god mode: free flight (WASD + mouse, E or Space up,
--             Q or Ctrl down, Shift fast)
--   M         cinema: the movie take for you alone (title card, chapter
--             captions, verdict hold, fade), no CoreGui or topbar, fixed
--             overview camera; M again stops it. Afterwards you rejoin the
--             shared run where it is.
--   board     walk up to a panel on the SCENARIOS board and press E: the
--             server switches everyone to that trace and restarts the clock.
--
-- The same buttons are on screen (right edge), so touch works too (Sober is
-- the Android client). The server publishes NandaScenario / NandaStart /
-- NandaRun (PlayClock.luau); this script renders that timeline from the trace
-- module, fast-forwarding through anything that happened before it joined.
--
-- For automation (MCP execute_luau on the client, tools/record_sober.sh uses a
-- real key press): set workspace attribute NandaKey to "V", "F", "M" or "W"
-- (walk) on the client to act as if the key were pressed; NandaPaused = true
-- freezes the replay for a screenshot. The client reports NandaMode, NandaSeq,
-- NandaCaughtUp and NandaCinema as workspace attributes (local only).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local NT = ReplicatedStorage:WaitForChild("NandaTown")
local Replay = require(NT:WaitForChild("Replay"))
local Util = require(NT:WaitForChild("Util"))
local Movie = require(NT:WaitForChild("Movie"))
local PlayClock = require(NT:WaitForChild("PlayClock"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local controls = nil
task.spawn(function()
	local ok, pm = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: ModuleScript)
	end)
	if ok and pm then
		controls = (pm :: any):GetControls()
	end
end)

local mode = "walk" -- walk | overview | fly
local cinema: { [string]: any }? = nil
local state: any = nil -- the shared replay's state (Replay.run)
local shared = { name = nil :: string?, start = 0, run = 0, timeline = nil :: any }

------------------------------------------------------------------------ helpers

local function hudRect()
	local vp = camera.ViewportSize
	local top = GuiService:GetGuiInset().Y
	return { x = 0, y = top, w = vp.X, h = vp.Y - top }
end

local function humanoid(): Humanoid?
	local c = player.Character
	return c and c:FindFirstChildOfClass("Humanoid") or nil
end

-- The client's town is collision-free (it is built for a camera); in the play
-- place you walk around it, so its buildings, stalls and ground are solid.
-- Agents and effects stay ghosts: they come and go with the replay.
local GROUND = { Plaza = true, ["Road (transport)"] = true, ["Road N-S"] = true }
local function makeSolid(town)
	for _, b in town.buildings do
		for _, p in b.model:GetDescendants() do
			if p:IsA("BasePart") then
				p.CanCollide = true
			end
		end
	end
	for _, s in town.stalls do
		for _, p in s.model:GetDescendants() do
			if p:IsA("BasePart") then
				p.CanCollide = true
			end
		end
	end
	for _, p in town.root:GetChildren() do
		if p:IsA("BasePart") and GROUND[p.Name] then
			p.CanCollide = true
		end
	end
end

------------------------------------------------------------------------ on-screen controls

local ui = Instance.new("ScreenGui")
ui.Name = "NandaPlayControls"
ui.ResetOnSpawn = false
ui.IgnoreGuiInset = true
ui.DisplayOrder = 30
ui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ui.Parent = playerGui

-- V / F / M: a small row at the top centre, under the topbar, between the
-- HUD's title and legend (positioned every frame below)
local strip = Instance.new("Frame")
strip.Name = "Strip"
strip.AnchorPoint = Vector2.new(0.5, 0)
strip.Size = UDim2.fromOffset(0, 46)
strip.AutomaticSize = Enum.AutomaticSize.X
strip.BackgroundTransparency = 1
strip.Parent = ui
local list = Instance.new("UIListLayout")
list.Padding = UDim.new(0, 6)
list.FillDirection = Enum.FillDirection.Horizontal
list.SortOrder = Enum.SortOrder.LayoutOrder
list.VerticalAlignment = Enum.VerticalAlignment.Top
list.Parent = strip
-- ▲ / ▼ for fly mode: right edge, middle (where a thumb is on a touch screen)
local flyStrip = Instance.new("Frame")
flyStrip.Name = "FlyStrip"
flyStrip.AnchorPoint = Vector2.new(1, 0.5)
flyStrip.Position = UDim2.new(1, -10, 0.5, 0)
flyStrip.Size = UDim2.fromOffset(58, 0)
flyStrip.AutomaticSize = Enum.AutomaticSize.Y
flyStrip.BackgroundTransparency = 1
flyStrip.Parent = ui
local flyList = list:Clone()
flyList.FillDirection = Enum.FillDirection.Vertical
flyList.Parent = flyStrip

local buttons: { [string]: TextButton } = {}
local function button(key: string, caption: string, order: number, parent: Instance?): TextButton
	local b = Instance.new("TextButton")
	b.Name = key
	b.LayoutOrder = order
	b.Size = UDim2.fromOffset(58, 46)
	b.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	b.BackgroundTransparency = 0.2
	b.AutoButtonColor = true
	b.RichText = true
	b.Text = string.format('<font size="20"><b>%s</b></font>\n<font size="12">%s</font>', key, caption)
	b.Font = Util.FONT_BOLD
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextSize = 14
	b.Parent = parent or strip
	Util.corner(b, 8)
	local s = Instance.new("UIStroke")
	s.Name = "Stroke"
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = Color3.fromRGB(90, 90, 100)
	s.Thickness = 1.5
	s.Parent = b
	buttons[key] = b
	return b
end
local bView = button("V", "overview", 1)
local bFly = button("F", "fly", 2)
local bMovie = button("M", "cinema", 3)
-- up / down for fly mode, mostly for touch (keys work too)
local hold = { up = false, down = false }
local bUp = button("▲", "up", 4, flyStrip)
local bDown = button("▼", "down", 5, flyStrip)
for b, key in { [bUp] = "up", [bDown] = "down" } do
	b.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			hold[key] = true
		end
	end)
	b.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			hold[key] = false
		end
	end)
end

-- one small status line, top centre under the HUD's title row: countdown
-- between runs, and who switched the scenario
local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 0)
status.Size = UDim2.fromOffset(420, 26)
status.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
status.BackgroundTransparency = 0.25
status.Font = Util.FONT_BOLD
status.TextSize = 16
status.TextColor3 = Color3.fromRGB(250, 190, 60)
status.RichText = true
status.Visible = false
status.Parent = ui
Util.corner(status, 13)

local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.LayoutOrder = 9
hint.Size = UDim2.fromOffset(84, 46)
hint.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
hint.BackgroundTransparency = 0.2
hint.Font = Util.FONT
hint.TextSize = 12
hint.TextWrapped = true
hint.TextColor3 = Color3.fromRGB(235, 235, 235)
hint.Text = "scenarios:\nboard by the\nspawn, E"
hint.Parent = strip
Util.corner(hint, 8)

local function refreshButtons()
	local active = { V = mode == "overview", F = mode == "fly", M = cinema ~= nil }
	for key, b in buttons do
		local on = active[key] == true
		b.BackgroundColor3 = on and Color3.fromRGB(250, 190, 60) or Color3.fromRGB(18, 18, 24)
		b.TextColor3 = on and Color3.fromRGB(20, 20, 20) or Color3.new(1, 1, 1)
	end
	bUp.Visible = mode == "fly"
	bDown.Visible = mode == "fly"
	workspace:SetAttribute("NandaMode", mode)
end

------------------------------------------------------------------------ fly

local fly: { [string]: any }? = nil

local function stopFly()
	if not fly then
		return
	end
	for _, inst in { fly.lv, fly.ao, fly.att } do
		if inst then
			inst:Destroy()
		end
	end
	if fly.hum and fly.hum.Parent then
		fly.hum.PlatformStand = false
		fly.hum:ChangeState(Enum.HumanoidStateType.Freefall)
	end
	fly = nil
end

local function startFly(): boolean
	local char = player.Character
	local hum = humanoid()
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (hum and hrp) or hum.Health <= 0 then
		return false
	end
	local att = Instance.new("Attachment")
	att.Name = "NandaFly"
	att.Parent = hrp
	local lv = Instance.new("LinearVelocity")
	lv.Name = "NandaFly"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = Vector3.zero
	lv.Parent = hrp
	local ao = Instance.new("AlignOrientation")
	ao.Name = "NandaFly"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.MaxTorque = math.huge
	ao.Responsiveness = 40
	ao.CFrame = hrp.CFrame.Rotation
	ao.Parent = hrp
	hum.PlatformStand = true
	-- a little lift so you leave the ground at once
	hrp.CFrame += Vector3.new(0, 3, 0)
	fly = { hum = hum, hrp = hrp, att = att, lv = lv, ao = ao }
	return true
end

local FLY_SPEED, FLY_FAST = 40, 110
local function stepFly()
	if not fly then
		return
	end
	if not fly.hrp.Parent or not fly.hum.Parent or fly.hum.Health <= 0 then
		stopFly()
		mode = "walk"
		refreshButtons()
		return
	end
	local move = controls and controls:GetMoveVector() or Vector3.zero
	-- automation (MCP): NandaFlyInput = Vector3(strafe, up, back) on the client
	local auto = workspace:GetAttribute("NandaFlyInput")
	local autoUp = 0
	if typeof(auto) == "Vector3" then
		move += Vector3.new(auto.X, 0, auto.Z)
		autoUp = auto.Y
	end
	local cf = camera.CFrame
	local dir = cf.RightVector * move.X - cf.LookVector * move.Z
	local up = autoUp
	if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) or hold.up or fly.hum.Jump then
		up += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Q) or UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or hold.down then
		up -= 1
	end
	dir += Vector3.new(0, up, 0)
	if dir.Magnitude > 1 then
		dir = dir.Unit
	end
	local fast = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
	fly.lv.VectorVelocity = dir * (fast and FLY_FAST or FLY_SPEED)
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude > 1e-3 then
		fly.ao.CFrame = CFrame.lookAt(Vector3.zero, look.Unit)
	end
end

------------------------------------------------------------------------ views

local function followCharacter()
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	local hum = humanoid()
	if hum then
		camera.CameraSubject = hum
	end
end

local function setMode(m: string)
	if cinema then
		return
	end
	if mode == "fly" and m ~= "fly" then
		stopFly()
	end
	if m == "fly" and mode ~= "fly" then
		if not startFly() then
			m = "walk"
		end
	end
	mode = m
	if m == "overview" then
		Replay.overview(camera, hudRect().w)
	else
		followCharacter()
	end
	refreshButtons()
end

------------------------------------------------------------------------ the shared replay

local function joinShared()
	if cinema then
		return
	end
	local name = workspace:GetAttribute("NandaScenario")
	local start = workspace:GetAttribute("NandaStart")
	if type(name) ~= "string" or type(start) ~= "number" then
		return
	end
	local trace = PlayClock.load(name)
	if not trace then
		warn("[NandaPlay] unknown scenario", name)
		return
	end
	local tl = PlayClock.timeline(trace)
	shared.name, shared.start, shared.timeline = name, start, tl
	shared.run = workspace:GetAttribute("NandaRun") or 0
	state = Replay.run(trace, {
		parent = workspace,
		guiParent = playerGui,
		camera = if mode == "overview" then camera else nil,
		hudRect = hudRect(),
		lead = tl.lead,
		targetSeconds = PlayClock.TARGET,
		clock = function()
			return workspace:GetServerTimeNow() - start
		end,
	})
	makeSolid(state.town)
	local by = workspace:GetAttribute("NandaPickedBy")
	if type(by) == "string" and by ~= "" then
		shared.toast = { text = string.format("%s picked <b>%s</b>", by, (string.gsub(name, "_", " "))), untilT = os.clock() + 4 }
	end
end

workspace:GetAttributeChangedSignal("NandaRun"):Connect(function()
	task.defer(joinShared) -- after the scenario and start attributes of the same change
end)

------------------------------------------------------------------------ cinema

local hidden = {} -- instances cinema mode took out of the picture, and where from

local function setCharactersHidden(on: boolean)
	for _, plr in Players:GetPlayers() do
		local c = plr.Character
		if c then
			for _, d in c:GetDescendants() do
				if d:IsA("BasePart") or d:IsA("Decal") then
					d.LocalTransparencyModifier = on and 1 or 0
				end
			end
			local hum = c:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.DisplayDistanceType = on and Enum.HumanoidDisplayDistanceType.None or Enum.HumanoidDisplayDistanceType.Viewer
			end
		end
	end
end

local function finishCinema()
	local c = cinema
	if not c then
		return
	end
	cinema = nil
	Movie.cleanup()
	Movie.showChrome()
	setCharactersHidden(false)
	for inst, parent in hidden do
		inst.Parent = parent
	end
	table.clear(hidden)
	ui.Enabled = true
	if controls then
		controls:Enable()
	end
	workspace:SetAttribute("NandaCinema", false)
	mode = c.prevMode == "fly" and "walk" or c.prevMode
	setMode(mode)
	joinShared()
end

local function startCinema()
	if cinema then
		cinema.token.cancelled = true -- Movie.run returns; its thread calls finishCinema
		return
	end
	local name = workspace:GetAttribute("NandaScenario")
	local trace = PlayClock.load(type(name) == "string" and name or PlayClock.DEFAULT)
	if not trace then
		return
	end
	local c = { token = { cancelled = false }, prevMode = mode }
	if mode == "fly" then
		stopFly()
	end
	cinema = c
	workspace:SetAttribute("NandaCinema", true)
	if controls then
		controls:Disable()
	end
	ui.Enabled = false
	local props = workspace:FindFirstChild("NandaPlay")
	if props then
		hidden[props] = props.Parent
		props.Parent = ReplicatedStorage
	end
	refreshButtons()
	task.spawn(function()
		local ok, err = pcall(Movie.run, trace, playerGui, function(extra)
			local opts: { [string]: any } = { parent = workspace, guiParent = playerGui, camera = camera }
			for k, v in extra do
				opts[k] = v
			end
			state = Replay.run(trace, opts)
			return state
		end, { token = c.token })
		if not ok then
			warn("[NandaPlay] cinema:", err)
		elseif not c.token.cancelled then
			task.wait(0.6) -- a beat of black after the fade
		end
		if cinema == c then
			finishCinema()
		end
	end)
end

------------------------------------------------------------------------ input

local function press(key: string)
	if key == "M" then
		startCinema()
	elseif cinema then
		return
	elseif key == "V" then
		setMode(mode == "overview" and "walk" or "overview")
	elseif key == "F" then
		setMode(mode == "fly" and "walk" or "fly")
	elseif key == "W" then
		setMode("walk")
	end
end

bView.Activated:Connect(function()
	press("V")
end)
bFly.Activated:Connect(function()
	press("F")
end)
bMovie.Activated:Connect(function()
	press("M")
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return -- typing in chat, or a ProximityPrompt / button took it
	end
	local k = input.KeyCode
	if k == Enum.KeyCode.V then
		press("V")
	elseif k == Enum.KeyCode.F then
		press("F")
	elseif k == Enum.KeyCode.M then
		press("M")
	end
end)

workspace:GetAttributeChangedSignal("NandaKey"):Connect(function()
	local k = workspace:GetAttribute("NandaKey")
	if type(k) == "string" and k ~= "" then
		workspace:SetAttribute("NandaKey", "")
		press(string.upper(k))
	end
end)
workspace:GetAttributeChangedSignal("NandaPaused"):Connect(function()
	Util.paused = workspace:GetAttribute("NandaPaused") == true
end)

player.CharacterAdded:Connect(function()
	if fly then
		stopFly()
	end
	if mode == "fly" then
		mode = "walk"
	end
	if not cinema and mode ~= "overview" then
		task.defer(followCharacter)
	end
	if cinema then
		task.defer(setCharactersHidden, true)
	end
	refreshButtons()
end)

------------------------------------------------------------------------ every frame

RunService:BindToRenderStep("NandaPlayCamera", Enum.RenderPriority.Camera.Value + 1, function()
	if cinema then
		Replay.overview(camera, Movie.frameRect().w)
		setCharactersHidden(true)
	elseif mode == "overview" then
		Replay.overview(camera, hudRect().w)
	end
	stepFly()
end)

local lastRect = ""
RunService.Heartbeat:Connect(function()
	if state then
		workspace:SetAttribute("NandaSeq", state.lastSeq)
		workspace:SetAttribute("NandaCaughtUp", state.caughtUp or 0)
	end
	if cinema then
		return
	end
	-- the HUD lives below the topbar and follows the window
	local r = hudRect()
	local key = string.format("%d,%d,%d,%d", r.x, r.y, r.w, r.h)
	if key ~= lastRect and state and state.hud and not cinema then
		lastRect = key
		state.hud:setRect(r)
	end
	-- status line: countdown between runs, or who picked the scenario
	local tl = shared.timeline
	local text = nil
	if shared.toast and os.clock() < shared.toast.untilT then
		text = shared.toast.text
	elseif tl then
		local t = workspace:GetServerTimeNow() - shared.start
		if t < 0 then
			text = "starting…"
		elseif t > tl.ends then
			text = string.format("next run in %d s", math.max(1, math.ceil(tl.period - t)))
		end
	end
	strip.Position = UDim2.fromOffset(r.w / 2, r.y + 12)
	status.Visible = text ~= nil
	if text then
		status.Text = text
		status.Position = UDim2.fromOffset(r.w / 2, r.y + 148) -- under the verdict banner
	end
end)

------------------------------------------------------------------------ go

refreshButtons()
if workspace:GetAttribute("NandaRun") then
	joinShared()
end
