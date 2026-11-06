-- not a test: Blue strategies over a full round against the bot Red (Ghost), by hand
local lib = require("./lib")
local Ghost = (require :: any)("../../src/market/shared/Market/Ghost")
local process = require("@lune/process")
local strategies = {
	{ "none", Ghost.NONE },
	{ "floor+voucher", { "priceFloor", "voucher" } },
	{ "sensible", Ghost.SENSIBLE },
	{ "sensible+ID", { "priceFloor", "voucher", "idCheck", "inspector" } },
	{ "escrow+ID", { "idCheck", "escrow" } },
	{ "all", Ghost.ALL },
}
local over = {}
for i = 1, #process.args, 2 do over[process.args[i]] = tonumber(process.args[i + 1]) end
local cfg = lib.config(over)
for _, st in strategies do
	local line = string.format("%-14s", st[1])
	for seed = 1, 7 do
		local r = Ghost.play(seed, st[2], cfg)
		line ..= string.format(" | B%6.0f R%6.0f %-6s (fee %5.0f ref %5.0f fine %4.0f cost %5.0f)", r.blue / 100, r.red / 100, (r.winner == "blue" and "B" or "R") .. (r.ended and ("!" .. (r.ended == "bankrupt" and "bk" or "br") .. tostring(r.endedAt)) or ""), r.fees / 100, r.refunds / 100, r.fines / 100, r.costs / 100)
	end
	print(line)
end
