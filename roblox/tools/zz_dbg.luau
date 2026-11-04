local base = "../src/shared/NandaTown/RedBlue/"
local Config = (require :: any)(base .. "Config")
local Game = (require :: any)(base .. "Game")
local g = Game.new({ config = Config, seed = 1 })
g:start(0)
local t = 0
local function run(s) local stop = t + s while t < stop - 1e-9 do t = math.min(stop, t + 0.1) g:tick(t) end end
run(5)
g:setBeat(1) run(60) g:setBeat(2) run(60) g:setBeat(3) run(60)
local ov0 = g.oversight
g:setBeat(4)
local ov = g.oversight
local orig = ov.resolved
local sw = g:rt()
ov.resolved = function(self, th, now)
	local t2 = self.threats[th.id] or {}
	if th.state == "escaped" then
		print(string.format("ESC %s %s +%.1fs born %.1f %s%s%s cases=%s", th.id, th.kind, now - sw, th.createdAt - sw, t2.cleared and "cleared " or "", t2.escalated and "escalated " or "", t2.wrong and "wrong" or "", tostring(t2.cases)))
	end
	return orig(self, th, now)
end
run(60)
