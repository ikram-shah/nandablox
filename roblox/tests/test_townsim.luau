-- TownSim: the honest marketplace on its own.

local lib = require("./lib")

local WEAK = { auth = "plain.v1", registry = "index.v1", transport = "memory.v1" }
local STRONG = { auth = "hmac.v1", registry = "index.owned.v1", transport = "memory.v1" }

return function(t)
	t.case("one deal runs the full NANDA Town cycle, in order", function(A)
		local sim = lib.sim(lib.quiet())
		local evs = lib.run(sim, 60)
		local pay = lib.first(evs, function(e)
			return e.kind == "payment_settled"
		end)
		A.ok(pay, "a payment settles within 60 s")
		local order = pay.subject
		local buyer = pay.detail.from
		-- the conversation of this buyer's first deal, in emission order
		local want = {
			"registry_lookup",
			"message_sent:quote_request",
			"message_delivered:quote_request",
			"message_sent:quote_response",
			"message_delivered:quote_response",
			"negotiation_started",
			"offer_made",
			"message_sent:nego_offer",
			"message_delivered:nego_offer",
			"counter_made",
			"message_sent:nego_counter",
			"message_delivered:nego_counter",
			"offer_accepted",
			"escrow_held",
			"message_sent:purchase_order",
			"message_delivered:purchase_order",
			"message_sent:delivery",
			"message_sent:invoice", -- the seller invoices right behind the crate
			"message_delivered:delivery",
			"message_delivered:invoice",
			"escrow_released",
			"payment_settled",
			"receipt_attested",
			"reputation_updated",
		}
		local seller = pay.detail.to
		local got = {}
		local msgs = {}
		for _, e in evs do
			local mine = false
			if e.kind == "message_sent" then
				local d = e.detail
				mine = (e.observer == buyer and d.to == seller) or (e.observer == seller and d.to == buyer)
				if mine then
					msgs[e.subject] = d.kind
				end
			elseif e.kind == "message_delivered" then
				mine = msgs[e.subject] ~= nil
			elseif e.kind == "registry_lookup" then
				mine = e.observer == buyer and #got == 0
			elseif e.kind == "escrow_held" or e.kind == "escrow_released" or e.kind == "payment_settled" then
				mine = e.subject == order
			elseif e.kind == "negotiation_started" or e.kind == "offer_made" or e.kind == "offer_accepted" then
				mine = e.observer == buyer
			elseif e.kind == "counter_made" then
				mine = e.observer == seller and #got > 0 and got[#got] == "message_delivered:nego_offer"
			elseif e.kind == "receipt_attested" or e.kind == "reputation_updated" then
				mine = e.observer == buyer and e.subject == seller
			end
			if mine then
				local k = e.kind
				if k == "message_sent" or k == "message_delivered" then
					k = k .. ":" .. tostring(msgs[e.subject])
				end
				table.insert(got, k)
			end
			if e == pay then
				-- stop a little after the payment: receipt + reputation follow it
			end
		end
		for i, w in want do
			A.eq(got[i], w, "step " .. i)
		end
		A.eq(pay.detail.via, "escrow")
		A.eq(pay.detail.cents, sim.cfg.QUANTITY * math.floor(sim.cfg.LIST_PRICE[seller] * 0.9 + 0.5), "pays the counter price")
	end)

	t.case("every event carries the NANDA Town envelope, ids in order", function(A)
		local sim = lib.sim(lib.config())
		local evs = lib.run(sim, 90)
		A.ok(#evs > 100, "plenty of events")
		for i, e in evs do
			A.eq(e.id, "ev-" .. e.seq)
			A.eq(e.event_id, e.id)
			A.ok(type(e.at) == "number" and type(e.observer) == "string" and type(e.kind) == "string" and type(e.subject) == "string" and type(e.detail) == "table", "envelope fields on " .. e.kind)
			if i > 1 then
				A.eq(e.seq, evs[i - 1].seq + 1, "consecutive seq")
				A.ok(e.at >= evs[i - 1].at, "time never runs backwards")
			end
		end
	end)

	t.case("money is conserved through a whole round, faults and all", function(A)
		local sim = lib.sim(lib.config({ DUPLICATE_DELIVERY_RATE = 0.5, DROP_QUOTE_RATE = 0.3 }))
		local before = lib.ledgerTotal(sim)
		for step = 1, 18 do
			lib.run(sim, step * 10)
			A.eq(lib.ledgerTotal(sim), before, "at t=" .. step * 10)
		end
	end)

	t.case("a deal settles every ~10-20 s under the defaults", function(A)
		local sim = lib.sim(lib.config())
		local evs = lib.run(sim, 180)
		local pays = lib.ofKind(evs, "payment_settled")
		A.between(#pays, 9, 18, "deals in a 180 s round")
		local gap = (pays[#pays].at - pays[1].at) / math.max(1, #pays - 1)
		A.between(gap, 7, 20, "mean seconds between deals")
	end)

	t.case("stronger layers cost throughput (the council's trade-off)", function(A)
		local function deals(layers)
			local total = 0
			for seed = 1, 5 do
				local sim = lib.sim(lib.config(), layers, seed)
				lib.run(sim, 180)
				total += sim.stats.dealsSettled
			end
			return total / 5
		end
		local weak, def, strong = deals(WEAK), deals(nil), deals(STRONG)
		print(string.format("        deals/round: plain+index %.1f · hmac+index (default) %.1f · hmac+owned %.1f", weak, def, strong))
		A.ok(weak > def, "hmac.v1 slows the town")
		A.ok(def > strong, "index.owned.v1 slows it further")
		A.ok(weak >= strong * 1.3, "the gap is worth voting over")
	end)

	t.case("hmac.v1 adds the signature check to every hop", function(A)
		local cfg = lib.quiet()
		local a = lib.sim(cfg, WEAK)
		local b = lib.sim(cfg, nil)
		A.near(a:hop(), cfg.HOP_SECONDS, 1e-9)
		A.near(b:hop(), cfg.HOP_SECONDS + cfg.HMAC_HOP_EXTRA, 1e-9)
		local ev = lib.first(lib.run(b, 20), function(e)
			return e.kind == "message_sent"
		end)
		A.near(ev.travel, cfg.HOP_SECONDS + cfg.HMAC_HOP_EXTRA, 1e-9, "travel hint")
	end)

	t.case("a duplicated delivery arrives twice and the buyer recognizes it", function(A)
		local sim = lib.sim(lib.config({ DUPLICATE_DELIVERY_RATE = 1, DROP_QUOTE_RATE = 0 }))
		local evs = lib.run(sim, 60)
		local dup = lib.first(evs, function(e)
			return e.kind == "message_duplicated"
		end)
		A.ok(dup, "a duplicate")
		A.eq(dup.detail.kind, "delivery")
		A.eq(lib.count(evs, function(e)
			return e.kind == "message_delivered" and e.subject == dup.subject
		end), 2, "delivered twice")
		A.ok(lib.first(evs, function(e)
			return e.kind == "duplicate_recognized"
		end), "recognized")
		-- and it is never paid twice
		local order = lib.first(evs, function(e)
			return e.kind == "duplicate_recognized"
		end).subject
		A.eq(lib.count(evs, function(e)
			return e.kind == "payment_settled" and e.subject == order
		end), 1)
	end)

	t.case("a dropped quote request is retried", function(A)
		local sim = lib.sim(lib.config({ DUPLICATE_DELIVERY_RATE = 0, DROP_QUOTE_RATE = 1 }))
		local evs = lib.run(sim, 30)
		local drop = lib.first(evs, function(e)
			return e.kind == "message_dropped"
		end)
		A.ok(drop, "a drop")
		local sent = lib.first(evs, function(e)
			return e.kind == "message_sent" and e.subject == drop.subject
		end)
		A.eq(lib.count(evs, function(e)
			return e.kind == "message_sent" and e.detail.kind == "quote_request" and e.detail.conversation == sent.detail.conversation
		end) >= 2, true, "sent again in the same conversation")
	end)

	t.case("the same seed gives the same town", function(A)
		local function run()
			local sim = lib.sim(lib.config(), nil, 99)
			local evs = lib.run(sim, 120)
			local sig = {}
			for _, e in evs do
				table.insert(sig, e.kind .. "@" .. e.at .. ":" .. e.subject)
			end
			return table.concat(sig, ",")
		end
		A.eq(run(), run())
	end)
end
