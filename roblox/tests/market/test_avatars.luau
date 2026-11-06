-- Real player avatars (Avatars.luau, RigFigures.takePlayer): the description
-- fetch with its deadline and cache, the proportion fitting, and the fallback
-- (no avatar template: a stock outfit in the team shirt; a template that
-- arrives later replaces it, outlined in the team colour, clothes untouched).

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local lib = require("./lib")
local Avatars = lib.Avatars
-- (Outfits uses Color3: load it with Lune's)
local Outfits = luau.load(fs.readFile("src/market/shared/Market/Outfits.luau"), {
	debugName = "Outfits",
	environment = { Color3 = roblox.Color3 },
})()

-- a fake clock: wait() advances it; spawn runs the function at once unless
-- `hang` (a call that never returns)
local function clockDeps(get, hang: boolean?)
	local d = { t = 0, calls = 0 }
	d.now = function()
		return d.t
	end
	d.wait = function(dt)
		d.t += dt
	end
	d.spawn = function(f)
		if not hang then
			f()
		end
	end
	d.get = function(userId)
		d.calls += 1
		return get(d, userId)
	end
	return d
end

-- the RigFigures module, loaded with stand-ins: real Lune instances for the
-- templates, stubs for the services and for the folder's ChildAdded signal
local function rigEnv()
	local function part(name: string, y: number, parent: Instance)
		local p = roblox.Instance.new("Part")
		p.Name = name
		p.Size = roblox.Vector3.new(2, 1, 1)
		p.CFrame = roblox.CFrame.new(0, y, 0)
		p.Color = roblox.Color3.fromRGB(200, 200, 200)
		p.Parent = parent
		return p
	end
	local function rig(name: string, controller: string)
		local m = roblox.Instance.new("Model")
		m.Name = name
		local root = part("HumanoidRootPart", 3, m)
		part("Head", 5, m)
		part("UpperTorso", 3.5, m)
		part("RightHand", 2, m)
		m.PrimaryPart = root
		local c = roblox.Instance.new(controller)
		roblox.Instance.new("Animator").Parent = c
		c.Parent = m
		return m
	end
	local stockFolder = roblox.Instance.new("Folder")
	for i = 1, #Outfits.LIST do
		rig("Outfit" .. i, "AnimationController").Parent = stockFolder
	end
	local added, removed = {}, {}
	local avatarList: { Instance } = {}
	local avatarFolder = {
		GetChildren = function()
			return avatarList
		end,
		ChildAdded = { Connect = function(_, f)
			table.insert(added, f)
		end },
		ChildRemoved = { Connect = function(_, f)
			table.insert(removed, f)
		end },
	}
	local market = { Outfits = "Outfits", Avatars = "Avatars" }
	local rs = {
		WaitForChild = function(_, name)
			if name == "Market" then
				return market
			elseif name == "MarketRigs" then
				return stockFolder
			elseif name == Avatars.FOLDER then
				return avatarFolder
			end
			return nil
		end,
	}
	local moved = {}
	local env = {
		game = { GetService = function()
			return rs
		end },
		workspace = { BulkMoveTo = function(_, parts, cfs)
			for i, p in parts do
				moved[p] = cfs[i]
			end
		end },
		Instance = roblox.Instance,
		Enum = roblox.Enum,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim2 = roblox.UDim2,
		UDim = roblox.UDim,
		task = { spawn = function(f, ...)
			f(...)
		end },
		require = function(m)
			return ({ Outfits = Outfits, Avatars = Avatars })[m]
		end,
		warn = function() end,
	}
	setmetatable(env, { __index = function(_, k)
		return (getfenv(0) :: any)[k]
	end })
	local src = fs.readFile("src/market/client/MarketUI/RigFigures.luau")
	local Rigs = luau.load(src, { debugName = "RigFigures", environment = env })()
	Rigs.init(roblox.Instance.new("Folder"))
	return {
		Rigs = Rigs,
		moved = moved,
		-- the server finishing a player's avatar: a template with a Humanoid
		arrive = function(userId: number, hip: number)
			local m = rig(Avatars.templateName(userId), "Humanoid")
			m:SetAttribute("UserId", userId)
			m:SetAttribute("Hip", hip)
			table.insert(avatarList, m)
			for _, f in added do
				f(m)
			end
			return m
		end,
		leave = function(m)
			for _, f in removed do
				f(m)
			end
		end,
	}
end

local RED = roblox.Color3.fromRGB(214, 56, 52)

local function same(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) < 0.01
end

return function(T)
	T.case("avatars: a fetched description is normalised to default proportions and cached", function(A)
		Avatars.forget()
		local deps = clockDeps(function()
			return { HeightScale = 1.3, WidthScale = 0.7, HeadScale = 1.5, DepthScale = 0.8, ProportionScale = 1, BodyTypeScale = 1, Shirt = 99 }
		end)
		local d, why = Avatars.fetch(7, deps)
		A.eq(why, "ok")
		A.ok(d ~= nil, "a description")
		for k, v in Avatars.SCALES do
			A.eq(d[k], v, k)
		end
		A.eq(d.Shirt, 99, "clothes untouched")
		local d2, why2 = Avatars.fetch(7, deps)
		A.eq(why2, "cached")
		A.ok(d2 == d, "the same description")
		A.eq(deps.calls, 1, "fetched once per user")
	end)

	T.case("avatars: fallback when the fetch errors, hangs or comes back late", function(A)
		Avatars.forget()
		-- an error: no description, nothing cached, the next join retries
		local bad = clockDeps(function()
			error("HTTP 500")
		end)
		local d, why = Avatars.fetch(8, bad)
		A.ok(d == nil, "no description on error")
		A.ok(string.find(why, "HTTP 500", 1, true) ~= nil, "the reason: " .. why)
		Avatars.fetch(8, bad)
		A.eq(bad.calls, 2, "a failure is not cached")
		-- a call that never returns: gives up at the deadline
		local hung = clockDeps(function()
			return {}
		end, true)
		local d2, why2 = Avatars.fetch(9, hung)
		A.ok(d2 == nil, "no description when it hangs")
		A.eq(why2, "timeout")
		A.ok(hung.t >= Avatars.TIMEOUT and hung.t < Avatars.TIMEOUT + 0.5, "gave up at ~5 s: " .. hung.t)
		-- a call that returns after the deadline: dropped
		local slow = clockDeps(function(dd)
			dd.t += Avatars.TIMEOUT + 2
			return {}
		end)
		local d3, why3 = Avatars.fetch(10, slow)
		A.ok(d3 == nil, "a late description is dropped")
		A.eq(why3, "timeout")
		-- nil from the service, or no user id
		local empty = clockDeps(function()
			return nil
		end)
		A.eq(select(2, Avatars.fetch(11, empty)), "invalid")
		A.eq(select(2, Avatars.fetch(nil :: any, empty)), "invalid")
	end)

	T.case("avatars: tall bodies are scaled down to fit under the awnings", function(A)
		A.eq(Avatars.fitScale(5.2), 1, "a stock height fits")
		A.eq(Avatars.fitScale(nil), 1, "unknown: leave it")
		A.eq(Avatars.fitScale(0 / 0), 1, "NaN: leave it")
		local k = Avatars.fitScale(7.25)
		A.ok(math.abs(7.25 * k - Avatars.MAX_HEIGHT) < 1e-9, "scaled to the cap")
		A.eq(Avatars.userIdFromPlayerId("p12345"), 12345)
		A.eq(Avatars.userIdFromPlayerId("p-1"), -1, "Studio's test players")
		A.ok(Avatars.userIdFromPlayerId("w1") == nil, "a bot watcher has no avatar")
	end)

	T.case("avatars: no template means a stock outfit in the team shirt; a late one replaces it", function(A)
		local env = rigEnv()
		local Rigs = env.Rigs
		A.ok(Rigs.ready, "stock templates loaded")
		A.ok(not Rigs.hasAvatar(42), "no avatar yet")
		-- the fallback: a stock rig, painted in the team colour
		local r = Rigs.takePlayer(42, "red")
		A.ok(r ~= nil, "a rig")
		A.ok(r.userId == nil, "a stock outfit, not an avatar")
		A.eq(r.outfit, Outfits.pick(10, "buyer"), "Red's stock outfit")
		Rigs.setTeam(r, RED)
		A.ok(same(r.model.UpperTorso.Color, RED), "team shirt on the stock rig")
		A.ok(r.glow == nil, "no outline on a stock rig")
		Rigs.give(r)
		-- the server finishes the avatar
		local m = env.arrive(42, 3.4)
		A.ok(Rigs.hasAvatar(42), "the avatar arrived")
		local a = Rigs.takePlayer(42, "red")
		A.eq(a.userId, 42, "the player's own avatar")
		A.ok(a.model ~= m, "a clone, not the template")
		local before = a.model.UpperTorso.Color
		Rigs.setTeam(a, RED)
		A.ok(same(a.model.UpperTorso.Color, before), "their clothes keep their colour")
		Rigs.setShirtColor(a, RED)
		A.ok(same(a.model.UpperTorso.Color, before), "setShirtColor never repaints an avatar")
		A.ok(a.glow ~= nil and a.glow.Enabled, "team outline on")
		A.ok(same(a.glow.OutlineColor, RED), "outlined in red")
		-- placed at its own hip height
		Rigs.place(a, roblox.CFrame.new(10, 0, 20), false)
		Rigs.flush()
		local cf = env.moved[a.root]
		A.ok(cf ~= nil and math.abs(cf.Position.Y - 3.4) < 1e-6, "root at the avatar's hip")
		-- pooled and reused, outline off while parked
		Rigs.give(a)
		A.ok(not a.glow.Enabled, "outline off in the pool")
		A.ok(Rigs.takePlayer(42, "red") == a, "reused from the pool")
		-- another player with no avatar still gets a stock rig (Blue's outfit)
		local b = Rigs.takePlayer(43, "blue")
		A.ok(b.userId == nil, "stock for a player without one")
		A.eq(b.outfit, Outfits.pick(1, "buyer"), "Blue's stock outfit")
		-- the player leaves: the template goes
		env.leave(m)
		A.ok(not Rigs.hasAvatar(42), "template gone after leaving")
	end)
end
