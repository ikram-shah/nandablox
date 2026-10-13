-- Replays a converted NANDA Town trace (see tools/trace_to_luau.py) in the town
-- built by Town.luau. Logical time is stretched to roughly `opts.targetSeconds`
-- of screen time; events sharing one logical `at` are staggered so each can be
-- seen. Messages fly sender -> recipient and land at their delivered time.
--
--   local Replay = require(ReplicatedStorage.NandaTown.Replay)
--   Replay.run(require(ReplicatedStorage.NandaTown.Traces.marketplace), {
--       parent = workspace, guiParent = playerGui, camera = workspace.CurrentCamera })
--
-- Optional: targetSeconds, speed, lead (seconds of town-only screen time before
-- the first event), hudRect and bannerY (pixels; Hud.luau), onEvent(e) (called
-- after each event is shown; Movie.luau uses it for chapter captions).

local Util = require(script.Parent.Util)
local Town = require(script.Parent.Town)
local Hud = require(script.Parent.Hud)

local Replay = {}

-- The one fixed overview camera.
Replay.CAMERA = { pos = Vector3.new(0, 66, 88), target = Vector3.new(0, 2, -16), fov = 50 }

-- Minimum on-screen gap before an event, by kind (seconds at speed 1). Bookkeeping is
-- quick; money, trust and verdicts get time to be read.
local MIN_GAP = {
	account_opened = 0.35,
	run_created = 0.6,
	participant_joined = 0.55,
	identity_created = 0.3,
	card_registered = 0.55,
	card_unverified = 0.9,
	message_sent = 0.55,
	message_delivered = 0.35,
	negotiation_started = 1.4,
	offer_made = 1.4,
	counter_made = 1.6,
	offer_accepted = 1.6,
	escrow_held = 2.0,
	escrow_released = 2.0,
	payment_settled = 1.4,
	receipt_attested = 1.7,
	reputation_updated = 1.9,
	memory_written = 1.2,
	duplicate_recognized = 1.8,
	message_duplicated = 1.6,
	message_dropped = 1.6,
	run_finished = 1.5,
}
local DEFAULT_GAP = 1.0
local IDLE_KNEE = 0.3 -- logical gaps longer than this are compressed
local IDLE_SQUASH = 0.25

------------------------------------------------------------------------ schedule

-- Returns display times (seconds from start) for every event, scaled to ~target seconds.
-- Each step is max(minimum gap for the kind × gapFactor, compressed logical gap × scale),
-- so logical pauses (a buyer waiting for quotes) stay visible as pauses.
local MIN_SCALE = 5 -- screen seconds per (compressed) logical second, at least
function Replay.schedule(trace, target: number): ({ number }, number)
	local evs = trace.events
	local function pass(scale: number, gfac: number): { number }
		local d = {}
		local prevAt, prevD = nil, 0
		for i, e in evs do
			local gap = (MIN_GAP[e.kind] or DEFAULT_GAP) * gfac
			if i == 1 then
				d[i] = 0.5
			else
				local dl = e.at - prevAt
				if dl > IDLE_KNEE then
					dl = IDLE_KNEE + (dl - IDLE_KNEE) * IDLE_SQUASH
				end
				d[i] = prevD + math.max(gap, dl * scale)
			end
			prevAt, prevD = e.at, d[i]
		end
		return d
	end
	local function search(lo: number, hi: number, f: (number) -> { number }): number
		for _ = 1, 30 do
			local mid = (lo + hi) / 2
			local d = f(mid)
			if d[#d] < target then
				lo = mid
			else
				hi = mid
			end
		end
		return lo
	end
	local d = pass(MIN_SCALE, 1)
	if d[#d] > target then
		-- too long: shrink the per-kind gaps (not below 35%) at the minimum scale
		local g = search(0.35, 1, function(x)
			return pass(MIN_SCALE, x)
		end)
		return pass(MIN_SCALE, g), MIN_SCALE
	end
	-- too short: stretch logical time
	local s = search(MIN_SCALE, 200, function(x)
		return pass(x, 1)
	end)
	return pass(s, 1), s
end

------------------------------------------------------------------------ text

local function trunc(s: any): string
	return tostring(s)
end

local function bodySummary(kind: string?, body: { [string]: any }?): string
	if not body then
		return ""
	end
	local bits = {}
	if body.quantity then
		table.insert(bits, tostring(body.quantity) .. " ×")
	end
	if body.sku then
		table.insert(bits, body.sku)
	end
	if body.unit_cents then
		table.insert(bits, "@ " .. body.unit_cents .. "¢")
	elseif body.cents then
		table.insert(bits, body.cents .. "¢")
	end
	return table.concat(bits, " ")
end

function Replay.describe(e, trace): string
	local d = e.detail or {}
	local k = e.kind
	local who, subj = trunc(e.observer), trunc(e.subject)
	if k == "account_opened" then
		return string.format("Bank opens an account for <b>%s</b> with %s", subj, Util.money(d.balance_cents))
	elseif k == "run_created" then
		return string.format("Run created: scenario <b>%s</b>, seed %s", tostring(d.scenario), tostring(d.seed))
	elseif k == "participant_joined" then
		return string.format("<b>%s</b> joins the town as a <b>%s</b>", subj, tostring(d.role))
	elseif k == "identity_created" then
		return string.format("<b>%s</b> gets identity %s", subj, tostring(d.agent_id))
	elseif k == "card_registered" then
		return string.format("<b>%s</b> pins a %s card to the notice board: %s", subj, d.verified and "verified" or "", table.concat(d.capabilities or {}, ", "))
	elseif k == "card_unverified" then
		return string.format("<b>%s</b>'s card is pinned <font color='#ff6060'>UNVERIFIED</font> (publisher %s)", subj, tostring(d.publisher))
	elseif k == "card_publish_refused" then
		return string.format("Registry <font color='#ff6060'>refuses</font> card %s: %s", subj, tostring(d.reason))
	elseif k == "signature_invalid" then
		return string.format("<font color='#ff6060'>Guards stop a forged signature</font> on %s (claimed %s)", subj, tostring(d.claimed))
	elseif k == "message_sent" then
		local s = bodySummary(d.kind, d.body)
		return string.format("<b>%s</b> → <b>%s</b>: ✉ %s%s", who, tostring(d.to), tostring(d.kind), s ~= "" and ("  (" .. s .. ")") or "")
	elseif k == "message_delivered" then
		return string.format("✉ %s delivered to <b>%s</b>  <font color='#aaaaaa'>(%s, from %s)</font>", tostring(d.kind), tostring(d.to), subj, tostring(e.from))
	elseif k == "message_duplicated" then
		return string.format("<font color='#ff9040'>Transport fault:</font> %s (%s → %s) is <b>duplicated</b>; a second copy is on the road", tostring(d.kind), tostring(e.from), tostring(d.to))
	elseif k == "message_dropped" then
		return string.format("<font color='#ff6060'>Transport fault:</font> %s to %s <b>dropped</b>; it never arrives", tostring(d.kind), tostring(d.to))
	elseif k == "message_delayed" then
		return string.format("<font color='#ff9040'>Transport fault:</font> %s to %s <b>delayed</b> %s s", tostring(d.kind), tostring(d.to), tostring(d.delay))
	elseif k == "negotiation_started" then
		return string.format("<b>%s</b> opens negotiation %s with <b>%s</b> over %s", who, subj, tostring(d.seller), tostring(d.subject))
	elseif k == "offer_made" then
		return string.format("<b>%s</b> offers <b>%s¢</b> per unit", who, tostring(d.cents))
	elseif k == "counter_made" then
		return string.format("<b>%s</b> counters at <b>%s¢</b>", who, tostring(d.cents))
	elseif k == "offer_accepted" then
		return string.format("<b>%s</b> accepts: deal at <b>%s¢</b> per unit", who, tostring(d.cents))
	elseif k == "escrow_held" then
		return string.format("Bank holds <b>%s</b> from <b>%s</b> in escrow for %s", Util.money(d.cents), tostring(d.from), subj)
	elseif k == "escrow_released" then
		return string.format("Escrow for %s released: <b>%s</b> to <b>%s</b>", subj, Util.money(d.cents), tostring(d.to))
	elseif k == "escrow_refunded" then
		return string.format("Escrow for %s refunded: %s back to %s", subj, Util.money(d.cents), tostring(d.to))
	elseif k == "payment_settled" then
		return string.format("Payment settled: <b>%s → %s %s</b>%s", tostring(d.from), tostring(d.to), Util.money(d.cents), d.via and (" via " .. d.via) or "")
	elseif k == "receipt_attested" then
		return string.format("<b>%s</b> files a receipt on <b>%s</b>: %s = <b>%s</b>", who, subj, tostring(d.claim), tostring(d.value))
	elseif k == "reputation_updated" then
		return string.format("<b>%s</b>'s reputation %s%s → score <b>%s</b> ★", subj, (d.delta or 0) >= 0 and "+" or "", tostring(d.delta), tostring(d.score))
	elseif k == "memory_written" then
		return string.format("<b>%s</b> writes to memory: <i>%s</i>", subj, tostring(d.key))
	elseif k == "duplicate_recognized" then
		return string.format("<b>%s</b> recognizes the duplicate %s for %s and ignores it", who, tostring(d.kind), subj)
	elseif k == "run_finished" then
		local v = trace.result and trace.result.verdict
		return string.format("Run finished at t = %.1f%s", tonumber(d.logical_time) or e.at, v and ("  ·  verdict <b>" .. string.upper(v) .. "</b>") or "")
	elseif k == "task_announced" then
		return string.format("<b>%s</b> announces task %s", who, subj)
	elseif k == "bid_placed" then
		return string.format("<b>%s</b> bids %s¢ on %s", who, tostring(d.cents), subj)
	elseif k == "task_awarded" then
		return string.format("%s awarded to <b>%s</b> at %s¢", subj, tostring(d.winner), tostring(d.cents))
	end
	return string.format("%s · %s · %s", who, k, subj)
end

------------------------------------------------------------------------ effects

local function setBubble(agent, text: string, life: number, bg: Color3?)
	if not agent then
		return
	end
	agent.bubbleToken += 1
	local token = agent.bubbleToken
	agent.bubbleText.Text = text
	local w = math.clamp(#text * 8.5 + 26, 90, 255)
	agent.bubble.Size = UDim2.fromOffset(w, 32)
	agent.bubble.BackgroundColor3 = bg or Color3.new(1, 1, 1)
	agent.bubble.Visible = true
	Util.delay(life, function()
		if agent.bubbleToken == token then
			agent.bubble.Visible = false
		end
	end)
end

local function floater(parent: Instance, at: Vector3, text: string, color: Color3, life: number?)
	local anchor = Util.part({ Name = "Floater", Size = Vector3.new(0.2, 0.2, 0.2), CFrame = CFrame.new(at), Transparency = 1, Parent = parent })
	local b = Util.billboard(anchor, 160, 34, 0, "Floater")
	local t = Util.label(b, { Text = text, TextSize = 26, Font = Util.FONT_HEAVY, TextColor3 = color, TextStrokeTransparency = 0 })
	local l = life or 2.2
	Util.animate(l, function(a)
		anchor.CFrame = CFrame.new(at + Vector3.new(0, 6 * a, 0))
		t.TextTransparency = math.max(0, (a - 0.6) / 0.4)
		t.TextStrokeTransparency = t.TextTransparency
	end, function()
		anchor:Destroy()
	end)
end

local function flash(building, color: Color3?)
	if not building or not building.flash then
		return
	end
	local h = building.flash :: Highlight
	if color then
		h.FillColor = color
		h.OutlineColor = color
	end
	Util.animate(1.4, function(a)
		local v = math.sin(a * math.pi)
		h.FillTransparency = 1 - 0.3 * v
		h.OutlineTransparency = 1 - v
	end)
end

local ENVELOPE_COLORS = {
	quote_request = Color3.fromRGB(250, 250, 250),
	quote_response = Color3.fromRGB(200, 230, 255),
	nego_offer = Color3.fromRGB(255, 220, 120),
	nego_counter = Color3.fromRGB(255, 190, 120),
	purchase_order = Color3.fromRGB(160, 235, 160),
}

local function makeEnvelope(parent: Instance, kind: string?, ghost: boolean): BasePart
	local p: BasePart
	if kind == "delivery" then
		p = Util.part({ Name = "Crate", Size = Vector3.new(3.2, 3.2, 3.2), Color = Color3.fromRGB(170, 120, 60), Material = Enum.Material.WoodPlanks, Parent = parent })
	else
		p = Util.part({
			Name = "Envelope",
			Size = Vector3.new(4.4, 0.5, 3),
			Color = ENVELOPE_COLORS[kind or ""] or Color3.fromRGB(240, 240, 240),
			Material = Enum.Material.Neon,
			Parent = parent,
		})
	end
	if ghost then
		p.Transparency = 0.45
		p.Color = Color3.fromRGB(255, 120, 60)
	end
	local b = Util.billboard(p, 170, 24, 2.8, "Tag")
	local t = Util.label(b, {
		Text = (ghost and "DUPLICATE " or "") .. (kind == "delivery" and "📦 delivery" or ("✉ " .. tostring(kind))),
		TextSize = 17,
		Font = Util.FONT_HEAVY,
		TextColor3 = ghost and Color3.fromRGB(255, 140, 60) or Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.1,
	})
	t.Name = "TagText"
	local trail0 = Instance.new("Attachment")
	trail0.Position = Vector3.new(0, 0, 0.8)
	trail0.Parent = p
	local trail1 = Instance.new("Attachment")
	trail1.Position = Vector3.new(0, 0, -0.8)
	trail1.Parent = p
	local trail = Instance.new("Trail")
	trail.Attachment0 = trail0
	trail.Attachment1 = trail1
	trail.Lifetime = 0.6
	trail.Color = ColorSequence.new(p.Color)
	trail.Transparency = NumberSequence.new(0.3, 1)
	trail.FaceCamera = true
	trail.Parent = p
	return p
end

local function coinStack(parent: Instance, n: number, label: string): (Model, BasePart, TextLabel)
	local m = Instance.new("Model")
	m.Name = "Coins"
	local base: BasePart? = nil
	for i = 1, n do
		local c = Util.part({
			Name = "Coin",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.9, 4.2, 4.2),
			CFrame = CFrame.new(0, (i - 1) * 0.95, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(255, 200, 40),
			Material = Enum.Material.Metal,
			Parent = m,
		})
		c.Reflectance = 0.25
		if not base then
			base = c
		end
	end
	m.PrimaryPart = base
	m.Parent = parent
	local b = Util.billboard(base :: BasePart, 130, 30, 6.5, "Amount")
	local t = Util.label(b, { Text = label, TextSize = 22, Font = Util.FONT_HEAVY, TextColor3 = Color3.fromRGB(255, 215, 60), TextStrokeTransparency = 0 })
	b.Size = UDim2.fromOffset(220, 30)
	return m, base :: BasePart, t
end

local function flyModel(m: Model, from: Vector3, to: Vector3, height: number, duration: number, done: (() -> ())?)
	local mid = (from + to) / 2 + Vector3.new(0, height, 0)
	local rel = {}
	local pivot = CFrame.new(m:GetPivot().Position) -- translation only: keep each part's own orientation
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			rel[p] = pivot:ToObjectSpace(p.CFrame)
		end
	end
	Util.animate(duration, function(a)
		local pos = Util.bezier(from, mid, to, Util.ease(a))
		local cf = CFrame.new(pos) * CFrame.Angles(0, (1 - a) * math.pi * 4, 0)
		for p, r in rel do
			p.CFrame = cf * r
		end
	end, done)
end

------------------------------------------------------------------------ run

function Replay.run(trace, opts: { [string]: any }?)
	local o = opts or {}
	Util.startClock()
	Util.speed = o.speed or 1
	local parent = o.parent or workspace
	local town = Town.build(trace, parent)
	local hud = Hud.new(trace, o.guiParent or game:GetService("StarterGui"), { rect = o.hudRect, bannerY = o.bannerY })
	local fx = Instance.new("Folder")
	fx.Name = "Effects"
	fx.Parent = town.root

	if o.camera then
		local cam = o.camera :: Camera
		cam.CameraType = Enum.CameraType.Scriptable
		cam.FieldOfView = o.fov or Replay.CAMERA.fov
		cam.CFrame = CFrame.lookAt(o.cameraPos or Replay.CAMERA.pos, o.cameraTarget or Replay.CAMERA.target)
	end

	local times, scale = Replay.schedule(trace, o.targetSeconds or 52)
	local bySeq = {}
	for i, e in trace.events do
		bySeq[e.seq] = i
	end
	local function timeOf(seq: number?): number?
		local i = seq and bySeq[seq]
		return i and times[i] or nil
	end

	-- state
	local balances, initialTotal = {}, 0
	local escrow, escrowTotal = {}, 0
	local cards, receipts = {}, {}
	local envelopes = {} -- message id -> { part, ghost }
	local ledgerLog = {}
	local A = town.agents

	local function agent(name: any)
		return name and A[name] or nil
	end
	local function posOf(name: any, kind: string?): Vector3
		local a = agent(name)
		if a then
			return a.chest
		end
		return town.center
	end

	local function refreshBalance(name: string)
		local a = A[name]
		if a and balances[name] then
			a.balance.Text = string.format("%s · %s", a.role, Util.money(balances[name]))
		end
	end

	local function refreshLedger()
		local bank = town.buildings.payments
		local lines, total = {}, 0
		for _, n in town.order do
			if balances[n] then
				total += balances[n]
				table.insert(lines, string.format("%s  %s", n, Util.money(balances[n])))
			end
		end
		total += escrowTotal
		table.insert(lines, string.format("in escrow  %s", Util.money(escrowTotal)))
		local ok = total == initialTotal
		table.insert(
			lines,
			string.format(
				"<font color='%s'>total %s %s</font>",
				ok and "#1a8a2a" or "#d02020",
				Util.money(total),
				ok and "✓ conserved" or "✗ NOT CONSERVED"
			)
		)
		bank.panel.Text = table.concat(lines, "\n")
	end

	local function refreshCards()
		local b = town.buildings.registry
		local lines = {}
		for _, c in cards do
			table.insert(lines, c)
		end
		b.panel.Text = table.concat(lines, "\n")
	end

	local function refreshReceipts()
		local lines = {}
		for i = math.max(1, #receipts - 3), #receipts do
			table.insert(lines, receipts[i])
		end
		town.buildings.trust.panel.Text = table.concat(lines, "\n")
	end

	-- hide agents until they join
	for _, a in A do
		for _, p in a.model:GetDescendants() do
			if p:IsA("BasePart") then
				p:SetAttribute("BaseTransparency", p.Transparency)
				p.Transparency = 1
			end
		end
		a.hud.Enabled = false
	end

	local function spawnAgent(a)
		local parts = {}
		for _, p in a.model:GetDescendants() do
			if p:IsA("BasePart") then
				parts[p] = p.CFrame
			end
		end
		Util.animate(0.6, function(al)
			local drop = (1 - Util.ease(al)) * 14
			for p, cf in parts do
				p.Transparency = (p:GetAttribute("BaseTransparency") or 0) + (1 - al) * 0.8
				p.CFrame = cf + Vector3.new(0, drop, 0)
			end
		end, function()
			for p, cf in parts do
				p.CFrame = cf
				p.Transparency = p:GetAttribute("BaseTransparency") or 0
			end
		end)
		a.hud.Enabled = true
	end

	local function pinPaper(building, color: Color3, idx: number, surface: BasePart)
		-- a little paper rectangle pinned on a board/wall, laid out in a grid
		local col, row = (idx - 1) % 5, (idx - 1) // 5
		local cf = surface.CFrame * CFrame.new(-surface.Size.X / 2 + 2 + col * 3.6, surface.Size.Y / 2 - 2 - row * 3, surface.Size.Z / 2 + 0.1)
		return Util.part({ Name = "Paper", Size = Vector3.new(2.8, 2.2, 0.15), CFrame = cf, Color = color, Material = Enum.Material.SmoothPlastic, Parent = building.model })
	end

	local function flyPaper(from: Vector3, to: Vector3, color: Color3, dur: number, done)
		local p = Util.part({ Name = "Paper", Size = Vector3.new(2.4, 0.2, 1.8), Color = color, Material = Enum.Material.Neon, Parent = fx })
		Util.fly(p, from, to, 10, dur, function()
			p:Destroy()
			if done then
				done()
			end
		end)
	end

	local handlers = {}

	handlers.account_opened = function(e)
		balances[e.subject] = e.detail.balance_cents or 0
		initialTotal += balances[e.subject]
		refreshBalance(e.subject)
		refreshLedger()
		flash(town.buildings.payments)
	end

	handlers.participant_joined = function(e)
		local a = agent(e.subject)
		if a then
			spawnAgent(a)
			refreshBalance(e.subject)
		end
	end

	handlers.identity_created = function(e)
		setBubble(agent(e.subject), "🪪 " .. tostring(e.detail.agent_id), 1.2, Color3.fromRGB(230, 220, 255))
	end

	local function cardEvent(e, ok: boolean)
		local reg = town.buildings.registry
		local a = agent(e.subject)
		reg.pinned += 1
		local idx = reg.pinned
		local color = ok and Color3.fromRGB(250, 250, 240) or Color3.fromRGB(255, 120, 120)
		local caps = table.concat(e.detail.capabilities or {}, ",")
		table.insert(cards, string.format("%s %s: %s", ok and "<font color='#1a8a2a'>✓</font>" or "<font color='#d02020'>✗ UNVERIFIED</font>", tostring(e.subject), caps))
		flyPaper(a and a.chest or town.center, reg.anchor, color, 1.0, function()
			pinPaper(reg, color, idx, reg.board)
			refreshCards()
		end)
		flash(reg, ok and Util.LAYER_COLORS.registry or Color3.fromRGB(255, 60, 60))
	end
	handlers.card_registered = function(e)
		cardEvent(e, e.detail.verified ~= false)
	end
	handlers.card_unverified = function(e)
		cardEvent(e, false)
	end
	handlers.card_publish_refused = function(e)
		flash(town.buildings.registry, Color3.fromRGB(255, 60, 60))
	end

	handlers.signature_invalid = function(e)
		local g = town.buildings.auth
		g.stopped += 1
		g.panel.Text = string.format("%d forged signature%s stopped", g.stopped, g.stopped == 1 and "" or "s")
		flash(g, Color3.fromRGB(255, 40, 40))
		floater(fx, g.anchor + Vector3.new(0, 6, 0), "✋ FORGED", Color3.fromRGB(255, 70, 70))
	end

	local SEND_BUBBLE = {
		quote_request = function(d)
			return "Price for " .. tostring(d.body and d.body.sku or "?") .. "?"
		end,
		quote_response = function(d)
			return tostring(d.body and d.body.sku or "") .. ": " .. tostring(d.body and d.body.unit_cents or "?") .. "¢ each"
		end,
		purchase_order = function(d)
			local b = d.body or {}
			return string.format("Order: %s × %s @ %s¢", tostring(b.quantity), tostring(b.sku), tostring(b.unit_cents))
		end,
		delivery = function(d)
			local b = d.body or {}
			return string.format("Shipping %s × %s 📦", tostring(b.quantity), tostring(b.sku))
		end,
	}

	handlers.message_sent = function(e)
		local d = e.detail
		local m = trace.messages[e.subject] or {}
		local from, to = posOf(e.observer), posOf(d.to)
		local env = makeEnvelope(fx, d.kind, false)
		local firstDelivery = m.deliveries and m.deliveries[1]
		local arrive = timeOf(firstDelivery)
		-- a dropped message falls at its fault time instead
		local dropSeq
		for _, f in m.faults or {} do
			if f.kind == "message_dropped" or f.kind == "delivery_failed" then
				dropSeq = f.seq
			end
		end
		local now = times[bySeq[e.seq]]
		local dur = ((arrive or timeOf(dropSeq) or (now + 1.2)) - now)
		dur = math.max(dur, 0.5)
		envelopes[e.subject] = { part = env, kind = d.kind, to = d.to, from = e.observer }
		local target = dropSeq and not arrive and (from + to) / 2 + Vector3.new(0, 4, 0) or to
		Util.fly(env, from, target, 9, dur * 0.97)
		local mk = SEND_BUBBLE[d.kind]
		if mk then
			setBubble(agent(e.observer), mk(d), 2.6)
		end
	end

	handlers.message_delivered = function(e)
		local env = envelopes[e.subject]
		local env2 = envelopes[e.subject .. "#dup"]
		-- the duplicate copy lands at the second delivery
		local m = trace.messages[e.subject] or {}
		local isSecond = m.deliveries and m.deliveries[2] == e.seq
		local target = isSecond and env2 or env
		if target and target.part and target.part.Parent then
			local p = target.part
			local a = agent(e.detail.to)
			if target.kind == "delivery" and a then
				-- crates pile up at the buyer's feet
				a.crates += 1
				local n = a.crates
				p:SetAttribute("Landed", true)
				p.CFrame = CFrame.new(a.pos + Vector3.new(6.5, 1.6 + (n - 1) * 3.3, 0))
				local tag = p:FindFirstChild("Tag")
				if tag and not isSecond then
					tag:Destroy()
				end
				local trail = p:FindFirstChildOfClass("Trail")
				if trail then
					trail.Enabled = false
				end
				p.Name = isSecond and "DuplicateCrate" or "Crate"
				if isSecond then
					a.dupCrate = p
				end
			else
				Util.animate(0.35, function(al)
					p.Size = p.Size:Lerp(Vector3.new(0.2, 0.2, 0.2), al)
				end, function()
					p:Destroy()
				end)
			end
		end
	end

	handlers.message_duplicated = function(e)
		local d = e.detail
		local m = trace.messages[e.subject] or {}
		local second = m.deliveries and m.deliveries[2]
		local now = times[bySeq[e.seq]]
		local arrive = timeOf(second) or (now + 1.5)
		local env = makeEnvelope(fx, d.kind or m.kind, true)
		envelopes[e.subject .. "#dup"] = { part = env, kind = d.kind or m.kind }
		Util.fly(env, posOf(e.from or m.from), posOf(d.to), 15, math.max(arrive - now, 0.6) * 0.97)
		floater(fx, posOf(e.from or m.from) + Vector3.new(0, 8, 0), "⚠ DUPLICATED", Color3.fromRGB(255, 140, 50))
	end

	handlers.message_dropped = function(e)
		local env = envelopes[e.subject]
		if env and env.part and env.part.Parent then
			local p = env.part
			p.Color = Color3.fromRGB(230, 40, 40)
			local start = p.Position
			Util.animate(0.8, function(a)
				p.CFrame = CFrame.new(start:Lerp(Vector3.new(start.X, 0.5, start.Z), a * a)) * CFrame.Angles(a * 3, 0, a * 2)
			end, function()
				floater(fx, p.Position + Vector3.new(0, 2, 0), "✗ DROPPED", Color3.fromRGB(255, 60, 60))
				p:Destroy()
			end)
		end
	end
	handlers.delivery_failed = handlers.message_dropped

	handlers.message_delayed = function(e)
		floater(fx, posOf(e.detail.to) + Vector3.new(0, 8, 0), "⏳ delayed", Color3.fromRGB(255, 180, 60))
	end

	handlers.negotiation_started = function(e)
		local seller = e.detail.seller
		setBubble(agent(e.observer), string.format("Let's haggle, %s: %s", tostring(seller), tostring(e.detail.subject)), 2.4)
		flash(town.stalls[seller])
	end
	handlers.offer_made = function(e)
		setBubble(agent(e.observer), string.format("Offer: %s¢", tostring(e.detail.cents)), 3.4, Color3.fromRGB(255, 240, 180))
	end
	handlers.counter_made = function(e)
		setBubble(agent(e.observer), string.format("Counter: %s¢", tostring(e.detail.cents)), 3.4, Color3.fromRGB(255, 215, 170))
		flash(town.stalls[e.observer])
	end
	-- A glowing strip on the ground ties buyer and seller from the deal until it settles.
	local deals = {} -- order ref or negotiation id -> strip part
	local negSeller = {}
	local function dealStrip(buyer, seller, text: string)
		local a, b = agent(buyer), agent(seller)
		if not a or not b then
			return nil
		end
		local p0, p1 = a.pos + Vector3.new(0, 0.45, 0), b.pos + Vector3.new(0, 0.45, 0)
		local strip = Util.part({
			Name = "Deal",
			Size = Vector3.new(1.6, 0.3, (p1 - p0).Magnitude),
			CFrame = CFrame.lookAt((p0 + p1) / 2, p1),
			Color = Color3.fromRGB(60, 230, 110),
			Material = Enum.Material.Neon,
			Transparency = 0.15,
			Parent = fx,
		})
		local tag = Util.billboard(strip, 230, 28, 1.5, "DealTag")
		tag.StudsOffsetWorldSpace = (p1 - p0) * 0.3 + Vector3.new(0, 2, 0) -- nearer the seller, clear of the buyer's bubble
		Util.label(tag, { Text = text, TextSize = 17, Font = Util.FONT_HEAVY, TextColor3 = Color3.fromRGB(120, 255, 150), TextStrokeTransparency = 0 })
		return strip
	end
	handlers.negotiation_started = (function(orig)
		return function(e)
			negSeller[e.subject] = e.detail.seller
			orig(e)
		end
	end)(handlers.negotiation_started)
	handlers.offer_accepted = function(e)
		setBubble(agent(e.observer), string.format("Deal! %s¢ 🤝", tostring(e.detail.cents)), 3.0, Color3.fromRGB(190, 245, 190))
		local seller = negSeller[e.subject]
		if seller then
			deals[e.subject] = dealStrip(e.observer, seller, string.format("DEAL %s · %s¢/unit", tostring(e.subject), tostring(e.detail.cents)))
		end
	end
	local function closeDeal(ref: string?, nid: string?)
		local s = (ref and deals[ref]) or (nid and deals[nid])
		if s then
			deals[ref or ""] = nil
			if nid then
				deals[nid] = nil
			end
			Util.animate(1.0, function(al)
				s.Transparency = 0.15 + 0.85 * al
			end, function()
				s:Destroy()
			end)
		end
	end
	local orderToNid = {}
	for _, ev in trace.events do
		local body = ev.kind == "message_sent" and ev.detail and ev.detail.body
		if body and body.order_id and body.nid then
			orderToNid[body.order_id] = body.nid
		end
	end

	handlers.escrow_held = function(e)
		local d = e.detail
		local bank = town.buildings.payments
		local from = d.from
		balances[from] = (balances[from] or 0) - (d.cents or 0)
		escrowTotal += d.cents or 0
		local stack, _, tag = coinStack(fx, 5, Util.money(d.cents) .. " → escrow")
		escrow[e.subject] = { model = stack, cents = d.cents, tag = tag }
		local slot = 0
		for _ in escrow do
			slot += 1
		end
		local dest = bank.vaultTop + Vector3.new((slot - 1) * 4.6 - 2.3, 0.5, 0)
		flyModel(stack, posOf(from), dest, 6, 1.6, function()
			tag.Text = Util.money(d.cents) .. " held"
		end)
		floater(fx, posOf(from) + Vector3.new(-8, 0, 0), "−" .. Util.money(d.cents), Color3.fromRGB(255, 90, 90))
		refreshBalance(from)
		refreshLedger()
		flash(bank)
	end

	handlers.escrow_released = function(e)
		local d = e.detail
		local held = escrow[e.subject]
		local bank = town.buildings.payments
		escrowTotal -= d.cents or 0
		balances[d.to] = (balances[d.to] or 0) + (d.cents or 0)
		local stack = held and held.model
		if not stack then
			stack = coinStack(fx, 4, Util.money(d.cents))
		end
		if held and held.tag then
			held.tag.Text = Util.money(d.cents) .. " → " .. tostring(d.to)
		end
		escrow[e.subject] = nil
		local start = stack:GetPivot().Position
		local dest = posOf(d.to) + Vector3.new(0, 1, 2.5)
		flyModel(stack, start, dest, 9, 1.6, function()
			floater(fx, posOf(d.to) + Vector3.new(-8, 0, 0), "+" .. Util.money(d.cents), Color3.fromRGB(90, 255, 120))
			refreshBalance(d.to)
			refreshLedger()
			Util.delay(1.2, function()
				stack:Destroy()
			end)
		end)
		flash(bank)
	end

	handlers.escrow_refunded = function(e)
		handlers.escrow_released({ subject = e.subject, detail = { to = e.detail.to, cents = e.detail.cents } })
	end

	handlers.payment_settled = function(e)
		local d = e.detail
		table.insert(ledgerLog, string.format("%s → %s %s", tostring(d.from), tostring(d.to), Util.money(d.cents)))
		closeDeal(e.subject, orderToNid[e.subject])
		if d.via ~= "escrow" then
			-- direct payment: coins straight from payer to payee
			balances[d.from] = (balances[d.from] or 0) - (d.cents or 0)
			balances[d.to] = (balances[d.to] or 0) + (d.cents or 0)
			local stack = coinStack(fx, 3, Util.money(d.cents))
			flyModel(stack, posOf(d.from), posOf(d.to), 14, 1.4, function()
				refreshBalance(d.from)
				refreshBalance(d.to)
				refreshLedger()
				Util.delay(1, function()
					stack:Destroy()
				end)
			end)
		end
		flash(town.buildings.payments)
	end

	handlers.receipt_attested = function(e)
		local wall = town.buildings.trust
		local d = e.detail
		wall.pinned += 1
		local idx = wall.pinned
		local good = d.value == "good" or d.value == true
		table.insert(receipts, string.format("%s %s → %s: %s", good and "<font color='#1a8a2a'>✓</font>" or "<font color='#d02020'>✗</font>", tostring(e.observer), tostring(e.subject), tostring(d.value)))
		local color = good and Color3.fromRGB(250, 250, 235) or Color3.fromRGB(255, 140, 140)
		flyPaper(posOf(e.observer), wall.anchor, color, 1.2, function()
			pinPaper(wall, color, idx, wall.wall)
			refreshReceipts()
		end)
		setBubble(agent(e.observer), "Receipt: " .. tostring(d.value) .. " 🧾", 2.0)
		flash(wall)
	end

	handlers.reputation_updated = function(e)
		local a = agent(e.subject)
		local d = e.detail
		if a then
			local score = tonumber(d.score) or 0
			local n = math.clamp(math.floor(score + 0.5), 0, 5)
			a.stars.Text = string.rep("★", n) .. string.format(" %s", tostring(d.score))
			a.stars.Visible = true
			local base = 30
			Util.animate(0.8, function(al)
				a.stars.TextSize = base + 14 * math.sin(al * math.pi)
			end)
			floater(fx, a.top + Vector3.new(0, 11, 0), string.format("%s%s ★", (d.delta or 0) >= 0 and "+" or "", tostring(d.delta)), Color3.fromRGB(255, 210, 40))
		end
		local line = string.format("<b>%s rep → %s</b>", tostring(e.subject), tostring(d.score))
		table.insert(receipts, line)
		refreshReceipts()
		flash(town.buildings.trust)
	end

	handlers.memory_written = function(e)
		setBubble(agent(e.subject), "📓 remembers: " .. tostring(e.detail.key), 2.2, Color3.fromRGB(225, 225, 255))
	end

	handlers.duplicate_recognized = function(e)
		local a = agent(e.observer)
		setBubble(a, "Already got this one, ignoring ✋", 2.6, Color3.fromRGB(255, 225, 200))
		if a and a.dupCrate and a.dupCrate.Parent then
			local p = a.dupCrate
			local x = Util.billboard(p, 60, 60, 0, "X")
			Util.label(x, { Text = "✗", TextSize = 56, Font = Util.FONT_HEAVY, TextColor3 = Color3.fromRGB(230, 30, 30), TextStrokeTransparency = 0 })
			Util.delay(1.6, function()
				Util.animate(0.6, function(al)
					p.Transparency = 0.45 + 0.55 * al
				end, function()
					p:Destroy()
					a.crates -= 1
				end)
			end)
		end
	end

	handlers.run_finished = function(e)
		local court = town.buildings.data_facts
		flash(court, Color3.fromRGB(255, 255, 200))
		local r = trace.result
		if r then
			local lines, passed = {}, 0
			for _, s in r.stages do
				local ok = s.status == "passed"
				if ok then
					passed += 1
				end
				table.insert(lines, string.format("%s %s", ok and "<font color='#1a8a2a'>✓</font>" or "<font color='#d02020'>✗</font>", s.name))
			end
			local good = r.verdict == "passed"
			court.panel.Text = string.format("<font color='%s'>%s</font> · %d/%d stages passed", good and "#1a8a2a" or "#d02020", string.upper(r.verdict or "?"), passed, #r.stages)
			hud:banner(string.format("VERDICT: %s  ·  %d/%d stages", string.upper(r.verdict or "?"), passed, #r.stages), good and Color3.fromRGB(120, 230, 140) or Color3.fromRGB(255, 110, 110))
			hud:stages(r.stages)
		else
			court.panel.Text = "run finished (no result.json)"
			hud:banner("RUN FINISHED", Color3.fromRGB(220, 220, 220))
		end
	end

	-- generic layer flash for kinds we don't draw specially
	local function fallback(e)
		local b = town.buildings[e.layer]
		if b then
			flash(b)
		end
	end

	local handle = function(e)
		local h = handlers[e.kind]
		local ok, err = pcall(h or fallback, e)
		if not ok then
			warn("[NandaTown] handler", e.kind, e.id, err)
		end
		hud:show(e, Replay.describe(e, trace))
		if o.onEvent then
			local okCb, errCb = pcall(o.onEvent, e)
			if not okCb then
				warn("[NandaTown] onEvent", e.kind, e.id, errCb)
			end
		end
	end

	local lead = o.lead or 0
	local state = { done = false, scale = scale, total = times[#times] + lead, town = town, hud = hud, times = times, lead = lead, lastSeq = 0 }
	if Replay.current then
		Replay.current.cancelled = true
	end
	Replay.current = state
	local runner = function()
		for i, e in trace.events do
			Util.waitUntil(times[i] + lead)
			if state.cancelled then
				return
			end
			handle(e)
			state.lastSeq = e.seq
		end
		state.done = true
	end
	if o.blocking then
		runner()
	else
		state.thread = task.spawn(runner)
	end
	return state
end

-- Pause the whole replay `after` virtual seconds after event `seq` fires
-- (mid-flight freeze for screenshots). Resume with Replay.resume().
function Replay.pauseAt(seq: number, after: number?)
	task.spawn(function()
		local st = Replay.current
		while st and not st.cancelled and (st.lastSeq or 0) < seq do
			task.wait()
		end
		Util.wait(after or 0)
		Util.paused = true
	end)
end

function Replay.resume()
	Util.paused = false
end

return Replay
