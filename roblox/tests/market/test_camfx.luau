-- The client camera and deal popups, headless: Camera.luau and Effects.luau
-- loaded with stand-ins for the Roblox services they touch (the camera is a
-- plain table, input never pressed, rigs not ready). Covers the scale sweep
-- when the market grows, the "auto" camera, and popup focus.

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local lib = require("./lib")

local UI = "src/market/client/MarketUI/"

local function stubs()
	local keys: { [any]: boolean } = {}
	local function signal()
		return { Connect = function() end }
	end
	local uis = {
		IsKeyDown = function(_, k)
			return keys[k] == true
		end,
		GetMouseLocation = function()
			return roblox.Vector2.zero
		end,
		InputBegan = signal(),
		InputEnded = signal(),
		InputChanged = signal(),
	}
	local market = { Layout = "Layout" }
	local game = {
		GetService = function(_, name)
			if name == "UserInputService" then
				return uis
			end
			return {
				WaitForChild = function()
					return market
				end,
			}
		end,
	}
	local camera = {
		CFrame = roblox.CFrame.new(0, 50, 0),
		FieldOfView = 50,
		CameraType = nil,
	}
	local workspace = {
		CurrentCamera = camera,
		FindFirstChild = function()
			return nil
		end,
	}
	local rigs = {
		ready = false,
		take = function() end,
		give = function() end,
		place = function() end,
		label = function() end,
		setShirtColor = function() end,
	}
	local theme = {
		GOLD = roblox.Color3.new(1, 0.8, 0),
		BAD = roblox.Color3.new(1, 0, 0),
		PAPER = roblox.Color3.new(1, 1, 1),
		WHITE = roblox.Color3.new(1, 1, 1),
		HEAVY = roblox.Enum.Font.GothamBlack,
		GOODS = {},
	}
	local delayed = {}
	local mods: { [any]: any } = { Layout = lib.Layout, RigFigures = rigs, Theme = theme }
	local script = { Parent = { RigFigures = "RigFigures", Effects = "Effects", Theme = "Theme" } }
	local base = {
		game = game,
		workspace = workspace,
		script = script,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		UDim = roblox.UDim,
		Enum = roblox.Enum,
		Instance = roblox.Instance,
		task = {
			delay = function(_, fn)
				table.insert(delayed, fn)
			end,
		},
		require = function(m)
			return mods[m]
		end,
	}
	local function load(name: string)
		local env = setmetatable(table.clone(base), { __index = function(_, k)
			return (_G :: any)[k] or (getfenv(0) :: any)[k]
		end })
		local src = fs.readFile(UI .. name .. ".luau")
		return luau.load(src, { debugName = name, environment = env })()
	end
	mods.Effects = load("Effects")
	local folder = roblox.Instance.new("Folder")
	mods.Effects.init(folder)
	local Cam = load("Camera")
	return { Cam = Cam, Effects = mods.Effects, camera = camera, keys = keys, delayed = delayed, folder = folder }
end

-- the stall nearest to stall `a` (a neighbour whose popups could get in the way)
local function neighbour(a: number): number
	local A0 = lib.Layout.SLOTS[a].pos
	local best, bd = nil, math.huge
	for i, S in lib.Layout.SLOTS do
		local d = math.sqrt((S.pos.x - A0.x) ^ 2 + (S.pos.z - A0.z) ^ 2)
		if i ~= a and d < bd then
			best, bd = i, d
		end
	end
	return best :: number
end

-- run the camera for `secs` at size n, 30 fps
local function run(Cam, secs: number, n: number)
	local dt = 1 / 30
	for _ = 1, math.floor(secs / dt + 0.5) do
		Cam.update(dt, n)
	end
end

local function height(env): number
	return env.camera.CFrame.Position.Y
end

return function(T)
	T.case("camera: growing the market sweeps out to the overview, then returns", function(A)
		local env = stubs()
		local Cam = env.Cam
		Cam.init()
		Cam.set("follow")
		Cam.topSlot = 1
		run(Cam, 6, 5) -- settled at stall 1
		A.eq(Cam.sweeping(), 0, "no sweep at start")
		A.eq(env.Effects.focused(), 1, "popups focus the framed stall")
		local low = height(env)
		run(Cam, 0.1, 300) -- the size jumps
		A.ok(Cam.sweeping() > 5, "sweep starts on growth: " .. Cam.sweeping())
		A.eq(env.Effects.focused(), nil, "no popup focus during the sweep")
		run(Cam, 4, 300)
		local high = height(env)
		A.ok(high > low + 30, string.format("camera rose for the overview: %.1f -> %.1f", low, high))
		run(Cam, 2.5, 300)
		A.eq(Cam.sweeping(), 0, "sweep over after ~6 s")
		A.eq(Cam.mode(), "follow", "mode unchanged by the sweep")
		run(Cam, 6, 300)
		A.ok(height(env) < low + 3, string.format("back at the stall: %.1f (was %.1f)", height(env), low))
		A.eq(env.Effects.focused(), 1, "focus back on the stall")
	end)

	T.case("camera: no sweep on shrink, on join, or behind a red counter", function(A)
		local env = stubs()
		local Cam = env.Cam
		Cam.init()
		Cam.set("follow")
		run(Cam, 0.5, 5)
		run(Cam, 0.2, 300) -- the first meter arrives on join
		A.eq(Cam.sweeping(), 0, "not on join")
		run(Cam, 5, 300)
		run(Cam, 0.2, 5)
		A.eq(Cam.sweeping(), 0, "not when the market shrinks")
		Cam.mind(3, "Rex's Spices")
		Cam.set("stall")
		run(Cam, 1, 5)
		run(Cam, 0.2, 300)
		A.eq(Cam.sweeping(), 0, "not for red behind the counter")
		A.eq(env.Effects.focused(), 3, "popups focus the stall red minds")
	end)

	T.case("camera: visiting a stall or walking ends the sweep", function(A)
		local env = stubs()
		local Cam = env.Cam
		Cam.init()
		Cam.set("follow")
		run(Cam, 5, 5)
		run(Cam, 0.2, 300)
		A.ok(Cam.sweeping() > 0, "sweeping")
		Cam.visitStall(7)
		run(Cam, 0.1, 300)
		A.eq(Cam.sweeping(), 0, "a card's visit ends it")
		A.eq(Cam.mode(), "walk")
		A.eq(env.Effects.focused(), 7, "walked-to stall is in focus")
		run(Cam, 5, 300)
		run(Cam, 0.2, 1000)
		A.ok(Cam.sweeping() > 0, "growing again sweeps, even in walk")
		env.keys[roblox.Enum.KeyCode.W] = true
		run(Cam, 0.2, 1000)
		A.eq(Cam.sweeping(), 0, "walking ends it")
	end)

	T.case("camera: auto follows the inbox up to 300, holds the overview above", function(A)
		local env = stubs()
		local Cam = env.Cam
		Cam.init()
		local seen = {}
		Cam.onModeChange = function(m)
			table.insert(seen, m)
		end
		Cam.set("auto")
		A.eq(Cam.modeName(), "auto")
		A.eq(Cam.mode(), "follow", "auto reads as follow to the stall highlight")
		A.eq(seen[#seen], "auto", "the camera row is told auto")
		Cam.topSlot = 2
		run(Cam, 8, 300)
		A.eq(env.Effects.focused(), 2, "at 300 auto frames the top case's stall")
		local atStall = height(env)
		run(Cam, 0.1, 1000)
		run(Cam, 12, 1000) -- (sweep, then auto's own rule)
		A.eq(Cam.sweeping(), 0)
		A.eq(env.Effects.focused(), nil, "above 300 auto ignores the top case")
		A.ok(height(env) > atStall + 30, string.format("overview: %.1f vs stall %.1f", height(env), atStall))
		Cam.inspectSlot = 4
		run(Cam, 6, 1000)
		A.eq(env.Effects.focused(), 4, "a stall you pick still wins")
		Cam.inspectSlot = nil
		-- plain follow keeps chasing the top case in a big market
		Cam.set("follow")
		A.eq(Cam.modeName(), "follow")
		run(Cam, 6, 1000)
		A.eq(env.Effects.focused(), 2, "follow frames the top case at 1000")
	end)

	T.case("camera: V cycles auto -> follow -> walk -> overview -> balcony -> street -> auto", function(A)
		local env = stubs()
		local Cam = env.Cam
		Cam.init()
		Cam.set("auto")
		local got = {}
		for _ = 1, 6 do
			table.insert(got, Cam.toggle())
		end
		A.eq(table.concat(got, ","), "follow,walk,overview,balcony,street,auto")
	end)

	T.case("effects: other stalls' popups dim and shrink while one is in focus", function(A)
		local env = stubs()
		local E = env.Effects
		A.eq(E.alpha(0, 5, nil, 50), 0, "no focus: as drawn")
		A.eq(E.alpha(0, 5, 5, 50), 0, "the focused stall: as drawn")
		A.eq(E.alpha(0, 6, 5, 50), E.DIM_ALPHA, "another stall: dimmed")
		A.eq(E.alpha(0.9, 6, 5, 50), 0.9, "already fading: kept")
		A.eq(E.alpha(0, 5, 5, 1), 1, "in the lens: gone")
		A.near(E.alpha(0, 5, 5, 3), 0.5, 1e-6, "near the lens: half")
		-- spawn deals at a focused and an unfocused stall, camera at the plaza
		local L5 = lib.Layout.SLOTS[5]
		E.update(roblox.Vector3.new(L5.pos.x, 20, L5.pos.z))
		E.focus(5)
		local nb = neighbour(5)
		E.deal(5, nil, "spice", true)
		E.deal(nb, nil, "spice", true)
		local coins = {}
		for _, p in env.folder:GetDescendants() do
			if p:IsA("Part") and p.Shape == roblox.Enum.PartType.Cylinder then
				table.insert(coins, p.Size.Y)
			end
		end
		table.sort(coins)
		A.eq(#coins, 2, "two coins in flight")
		A.near(coins[1], 0.9 * E.DIM_SCALE, 1e-4, "the other stall's coin is small")
		A.near(coins[2], 0.9, 1e-4, "the focused stall's coin is full size")
	end)

	T.case("effects: the focused stall keeps half the flight slots; no on-top label elsewhere", function(A)
		local env = stubs()
		local E = env.Effects
		local L5 = lib.Layout.SLOTS[5]
		E.update(roblox.Vector3.new(L5.pos.x, 20, L5.pos.z))
		E.focus(5)
		local nb = neighbour(5)
		for _ = 1, 40 do
			E.deal(nb, nil, "spice", true) -- 2 flights each
		end
		local function inFlight()
			return #env.folder:GetDescendants() - 1 -- (Effects.init's own folder)
		end
		local before = inFlight()
		A.ok(before >= E.MAX // 2 and before <= E.MAX // 2 + 1, "others capped at half: " .. before)
		E.deal(5, nil, "spice", true)
		A.ok(inFlight() > before, "the focused stall still gets its popup")
		-- the always-on-top "counterfeit" label: only for the stall in focus
		local env2 = stubs()
		local E2 = env2.Effects
		E2.update(roblox.Vector3.new(L5.pos.x, 20, L5.pos.z))
		E2.focus(5)
		E2.deal(nb, nil, "lamp", false, true)
		A.eq(#env2.delayed, 0, "no label for a counterfeit sale at another stall")
		E2.deal(5, nil, "lamp", false, true)
		A.eq(#env2.delayed, 1, "the focused stall's counterfeit gets the label")
		E2.focus(nil)
		E2.deal(nb, nil, "lamp", false, true)
		A.eq(#env2.delayed, 2, "with no focus, every counterfeit gets it")
	end)
end
