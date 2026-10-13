-- Paste into Studio's command bar (or send through the MCP `execute_luau` tool)
-- while `python3 -m http.server 34901 --bind 127.0.0.1 --directory ~/prg/mit-nanda/roblox`
-- runs. Studio plugins / the command bar may call localhost, so this pulls the
-- current sources into ReplicatedStorage.NandaTown (a poor man's `rojo serve`)
-- and starts the replay in edit mode. Set RUN = false to only load.
local BASE = "http://127.0.0.1:34901/src/shared/NandaTown/"
local MODULES = { "Util", "Town", "Hud", "Replay" }
local TRACES = {
	"marketplace", "auction", "capability_spoofing", "capability_spoofing_weak_auth", "capped_influence",
	"capped_influence_uncapped_control", "consensus", "registry_eviction", "registry_eviction_unowned",
	"supply_chain", "voting",
}
for _, t in TRACES do
	table.insert(MODULES, "Traces/" .. t)
end
local TRACE = "marketplace"
local RUN = true
local SPEED = 1

if _G.NandaTownState then
	_G.NandaTownState.cancelled = true -- stop a replay from a previous load
end
local HttpService = game:GetService("HttpService")
local RS = game:GetService("ReplicatedStorage")
local old = RS:FindFirstChild("NandaTown")
if old then
	old:Destroy()
end
local root = Instance.new("Folder")
root.Name = "NandaTown"
for _, path in MODULES do
	local src = HttpService:GetAsync(BASE .. path .. ".luau", true)
	local parent = root
	local name = path
	local dir, leaf = string.match(path, "^(.*)/([^/]+)$")
	if dir then
		parent = root:FindFirstChild(dir) or Instance.new("Folder")
		parent.Name = dir
		parent.Parent = root
		name = leaf
	end
	local m = Instance.new("ModuleScript")
	m.Name = name
	m.Source = src
	m.Parent = parent
end
root.Parent = RS

if RUN then
	local Replay = require(root.Replay)
	local trace = require(root.Traces[TRACE])
	_G.NandaTownState = Replay.run(trace, {
		parent = workspace,
		-- StarterGui, not CoreGui: edit mode shows StarterGui in the viewport and
		-- Studio's CaptureService (MCP screenshots) only sees StarterGui.
		guiParent = game:GetService("StarterGui"),
		camera = workspace.CurrentCamera,
		speed = SPEED,
	})
end
