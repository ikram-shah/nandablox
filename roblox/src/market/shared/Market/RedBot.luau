-- RedBot: the bot Red, a simple adaptive attacker (docs/market-game.md, "How
-- each side plays").
--
-- It keeps a success rate per attack (an attack = a stall kind plus the
-- modifiers bought for it), tries the best one most of the time and
-- something else sometimes, and so drifts toward the gaps in Blue's loadout.
-- Old evidence decays, so when Blue closes a gap the bot moves on. Pure Luau,
-- seeded; MarketSim drives it.
--
--   local bot = RedBot.new(cfg, rng)
--   local arm = bot:choose(unlocked)    -- unlocked: id -> true (nil = all)
--   bot:record(arm.id, true)            -- paid out: a success
--   bot:rates()                         -- { { id, label, rate, tries } }

local function sibling(name: string): any
	if typeof(script) == "Instance" then
		return require((script :: any).Parent[name])
	end
	return (require :: any)("./" .. name)
end
local DefaultConfig = sibling("Config")

local RedBot = {}
RedBot.__index = RedBot

-- The attacks it can try: each base attack alone, with the modifier that
-- could matter for it (a bought vouch for the unvouched ones, a stolen ID for
-- the impostor), and the impostor with both.
RedBot.ARMS = {
	{ id = "scam", kind = "scam", label = "scam stall" },
	{ id = "scam+vouch", kind = "scam", vouch = true, label = "scam + bought vouch" },
	{ id = "impostor", kind = "impostor", label = "impostor" },
	{ id = "impostor+id", kind = "impostor", stolenId = true, label = "impostor + stolen ID" },
	{ id = "counterfeit", kind = "counterfeit", label = "counterfeit" },
	{ id = "counterfeit+vouch", kind = "counterfeit", vouch = true, label = "counterfeit + bought vouch" },
	{ id = "talker", kind = "talker", label = "smooth talker" },
	{ id = "talker+vouch", kind = "talker", vouch = true, label = "smooth talker + bought vouch" },
}

function RedBot.arm(id: string)
	for _, a in RedBot.ARMS do
		if a.id == id then
			return a
		end
	end
	return nil
end

-- is this attack open to Red? `unlocked` maps attack and modifier ids to true
function RedBot.available(arm, unlocked): boolean
	if not unlocked then
		return true
	end
	if not unlocked[arm.kind] then
		return false
	end
	if arm.vouch and not unlocked.vouch then
		return false
	end
	if arm.stolenId and not unlocked.stolenId then
		return false
	end
	return true
end

function RedBot.new(cfg, rng)
	cfg = cfg or DefaultConfig
	local stats = {}
	for _, a in RedBot.ARMS do
		stats[a.id] = { s = 0, n = 0, tries = 0, wins = 0 }
	end
	return setmetatable({ cfg = cfg, rng = rng, stats = stats, history = {} }, RedBot)
end

function RedBot:rate(id: string): number
	local st = self.stats[id]
	local prior = self.cfg.BOT.prior
	return (st.s + prior[1]) / (st.n + prior[1] + prior[2])
end

-- Pick an attack among the unlocked ones: explore with probability
-- BOT.explore, otherwise the best success rate (ties: the earliest in ARMS,
-- which is also the cheapest).
function RedBot:choose(unlocked)
	local avail = {}
	for _, a in RedBot.ARMS do
		if RedBot.available(a, unlocked) then
			table.insert(avail, a)
		end
	end
	if #avail == 0 then
		return nil
	end
	local pick
	if self.rng:chance(self.cfg.BOT.explore) then
		pick = self.rng:pick(avail)
	else
		local best, bestR = nil, -1
		for _, a in avail do
			local r = self:rate(a.id)
			if r > bestR + 1e-9 then
				best, bestR = a, r
			end
		end
		pick = best
	end
	self.stats[pick.id].tries += 1
	table.insert(self.history, pick.id)
	return pick
end

-- What happened to one of its stalls: success = it was paid out.
function RedBot:record(id: string, success: boolean)
	local st = self.stats[id]
	if not st then
		return
	end
	local d = self.cfg.BOT.decay
	st.s = st.s * d + (success and 1 or 0)
	st.n = st.n * d + 1
	if success then
		st.wins += 1
	end
end

function RedBot:rates()
	local out = {}
	for _, a in RedBot.ARMS do
		local st = self.stats[a.id]
		table.insert(out, { id = a.id, label = a.label, rate = math.floor(self:rate(a.id) * 100 + 0.5) / 100, tries = st.tries, wins = st.wins })
	end
	return out
end

return RedBot
