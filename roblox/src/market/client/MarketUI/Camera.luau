-- The camera. Three shots, no character:
--   * street   — eye level (~7 studs), drifting slowly along the first aisle
--                past the stalls nearest HOME, looking down the aisle: the
--                crowd reads as people, deals as coins and parcels;
--   * overview — high, the whole square, pulling back as the market grows
--                (the overflow beat);
--   * balcony  — the watchers' view from the balcony over the south gate.
-- Each demo beat picks one (the server sends it); V cycles them by hand.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)

local Cam = {}

local MODES = { "street", "overview", "balcony" }
local mode = "street"
local manual: string? = nil -- a mode chosen with V overrides the beat's until the next beat
local t = 0
local dist = 60
local scripted = true
Cam.balconyCFrame = nil :: CFrame? -- set by Landmarks

function Cam.init()
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 50
end

function Cam.toggle()
	local cur = manual or mode
	local i = table.find(MODES, cur) or 1
	manual = MODES[i % #MODES + 1]
end

function Cam.mode(): string
	return manual or mode
end

-- the beat's shot (clears any manual override)
function Cam.set(m: string?)
	if m and table.find(MODES, m) then
		mode = m
	end
	manual = nil
end

-- the radius the market fills at size n
local function extent(n: number): number
	local need = math.max(2, math.floor(n * 0.3 + 0.5)) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return Layout.aisleRadius(a - 1) + 10
		end
	end
	return Layout.EDGE_R
end

local function polar(r: number, th: number, y: number): Vector3
	return Vector3.new(r * math.cos(th), y, r * math.sin(th))
end

function Cam.update(dt: number, n: number)
	if not scripted then
		return
	end
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	t += dt
	local want = extent(n)
	dist += (want - dist) * math.min(1, dt * 0.8)
	local m = manual or mode
	local cf, fov
	if m == "street" then
		-- stand in the first aisle, a little off HOME, looking along the aisle
		-- toward HOME; sway gently back and forth so the shot breathes. In a
		-- big market the camera lifts a little to see over the crowd.
		local A = Layout.aisleRadius(0)
		local lift = math.clamp((n - 5) / 300, 0, 1)
		local th = Layout.HOME - 0.42 + math.sin(t * 0.05) * 0.06
		local eye = polar(A + 1.5, th, 7 + 5 * lift)
		local look = polar(A - 1, Layout.HOME + 0.12, 3.5)
		cf = CFrame.lookAt(eye, look)
		fov = 55
	elseif m == "balcony" and Cam.balconyCFrame then
		-- from the balcony, over the rail, out across the square
		local b = Cam.balconyCFrame
		local eye = b.Position + Vector3.new(0, 5, 0)
		cf = CFrame.lookAt(eye, Vector3.new(0, 0, 0))
		fov = 60
	else
		-- overview: high over the square from HOME's side, pulling back as N grows
		local k = math.clamp((dist - 44) / (Layout.EDGE_R - 44), 0, 1)
		local r = dist * (1.05 + 0.5 * k) + 18
		local h = 16 + dist * (0.25 + 0.95 * k)
		local th = Layout.HOME + math.sin(t * 0.02) * 0.25
		local eye = polar(r, th, h)
		cf = CFrame.lookAt(eye, Vector3.new(0, 0, 0))
		cf = cf * CFrame.new(dist * 0.2, 0, 0)
		fov = 50
	end
	cam.CFrame = cam.CFrame:Lerp(cf, math.min(1, dt * 2.5))
	cam.FieldOfView += (fov - cam.FieldOfView) * math.min(1, dt * 2.5)
end

-- for screenshots and tests
function Cam.snap(cf: CFrame)
	scripted = false
	workspace.CurrentCamera.CFrame = cf
end

function Cam.release()
	scripted = true
end

return Cam
