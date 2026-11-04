-- The screen: the inbox (case cards with Allow / Block and a deadline bar),
-- the meter (judgment calls per minute against the budget line), the
-- controls (N, monitor, the lever vote, red's buttons), the caption, and the
-- price strip. Presenter view hides everything but the inbox, the meter and
-- the caption.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local new, label, button = Theme.new, Theme.label, Theme.button

local Hud = {}

local gui: ScreenGui
local send: (any) -> ()
local you = ""
local budget = 12

local cards = {} -- case id -> { frame, bar, c }
local order = {} -- case ids in arrival order
local inboxList: Frame
local inboxTitle: TextLabel
local inboxMore: TextLabel
local MAX_CARDS = 6

local meter: any = {}
local controls: Frame
local caption: TextLabel
local captionBox: Frame
local priceStrip: Frame
local priceLabels = {}
local toast: TextLabel
local status: TextLabel
local presenter = false
local onFocus: ((any) -> ())?

------------------------------------------------------------------ helpers

local function pct(price: number, market: number): string
	if market <= 0 then
		return ""
	end
	local d = (price - market) / market
	local n = math.floor(math.abs(d) * 100 + 0.5)
	if n <= 2 then
		return "at market"
	end
	return string.format("%d%% %s market", n, d < 0 and "below" or "above")
end

local function ageText(s: number): string
	if s < 60 then
		return "new"
	elseif s < 3600 then
		return string.format("%d min", s // 60)
	end
	return string.format("%d h", s // 3600)
end

local function panel(props)
	local f = new("Frame", {
		BackgroundColor3 = Theme.PANEL,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
	})
	for k, v in props do
		(f :: any)[k] = v
	end
	Theme.corner(14).Parent = f
	Theme.stroke(Color3.new(1, 1, 1), 1, 0.9).Parent = f
	return f
end

------------------------------------------------------------------ inbox

local function cardFor(c, now: number)
	local mine = c.watcher == you or c.watcher == nil
	local f = new("Frame", {
		Name = c.id,
		Size = UDim2.new(1, 0, 0, 104),
		BackgroundColor3 = mine and Theme.PAPER or Color3.fromRGB(70, 66, 72),
		BorderSizePixel = 0,
		LayoutOrder = c.created and math.floor(c.created * 10) or 0,
	}, { Theme.corner(10) })
	local ink = mine and Theme.INK or Theme.WHITE
	local muted = mine and Color3.fromRGB(110, 100, 92) or Theme.MUTED
	local below = c.price < c.market * 0.85
	local good = Theme.GOODS[c.good]
	label({
		Text = (good and good.icon or "") .. "  " .. c.stall,
		Font = Theme.HEAVY,
		TextSize = 19,
		TextColor3 = ink,
		Size = UDim2.new(1, -150, 0, 24),
		Position = UDim2.new(0, 12, 0, 8),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = f,
	})
	label({
		Text = string.format("%s %s · <b>%s</b>", Theme.money(c.price), c.good, pct(c.price, c.market)),
		RichText = true,
		TextSize = 16,
		TextColor3 = below and (mine and Color3.fromRGB(190, 60, 40) or Theme.WARN) or ink,
		Size = UDim2.new(1, -150, 0, 20),
		Position = UDim2.new(0, 12, 0, 33),
		Parent = f,
	})
	local facts = {}
	table.insert(facts, ageText(c.age_s or 0))
	table.insert(facts, (c.ratings or 0) == 0 and "no ratings" or string.format("%d ratings ★%.1f", c.ratings, c.rating_avg or 0))
	if c.signature == "unchecked" then
		table.insert(facts, "unsigned")
	end
	label({
		Text = table.concat(facts, " · "),
		TextSize = 15,
		TextColor3 = muted,
		Size = UDim2.new(1, -150, 0, 18),
		Position = UDim2.new(0, 12, 0, 54),
		Parent = f,
	})
	if c.twin then
		label({
			Text = "⚠ TWO STALLS, ONE NAME",
			Font = Theme.HEAVY,
			TextSize = 14,
			TextColor3 = Color3.fromRGB(200, 70, 40),
			Size = UDim2.new(1, -150, 0, 18),
			Position = UDim2.new(0, 12, 0, 72),
			Parent = f,
		})
	elseif c.why then
		label({
			Text = (c.whyBy and c.whyBy ~= "rules" and (c.whyBy .. ": ") or "monitor: ") .. c.why,
			TextSize = 13,
			Font = Theme.FONT,
			TextColor3 = muted,
			Size = UDim2.new(1, -150, 0, 18),
			Position = UDim2.new(0, 12, 0, 72),
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = f,
		})
	end
	if not mine then
		label({
			Text = "another watcher's",
			TextSize = 13,
			TextColor3 = Theme.MUTED,
			Size = UDim2.new(0, 130, 0, 18),
			Position = UDim2.new(1, -140, 0, 8),
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = f,
		})
	end
	local allow = button({
		Text = "Allow",
		BackgroundColor3 = Theme.OK,
		TextColor3 = Theme.INK,
		Size = UDim2.new(0, 64, 0, 40),
		Position = UDim2.new(1, -142, 0, mine and 26 or 32),
		Parent = f,
	}, function()
		send({ op = "verdict", case = c.id, v = "allow" })
		Hud.removeCase(c.id, "allow")
	end)
	local block = button({
		Text = "Block",
		BackgroundColor3 = Theme.BAD,
		Size = UDim2.new(0, 64, 0, 40),
		Position = UDim2.new(1, -72, 0, mine and 26 or 32),
		Parent = f,
	}, function()
		send({ op = "verdict", case = c.id, v = "block" })
		Hud.removeCase(c.id, "block")
	end)
	allow.TextSize = 17
	block.TextSize = 17
	-- the deadline bar
	local track = new("Frame", {
		Size = UDim2.new(1, -24, 0, 6),
		Position = UDim2.new(0, 12, 1, -12),
		BackgroundColor3 = mine and Color3.fromRGB(226, 218, 204) or Color3.fromRGB(50, 48, 54),
		BorderSizePixel = 0,
		Parent = f,
	}, { Theme.corner(3) })
	local bar = new("Frame", {
		Size = UDim2.new(1, 0, 1, 0),
		BackgroundColor3 = Theme.OK,
		BorderSizePixel = 0,
		Parent = track,
	}, { Theme.corner(3) })
	-- hover a card: point at its stall
	f.MouseEnter:Connect(function()
		if onFocus then
			onFocus(c)
		end
	end)
	return { frame = f, bar = bar, c = c, mine = mine }
end

function Hud.addCase(c, now: number)
	if cards[c.id] then
		local old = cards[c.id]
		old.frame:Destroy()
		cards[c.id] = nil
		local i = table.find(order, c.id)
		if i then
			table.remove(order, i)
		end
	end
	local card = cardFor(c, now)
	cards[c.id] = card
	table.insert(order, c.id)
	Hud.layout()
end

function Hud.removeCase(id: string, how: string?)
	local card = cards[id]
	if not card then
		return
	end
	cards[id] = nil
	local i = table.find(order, id)
	if i then
		table.remove(order, i)
	end
	local f = card.frame
	if how == "expired" then
		f.BackgroundColor3 = Color3.fromRGB(120, 60, 56)
	end
	TweenService:Create(f, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	for _, d in f:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			TweenService:Create(d, TweenInfo.new(0.25), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif d:IsA("Frame") then
			TweenService:Create(d, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
		end
	end
	task.delay(0.26, function()
		f:Destroy()
		Hud.layout()
	end)
end

function Hud.clearCases()
	for id, card in cards do
		card.frame:Destroy()
		cards[id] = nil
	end
	table.clear(order)
	Hud.layout()
end

-- mine first (oldest deadline first), then others'
function Hud.layout()
	local mine, theirs = {}, {}
	for _, id in order do
		local card = cards[id]
		if card then
			table.insert(card.mine and mine or theirs, card)
		end
	end
	table.sort(mine, function(a, b)
		return a.c.deadline_at < b.c.deadline_at
	end)
	table.sort(theirs, function(a, b)
		return a.c.deadline_at < b.c.deadline_at
	end)
	local shown = 0
	for _, list in { mine, theirs } do
		for _, card in list do
			shown += 1
			if shown <= MAX_CARDS then
				card.frame.LayoutOrder = shown
				card.frame.Parent = inboxList
			else
				card.frame.Parent = nil
			end
		end
	end
	local total = #mine + #theirs
	inboxTitle.Text = string.format("INBOX  <font color=\"#%s\">%d</font>", total > 6 and "F05A48" or "FFFFFF", #mine)
		.. (#theirs > 0 and string.format("  <font size=\"15\" color=\"#A09A96\">+%d for other watchers</font>", #theirs) or "")
	inboxMore.Text = total > MAX_CARDS and string.format("+ %d more waiting", total - MAX_CARDS) or (total == 0 and "nothing to decide" or "")
	inboxMore.TextColor3 = total > MAX_CARDS and Theme.BAD or Theme.MUTED
end

function Hud.tickCards(now: number)
	for _, card in cards do
		local c = card.c
		local span = math.max(0.1, c.deadline_at - c.created)
		local left = math.clamp((c.deadline_at - now) / span, 0, 1)
		card.bar.Size = UDim2.new(left, 0, 1, 0)
		card.bar.BackgroundColor3 = left > 0.5 and Theme.OK or (left > 0.25 and Theme.WARN or Theme.BAD)
	end
end

function Hud.caseCount(): number
	return #order
end

------------------------------------------------------------------ the meter

local function buildMeter(parent)
	local f = panel({
		Name = "Meter",
		Size = UDim2.new(0, 400, 0, 196),
		Position = UDim2.new(0, 16, 1, -212),
		Parent = parent,
	})
	Theme.pad(14, 16).Parent = f
	label({ Text = "JUDGMENT CALLS PER MINUTE", Font = Theme.HEAVY, TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = f })
	meter.big = label({
		Text = "0",
		Font = Theme.HEAVY,
		TextSize = 54,
		Size = UDim2.new(0, 140, 0, 56),
		Position = UDim2.new(0, 0, 0, 18),
		Parent = f,
	})
	meter.sub = label({
		Text = "budget 12 per watcher",
		TextSize = 15,
		TextColor3 = Theme.MUTED,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.new(0, 140, 0, 30),
		Parent = f,
	})
	meter.sub2 = label({
		Text = "",
		TextSize = 15,
		TextColor3 = Theme.MUTED,
		Size = UDim2.new(1, -140, 0, 20),
		Position = UDim2.new(0, 140, 0, 50),
		Parent = f,
	})
	-- the bar, with the budget line at 12 (the bar's scale is 0..48)
	local track = new("Frame", {
		Size = UDim2.new(1, 0, 0, 16),
		Position = UDim2.new(0, 0, 0, 82),
		BackgroundColor3 = Theme.PANEL2,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = f,
	}, { Theme.corner(8) })
	meter.fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.OK, BorderSizePixel = 0, Parent = track }, { Theme.corner(8) })
	meter.line = new("Frame", { Size = UDim2.new(0, 3, 0, 24), Position = UDim2.new(0.25, -1, 0, -4), BackgroundColor3 = Theme.WHITE, BorderSizePixel = 0, Parent = f })
	meter.line.Position = UDim2.new(0.25, -1, 0, 78)
	label({ Text = "12", Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.WHITE, Size = UDim2.new(0, 30, 0, 14), Position = UDim2.new(0.25, -15, 0, 100), TextXAlignment = Enum.TextXAlignment.Center, Parent = f })
	meter.scale = label({ Text = "48", TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 40, 0, 14), Position = UDim2.new(1, -40, 0, 100), TextXAlignment = Enum.TextXAlignment.Right, Parent = f })
	-- the four numbers
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 52), Position = UDim2.new(0, 0, 0, 118), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 0), Parent = row })
	local function stat(name: string, color: Color3)
		local s = new("Frame", { Size = UDim2.new(0.25, 0, 1, 0), BackgroundTransparency = 1, Parent = row })
		local v = label({ Text = "0", Font = Theme.HEAVY, TextSize = 26, TextColor3 = color, Size = UDim2.new(1, 0, 0, 28), Parent = s })
		label({ Text = name, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 0, 30), Parent = s })
		return v
	end
	meter.caught = stat("caught", Theme.OK)
	meter.escaped = stat("escaped", Theme.BAD)
	meter.falseAlarms = stat("false alarms", Theme.WARN)
	meter.deals = stat("deals / min", Theme.WHITE)
	meter.frame = f
end

function Hud.meter(m)
	local calls = m.perWatcher or 0
	budget = m.budget or 12
	local top = math.max(48, math.ceil(calls / 12) * 12)
	meter.big.Text = string.format("%d", math.floor(calls + 0.5))
	local over = calls > budget * 1.05
	meter.big.TextColor3 = over and Theme.BAD or (calls > budget * 0.8 and Theme.WARN or Theme.OK)
	meter.fill.BackgroundColor3 = meter.big.TextColor3
	TweenService:Create(meter.fill, TweenInfo.new(0.4), { Size = UDim2.new(math.clamp(calls / top, 0, 1), 0, 1, 0) }):Play()
	meter.line.Position = UDim2.new(budget / top, -1, 0, 78)
	meter.scale.Text = tostring(top)
	if m.watchers and m.watchers > 1 then
		meter.sub.Text = string.format("each, %d watchers · budget %d", m.watchers, budget)
	else
		meter.sub.Text = string.format("budget %d per watcher", budget)
	end
	local mon = m.monitor == "off" and "monitor off" or (m.monitor == "rules" and "rule monitor" or ("monitor: " .. tostring(m.monitorName)))
	meter.sub2.Text = string.format("%d traders · %s · signatures %s", m.n, mon, m.signatures and "on" or "off")
	local mins = math.max(m.elapsed or 0, 1) / 60
	meter.caught.Text = tostring(m.caught)
	meter.escaped.Text = tostring(m.escaped)
	meter.falseAlarms.Text = tostring(m.falseAlarms)
	meter.deals.Text = string.format("%d", math.floor((m.dealsPerMin or 0) + 0.5))
	_ = mins
	Hud.settings(m)
end

------------------------------------------------------------------ controls

local seg = {} -- group -> { value -> button }

local function segmented(parent, title: string, group: string, options, onPick)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = parent })
	label({ Text = title, Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = f })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 20), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	seg[group] = {}
	for _, o in options do
		local b = button({
			Text = o.text,
			Size = UDim2.new(1 / #options, -6 + 6 / #options, 1, 0),
			TextSize = 15,
			Parent = row,
		}, function()
			onPick(o.value)
		end)
		seg[group][o.value] = b
	end
	return f
end

local function pick(group: string, value: any)
	for v, b in seg[group] or {} do
		local on = v == value
		b.BackgroundColor3 = on and Theme.WHITE or Theme.PANEL2
		b.TextColor3 = on and Theme.INK or Theme.WHITE
	end
end

function Hud.settings(m)
	pick("n", m.n)
	pick("monitor", m.monitor)
	pick("sig", m.signatures)
end

local function buildControls(parent, sizes)
	controls = panel({
		Name = "Controls",
		Size = UDim2.new(0, 300, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Position = UDim2.new(0, 16, 0, 16),
		Parent = parent,
	})
	Theme.pad(12, 14).Parent = controls
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = controls })
	label({ Text = "NANDA MARKET", Font = Theme.HEAVY, TextSize = 20, Size = UDim2.new(1, 0, 0, 22), Parent = controls })
	local opts = {}
	for _, n in sizes do
		table.insert(opts, { text = tostring(n), value = n })
	end
	segmented(controls, "TRADERS", "n", opts, function(v)
		send({ op = "size", n = v })
	end)
	segmented(controls, "MONITOR", "monitor", {
		{ text = "off", value = "off" },
		{ text = "rules", value = "rules" },
		{ text = "yours", value = "external" },
	}, function(v)
		send({ op = "monitor", mode = v })
	end)
	segmented(controls, "SIGNATURE CHECKS (your vote)", "sig", {
		{ text = "on", value = true },
		{ text = "off", value = false },
	}, function(v)
		send({ op = "vote", on = v })
	end)
	-- red
	local red = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundTransparency = 1, Parent = controls })
	label({ Text = "FRAUD (red)", Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Parent = red })
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 20), BackgroundTransparency = 1, Parent = red })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	button({ Text = "Scam stall", Size = UDim2.new(0.5, -3, 1, 0), BackgroundColor3 = Color3.fromRGB(110, 40, 40), TextSize = 15, Parent = row }, function()
		send({ op = "fraud", kind = "scam", price = 0.6 })
	end)
	button({ Text = "Impersonate", Size = UDim2.new(0.5, -3, 1, 0), BackgroundColor3 = Color3.fromRGB(110, 40, 40), TextSize = 15, Parent = row }, function()
		send({ op = "fraud", kind = "impostor" })
	end)
	status = label({ Text = "", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, TextWrapped = true, Parent = controls })
	label({
		Text = "V camera · N / P demo beats · H presenter view",
		TextSize = 12,
		TextColor3 = Theme.MUTED,
		Size = UDim2.new(1, 0, 0, 16),
		Parent = controls,
	})
end

function Hud.status(s)
	if not status then
		return
	end
	local bits = {}
	if s.gateway and s.gateway.enabled then
		table.insert(bits, string.format("gateway: %s (%d ok, %d errors)", s.gateway.health, s.gateway.ok, s.gateway.errors))
	end
	if s.watchers then
		local names = {}
		for _, w in s.watchers do
			table.insert(names, w.label .. (w.auto and " (auto)" or ""))
		end
		table.insert(bits, "watchers: " .. table.concat(names, ", "))
	end
	status.Text = table.concat(bits, "\n")
end

------------------------------------------------------------------ caption, prices, toast

function Hud.caption(text: string?, beat: number?, beats: number?)
	if text and text ~= "" then
		caption.Text = (beat and beat > 0 and string.format("<font color=\"#A09A96\">%d/%d</font>   ", beat, beats or 0) or "") .. text
		captionBox.Visible = true
	else
		captionBox.Visible = false
	end
end

function Hud.prices(p)
	for good, l in priceLabels do
		if p[good] then
			l.Text = Theme.GOODS[good].icon .. " " .. good .. "  " .. Theme.money(p[good])
		end
	end
end

function Hud.toast(text: string, color: Color3?)
	toast.Text = text
	toast.TextColor3 = color or Theme.WHITE
	toast.TextTransparency = 0
	toast.BackgroundTransparency = 0.15
	local mine = {}
	Hud._toast = mine
	task.delay(2.5, function()
		if Hud._toast == mine then
			TweenService:Create(toast, TweenInfo.new(0.5), { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		end
	end)
end

function Hud.presenter(on: boolean)
	presenter = on
	controls.Visible = not on
	priceStrip.Visible = not on
end

function Hud.isPresenter(): boolean
	return presenter
end

------------------------------------------------------------------ build

function Hud.build(opts)
	send = opts.send
	you = opts.you
	onFocus = opts.onFocus
	gui = new("ScreenGui", {
		Name = "MarketHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	-- the inbox, right
	local inbox = panel({
		Name = "Inbox",
		Size = UDim2.new(0, 420, 1, -32),
		Position = UDim2.new(1, -436, 0, 16),
		BackgroundTransparency = 0.18,
		Parent = gui,
	})
	Theme.pad(14, 14).Parent = inbox
	inboxTitle = label({ Text = "INBOX", RichText = true, Font = Theme.HEAVY, TextSize = 22, Size = UDim2.new(1, 0, 0, 26), Parent = inbox })
	label({ Text = "Allow or Block before the first buyer arrives", TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 18), Position = UDim2.new(0, 0, 0, 28), Parent = inbox })
	inboxList = new("Frame", { Size = UDim2.new(1, 0, 1, -90), Position = UDim2.new(0, 0, 0, 56), BackgroundTransparency = 1, Parent = inbox })
	new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder, Parent = inboxList })
	inboxMore = label({ Text = "", Font = Theme.HEAVY, TextSize = 18, TextColor3 = Theme.BAD, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.new(0, 0, 1, -26), TextXAlignment = Enum.TextXAlignment.Center, Parent = inbox })
	buildMeter(gui)
	buildControls(gui, opts.sizes or { 5, 50, 300, 1000 })
	-- caption, bottom centre
	captionBox = panel({
		Name = "Caption",
		Size = UDim2.new(0, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, -210, 1, -18),
		Visible = false,
		Parent = gui,
	})
	Theme.pad(12, 20).Parent = captionBox
	caption = label({
		Text = "",
		RichText = true,
		Font = Theme.BOLD,
		TextSize = 24,
		Size = UDim2.new(0, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = captionBox,
	})
	new("UISizeConstraint", { MaxSize = Vector2.new(820, 200), Parent = caption })
	caption.TextWrapped = true
	-- prices, top centre
	priceStrip = panel({
		Name = "Prices",
		Size = UDim2.new(0, 0, 0, 40),
		AutomaticSize = Enum.AutomaticSize.X,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -110, 0, 16),
		Parent = gui,
	})
	Theme.pad(8, 16).Parent = priceStrip
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 20), VerticalAlignment = Enum.VerticalAlignment.Center, Parent = priceStrip })
	label({ Text = "MARKET PRICE", Font = Theme.HEAVY, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = priceStrip })
	for _, g in { "bread", "cloth", "lamp", "spice" } do
		priceLabels[g] = label({ Text = g, Font = Theme.BOLD, TextSize = 17, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X, Parent = priceStrip })
	end
	toast = label({
		Text = "",
		Font = Theme.BOLD,
		TextSize = 18,
		BackgroundColor3 = Theme.PANEL,
		BackgroundTransparency = 1,
		TextTransparency = 1,
		Size = UDim2.new(0, 0, 0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, -210, 0, 66),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = gui,
	})
	Theme.corner(10).Parent = toast
	Theme.pad(6, 14).Parent = toast
	return gui
end

return Hud
