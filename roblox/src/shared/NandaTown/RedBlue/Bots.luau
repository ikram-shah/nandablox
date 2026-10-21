-- Scripted players, so one human can play either side alone.
--
-- RedBot: attacks at intervals while it has tokens. With RED_BOT_SMART it
-- picks an attack the current layers let through (forge under plain.v1, spoof
-- under index.v1), else whatever is left.
-- BlueBot: notices each live threat after a reaction delay with a fixed
-- probability per second, and now and then false-alarms on an honest envelope.
--
-- Both act only through the same Game calls a human's RemoteEvent reaches
-- (game:attack, game:flag), so they are scored the same way. Pure.

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local Rng = sibling("Rng")

local Bots = {}

Bots.RED_ID = "bot:red"
Bots.BLUE_ID = "bot:blue"

------------------------------------------------------------------------ red

local RedBot = {}
RedBot.__index = RedBot
Bots.RedBot = RedBot

function RedBot.new(cfg, seed: number?)
	return setmetatable({ cfg = cfg, rng = Rng.new(seed or 7), nextAt = cfg.RED_BOT_FIRST }, RedBot)
end

function RedBot:reset()
	self.nextAt = self.cfg.RED_BOT_FIRST
end

function RedBot:choose(layers): string
	if self.cfg.RED_BOT_SMART then
		local open = {}
		if layers.auth == "plain.v1" then
			table.insert(open, "forge")
		end
		if layers.registry == "index.v1" then
			table.insert(open, "spoof")
		end
		if #open > 0 then
			return self.rng:pick(open)
		end
	end
	return self.rng:pick({ "forge", "spoof" })
end

-- rt: seconds into the round. Returns the attack it launched, or nil.
function RedBot:tick(game, rt: number): string?
	if rt < self.nextAt or game.tokens <= 0 then
		return nil
	end
	local iv = self.cfg.RED_BOT_INTERVAL
	self.nextAt = rt + self.rng:range(iv[1], iv[2])
	local kind = self:choose(game.layers)
	local claimed = self.rng:pick(self.cfg.SELLERS)
	local ok = game:attack(Bots.RED_ID, kind, claimed)
	return ok and kind or nil
end

------------------------------------------------------------------------ blue

local BlueBot = {}
BlueBot.__index = BlueBot
Bots.BlueBot = BlueBot

function BlueBot.new(cfg, seed: number?)
	return setmetatable({ cfg = cfg, rng = Rng.new(seed or 11) }, BlueBot)
end

function BlueBot:reset() end

-- dt: seconds since the last tick. Returns a list of {target, result}.
function BlueBot:tick(game, rt: number, dt: number): { any }
	local acted = {}
	local sim = game.sim
	if not sim then
		return acted
	end
	local p = 1 - (1 - self.cfg.BLUE_BOT_DETECT_PER_SECOND) ^ dt
	for _, th in sim:liveThreats() do
		if rt - th.createdAt >= self.cfg.BLUE_BOT_REACTION and self.rng:chance(p) then
			local ids = sim:threatTargets(th)
			if #ids > 0 then
				local target = ids[1]
				table.insert(acted, { target = target, result = game:flag(Bots.BLUE_ID, target, { camera = "bot" }) })
			end
		end
	end
	local fa = 1 - (1 - self.cfg.BLUE_BOT_FALSE_ALARM_PER_SECOND) ^ dt
	if self.rng:chance(fa) then
		local ids = sim:honestTargets()
		if #ids > 0 then
			local target = self.rng:pick(ids)
			table.insert(acted, { target = target, result = game:flag(Bots.BLUE_ID, target, { camera = "bot" }) })
		end
	end
	return acted
end

return Bots
