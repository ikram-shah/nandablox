-- Red vs. Blue (live), the server side: runs the pure Game (RedBlue/Game.luau,
-- which runs TownSim) on the server clock and connects it to Roblox.
--
--   Teams        Red and Blue (Teams service), joined on two pads by the spawn
--   red          ProximityPrompts at the gate (forge) and the notice board (spoof)
--   blue         RemoteEvent Flag(id, cameraMode), sent by a click (RedBlueView)
--   council      RemoteEvent Vote(layer); a chamber with the laws on a board
--   watchtower   a tall tower east of the spawn; a prompt at its foot lifts you up
--   stream       RemoteEvent Events: batches of town + game events, with the
--                private keys (leading "_") stripped. Hello -> a snapshot.
--   HUD          workspace attributes RB_* (phase, clock, scores, tokens, layers, votes)
--   telemetry    FlowBench records printed as JSON lines ("FLOWBENCH {...}")
--   agents       RemoteEvent Llm: cycle which roles a language model drives
--                (Config.LLM_PRESETS; default: none, every trader scripted).
--                A coroutine polls the external harness over HttpService and
--                hands what it says to LlmPolicy; nothing waits for it.
--
-- Nothing here takes text from players. The structures are built from parts
-- by code; their positions match the town that Town.luau builds on clients.
-- Next step (not built): replace TownSim with a real NANDA Town server polled
-- over HttpService; see roblox/README.md, "Red vs. Blue (live)".

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Teams = game:GetService("Teams")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local NT = ReplicatedStorage:WaitForChild("NandaTown")
local Util = require(NT:WaitForChild("Util"))
local RB = NT:WaitForChild("RedBlue")
local Config = require(RB:WaitForChild("Config"))
local Game = require(RB:WaitForChild("Game"))
local LlmPolicy = require(RB:WaitForChild("LlmPolicy"))
local Harness = require(RB:WaitForChild("Harness"))

local RedBlueServer = {}

-- where things are (Town.luau builds the same town on every client)
RedBlueServer.GATE_PROMPT = Vector3.new(-62, 3, 2) -- plaza side of the gate
RedBlueServer.BOARD_PROMPT = Vector3.new(-44, 3, -35) -- in front of the notice board
RedBlueServer.TOWER = Vector3.new(74, 0, 58)
RedBlueServer.TOWER_HEIGHT = 40
RedBlueServer.CHAMBER = Vector3.new(-82, 0, 40)
RedBlueServer.PADS = { red = Vector3.new(-14, 0, 57), blue = Vector3.new(14, 0, 57) }

local ATTR_PREFIX = "RB_"

------------------------------------------------------------------ the secret

-- The shared secret a hosted harness requires (see Config.LLM_SECRET). Looked
-- up once and cached. It is never printed: a `Secret` cannot be printed at
-- all, and the fallback is only ever concatenated into a header.
--
--   1. HttpService:GetSecret(Config.LLM_SECRET) -- the experience's secrets
--      store, which is the right place for it: not in the place file at all.
--      It does not exist in Studio or in a local run, and that is fine.
--   2. ServerStorage.NandaSecrets.LlmToken -- a module baked into the *built*
--      place by tools/secret.sh, never committed. ServerStorage is not
--      replicated, so no player can read it; anyone who can edit the place
--      can. Demo-grade, and second for that reason.
--
-- Deliberately no attribute and no RemoteEvent route: workspace attributes
-- replicate to every client, which would hand the token to everyone present.
local llmAuth: any = nil -- the Authorization value; false once we know there is none
local llmAuthSource = "none"

local function resolveLlmAuth()
	if llmAuth ~= nil then
		return
	end
	local name = Config.LLM_SECRET
	if type(name) == "string" and name ~= "" then
		local ok, header = pcall(function()
			return (HttpService :: any):GetSecret(name):AddPrefix("Bearer ")
		end)
		if ok and header then
			llmAuth, llmAuthSource = header, "secrets_store"
			return
		end
	end
	local box = ServerStorage:FindFirstChild("NandaSecrets")
	local mod = box and box:FindFirstChild("LlmToken")
	if mod and mod:IsA("ModuleScript") then
		local ok, token = pcall(require, mod)
		if ok and type(token) == "string" and token ~= "" then
			llmAuth, llmAuthSource = "Bearer " .. token, "place"
			return
		end
	end
	llmAuth, llmAuthSource = false, "none"
end

local function llmTokenSource(): string
	resolveLlmAuth()
	return llmAuthSource
end

-- The headers for one poll: JSON, the shared secret, and which Roblox server
-- this is. The harness rate-limits per JobId, so one live server cannot
-- monopolise it however many are running.
local function llmHeaders(serverId: string): { [string]: any }
	resolveLlmAuth()
	local headers: { [string]: any } = { ["Content-Type"] = "application/json", ["X-Nanda-Server"] = serverId }
	if llmAuth then
		headers["Authorization"] = llmAuth
	end
	return headers
end

local function notice(remotes, player: Player, text: string, color: string?, extra: { [string]: any }?)
	local n = { text = text, color = color }
	for k, v in extra or {} do
		n[k] = v
	end
	remotes.Notice:FireClient(player, n)
end

------------------------------------------------------------------------ structures

local function sign(part: BasePart, face: Enum.NormalId, text: string, color: Color3, bg: Color3?, pps: number?)
	return Util.sign(part, face, text, { bg = bg or Color3.fromRGB(25, 25, 32), color = color, pps = pps or 20 })
end

local function buildPads(folder: Instance, onPad: (Player, string) -> ())
	for team, pos in RedBlueServer.PADS do
		local color = team == "red" and Color3.fromRGB(220, 50, 50) or Color3.fromRGB(50, 110, 240)
		local pad = Util.part({
			Name = "Pad " .. team,
			Size = Vector3.new(9, 0.6, 9),
			CFrame = CFrame.new(pos + Vector3.new(0, 0.3, 0)),
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = true,
			Parent = folder,
		})
		pad.CanTouch = true
		local post = Util.part({ Name = "PadSign", Size = Vector3.new(7, 2.2, 0.4), CFrame = CFrame.new(pos + Vector3.new(0, 4.2, -4.6)), Color = color, CanCollide = false, Parent = folder })
		local label = team == "red" and "RED TEAM · attack" or "BLUE TEAM · watch"
		sign(post, Enum.NormalId.Back, label, Color3.new(1, 1, 1), color, 30)
		sign(post, Enum.NormalId.Front, label, Color3.new(1, 1, 1), color, 30)
		local debounce = {}
		pad.Touched:Connect(function(hit)
			local char = hit:FindFirstAncestorOfClass("Model")
			local player = char and Players:GetPlayerFromCharacter(char)
			if player and not debounce[player] then
				debounce[player] = true
				onPad(player, team)
				task.delay(1, function()
					debounce[player] = nil
				end)
			end
		end)
	end
end

local function buildTower(folder: Instance): BasePart
	local base = RedBlueServer.TOWER
	local h = RedBlueServer.TOWER_HEIGHT
	local m = Instance.new("Model")
	m.Name = "Watchtower"
	m.Parent = folder
	local wood = Color3.fromRGB(120, 85, 55)
	for _, dx in { -5, 5 } do
		for _, dz in { -5, 5 } do
			Util.part({ Name = "Leg", Size = Vector3.new(1.6, h, 1.6), CFrame = CFrame.new(base + Vector3.new(dx, h / 2, dz)), Color = wood, Material = Enum.Material.Wood, CanCollide = true, Parent = m })
		end
	end
	for y = 10, h - 6, 10 do
		for _, dz in { -5, 5 } do
			Util.part({ Name = "Brace", Size = Vector3.new(10, 0.8, 0.8), CFrame = CFrame.new(base + Vector3.new(0, y, dz)), Color = wood, Material = Enum.Material.Wood, CanCollide = true, Parent = m })
		end
	end
	local deck = Util.part({ Name = "Deck", Size = Vector3.new(16, 1, 16), CFrame = CFrame.new(base + Vector3.new(0, h + 0.5, 0)), Color = Color3.fromRGB(150, 110, 70), Material = Enum.Material.WoodPlanks, CanCollide = true, Parent = m })
	for _, side in { { 0, -8, 16, 0.6 }, { 0, 8, 16, 0.6 }, { -8, 0, 0.6, 16 }, { 8, 0, 0.6, 16 } } do
		Util.part({ Name = "Rail", Size = Vector3.new(side[3], 1.2, side[4]), CFrame = CFrame.new(base + Vector3.new(side[1], h + 2.6, side[2])), Color = wood, Material = Enum.Material.Wood, CanCollide = true, Parent = m })
	end
	Util.part({ Name = "Roof", Size = Vector3.new(17, 0.8, 17), CFrame = CFrame.new(base + Vector3.new(0, h + 11, 0)), Color = Color3.fromRGB(40, 70, 150), CanCollide = true, Parent = m })
	for _, dx in { -7.5, 7.5 } do
		for _, dz in { -7.5, 7.5 } do
			Util.part({ Name = "RoofPost", Size = Vector3.new(0.8, 10, 0.8), CFrame = CFrame.new(base + Vector3.new(dx, h + 6, dz)), Color = wood, CanCollide = true, Parent = m })
		end
	end
	-- a ladder you can climb (a TrussPart), on the town side
	local truss = Instance.new("TrussPart")
	truss.Name = "Ladder"
	truss.Anchored = true
	truss.Size = Vector3.new(2, h, 2)
	truss.CFrame = CFrame.new(base + Vector3.new(0, h / 2, -6.2))
	truss.Color = Color3.fromRGB(90, 90, 100)
	truss.Parent = m
	-- the sign faces the spawn (south), out of the watchers' line of sight
	local board = Util.part({ Name = "TowerSign", Size = Vector3.new(14, 2.4, 0.4), CFrame = CFrame.new(base + Vector3.new(0, h + 12.8, 8.4)), Color = Color3.fromRGB(25, 25, 32), Parent = m })
	sign(board, Enum.NormalId.Back, "WATCHTOWER · blue", Color3.fromRGB(140, 180, 255), nil, 24)
	local foot = Util.part({ Name = "TowerFoot", Size = Vector3.new(3, 3, 3), CFrame = CFrame.new(base + Vector3.new(0, 1.5, -9)), Transparency = 1, Parent = m })
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Climb"
	prompt.ActionText = "Climb the watchtower"
	prompt.ObjectText = "Watchtower"
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = foot
	prompt.Triggered:Connect(function(player)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			char:PivotTo(CFrame.lookAt(base + Vector3.new(0, h + 4, -3), base + Vector3.new(-40, h, -80)))
		end
	end)
	return deck
end

local function buildChamber(folder: Instance): TextLabel
	local c = RedBlueServer.CHAMBER
	local m = Instance.new("Model")
	m.Name = "Council chamber"
	m.Parent = folder
	local marble = Color3.fromRGB(240, 236, 228)
	local floor = Util.part({ Name = "Floor", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1, 22, 22), CFrame = CFrame.new(c + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = Color3.fromRGB(210, 200, 230), Material = Enum.Material.Marble, CanCollide = true, Parent = m })
	floor.CastShadow = false
	for i = 0, 7 do
		local a = i * math.pi / 4
		if i ~= 2 then -- an open side toward the square
			Util.part({ Name = "Column", Size = Vector3.new(1.4, 12, 1.4), CFrame = CFrame.new(c + Vector3.new(math.cos(a) * 9.5, 7, math.sin(a) * 9.5)), Color = marble, Material = Enum.Material.Marble, CanCollide = true, Parent = m })
		end
	end
	Util.part({ Name = "Ring", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.2, 23, 23), CFrame = CFrame.new(c + Vector3.new(0, 13.6, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = marble, Material = Enum.Material.Marble, Parent = m })
	Util.part({ Name = "Dome", Shape = Enum.PartType.Ball, Size = Vector3.new(19, 19, 19), CFrame = CFrame.new(c + Vector3.new(0, 14, 0)), Color = Color3.fromRGB(170, 140, 220), Material = Enum.Material.SmoothPlastic, Parent = m })
	local laws = Util.part({ Name = "Laws", Size = Vector3.new(9, 6, 0.4), CFrame = CFrame.lookAt(c + Vector3.new(0, 4.5, -3), c + Vector3.new(0, 4.5, 20)), Color = Color3.fromRGB(30, 25, 45), CanCollide = true, Parent = m })
	local text = Util.sign(laws, Enum.NormalId.Front, "", { bg = Color3.fromRGB(30, 25, 45), color = Color3.fromRGB(230, 210, 255), pps = 40, scaled = true })
	local title = Util.part({ Name = "ChamberSign", Size = Vector3.new(14, 2, 0.4), CFrame = CFrame.lookAt(c + Vector3.new(0, 16.4, 9.8), c + Vector3.new(0, 16.4, 30)), Color = Color3.fromRGB(30, 25, 45), Parent = m })
	sign(title, Enum.NormalId.Front, "COUNCIL CHAMBER", Color3.fromRGB(220, 190, 255), Color3.fromRGB(30, 25, 45), 24)
	return text
end

-- a red-only prompt at a building
local function attackPrompt(folder: Instance, name: string, pos: Vector3, action: string, object: string, onTrigger: (Player) -> ())
	local anchor = Util.part({ Name = name, Size = Vector3.new(2, 2, 2), CFrame = CFrame.new(pos), Transparency = 1, Parent = folder })
	local p = Instance.new("ProximityPrompt")
	p.Name = "Attack"
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0.6
	p.MaxActivationDistance = 12
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p:SetAttribute("RedOnly", true) -- RedBlueView hides it from everyone else
	p.Parent = anchor
	p.Triggered:Connect(onTrigger)
	return p
end

------------------------------------------------------------------------ start / stop

-- world: the NandaPlay folder (cinema mode hides it on the client)
function RedBlueServer.start(world: Instance)
	local self = { conns = {}, running = true }

	-- teams
	local red = Instance.new("Team")
	red.Name = "Red"
	red.TeamColor = BrickColor.new("Really red")
	red.AutoAssignable = false
	red.Parent = Teams
	local blue = Instance.new("Team")
	blue.Name = "Blue"
	blue.TeamColor = BrickColor.new("Really blue")
	blue.AutoAssignable = false
	blue.Parent = Teams
	self.teams = { red = red, blue = blue }

	-- remotes
	local remotes = Instance.new("Folder")
	remotes.Name = "NandaRedBlue"
	for _, n in { "Events", "Hello", "Flag", "Vote", "Camera", "Notice", "Llm" } do
		local r = Instance.new("RemoteEvent")
		r.Name = n
		r.Parent = remotes
	end
	remotes.Parent = ReplicatedStorage
	self.remotes = remotes

	-- the game. Every trader's decisions go through LlmPolicy's wrapper, which
	-- is Policy.Scripted* exactly until someone makes an agent model-driven.
	local prefix = Config.TELEMETRY_PREFIX
	local store = LlmPolicy.new({ config = Config })
	local harness = Harness.new({ config = Config, store = store })
	self.store, self.harness = store, harness
	harness.serverId = (game.JobId ~= "" and game.JobId) or "studio"
	harness.tokenSource = llmTokenSource()
	local game_ = Game.new({
		config = Config,
		seed = os.time() % 100000,
		policies = store:policies(),
		sink = function(r)
			print(prefix .. HttpService:JSONEncode(r))
		end,
	})
	self.game = game_
	local t0 = workspace:GetServerTimeNow()
	local function now(): number
		return workspace:GetServerTimeNow() - t0
	end

	local function setTeam(player: Player, team: string?)
		player.Team = team and self.teams[team] or nil
		player.Neutral = team == nil
		game_:setTeam(player.UserId, team)
	end

	-- structures
	local folder = Instance.new("Folder")
	folder.Name = "RedBlue"
	folder.Parent = world
	self.folder = folder
	buildPads(folder, function(player, team)
		if game_:teamOf(player.UserId) ~= team then
			setTeam(player, team)
			notice(remotes, player, team == "red" and "You joined RED: attack at the gate and the notice board" or "You joined BLUE: climb the watchtower and flag what looks wrong", team, { seconds = 5 })
		end
	end)
	buildTower(folder)
	local laws = buildChamber(folder)

	local function attack(kind: string)
		return function(player: Player)
			local ok, why, th = game_:attack(player.UserId, kind)
			if not ok then
				local msg = ({
					not_red = "Only the red team can do that (step on the red pad)",
					no_tokens = "No attacks left this round",
					cooldown = "Wait a moment between attacks",
					not_playing = "Between rounds: wait for the next one",
				})[why] or why
				notice(remotes, player, msg, "gold")
				return
			end
			if th.state == "blocked" then
				notice(remotes, player, kind == "forge" and "Blocked: the guards check signatures (hmac.v1). Token spent." or "Refused: the board checks who owns a name (index.owned.v1). Token spent.", "red", { seconds = 5 })
			elseif kind == "forge" then
				notice(remotes, player, string.format("Forged invoice from %s to %s: pays %s in %d s unless blue flags it", th.claimed, th.victim, th.alias, Config.FORGE_WINDOW), "red", { seconds = 6 })
			else
				notice(remotes, player, string.format("Spoofed card '%s' is on the board: the next buyer pays you unless blue flags it", th.claimed), "red", { seconds = 6 })
			end
		end
	end
	attackPrompt(folder, "Forge at the gate", RedBlueServer.GATE_PROMPT, "Forge an invoice", "Gate · red team", attack("forge"))
	attackPrompt(folder, "Spoof at the board", RedBlueServer.BOARD_PROMPT, "Spoof a seller's card", "Notice board · red team", attack("spoof"))

	-- players
	local function join(player: Player)
		game_:join(player.UserId, player.DisplayName)
		player.Neutral = true
	end
	for _, p in Players:GetPlayers() do
		join(p)
	end
	table.insert(self.conns, Players.PlayerAdded:Connect(join))
	table.insert(self.conns, Players.PlayerRemoving:Connect(function(p)
		game_:leave(p.UserId)
	end))

	table.insert(self.conns, remotes.Hello.OnServerEvent:Connect(function(player)
		local snap = {}
		for _, e in game_:snapshotEvents() do
			table.insert(snap, Game.public(e))
		end
		remotes.Events:FireClient(player, snap)
	end))
	table.insert(self.conns, remotes.Flag.OnServerEvent:Connect(function(player, id, camera)
		if type(id) ~= "string" or #id > 40 then
			return
		end
		local cam = type(camera) == "string" and string.sub(camera, 1, 16) or nil
		local result = game_:flag(player.UserId, id, { camera = cam })
		local msg = ({
			catch = { "CAUGHT it: +" .. Config.CATCH_POINTS .. " blue", "blue" },
			false_alarm = { "False alarm: that one was honest (" .. Config.FALSE_ALARM_POINTS .. ")", "gold" },
			stale = { "Too late: that one is already settled", "gold" },
			miss = { "Nothing to flag there: click a courier or a card", nil },
			not_blue = { "Only the blue team flags (step on the blue pad)", "gold" },
		})[result]
		if msg then
			notice(remotes, player, msg[1], msg[2])
		end
	end))
	table.insert(self.conns, remotes.Vote.OnServerEvent:Connect(function(player, layer)
		if type(layer) ~= "string" then
			return
		end
		local yes = game_:vote(player.UserId, layer)
		if yes ~= nil then
			local carried = game_.council:count(layer) == 0 and yes
			notice(remotes, player, carried and string.format("Carried: %s is now %s", layer, game_.layers[layer]) or (yes and string.format("You voted to switch %s to %s", layer, game_:otherOption(layer)) or string.format("You withdrew your %s vote", layer)), "gold", { kind = "vote", layer = layer, yes = yes and not carried })
		end
	end))
	table.insert(self.conns, remotes.Camera.OnServerEvent:Connect(function(player, mode)
		if type(mode) == "string" and #mode <= 16 then
			game_:setCamera(player.UserId, mode)
		end
	end))

	------------------------------------------------------------ model-driven agents

	-- Which traders a language model drives. Default: none, so the published
	-- place is the scripted town it has always been. L (or the HUD button,
	-- or the RB_LlmCmd attribute) cycles Config.LLM_PRESETS.
	local preset = 1
	local lastLlmJson = nil
	local lastLogged = {} -- agent -> the decision seq already in the telemetry
	local function publishLlm()
		local st = harness:status()
		local names = store:agents()
		local health = (#names == 0 and "off")
			or (st.health == "error" and "error")
			or (st.llm == "no_key" and "no_key")
			or (st.ok > 0 and "ok")
			or "waiting"
		local model = Config.LLM_MODEL
		local line, latency = nil, nil
		for _, a in st.agents do
			model = a.model or model
			line = line or a.line
			latency = latency or a.latency
		end
		local json = HttpService:JSONEncode({
			agents = st.agents,
			health = health,
			url = st.url,
			requests = st.requests,
			errors = st.errors,
			actions = st.actions,
			roundTrip = st.roundTrip,
			error = st.error,
			model = model,
			token = st.token, -- where the shared secret came from, never the secret
		})
		if json ~= lastLlmJson then
			lastLlmJson = json
			workspace:SetAttribute(ATTR_PREFIX .. "Llm", json)
		end
		workspace:SetAttribute(ATTR_PREFIX .. "LlmAgents", table.concat(names, ","))
		workspace:SetAttribute(ATTR_PREFIX .. "LlmHealth", health)
		workspace:SetAttribute(ATTR_PREFIX .. "LlmModel", model)
		workspace:SetAttribute(ATTR_PREFIX .. "LlmLine", line or "")
		workspace:SetAttribute(ATTR_PREFIX .. "LlmLatency", latency or 0)
	end

	-- who: a player, or nil for an automated switch
	local function setPreset(i: number, who: string?)
		preset = ((i - 1) % #Config.LLM_PRESETS) + 1
		local names = store:setAgents(Config.LLM_PRESETS[preset])
		publishLlm()
		game_.telemetry:record(now(), "llm_mode", { agents = names, model = Config.LLM_MODEL, by = who })
		local text = #names == 0 and "Agents: every trader is scripted Luau again"
			or string.format(
				"Agents: %s %s now model-driven (%s, through the local harness)",
				table.concat(names, " and "),
				#names == 1 and "is" or "are",
				Config.LLM_MODEL
			)
		for _, p in Players:GetPlayers() do
			notice(remotes, p, text, "gold", { seconds = 5 })
		end
	end

	-- The harness's address, if it is not the one in Config (a tunnel, another
	-- machine on the LAN, a hosted endpoint). Set RB_LlmUrl on the server.
	table.insert(self.conns, workspace:GetAttributeChangedSignal(ATTR_PREFIX .. "LlmUrl"):Connect(function()
		local v = workspace:GetAttribute(ATTR_PREFIX .. "LlmUrl")
		if type(v) == "string" and string.match(v, "^https?://[%w%.%-:_/]+$") then
			harness.url = v .. Config.LLM_PATH
			publishLlm()
		end
	end))

	table.insert(self.conns, remotes.Llm.OnServerEvent:Connect(function(player, what)
		if what == nil or what == "toggle" then
			setPreset(preset + 1, player.DisplayName)
		elseif what == "off" then
			setPreset(1, player.DisplayName)
		end
	end))
	-- automation (MCP execute_luau on the server): "toggle" | "off" | "1".."3"
	table.insert(self.conns, workspace:GetAttributeChangedSignal(ATTR_PREFIX .. "LlmCmd"):Connect(function()
		local v = workspace:GetAttribute(ATTR_PREFIX .. "LlmCmd")
		if type(v) ~= "string" or v == "" then
			return
		end
		workspace:SetAttribute(ATTR_PREFIX .. "LlmCmd", "")
		if v == "toggle" then
			setPreset(preset + 1)
		elseif v == "off" then
			setPreset(1)
		elseif tonumber(v) then
			setPreset(tonumber(v) :: number)
		end
	end))

	-- The poll loop. It lives in its own coroutine, so the yield inside
	-- RequestAsync (0.5 s to 12 s, depending on the model) never holds up the
	-- round: the town keeps trading on each agent's last stance, and on the
	-- scripted policy once that expires. Harness:due() keeps it to one
	-- request at a time, one per LLM_POLL_SECONDS, under LLM_MAX_PER_MINUTE.
	task.spawn(function()
		while self.running do
			if harness:due() then
				local okBody, body = pcall(function()
					return HttpService:JSONEncode(harness:observation(game_))
				end)
				if okBody and harness:begin() then
					local okReq, res = pcall(function()
						return HttpService:RequestAsync({
							Url = harness.url,
							Method = "POST",
							Headers = llmHeaders(harness.serverId),
							Body = body,
						})
					end)
					if not okReq then
						-- no harness listening, or HTTP requests are off in this place
						harness:fail(tostring(res))
					elseif not res.Success then
						harness:fail(string.format("HTTP %d %s", res.StatusCode, tostring(res.StatusMessage)))
					else
						local okJson, decoded = pcall(function()
							return HttpService:JSONDecode(res.Body)
						end)
						if okJson then
							local n = harness:finish(decoded)
							if n > 0 then
								-- one telemetry line per *new* decision, not per poll
								for _, a in store:report() do
									if a.seq and lastLogged[a.name] ~= a.seq then
										lastLogged[a.name] = a.seq
										game_.telemetry:record(now(), "llm_decision", {
											agent = a.name,
											model = a.model,
											reason = a.reason,
											line = a.line,
											latency = a.latency,
											seq = a.seq,
										})
									end
								end
							end
						else
							harness:fail("the harness did not answer JSON")
						end
					end
					publishLlm()
				end
			end
			task.wait(0.25)
		end
	end)
	publishLlm()

	-- the clock
	local acc = 0
	local llmAcc = 0
	local function publish()
		local s = game_:status()
		workspace:SetAttribute(ATTR_PREFIX .. "Phase", s.phase)
		workspace:SetAttribute(ATTR_PREFIX .. "Round", s.round)
		workspace:SetAttribute(ATTR_PREFIX .. "Ends", workspace:GetServerTimeNow() + s.left)
		workspace:SetAttribute(ATTR_PREFIX .. "Red", s.red)
		workspace:SetAttribute(ATTR_PREFIX .. "Blue", s.blue)
		workspace:SetAttribute(ATTR_PREFIX .. "Deals", s.deals)
		workspace:SetAttribute(ATTR_PREFIX .. "Tokens", s.tokens)
		workspace:SetAttribute(ATTR_PREFIX .. "Auth", s.auth)
		workspace:SetAttribute(ATTR_PREFIX .. "Registry", s.registry)
		workspace:SetAttribute(ATTR_PREFIX .. "VoteAuth", s.voteAuth)
		workspace:SetAttribute(ATTR_PREFIX .. "VoteRegistry", s.voteRegistry)
		workspace:SetAttribute(ATTR_PREFIX .. "Needed", s.needed)
		workspace:SetAttribute(ATTR_PREFIX .. "Present", s.present)
		workspace:SetAttribute(ATTR_PREFIX .. "RedBot", s.redBot)
		workspace:SetAttribute(ATTR_PREFIX .. "BlueBot", s.blueBot)
		workspace:SetAttribute(ATTR_PREFIX .. "WinsRed", s.winsRed)
		workspace:SetAttribute(ATTR_PREFIX .. "WinsBlue", s.winsBlue)
		workspace:SetAttribute(ATTR_PREFIX .. "Escapes", s.escapes)
		workspace:SetAttribute(ATTR_PREFIX .. "Catches", s.catches)
		workspace:SetAttribute(ATTR_PREFIX .. "FalseAlarms", s.falseAlarms)
		laws.Text = string.format("THE TOWN'S LAWS\nauth: %s\nregistry: %s\nround %d · red %d · blue %d", s.auth, s.registry, s.round, s.red, s.blue)
	end
	game_:start(now()) -- its first events go out with the first tick
	table.insert(self.conns, RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < Config.TICK_SECONDS then
			return
		end
		acc = 0
		local evs = game_:tick(now())
		if #evs > 0 then
			local out = table.create(#evs)
			for _, e in evs do
				table.insert(out, Game.public(e))
			end
			remotes.Events:FireAllClients(out)
			if store:any() then
				harness:note(evs) -- the context the model is given, from the town's own events
			end
		end
		publish()
		llmAcc += dt
		if llmAcc >= 1 then
			llmAcc = 0
			publishLlm() -- a stance can expire with nothing else happening
		end
	end))
	publish()

	function self.stop()
		if not self.running then
			return
		end
		self.running = false
		for _, c in self.conns do
			c:Disconnect()
		end
		for _, p in Players:GetPlayers() do
			p.Team = nil
			p.Neutral = true
		end
		red:Destroy()
		blue:Destroy()
		remotes:Destroy()
		folder:Destroy()
		for name in workspace:GetAttributes() do
			if string.sub(name, 1, #ATTR_PREFIX) == ATTR_PREFIX then
				workspace:SetAttribute(name, nil)
			end
		end
	end

	return self
end

return RedBlueServer
