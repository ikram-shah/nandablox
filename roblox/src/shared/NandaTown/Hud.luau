-- Screen overlay: title, legend, a ticker for the current event, the last few
-- events, and a progress bar.

local Util = require(script.Parent.Util)

local Hud = {}
Hud.__index = Hud

local function panel(parent: Instance, props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
	f.BackgroundTransparency = 0.15
	f.BorderSizePixel = 0
	for k, v in props do
		(f :: any)[k] = v
	end
	f.Parent = parent
	Util.corner(f, 10)
	return f
end

-- opts.rect = {x, y, w, h} (pixels) confines the whole overlay to part of the
-- screen (movie mode: the 16:9 area the recorder crops to; see Hud:setRect);
-- opts.bannerY moves the verdict banner down (under movie mode's chapter caption).
function Hud.new(trace, parent: Instance, opts: { [string]: any }?)
	local bannerY = (opts and opts.bannerY) or 84
	local old = parent:FindFirstChild("NandaTownHud")
	if old then
		old:Destroy()
	end
	local g = Instance.new("ScreenGui")
	g.Name = "NandaTownHud"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.DisplayOrder = 10
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = parent
	local root = Instance.new("Frame")
	root.Name = "Safe"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = g

	-- title, top-left
	local title = panel(root, { Name = "Title", Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(470, 62) })
	Util.label(title, {
		Text = "NANDA Town  ·  replay of one real run",
		Size = UDim2.new(1, -20, 0, 32),
		Position = UDim2.fromOffset(12, 4),
		TextSize = 26,
		Font = Util.FONT_HEAVY,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	Util.label(title, {
		Text = string.format(
			"scenario <b>%s</b> · seed %s · run %s · %d events",
			tostring(trace.scenario),
			tostring(trace.seed),
			tostring(trace.run_id),
			#trace.events
		),
		Size = UDim2.new(1, -20, 0, 20),
		Position = UDim2.fromOffset(12, 36),
		TextSize = 16,
		Font = Util.FONT,
		TextColor3 = Color3.fromRGB(200, 200, 210),
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	-- legend, top-right
	local roles = {}
	for _, p in trace.participants do
		if not table.find(roles, p.role) then
			table.insert(roles, p.role)
		end
	end
	local rows = {}
	for _, r in roles do
		local c = Util.roleColor(r)
		table.insert(rows, string.format('<font color="rgb(%d,%d,%d)">■</font> %s', c.R * 255, c.G * 255, c.B * 255, r))
	end
	local legendText = table.concat(rows, "    ")
		.. "\n✉ envelope = message on the road"
		.. "\n● gold coins = money (escrow → vault → payee)"
		.. "\n★ over a head = reputation score"
	local legend = panel(root, { Name = "Legend", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 12), Size = UDim2.fromOffset(330, 100) })
	Util.label(legend, {
		Text = legendText,
		Size = UDim2.new(1, -20, 1, -12),
		Position = UDim2.fromOffset(12, 6),
		TextSize = 16,
		Font = Util.FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	-- recent events, bottom-left above the ticker
	local recent = panel(root, {
		Name = "Recent",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -96),
		Size = UDim2.fromOffset(560, 118),
		BackgroundTransparency = 0.35,
	})
	local recentLines = {}
	for i = 1, 5 do
		recentLines[i] = Util.label(recent, {
			Text = "",
			Size = UDim2.new(1, -16, 0, 21),
			Position = UDim2.fromOffset(8, 4 + (i - 1) * 22),
			TextSize = 15,
			Font = Util.FONT,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTransparency = (5 - i) * 0.15,
			TextTruncate = Enum.TextTruncate.AtEnd,
		})
	end

	-- ticker, bottom
	local ticker = panel(root, {
		Name = "Ticker",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.new(1, -28, 0, 66),
		BackgroundTransparency = 0.05,
	})
	local clock = Util.label(ticker, {
		Text = "t = 0.00 s",
		Size = UDim2.fromOffset(120, 30),
		Position = UDim2.fromOffset(14, 6),
		TextSize = 22,
		Font = Util.FONT_HEAVY,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local evno = Util.label(ticker, {
		Text = "",
		Size = UDim2.fromOffset(120, 22),
		Position = UDim2.fromOffset(14, 36),
		TextSize = 15,
		Font = Util.FONT,
		TextColor3 = Color3.fromRGB(180, 180, 190),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local chip = Instance.new("Frame")
	chip.Name = "LayerChip"
	chip.Size = UDim2.fromOffset(130, 34)
	chip.Position = UDim2.fromOffset(140, 16)
	chip.BackgroundColor3 = Color3.fromRGB(80, 80, 90)
	chip.Parent = ticker
	Util.corner(chip, 17)
	local chipText = Util.label(chip, { Text = "", TextSize = 16, Font = Util.FONT_HEAVY, TextColor3 = Color3.fromRGB(20, 20, 20) })
	local main = Util.label(ticker, {
		Text = "",
		Size = UDim2.new(1, -300, 1, -8),
		Position = UDim2.fromOffset(286, 4),
		TextSize = 24,
		Font = Util.FONT_BOLD,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
	})
	local bar = Instance.new("Frame")
	bar.Name = "Progress"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 14, 1, -6)
	bar.Size = UDim2.new(0, 0, 0, 6)
	bar.BackgroundColor3 = Color3.fromRGB(250, 190, 60)
	bar.BorderSizePixel = 0
	bar.Parent = root

	local self = setmetatable({
		gui = g,
		root = root,
		clock = clock,
		evno = evno,
		chip = chip,
		chipText = chipText,
		main = main,
		bar = bar,
		recentLines = recentLines,
		bannerY = bannerY,
		history = {},
		total = #trace.events,
	}, Hud)
	if opts and opts.rect then
		self:setRect(opts.rect)
	end
	return self
end

function Hud:setRect(r: { x: number, y: number, w: number, h: number })
	self.root.Position = UDim2.fromOffset(r.x, r.y)
	self.root.Size = UDim2.fromOffset(r.w, r.h)
end

function Hud:show(e, text: string)
	self.clock.Text = string.format("t = %.2f s", e.at)
	self.evno.Text = string.format("%s  (%d/%d)", e.id, e.seq, self.total)
	local c = Util.LAYER_COLORS[e.layer] or Util.LAYER_COLORS.other
	self.chip.BackgroundColor3 = c
	self.chipText.Text = string.upper(string.gsub(e.layer, "_", " "))
	self.main.Text = text
	self.bar.Size = UDim2.new(e.seq / self.total, -28 * e.seq / self.total, 0, 6)
	table.insert(self.history, string.format("<b>%.1fs</b>  %s", e.at, text))
	local n = #self.history
	for i = 1, 5 do
		local h = self.history[n - 5 + i]
		self.recentLines[i].Text = h or ""
	end
end

function Hud:banner(text: string, color: Color3)
	local f = panel(self.root, {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, self.bannerY),
		Size = UDim2.fromOffset(560, 56),
		BackgroundColor3 = color,
		BackgroundTransparency = 0.05,
	})
	Util.label(f, { Text = text, TextSize = 30, Font = Util.FONT_HEAVY, TextColor3 = Color3.fromRGB(15, 15, 15) })
	return f
end

-- The evaluator's stages (result.json), shown when the run finishes.
function Hud:stages(stages)
	local h = 30 + #stages * 22
	local f = panel(self.root, {
		Name = "Stages",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -14, 1, -96),
		Size = UDim2.fromOffset(330, h),
		BackgroundColor3 = Color3.fromRGB(250, 248, 240),
		BackgroundTransparency = 0.03,
	})
	Util.label(f, {
		Text = "COURTHOUSE · evaluator stages",
		Size = UDim2.new(1, -16, 0, 24),
		Position = UDim2.fromOffset(10, 3),
		TextSize = 17,
		Font = Util.FONT_HEAVY,
		TextColor3 = Color3.fromRGB(30, 30, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	for i, s in stages do
		local ok = s.status == "passed"
		Util.label(f, {
			Text = string.format("<font color='%s'>%s</font>  %s", ok and "#1a8a2a" or "#d02020", ok and "✓" or "✗", s.name),
			Size = UDim2.new(1, -16, 0, 22),
			Position = UDim2.fromOffset(12, 26 + (i - 1) * 22),
			TextSize = 16,
			Font = Util.FONT_BOLD,
			TextColor3 = Color3.fromRGB(30, 30, 30),
			TextXAlignment = Enum.TextXAlignment.Left,
		})
	end
	return f
end

return Hud
