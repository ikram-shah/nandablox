-- The camera. Three shots, no character:
--   * "street": eye level (7 studs), standing in the first aisle near where
--     the market starts (Layout.HOME), looking along the aisle at the stalls,
--     so the nearest people are dressed R15 rigs at a counter. It drifts
--     slowly along the aisle.
--   * "overview": above and to one side, looking at the plaza. Low and close
--     for a small market, pulling up as N grows; the wide shot for 300+.
--   * "balcony": from the watchers' balcony over the south gate, looking out
--     over the square (beat 5).
-- "auto" picks street for a small market and overview for a big one.

local Market = game:GetService("ReplicatedStorage"):WaitForChild("Market")
local Layout = require(Market.Layout)

local Cam = {}

local mode = "auto"
local t = 0
local dist = 60
local scripted = true
Cam.balconyCF = nil :: CFrame? -- set from Landmarks

function Cam.init()
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.FieldOfView = 50
end

-- V cycles: auto -> street -> overview -> balcony -> auto
local ORDER = { "auto", "street", "overview", "balcony" }
function Cam.toggle(): string
	local i = table.find(ORDER, mode) or 1
	mode = ORDER[i % #ORDER + 1]
	return mode
end

function Cam.mode(): string
	return mode
end

-- the beat's shot; nil = auto
function Cam.set(m: string?)
	mode = (m == "street" or m == "overview" or m == "balcony") and m or "auto"
end

-- the radius the market fills at size n
local function extent(n: number): number
	local need = math.max(4, math.floor(n * 0.3 + 0.5)) * 1.3 + 6
	for a = 1, Layout.AISLES do
		if Layout.capacity(a) >= need then
			return Layout.aisleRadius(a - 1) + 10
		end
	end
	return Layout.EDGE_R
end

local function street(n: number): (CFrame, number)
	-- stand in the first aisle a little before HOME and look along it; drift
	-- slowly back and forth so the shot breathes. In a crowded market lift a
	-- little, over the shoppers' heads.
	local A = Layout.aisleRadius(0)
	local th = Layout.HOME - 0.42 + math.sin(t * 0.05) * 0.08
	local y = 7 + 5 * math.clamp((n - 5) / 295, 0, 1)
	local eye = Vector3.new(A * math.cos(th), y, A * math.sin(th))
	local ahead = th + 0.38
	local look = Vector3.new((A - 1) * math.cos(ahead), 4.2, (A - 1) * math.sin(ahead))
	return CFrame.lookAt(eye, look), 55
end

local function overview(n: number, dt: number): (CFrame, number)
	dist += (extent(n) - dist) * math.min(1, dt * 0.8)
	-- k: 0 for a small market (low, close), 1 for the full square (high, wide)
	local k = math.clamp((dist - 44) / (Layout.EDGE_R - 44), 0, 1)
	local ang = Layout.HOME + t * 0.02 * k -- a small market holds still on its stalls
	local r = dist * (0.9 + 0.65 * k) + 16
	local h = 14 + dist * (0.3 + 0.9 * k)
	local eye = Vector3.new(r * math.cos(ang), h, r * math.sin(ang))
	-- look at the market's middle: the cluster when small, the plaza when big
	local focus = Layout.aisleRadius(0) * (1 - k)
	local look = Vector3.new(focus * math.cos(Layout.HOME), 0, focus * math.sin(Layout.HOME))
	local cf = CFrame.lookAt(eye, look)
	-- shift left a little, so the inbox on the right doesn't cover the middle
	return cf * CFrame.new(dist * 0.18, 0, 0), 50
end

local function balcony(): (CFrame, number)
	local b = Cam.balconyCF
	if not b then
		return overview(300, 0)
	end
	-- a watcher's eye on the balcony, looking out over the square
	local eye = (b * CFrame.new(0, 5.5, 1)).Position
	local look = Vector3.new(0, 2, 0)
	return CFrame.lookAt(eye, look), 60
end

function Cam.update(dt: number, n: number)
	if not scripted then
		return
	end
	t += dt
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	local m = mode
	if m == "auto" then
		m = n <= 50 and "street" or "overview"
	end
	local cf, fov
	if m == "street" then
		cf, fov = street(n)
		dist = extent(n)
	elseif m == "balcony" then
		cf, fov = balcony()
	else
		cf, fov = overview(n, dt)
	end
	local a = math.min(1, dt * 2.2)
	cam.CFrame = cam.CFrame:Lerp(cf, a)
	cam.FieldOfView += (fov - cam.FieldOfView) * a
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
