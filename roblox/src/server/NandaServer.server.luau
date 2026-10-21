-- The play place's server: the ground players stand on, the spawn, the
-- scenario board, and the shared clock. The town itself is built by each
-- client (NandaPlay.client.luau) from the trace, like the replay places; the
-- server only says which trace is playing and when it started (PlayClock.luau).
-- Nothing here takes text from players, calls out, or stores anything.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NT = ReplicatedStorage:WaitForChild("NandaTown")
local PlayClock = require(NT:WaitForChild("PlayClock"))
local Util = require(NT:WaitForChild("Util"))
-- Red vs. Blue (live): a mode of this place, started from the portal by the spawn
local RedBlueServer = require(game:GetService("ServerScriptService"):WaitForChild("RedBlueServer"))

------------------------------------------------------------------------ world

local world = Instance.new("Folder")
world.Name = "NandaPlay" -- cinema mode hides this folder on the client
world.Parent = workspace

-- What players stand on. Invisible: each client draws the grass and plaza at
-- the same height (Town.luau); this is the collision under it, so characters
-- stand still even before a client has built its town.
local floor = Util.part({
	Name = "Floor",
	Size = Vector3.new(2048, 4, 2048),
	CFrame = CFrame.new(0, -2, -10),
	Transparency = 1,
	CanCollide = true,
	CastShadow = false,
	Parent = workspace,
})
floor.Locked = true

-- The spawn: the south edge of the square, facing the town (north, -z) and a
-- little toward the board.
local SPAWN = Vector3.new(0, 0, 62)
local spawn = Instance.new("SpawnLocation")
spawn.Name = "Spawn"
spawn.Anchored = true
spawn.Size = Vector3.new(10, 0.4, 10)
spawn.CFrame = CFrame.lookAt(SPAWN + Vector3.new(0, 0.2, 0), Vector3.new(-14, 0.2, 24))
spawn.Color = Color3.fromRGB(205, 200, 190)
spawn.Material = Enum.Material.Limestone
spawn.TopSurface = Enum.SurfaceType.Smooth
spawn.Duration = 0 -- no force field
spawn.Neutral = true
spawn.Parent = world

------------------------------------------------------------------------ board

-- One panel per converted Lab trace. Text comes from the trace only: its
-- scenario name, cast, event count and the evaluator's verdict.
local BOARD_CENTER = Vector3.new(-30, 0, 50)
local BOARD_FACING = Vector3.new(0.5, 0, 1).Unit -- toward the spawn
-- One row, at eye level: Roblox shows only the nearest prompt per key, so with
-- two rows the lower panel always won and the top row could not be picked.
local COLS, PW, PH, GAP = 11, 3.6, 4.0, 0.35
local PANEL_Y = 4.7
local GOLD = Color3.fromRGB(250, 190, 60)
local PANEL_BG = Color3.fromRGB(28, 28, 36)

local boardModel = Instance.new("Model")
boardModel.Name = "ScenarioBoard"
boardModel.Parent = world
local boardCF = CFrame.lookAt(BOARD_CENTER, BOARD_CENTER + BOARD_FACING)
local width = COLS * (PW + GAP) + GAP
local function at(dx: number, dy: number, dz: number): CFrame
	return boardCF * CFrame.new(dx, dy, dz)
end
Util.part({
	Name = "Backboard",
	Size = Vector3.new(width + 1, 7.6, 0.6),
	CFrame = at(0, 6.0, 0.3),
	Color = Color3.fromRGB(110, 75, 45),
	Material = Enum.Material.Wood,
	CanCollide = true,
	Parent = boardModel,
})
for _, dx in { -width / 2, width / 2 } do
	Util.part({ Name = "Post", Size = Vector3.new(1, 10.6, 1), CFrame = at(dx, 5.3, 0.3), Color = Color3.fromRGB(90, 60, 35), Material = Enum.Material.Wood, CanCollide = true, Parent = boardModel })
end
local header = Util.part({ Name = "Header", Size = Vector3.new(width + 1, 1.8, 0.4), CFrame = at(0, 8.6, 0.1), Color = Color3.fromRGB(25, 25, 32), Parent = boardModel })
Util.sign(header, Enum.NormalId.Front, "SCENARIOS  ·  press E at one to replay it for everyone", {
	bg = Color3.fromRGB(25, 25, 32),
	color = GOLD,
	pps = 30,
	scaled = false, -- TextScaled overflowed the header at this aspect
	textSize = 28,
})

local panels: { [string]: { part: BasePart, stroke: UIStroke, name: TextLabel } } = {}

local function castOf(trace): string
	local counts, order = {}, {}
	for _, p in trace.participants do
		if not counts[p.role] then
			counts[p.role] = 0
			table.insert(order, p.role)
		end
		counts[p.role] += 1
	end
	local bits = {}
	for _, r in order do
		table.insert(bits, string.format("%d %s", counts[r], string.gsub(r, "_", " ")))
	end
	return table.concat(bits, " · ")
end

local function verdictOf(trace): (string, boolean)
	local r = trace.result
	if not r then
		return "no verdict", false
	end
	local passed = 0
	for _, s in r.stages do
		if s.status == "passed" then
			passed += 1
		end
	end
	local good = r.verdict == "passed"
	return string.format("%s %d/%d", string.upper(r.verdict or "?"), passed, #r.stages), good
end

local startRun -- forward

local function makePanel(i: number, name: string, trace)
	local row, col = (i - 1) // COLS, (i - 1) % COLS
	local inRow = math.min(COLS, #PlayClock.ORDER - row * COLS)
	-- seen from the front, a part's +X points to the viewer's left
	local x = -(col - (inRow - 1) / 2) * (PW + GAP)
	local y = PANEL_Y - row * (PH + GAP)
	local p = Util.part({
		Name = "Panel " .. name,
		Size = Vector3.new(PW, PH, 0.3),
		CFrame = at(x, y, -0.15),
		Color = PANEL_BG,
		CanCollide = false,
		Parent = boardModel,
	})
	local g = Instance.new("SurfaceGui")
	g.Name = "Face"
	g.Face = Enum.NormalId.Front
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 60
	g.LightInfluence = 0
	g.Parent = p
	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = PANEL_BG
	bg.BorderSizePixel = 0
	bg.Parent = g
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 6
	stroke.Color = Color3.fromRGB(70, 70, 80)
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = bg
	local verdict, good = verdictOf(trace)
	local title = Util.label(bg, {
		Name = "Name",
		Text = (string.gsub(name, "_", " ")),
		Position = UDim2.fromScale(0.05, 0.04),
		Size = UDim2.fromScale(0.9, 0.42),
		TextScaled = true,
		TextWrapped = true,
		Font = Util.FONT_HEAVY,
		TextColor3 = Color3.new(1, 1, 1),
	})
	-- cap the size, or TextScaled breaks "marketplace" mid-word to fill the panel
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 30
	cap.Parent = title
	Util.label(bg, {
		Name = "Cast",
		Text = castOf(trace),
		Position = UDim2.fromScale(0.05, 0.48),
		Size = UDim2.fromScale(0.9, 0.22),
		TextScaled = true,
		TextWrapped = true,
		Font = Util.FONT,
		TextColor3 = Color3.fromRGB(205, 205, 215),
	})
	Util.label(bg, {
		Name = "Verdict",
		Text = string.format("%d events · <font color='%s'>%s</font>", #trace.events, good and "#78e68c" or "#ff7070", verdict),
		Position = UDim2.fromScale(0.05, 0.73),
		Size = UDim2.fromScale(0.9, 0.22),
		TextScaled = true,
		Font = Util.FONT_BOLD,
		TextColor3 = Color3.fromRGB(230, 230, 230),
	})
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Pick"
	prompt.ActionText = "Replay for everyone"
	prompt.ObjectText = (string.gsub(name, "_", " "))
	prompt.HoldDuration = 0.25
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Parent = p
	prompt.Triggered:Connect(function(player)
		startRun(name, workspace:GetServerTimeNow() + PlayClock.SWITCH_DELAY, player)
	end)
	panels[name] = { part = p, stroke = stroke, name = title }
end

for i, name in PlayClock.ORDER do
	local trace = PlayClock.load(name)
	if trace then
		makePanel(i, name, trace)
	else
		warn("[NandaServer] no trace module for", name)
	end
end

local current = { name = "", start = 0, period = 60 }
local lastPick = -math.huge

------------------------------------------------------------------------ portal

-- Red vs. Blue (live): an arch on the right of the spawn, opposite the
-- board. E starts it for everyone; in live mode the same arch leads back to
-- the replay. The default experience (the replay) never changes until
-- someone walks through it.
local PORTAL = Vector3.new(30, 0, 46)
local portalModel = Instance.new("Model")
portalModel.Name = "RedBluePortal"
portalModel.Parent = world
local portalCF = CFrame.lookAt(PORTAL, Vector3.new(SPAWN.X, 0, SPAWN.Z))
for i, dx in { -5, 5 } do
	Util.part({
		Name = "Pillar",
		Size = Vector3.new(2, 12, 2),
		CFrame = portalCF * CFrame.new(dx, 6, 0),
		Color = i == 1 and Color3.fromRGB(215, 50, 50) or Color3.fromRGB(50, 110, 235),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
		Parent = portalModel,
	})
end
local portalTop = Util.part({ Name = "Lintel", Size = Vector3.new(14, 3, 1.2), CFrame = portalCF * CFrame.new(0, 13.5, 0), Color = Color3.fromRGB(25, 25, 32), CanCollide = true, Parent = portalModel })
local portalSign = Util.sign(portalTop, Enum.NormalId.Back, "", { bg = Color3.fromRGB(25, 25, 32), color = GOLD, pps = 24 })
local portalVeil = Util.part({ Name = "Veil", Size = Vector3.new(8, 11.5, 0.3), CFrame = portalCF * CFrame.new(0, 5.9, 0), Color = Color3.fromRGB(160, 110, 230), Material = Enum.Material.Neon, Transparency = 0.55, Parent = portalModel })
local portalPrompt = Instance.new("ProximityPrompt")
portalPrompt.Name = "Live"
portalPrompt.HoldDuration = 0.4
portalPrompt.MaxActivationDistance = 10
portalPrompt.RequiresLineOfSight = false
portalPrompt.KeyboardKeyCode = Enum.KeyCode.E
portalPrompt.Parent = portalVeil

local function setPortal(on: boolean)
	portalSign.Text = on and "BACK TO THE REPLAY  ·  E" or "RED vs. BLUE  ·  LIVE  ·  E"
	portalPrompt.ActionText = on and "Back to the replay (for everyone)" or "Start Red vs. Blue (for everyone)"
	portalPrompt.ObjectText = on and "Red vs. Blue is on" or "a live town, two teams, a council"
	portalVeil.Color = on and Color3.fromRGB(250, 190, 60) or Color3.fromRGB(160, 110, 230)
end
setPortal(false)
portalPrompt.Triggered:Connect(function(player)
	if current.name == PlayClock.LIVE then
		startRun(PlayClock.DEFAULT, workspace:GetServerTimeNow() + PlayClock.SWITCH_DELAY, player)
	else
		startRun(PlayClock.LIVE, workspace:GetServerTimeNow(), player)
	end
end)

-- automation (MCP execute_luau on the server): NandaServerCmd = "live" | "replay"
workspace:GetAttributeChangedSignal("NandaServerCmd"):Connect(function()
	local cmd = workspace:GetAttribute("NandaServerCmd")
	if cmd == "live" then
		startRun(PlayClock.LIVE, workspace:GetServerTimeNow())
	elseif cmd == "replay" then
		startRun(PlayClock.DEFAULT, workspace:GetServerTimeNow() + PlayClock.SWITCH_DELAY)
	end
	if cmd ~= nil and cmd ~= "" then
		workspace:SetAttribute("NandaServerCmd", "")
	end
end)

------------------------------------------------------------------------ clock

local function highlightPanel(name: string)
	for n, p in panels do
		local on = n == name
		p.stroke.Color = on and GOLD or Color3.fromRGB(70, 70, 80)
		p.name.TextColor3 = on and GOLD or Color3.new(1, 1, 1)
	end
end

local live = nil -- the running RedBlueServer, in live mode

startRun = function(name: string, start: number, by: Player?)
	local trace = PlayClock.load(name)
	if not trace and name ~= PlayClock.LIVE then
		return
	end
	if by then
		local now = os.clock()
		if now - lastPick < 1.0 then
			return
		end
	end
	if name == PlayClock.LIVE then
		lastPick = os.clock()
		if not live then
			live = RedBlueServer.start(world) -- remotes exist before clients hear of it
		end
		current.name, current.start, current.period = name, start, math.huge
		workspace:SetAttribute("NandaScenario", name)
		workspace:SetAttribute("NandaStart", start)
		workspace:SetAttribute("NandaPeriod", 0)
		workspace:SetAttribute("NandaPickedBy", by and by.DisplayName or "")
		workspace:SetAttribute("NandaRun", (workspace:GetAttribute("NandaRun") or 0) + 1)
		highlightPanel("")
		setPortal(true)
		return
	end
	if live then
		live.stop()
		live = nil
		setPortal(false)
	end
	if by then
		-- one pick per second for the whole server, so two players can't thrash it
		local now = os.clock()
		if now - lastPick < 1.0 then
			return
		end
		lastPick = now
	end
	local tl = PlayClock.timeline(trace)
	current.name, current.start, current.period = name, start, tl.period
	workspace:SetAttribute("NandaScenario", name)
	workspace:SetAttribute("NandaStart", start)
	workspace:SetAttribute("NandaPeriod", tl.period)
	workspace:SetAttribute("NandaPickedBy", by and by.DisplayName or "")
	-- last: clients restart on this one
	workspace:SetAttribute("NandaRun", (workspace:GetAttribute("NandaRun") or 0) + 1)
	highlightPanel(name)
end

startRun(PlayClock.DEFAULT, workspace:GetServerTimeNow() + PlayClock.SWITCH_DELAY)

-- Loop: when a run's period is over, the next run of the same scenario starts
-- exactly where the last one ended (no drift); after a long stall, from now.
task.spawn(function()
	while true do
		task.wait(0.2)
		local now = workspace:GetServerTimeNow()
		local nextStart = current.start + current.period
		if current.name ~= PlayClock.LIVE and now >= nextStart then
			if now - nextStart > current.period then
				nextStart = now + PlayClock.SWITCH_DELAY
			end
			startRun(current.name, nextStart)
		end
	end
end)

------------------------------------------------------------------------ characters

-- Characters load once the spawn exists (CharacterAutoLoads is off in
-- play.project.json), and again a few seconds after a death or a fall.
local function setup(player: Player)
	player.CharacterAdded:Connect(function(char)
		local hum = char:WaitForChild("Humanoid") :: Humanoid
		hum.Died:Connect(function()
			task.delay(Players.RespawnTime, function()
				if player.Parent then
					player:LoadCharacter()
				end
			end)
		end)
	end)
	player:LoadCharacter()
end

Players.PlayerAdded:Connect(setup)
for _, player in Players:GetPlayers() do
	task.spawn(setup, player)
end
