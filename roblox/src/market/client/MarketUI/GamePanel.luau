-- The game's panels (docs/market-game.md): Blue's loadout strip and its
-- escapes list, Red's attack shop and outcome log, and the scoreboard's
-- game chart. Fed by the server's per-team view (`g`, on state ticks) and
-- the static menus in hello.config.game.
--
-- Placement (nothing over the inbox, right, or the meter, bottom left): the
-- loadout strip and the attack shop sit bottom centre between them; the
-- escapes list sits in the left column under the controls.
--
-- Blue's crew roles (L3): lookout (inbox, escapes), trim (loadout), skipper
-- (council votes). A solo Blue holds all three; GamePanel.setRoles narrows
-- what this player can press (the others' panels stay readable).

local Players = game:GetService("Players")

local Theme = require(script.Parent.Theme)
local new, label, button = Theme.new, Theme.label, Theme.button

local GamePanel = {}

local send: (any) -> () = function() end
local gui: ScreenGui
local cfg: any = nil -- hello.config.game
local roles = { lookout = true, trim = true, skipper = true }
local last: any = nil -- the last `g`
local team = "blue"
local inRound = false

local blue: any = {}
local red: any = {}

local BAND_COLOR = { healthy = Theme.OK, slow = Theme.WARN, seized = Theme.BAD }
local ACT_TEXT = { escalate = "→ inbox", reject = "rejects", shut = "shuts", refund = "refunds" }
local OUTCOME_COLOR = {
	rejected = Theme.BAD,
	blocked = Theme.BAD,
	inspected = Theme.BAD,
	refunded = Theme.BAD,
	paid = Theme.GOLD,
}
local KIND_TEXT = { scam = "scam", impostor = "impostor", counterfeit = "counterfeit", talker = "talker" }
-- when each attack unlocks in the round (shown on a locked button)
local UNLOCK_AT = { scam = "0:00", impostor = "1:00", counterfeit = "2:00", vouch = "2:00", talker = "3:00", stolenId = "3:00" }

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

-- Nandabux (internally cents: 1 NB = 100)
local function money(c: number?): string
	local nb = (c or 0) / 100
	local neg = nb < 0
	nb = math.abs(nb)
	local s = nb < 10 and string.format("%.1f", nb) or string.format("%d", math.floor(nb + 0.5))
	return (neg and "−" or "") .. s .. " NB"
end
GamePanel.nb = money

local function checkInfo(id: string)
	for _, c in cfg and cfg.checks or {} do
		if c.id == id then
			return c
		end
	end
	return nil
end

local function has(list, id: string): boolean
	for _, v in list or {} do
		if v == id then
			return true
		end
	end
	return false
end

------------------------------------------------------------------ Blue: the loadout strip

local function buildLoadout()
	local f = panel({
		Name = "Loadout",
		Size = UDim2.new(0, 660, 0, 196),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, -10, 1, -16),
		Visible = false,
		Parent = gui,
	})
	Theme.stroke(Theme.BLUE, 2, 0.45).Parent = f
	Theme.pad(10, 14).Parent = f
	-- header: title, friction gauge, trade health, compute
	local head = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Parent = f })
	label({ Text = "LOADOUT", Font = Theme.HEAVY, TextSize = 18, TextColor3 = Theme.BLUE, Size = UDim2.new(0, 88, 1, 0), Parent = head })
	blue.roleChip = label({ Text = "", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 150, 1, 0), Position = UDim2.new(0, 88, 0, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
	label({ Text = "FRICTION", Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 60, 1, 0), Position = UDim2.new(0, 240, 0, 0), Parent = head })
	local track = new("Frame", { Size = UDim2.new(0, 132, 0, 12), Position = UDim2.new(0, 300, 0.5, -6), BackgroundColor3 = Theme.PANEL2, BorderSizePixel = 0, ClipsDescendants = true, Parent = head }, { Theme.corner(6) })
	-- the bands behind the fill: 0-6 / 7-9 / 10-12
	new("Frame", { Size = UDim2.new(6.5 / 12, 0, 1, 0), BackgroundColor3 = Theme.OK, BackgroundTransparency = 0.8, BorderSizePixel = 0, Parent = track })
	new("Frame", { Size = UDim2.new(3 / 12, 0, 1, 0), Position = UDim2.new(6.5 / 12, 0, 0, 0), BackgroundColor3 = Theme.WARN, BackgroundTransparency = 0.8, BorderSizePixel = 0, Parent = track })
	new("Frame", { Size = UDim2.new(2.5 / 12, 0, 1, 0), Position = UDim2.new(9.5 / 12, 0, 0, 0), BackgroundColor3 = Theme.BAD, BackgroundTransparency = 0.8, BorderSizePixel = 0, Parent = track })
	blue.fFill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = Theme.OK, BorderSizePixel = 0, Parent = track }, { Theme.corner(6) })
	blue.fText = label({ Text = "0 · healthy", Font = Theme.HEAVY, TextSize = 15, Size = UDim2.new(0, 100, 1, 0), Position = UDim2.new(0, 438, 0, 0), Parent = head })
	blue.health = label({ Text = "", RichText = true, Font = Theme.BOLD, TextSize = 14, Size = UDim2.new(1, -538, 1, 0), Position = UDim2.new(0, 538, 0, 0), TextXAlignment = Enum.TextXAlignment.Right, Parent = head })
	-- the six checks
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 90), Position = UDim2.new(0, 0, 0, 32), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	blue.tiles = {}
	for _, c in cfg.checks do
		local b = button({
			Text = "",
			AutoButtonColor = true,
			BackgroundColor3 = Theme.PANEL2,
			Size = UDim2.new(1 / 6, -5, 1, 0),
			Parent = row,
		}, function()
			if not roles.trim then
				GamePanel.hint("The trim sets the loadout")
				return
			end
			local tile = blue.tiles[c.id]
			send({ op = "check", id = c.id, on = not tile.want })
		end)
		local name = label({ Text = c.label, Font = Theme.HEAVY, TextSize = 14, TextWrapped = true, Size = UDim2.new(1, -10, 0, 34), Position = UDim2.new(0, 5, 0, 3), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Parent = b })
		local fr = label({ Text = string.format("+%d%s", c.friction, c.compute and " + $" or ""), Font = Theme.BOLD, TextSize = 13, TextColor3 = Theme.WARN, Size = UDim2.new(1, -10, 0, 16), Position = UDim2.new(0, 5, 0, 38), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
		local st = label({ Text = "off", Font = Theme.HEAVY, TextSize = 14, TextColor3 = Theme.MUTED, Size = UDim2.new(1, -10, 0, 16), Position = UDim2.new(0, 5, 0, 54), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
		local act = label({ Text = ACT_TEXT[c.act] or "", TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(1, -10, 0, 14), Position = UDim2.new(0, 5, 0, 71), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
		local stroke = Theme.stroke(Theme.WARN, 2, 1)
		stroke.Parent = b
		blue.tiles[c.id] = { b = b, name = name, fr = fr, st = st, act = act, stroke = stroke, want = false }
	end
	-- signs at the gate
	local signs = new("Frame", { Size = UDim2.new(1, 0, 0, 28), Position = UDim2.new(0, 0, 0, 128), BackgroundTransparency = 1, Parent = f })
	label({ Text = "SIGNS (free)", Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 84, 1, 0), Parent = signs })
	local srow = new("Frame", { Size = UDim2.new(1, -88, 1, 0), Position = UDim2.new(0, 88, 0, 0), BackgroundTransparency = 1, Parent = signs })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 5), Parent = srow })
	blue.signs = {}
	for _, c in cfg.checks do
		local b = button({ Text = (c.short or c.id), TextSize = 13, Size = UDim2.new(1 / 6, -5, 1, 0), BackgroundColor3 = Theme.PANEL2, Parent = srow }, function()
			if not roles.trim then
				GamePanel.hint("The trim posts signs")
				return
			end
			send({ op = "sign", id = c.id, on = not has(last and last.signs, c.id) })
		end)
		blue.signs[c.id] = b
	end
	blue.foot = label({ Text = "", RichText = true, TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, -214, 0, 18), Position = UDim2.new(0, 0, 0, 160), TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
	-- who decides a listing: you see every one, or only what a check escalates
	blue.monBtn = button({ Text = "", TextSize = 13, Size = UDim2.new(0, 206, 0, 22), Position = UDim2.new(1, -206, 0, 158), BackgroundColor3 = Theme.PANEL2, Parent = f }, function()
		if not roles.trim then
			GamePanel.hint("The trim decides what reaches the inbox")
			return
		end
		local judgingAll = last and last.monitor == "off"
		send({ op = "monitor", mode = judgingAll and "rules" or "off", keep = true })
	end)
	blue.strip = f
end

local function healthText(g): string
	local h = g.health or 0
	local col = h >= 0.7 and "56C478" or (h >= 0.4 and "F0B43C" or "E85448")
	return string.format("trade <font color=\"#%s\">%d%%</font> <font size=\"12\" color=\"#A09A96\">%.0f/min</font>", col, math.floor(h * 100 + 0.5), g.dealsPerMin or 0)
end

local function updateLoadout(g)
	if not blue.strip then
		return
	end
	local f = g.friction or 0
	local band = g.band or "healthy"
	blue.fFill.Size = UDim2.new(math.clamp(f / 12, 0, 1), 0, 1, 0)
	blue.fFill.BackgroundColor3 = BAND_COLOR[band] or Theme.OK
	blue.fText.Text = string.format("%d · %s", f, band)
	blue.fText.TextColor3 = BAND_COLOR[band] or Theme.OK
	blue.health.Text = healthText(g)
	local pend = {}
	for _, p in g.pending or {} do
		pend[p.id] = p
	end
	for id, tile in blue.tiles do
		local on = has(g.loadout, id)
		local p = pend[id]
		tile.want = p and p.on or on
		if p then
			tile.st.Text = string.format("%s in %ds", p.on and "on" or "off", math.ceil(p.inS or 0))
			tile.st.TextColor3 = Theme.WARN
			tile.stroke.Transparency = 0.1
		else
			tile.st.Text = on and "ON" or "off"
			tile.st.TextColor3 = on and Theme.OK or Theme.MUTED
			tile.stroke.Transparency = 1
		end
		tile.b.BackgroundColor3 = on and Color3.fromRGB(32, 70, 52) or Theme.PANEL2
	end
	for id, b in blue.signs do
		local on = has(g.signs, id)
		b.BackgroundColor3 = on and Color3.fromRGB(80, 66, 30) or Theme.PANEL2
		b.TextColor3 = on and Theme.GOLD or Theme.MUTED
	end
	local trim = roles.trim and "" or "  <font color=\"#F0B43C\">(the trim's call)</font>"
	blue.foot.Text = string.format("changes land %d s later · compute %s%s", cfg.delay or 30, money(g.compute), trim)
	local all = g.monitor == "off"
	blue.monBtn.Text = all and "inbox: EVERY listing · switch" or (g.monitor == "external" and "inbox: your monitor · switch" or "inbox: checks escalate · switch")
	blue.monBtn.TextColor3 = all and Theme.WARN or Theme.OK
end

------------------------------------------------------------------ Blue: escapes and catches (the lookout's)

local function buildEscapes()
	local f = panel({
		Name = "Escapes",
		Size = UDim2.new(0, 300, 0, 160),
		Position = UDim2.new(0, 16, 0, 300),
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = gui,
	})
	Theme.pad(10, 12).Parent = f
	label({ Text = "ESCAPES <font size=\"12\" color=\"#A09A96\">by type</font> <font color=\"#56C478\">&amp; CATCHES</font>", RichText = true, Font = Theme.HEAVY, TextSize = 15, TextColor3 = Theme.BAD, Size = UDim2.new(1, 0, 0, 18), Parent = f })
	blue.escList = new("Frame", { Size = UDim2.new(1, 0, 1, -22), Position = UDim2.new(0, 0, 0, 22), BackgroundTransparency = 1, ClipsDescendants = true, Parent = f })
	new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder, Parent = blue.escList })
	blue.escRows = {}
	for i = 1, 7 do
		blue.escRows[i] = label({ Text = "", RichText = true, TextSize = 13, TextWrapped = true, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i, Visible = false, Parent = blue.escList })
	end
	blue.escNone = label({ Text = "nothing yet", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 17), LayoutOrder = 0, Parent = blue.escList })
	blue.escPanel = f
end

local CATCH_BY = { idCheck = "ID check", watcher = "a watcher", monitor = "the monitor", inspector = "inspector", escrow = "escrow" }

local function updateEscapes(g)
	if not blue.escPanel then
		return
	end
	-- newest first: escapes (red) and catches (green), interleaved by time
	local items = {}
	for _, e in g.escapes or {} do
		table.insert(items, { t = e.t, text = string.format("<font color=\"#E85448\">✕</font> %s <font color=\"#A09A96\">%s</font>", e.text, money(e.value)) })
	end
	for _, c in g.catches or {} do
		local kind = KIND_TEXT[c.kind] or c.kind
		local an = string.match(kind, "^[aeiou]") and "an" or "a"
		table.insert(items, { t = c.t, text = string.format("<font color=\"#56C478\">✓</font> %s caught %s %s <font color=\"#A09A96\">(%s)</font>", CATCH_BY[c.by] or c.by, an, kind, c.stall or "") })
	end
	table.sort(items, function(a, b)
		return a.t > b.t
	end)
	for i, row in blue.escRows do
		local it = items[i]
		row.Visible = it ~= nil
		row.Text = it and it.text or ""
	end
	blue.escNone.Visible = #items == 0
end

------------------------------------------------------------------ Red: the attack shop

local function buildShop()
	local f = panel({
		Name = "AttackShop",
		Size = UDim2.new(0, 660, 0, 196),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, -10, 1, -16),
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = gui,
	})
	Theme.stroke(Theme.BAD, 2, 0.4).Parent = f
	Theme.pad(10, 14).Parent = f
	local head = new("Frame", { Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Parent = f })
	label({ Text = "ATTACK SHOP", Font = Theme.HEAVY, TextSize = 18, TextColor3 = Theme.BAD, Size = UDim2.new(0, 130, 1, 0), Parent = head })
	red.rent = label({ Text = "", Font = Theme.BOLD, TextSize = 14, TextColor3 = Theme.GOLD, Size = UDim2.new(0, 290, 1, 0), Position = UDim2.new(0, 130, 0, 0), TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
	red.speed = label({ Text = "", RichText = true, Font = Theme.BOLD, TextSize = 14, Size = UDim2.new(1, -424, 1, 0), Position = UDim2.new(0, 424, 0, 0), TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, Parent = head })
	-- the attacks
	local row = new("Frame", { Size = UDim2.new(1, 0, 0, 66), Position = UDim2.new(0, 0, 0, 32), BackgroundTransparency = 1, Parent = f })
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), Parent = row })
	red.buttons = {}
	red.mods = { vouch = false, stolenId = false }
	for _, a in cfg.attacks do
		local b = button({ Text = "", BackgroundColor3 = Color3.fromRGB(110, 36, 36), Size = UDim2.new(1 / #cfg.attacks, -5, 1, 0), Parent = row }, function()
			if not has(last and last.unlocked, a.id) then
				GamePanel.hint(a.label .. " unlocks at " .. (UNLOCK_AT[a.id] or "later"))
				return
			end
			local msg: any = { op = "attack", kind = a.id, vouch = red.mods.vouch or nil, stolenId = red.mods.stolenId or nil }
			send(msg)
		end)
		local name = label({ Text = a.label, Font = Theme.HEAVY, TextSize = 15, Size = UDim2.new(1, -12, 0, 18), Position = UDim2.new(0, 6, 0, 4), TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd, Parent = b })
		local cost = label({ Text = "", TextSize = 12, TextColor3 = Color3.fromRGB(240, 200, 196), Size = UDim2.new(1, -12, 0, 14), Position = UDim2.new(0, 6, 0, 24), TextXAlignment = Enum.TextXAlignment.Center, Parent = b })
		local what = label({ Text = a.what or "", TextSize = 12, TextColor3 = Color3.fromRGB(220, 180, 176), TextWrapped = true, Size = UDim2.new(1, -12, 0, 26), Position = UDim2.new(0, 6, 0, 38), TextXAlignment = Enum.TextXAlignment.Center, TextYAlignment = Enum.TextYAlignment.Top, Parent = b })
		red.buttons[a.id] = { b = b, name = name, cost = cost, what = what, a = a }
	end
	-- the modifiers (added to the next attack)
	local mrow = new("Frame", { Size = UDim2.new(1, 0, 0, 30), Position = UDim2.new(0, 0, 0, 104), BackgroundTransparency = 1, Parent = f })
	label({ Text = "ADD TO NEXT", Font = Theme.BOLD, TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, 88, 1, 0), Parent = mrow })
	red.modButtons = {}
	for i, m in cfg.mods do
		local b = button({ Text = "", TextSize = 14, Size = UDim2.new(0, 200, 1, 0), Position = UDim2.new(0, 88 + (i - 1) * 208, 0, 0), BackgroundColor3 = Theme.PANEL2, Parent = mrow }, function()
			if not has(last and last.unlocked, m.id) then
				GamePanel.hint(m.label .. " unlocks at " .. (UNLOCK_AT[m.id] or "later"))
				return
			end
			red.mods[m.id] = not red.mods[m.id]
			GamePanel.update(last)
		end)
		red.modButtons[m.id] = { b = b, m = m }
	end
	-- Blue's signs (what Blue says it runs: it may be bluffing)
	red.signs = label({ Text = "", RichText = true, TextSize = 14, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.new(0, 0, 0, 140), TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
	red.foot = label({ Text = "", TextSize = 13, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 16), Position = UDim2.new(0, 0, 0, 160), TextTruncate = Enum.TextTruncate.AtEnd, Parent = f })
	red.shop = f
end

local function updateShop(g)
	if not red.shop then
		return
	end
	local purse = g.red and g.red.score and g.red.score.purse
	red.rent.Text = string.format("purse %s · deposit %s · rent %s/min", purse and money(purse) or "150 NB", money(cfg.deposit), money(cfg.rent))
	local h = g.health or 0
	local col = h >= 0.7 and "56C478" or (h >= 0.4 and "F0B43C" or "E85448")
	red.speed.Text = string.format("trade speed <font color=\"#%s\">%d%%</font>", col, math.floor(h * 100 + 0.5))
	local extra = 0
	for id, on in red.mods do
		if on then
			for _, m in cfg.mods do
				if m.id == id then
					extra += m.cost
				end
			end
		end
	end
	for id, btn in red.buttons do
		local open = has(g.unlocked, id)
		local cost = (btn.a.cost or 0) + extra
		btn.cost.Text = open and (money(cost + (cfg.deposit or 0)) .. (btn.a.costLabel and (" incl. " .. btn.a.costLabel) or "") .. " + rent") or ("🔒 unlocks " .. (UNLOCK_AT[id] or "later"))
		btn.b.BackgroundColor3 = open and Color3.fromRGB(110, 36, 36) or Color3.fromRGB(58, 46, 48)
		btn.name.TextColor3 = open and Theme.WHITE or Theme.MUTED
	end
	for id, mb in red.modButtons do
		local open = has(g.unlocked, id)
		if not open then
			red.mods[id] = false
		end
		local on = red.mods[id]
		mb.b.Text = string.format("%s %s  %s", on and "☑" or "☐", mb.m.label, open and money(mb.m.cost) or ("🔒 " .. (UNLOCK_AT[id] or "")))
		mb.b.BackgroundColor3 = on and Color3.fromRGB(120, 60, 30) or Theme.PANEL2
		mb.b.TextColor3 = open and Theme.WHITE or Theme.MUTED
	end
	local names = {}
	for _, id in g.signs or {} do
		local c = checkInfo(id)
		table.insert(names, c and c.label or id)
	end
	red.signs.Text = #names > 0 and ("<font color=\"#A09A96\">BLUE'S SIGNS:</font> " .. table.concat(names, " · ")) or "<font color=\"#A09A96\">BLUE'S SIGNS: none posted</font>"
	red.foot.Text = "You see each fraud's outcome, never which check caught it. A slow market means a heavy loadout."
end

------------------------------------------------------------------ Red: the outcome log (in Hud's red panel)

-- rows for Hud's red panel: { text, color } newest first
function GamePanel.redLog(g)
	local out = {}
	local log = g and g.red and g.red.log or {}
	local labels = {}
	for _, o in cfg and cfg.outcomes or {} do
		labels[o.id] = o.label
	end
	for i = #log, 1, -1 do
		local e = log[i]
		local mods = (e.vouch and " +vouch" or "") .. (e.stolenId and " +ID" or "")
		local text = string.format("%s%s · %s → %s%s", KIND_TEXT[e.kind] or e.kind, mods, e.stall or "", labels[e.outcome] or e.outcome, (e.stolen or 0) > 0 and (" · " .. money(e.stolen)) or "")
		table.insert(out, { text = text, color = OUTCOME_COLOR[e.outcome] or Theme.MUTED })
	end
	return out
end

function GamePanel.redScore(g)
	return g and g.red and g.red.score or nil
end

------------------------------------------------------------------ the scoreboard's game chart

local function seg(parent, x0: number, y0: number, x1: number, y1: number, color: Color3, w: number)
	local dx, dy = x1 - x0, y1 - y0
	local len = math.sqrt(dx * dx + dy * dy)
	new("Frame", {
		Size = UDim2.new(0, len + 1, 0, w),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, (x0 + x1) / 2, 0, (y0 + y1) / 2),
		Rotation = math.deg(math.atan2(dy, dx)),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = parent,
	})
end

-- Blue's loadout over time (a lane per check) above trade health and the
-- fraud stolen so far. Draws into `parent` at (x, y), w x h.
function GamePanel.drawSeries(parent, sb, x: number, y: number, w: number, h: number)
	local series = sb.series or {}
	local length = sb.length or 300
	local checks = cfg and cfg.checks or {}
	local laneH = 14
	local lanesH = #checks * laneH
	local labW = 96
	local cw = w - labW
	local function X(t: number): number
		return labW + math.clamp(t / length, 0, 1) * cw
	end
	label({ Text = "BLUE'S LOADOUT", Font = Theme.HEAVY, TextSize = 13, TextColor3 = Theme.BLUE, Size = UDim2.new(0, 200, 0, 16), Position = UDim2.new(0, x, 0, y), Parent = parent })
	local box = new("Frame", { Size = UDim2.new(0, w, 0, h - 18), Position = UDim2.new(0, x, 0, y + 18), BackgroundTransparency = 1, Parent = parent })
	for i, c in checks do
		local ly = (i - 1) * laneH
		label({ Text = c.label, TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(0, labW - 6, 0, laneH), Position = UDim2.new(0, 0, 0, ly), TextTruncate = Enum.TextTruncate.AtEnd, Parent = box })
		new("Frame", { Size = UDim2.new(0, cw, 0, laneH - 4), Position = UDim2.new(0, labW, 0, ly + 2), BackgroundColor3 = Theme.PANEL2, BackgroundTransparency = 0.5, BorderSizePixel = 0, Parent = box })
		-- runs where the check was on
		local runStart = nil
		for k, s in series do
			local on = has(s.lo, c.id)
			local lastOne = k == #series
			if on and not runStart then
				runStart = s.t
			end
			if runStart and (not on or lastOne) then
				local t1 = on and s.t or s.t
				new("Frame", { Size = UDim2.new(0, math.max(2, X(t1) - X(runStart)), 0, laneH - 4), Position = UDim2.new(0, X(runStart), 0, ly + 2), BackgroundColor3 = Theme.BLUE, BorderSizePixel = 0, Parent = box })
				runStart = nil
			end
		end
	end
	-- trade health (green, 0..120%) and friction (amber, 0..12) and stolen (red, 0..max)
	local top = lanesH + 8
	local chH = (h - 18) - top - 16
	local chart = new("Frame", { Size = UDim2.new(0, cw, 0, chH), Position = UDim2.new(0, labW, 0, top), BackgroundColor3 = Theme.PANEL2, BackgroundTransparency = 0.4, BorderSizePixel = 0, Parent = box })
	label({ Text = "trade health", TextSize = 12, TextColor3 = Theme.OK, Size = UDim2.new(0, labW - 6, 0, 14), Position = UDim2.new(0, 0, 0, top), Parent = box })
	label({ Text = "friction", TextSize = 12, TextColor3 = Theme.WARN, Size = UDim2.new(0, labW - 6, 0, 14), Position = UDim2.new(0, 0, 0, top + 16), Parent = box })
	label({ Text = "stolen", TextSize = 12, TextColor3 = Theme.BAD, Size = UDim2.new(0, labW - 6, 0, 14), Position = UDim2.new(0, 0, 0, top + 32), Parent = box })
	label({ Text = "caught", TextSize = 12, TextColor3 = Theme.WHITE, Size = UDim2.new(0, labW - 6, 0, 14), Position = UDim2.new(0, 0, 0, top + 48), Parent = box })
	local maxSt, maxC = 1, 1
	for _, s in series do
		maxSt = math.max(maxSt, s.st or 0)
		maxC = math.max(maxC, s.c or 0)
	end
	local function CX(t: number): number
		return math.clamp(t / length, 0, 1) * cw
	end
	local function Y(v: number): number
		return chH - math.clamp(v, 0, 1) * chH
	end
	for k = 2, #series do
		local a, b = series[k - 1], series[k]
		seg(chart, CX(a.t), Y((a.h or 0) / 1.2), CX(b.t), Y((b.h or 0) / 1.2), Theme.OK, 2)
		seg(chart, CX(a.t), Y((a.f or 0) / 12), CX(b.t), Y((b.f or 0) / 12), Theme.WARN, 2)
		seg(chart, CX(a.t), Y((a.st or 0) / maxSt), CX(b.t), Y((b.st or 0) / maxSt), Theme.BAD, 2)
		seg(chart, CX(a.t), Y((a.c or 0) / maxC), CX(b.t), Y((b.c or 0) / maxC), Theme.WHITE, 1)
	end
	-- the healthy line (friction 6) and full trade (100%)
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 0, Y(1 / 1.2)), BackgroundColor3 = Theme.OK, BackgroundTransparency = 0.6, BorderSizePixel = 0, Parent = chart })
	label({ Text = string.format("max stolen %s · caught %d", money(maxSt), maxC), TextSize = 12, TextColor3 = Theme.MUTED, Size = UDim2.new(1, 0, 0, 14), Position = UDim2.new(0, 0, 1, 2), TextXAlignment = Enum.TextXAlignment.Right, Parent = chart })
	for _, m in sb.marks or {} do
		if m.at > 0 and m.at < length then
			new("Frame", { Size = UDim2.new(0, 1, 1, 0), Position = UDim2.new(0, X(m.at), 0, 0), BackgroundColor3 = Theme.WHITE, BackgroundTransparency = 0.75, BorderSizePixel = 0, Parent = box })
		end
	end
end

------------------------------------------------------------------ public

function GamePanel.hint(text: string)
	if GamePanel.onHint then
		GamePanel.onHint(text)
	end
end

-- which crew roles this player holds (a solo Blue: all three)
function GamePanel.setRoles(list: { string }?)
	roles = { lookout = false, trim = false, skipper = false }
	for _, r in list or { "lookout", "trim", "skipper" } do
		roles[r] = true
	end
	if blue.roleChip then
		local names = {}
		for _, r in { "lookout", "trim", "skipper" } do
			if roles[r] then
				table.insert(names, r)
			end
		end
		blue.roleChip.Text = "you: " .. table.concat(names, " · ")
	end
end

function GamePanel.roles()
	return roles
end

function GamePanel.setTeam(t: string)
	team = t
	GamePanel.layout()
end

function GamePanel.layout()
	local isBlue = team ~= "red"
	if blue.strip then
		blue.strip.Visible = isBlue and inRound
	end
	if blue.escPanel then
		blue.escPanel.Visible = isBlue and inRound
	end
	if red.shop then
		red.shop.Visible = (not isBlue) and inRound
	end
	-- fit the bottom-centre panels between the meter (left, 416 px) and the
	-- inbox (right, 436 px)
	local W = gui and gui.AbsoluteSize.X or 1600
	local room = W - 416 - 436 - 24
	local w = math.clamp(room, 480, 700)
	local cx = 416 + 12 + w / 2
	for _, p in { blue.strip, red.shop } do
		if p then
			p.Size = UDim2.new(0, w, 0, 196)
			p.Position = UDim2.new(0, cx, 1, -16)
		end
	end
end

-- left column: the escapes list sits under the controls, above the meter
function GamePanel.placeEscapes(controlsBottom: number, meterTop: number)
	if not blue.escPanel then
		return
	end
	local top = controlsBottom + 16
	-- as tall as seven wrapped lines, no taller than the room above the meter
	local h = math.clamp(meterTop - 10 - top, 80, 250)
	blue.escPanel.Position = UDim2.new(0, 16, 0, top)
	blue.escPanel.Size = UDim2.new(0, 300, 0, h)
end

-- the server's view for this player (b.g), each state tick
function GamePanel.update(g)
	if not g then
		return
	end
	last = g
	local was = inRound
	inRound = g.roundOn == true
	if was ~= inRound then
		GamePanel.layout()
	end
	if team ~= "red" then
		updateLoadout(g)
		updateEscapes(g)
	else
		updateShop(g)
	end
end

function GamePanel.inRound(): boolean
	return inRound
end

function GamePanel.build(opts)
	send = opts.send
	gui = opts.gui
	cfg = opts.config
	if not cfg then
		return
	end
	buildLoadout()
	buildEscapes()
	buildShop()
	GamePanel.setRoles(nil)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(GamePanel.layout)
	GamePanel.layout()
	_ = Players
end

return GamePanel
