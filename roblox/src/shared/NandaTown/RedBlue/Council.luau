-- The council: players vote on layer swaps. A proposal carries when a strict
-- majority of the players present vote yes (1 of 1, 2 of 3, 3 of 4). Votes
-- are per player and per proposal, and are cleared when the proposal carries
-- or the player leaves. Pure: player ids are any keys; no Roblox services.

local Council = {}
Council.__index = Council

-- proposals: { [id] = true }, e.g. { auth = true, registry = true }
function Council.new(proposals: { [string]: boolean })
	local votes = {}
	for id in proposals do
		votes[id] = {}
	end
	return setmetatable({ votes = votes }, Council)
end

-- Set one player's vote on a proposal (yes = true, withdrawn = false).
function Council:vote(player: any, proposal: string, yes: boolean): boolean
	local v = self.votes[proposal]
	if not v then
		return false
	end
	v[player] = yes or nil
	return true
end

function Council:toggle(player: any, proposal: string): boolean?
	local v = self.votes[proposal]
	if not v then
		return nil
	end
	local now = not v[player]
	v[player] = now or nil
	return now
end

function Council:has(player: any, proposal: string): boolean
	local v = self.votes[proposal]
	return v ~= nil and v[player] == true
end

function Council:count(proposal: string): number
	local n = 0
	for _ in self.votes[proposal] or {} do
		n += 1
	end
	return n
end

-- yes votes a proposal needs with `present` players
function Council.needed(present: number): number
	return math.floor(present / 2) + 1
end

function Council:passes(proposal: string, present: number): boolean
	return present > 0 and self:count(proposal) >= Council.needed(present)
end

function Council:clear(proposal: string)
	if self.votes[proposal] then
		self.votes[proposal] = {}
	end
end

function Council:remove(player: any)
	for _, v in self.votes do
		v[player] = nil
	end
end

return Council
