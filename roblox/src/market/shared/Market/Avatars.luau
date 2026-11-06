-- Real player avatars in the market square.
--
-- The square's people are pooled, Humanoid-less R15 rigs that the CLIENT
-- poses (RigFigures.luau); a player is drawn the same way, from the pose the
-- server syncs. To make a player look like themselves, the SERVER fetches
-- their HumanoidDescription (cached per user), normalises its proportions,
-- builds one R15 model from it (Players:CreateHumanoidModelFromDescriptionAsync
-- works on the server; applying a description on the client does not), and
-- puts it in ReplicatedStorage.MarketAvatars as "Avatar<userId>". Every client
-- then clones that template for that player instead of a stock outfit.
--
-- Fallback: if the fetch or the build fails or takes longer than TIMEOUT
-- seconds, no template appears and the player keeps today's look: a stock
-- outfit in the team's shirt colour. A template that arrives later replaces
-- the stock rig on the next frame.
--
-- Pure: no Roblox services here. The server passes the calls in (deps), so
-- the timeout and fallback are testable headless (tests/market/test_avatars).

local Avatars = {}

Avatars.FOLDER = "MarketAvatars"
Avatars.TIMEOUT = 5 -- seconds for the description fetch (and, separately, the build)

-- Every avatar is built at Roblox's default R15 proportions, so a very tall,
-- wide or big-headed avatar stands like everyone else in the square.
Avatars.SCALES = {
	HeightScale = 1,
	WidthScale = 1,
	DepthScale = 1,
	HeadScale = 1,
	ProportionScale = 0,
	BodyTypeScale = 0,
}
-- Even at default scales some bundles (Rthro, tall mesh bodies) are taller
-- than a stock R15 (head top ~5.3 studs). Above this the whole model is
-- scaled down so nobody pokes through a stall's awning.
Avatars.MAX_HEIGHT = 5.8

function Avatars.templateName(userId: number): string
	return "Avatar" .. tostring(userId)
end

-- "p12345" (the watcher/player id in state().players) -> 12345
function Avatars.userIdFromPlayerId(id: string?): number?
	if type(id) ~= "string" then
		return nil
	end
	local n = tonumber(string.match(id, "^p(%-?%d+)$"))
	return n
end

-- set the proportion fields on a HumanoidDescription (or any table)
function Avatars.normalise(desc: any): any
	for k, v in Avatars.SCALES do
		desc[k] = v
	end
	return desc
end

-- the factor to scale a built model by so its head top is at most MAX_HEIGHT
-- (1 when it already fits, or when the height is unknown)
function Avatars.fitScale(headTop: number?): number
	if type(headTop) ~= "number" or headTop ~= headTop or headTop <= 0 then
		return 1
	end
	if headTop <= Avatars.MAX_HEIGHT then
		return 1
	end
	return Avatars.MAX_HEIGHT / headTop
end

-- Run fn(...) with a deadline. deps: { spawn(f), wait(dt), now() -> s }.
-- Returns ok, result | reason, where reason is "timeout" or the error. A call
-- that comes back after the deadline counts as a timeout (its result is
-- dropped), so a slow asset server never blocks the round.
function Avatars.withDeadline(deps: any, timeout: number, fn: (...any) -> any, ...: any): (boolean, any)
	local args = table.pack(...)
	local t0 = deps.now()
	local done, ok, res, doneAt = false, false, nil, 0
	deps.spawn(function()
		ok, res = pcall(fn, table.unpack(args, 1, args.n))
		doneAt = deps.now()
		done = true
	end)
	while not done and deps.now() - t0 < timeout do
		deps.wait(0.1)
	end
	if not done or doneAt - t0 > timeout then
		return false, "timeout"
	end
	if not ok then
		return false, tostring(res)
	end
	return true, res
end

-- userId -> HumanoidDescription, successes only (a failure is retried at the
-- player's next join)
local cache: { [number]: any } = {}

-- Fetch (or reuse) a user's normalised description.
-- deps: { get(userId) -> description, spawn, wait, now, timeout? }.
-- Returns desc | nil, reason ("ok" | "cached" | "timeout" | "invalid" | error).
function Avatars.fetch(userId: number, deps: any): (any, string)
	if type(userId) ~= "number" then
		return nil, "invalid"
	end
	if cache[userId] then
		return cache[userId], "cached"
	end
	local ok, res = Avatars.withDeadline(deps, deps.timeout or Avatars.TIMEOUT, deps.get, userId)
	if not ok then
		return nil, res
	end
	if res == nil then
		return nil, "invalid"
	end
	Avatars.normalise(res)
	cache[userId] = res
	return res, "ok"
end

function Avatars.forget(userId: number?)
	if userId then
		cache[userId] = nil
	else
		table.clear(cache)
	end
end

return Avatars
