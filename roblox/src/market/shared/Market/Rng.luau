-- Copied from src/shared/NandaTown/RedBlue/Rng.luau (the market is a separate Rojo project).
-- A tiny seeded RNG (Park–Miller minimal standard), so the town, the bots and
-- the tests are deterministic and need no Roblox `Random`. All arithmetic stays
-- below 2^53, so it is exact in Luau's doubles.

local Rng = {}
Rng.__index = Rng

local M = 2147483647
local A = 16807

function Rng.new(seed: number?)
	local s = math.floor(math.abs(seed or 1)) % M
	if s == 0 then
		s = 1
	end
	return setmetatable({ s = s }, Rng)
end

-- [0, 1)
function Rng:next(): number
	self.s = (self.s * A) % M
	return (self.s - 1) / (M - 1)
end

-- uniform in [lo, hi)
function Rng:range(lo: number, hi: number): number
	return lo + (hi - lo) * self:next()
end

-- integer in [lo, hi]
function Rng:int(lo: number, hi: number): number
	return lo + math.floor(self:next() * (hi - lo + 1))
end

function Rng:chance(p: number): boolean
	return self:next() < p
end

function Rng:pick<T>(list: { T }): T
	return list[self:int(1, #list)]
end

return Rng
