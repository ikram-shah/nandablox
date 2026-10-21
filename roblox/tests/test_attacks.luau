-- Each attack under each layer setting, and what the watchtower can do to it.

local lib = require("./lib")

local function layers(auth, registry)
	return { auth = auth, registry = registry, transport = "memory.v1" }
end

local function warm(cfg, l, seed)
	local sim = lib.sim(cfg or lib.quiet(), l, seed)
	lib.run(sim, 30) -- some deals under way, orders on the books
	return sim
end

local RED = "red-team"

return function(t)
	------------------------------------------------------------------ forge

	t.case("forge under hmac.v1: the guards stop it at once", function(A)
		local sim = warm(nil, layers("hmac.v1", "index.v1"))
		local th = sim:forge("seller-a")
		local evs = sim:drain()
		A.eq(th.state, "blocked")
		local sent = lib.first(evs, function(e)
			return e.kind == "message_sent"
		end)
		A.eq(sent.observer, "seller-a", "signed as the real seller")
		A.eq(sent.origin, "gate", "sets off from the gate")
		A.eq(sent.detail.kind, "invoice")
		local bad = lib.first(evs, function(e)
			return e.kind == "signature_invalid"
		end)
		A.ok(bad, "signature_invalid")
		A.eq(bad.subject, sent.subject)
		A.eq(bad.detail.claimed, "seller-a")
		A.ok(lib.first(evs, function(e)
			return e.kind == "delivery_failed" and e.subject == sent.subject
		end), "never delivered")
		local later = lib.run(sim, 60)
		A.eq(lib.count(later, function(e)
			return e.kind == "payment_settled" and e.detail.to == RED
		end), 0, "red is never paid")
		A.eq(sim.balances[RED], 0)
	end)

	t.case("forge under plain.v1: a live threat that pays red after the window", function(A)
		local sim = warm(nil, layers("plain.v1", "index.v1"))
		local t0 = sim.now
		local th = sim:forge("seller-b")
		local evs = sim:drain()
		A.eq(th.state, "live")
		local sent = lib.first(evs, function(e)
			return e.kind == "message_sent"
		end)
		A.eq(sent.origin, "gate", "the tell: it sets off from the gate, not seller-b's stall")
		A.eq(sent._threat, th.id, "private threat id on the server copy")
		local alias = sent.detail.body.pay_to
		A.ok(not sim:listedNames()[alias], "the tell: payee " .. alias .. " is not on the notice board")
		A.eq(lib.count(evs, function(e)
			return e.kind == "signature_invalid"
		end), 0, "no guards")
		local later = lib.run(sim, t0 + sim.cfg.FORGE_WINDOW + 0.2)
		local paid = lib.first(later, function(e)
			return e.kind == "payment_settled" and e.detail.to == RED
		end)
		A.ok(paid, "red is paid")
		A.near(paid.at, t0 + sim.cfg.FORGE_WINDOW, 0.11, "at the end of the window")
		A.eq(paid.detail.cents, sim.cfg.FORGE_CENTS)
		A.eq(th.state, "escaped")
		A.eq(sim.balances[RED], sim.cfg.FORGE_CENTS)
		local res = sim:drainResolved()
		A.eq(#res, 1)
		A.eq(res[1].id, th.id)
	end)

	t.case("forge caught in flight or at the buyer: no payout", function(A)
		for _, delay in { 0.5, 6 } do -- on the road / held at the buyer
			local sim = warm(nil, layers("plain.v1", "index.v1"))
			local th = sim:forge("seller-a")
			sim:drain()
			lib.run(sim, sim.now + delay)
			local kind, _, live = sim:target(th.msgId)
			A.eq(kind, "message")
			A.eq(live and live.id, th.id, "the envelope is the live threat")
			A.ok(sim:catch(th.id), "caught")
			local evs = sim:drain()
			A.ok(lib.first(evs, function(e)
				return e.kind == "delivery_failed" and e.subject == th.msgId
			end), "envelope taken off the road")
			local later = lib.run(sim, sim.now + 20)
			A.eq(lib.count(later, function(e)
				return e.kind == "payment_settled" and e.detail.to == RED
			end), 0, "no payout after a catch (delay " .. delay .. ")")
			A.eq(th.state, "caught")
			A.ok(not sim:catch(th.id), "a second catch does nothing")
		end
	end)

	------------------------------------------------------------------ spoof

	t.case("spoof under index.owned.v1: card_publish_refused", function(A)
		for _, auth in { "hmac.v1", "plain.v1" } do
			local sim = warm(nil, layers(auth, "index.owned.v1"))
			local cards = #sim.cards
			local th = sim:spoof("seller-a")
			local evs = sim:drain()
			A.eq(th.state, "blocked")
			local ref = lib.first(evs, function(e)
				return e.kind == "card_publish_refused"
			end)
			A.ok(ref, "refused under " .. auth)
			A.eq(ref.subject, "seller-a")
			A.eq(ref.detail.publisher, RED)
			A.eq(#sim.cards, cards, "nothing pinned")
		end
	end)

	t.case("spoof under index.v1 + hmac.v1: pinned UNVERIFIED, routes a deal to red, pays out", function(A)
		local sim = warm(nil, layers("hmac.v1", "index.v1"))
		local th = sim:spoof("seller-a")
		local evs = sim:drain()
		A.eq(th.state, "live")
		A.ok(lib.first(evs, function(e)
			return e.kind == "signature_invalid" and e.subject == "seller-a"
		end), "the signature does not match the name")
		local card = lib.first(evs, function(e)
			return e.kind == "card_unverified"
		end)
		A.ok(card, "but index.v1 still pins it, unverified")
		A.eq(card.card, th.cardId)
		local later = lib.run(sim, sim.now + 90)
		local routed = lib.first(later, function(e)
			return e.kind == "message_sent" and e.dest == RED
		end)
		A.ok(routed, "a buyer's courier is routed to red's stall")
		A.eq(routed.detail.to, "seller-a", "addressed to the name on the card")
		local reply = lib.first(later, function(e)
			return e.kind == "message_sent" and e.origin == RED
		end)
		A.ok(reply and reply.observer == "seller-a", "the impostor answers as seller-a, from red's stall")
		local paid = lib.first(later, function(e)
			return e.kind == "payment_settled" and e.detail.to == RED
		end)
		A.ok(paid, "red is paid out of escrow")
		A.eq(paid.detail.via, "escrow")
		A.eq(th.state, "escaped")
		local bad = lib.first(later, function(e)
			return e.kind == "receipt_attested" and e.detail.value == "bad"
		end)
		A.ok(bad and bad.subject == "seller-a", "the honest seller's name takes the bad receipt")
		A.ok(lib.first(later, function(e)
			return e.kind == "card_withdrawn" and e.card == th.cardId
		end), "the impostor's card comes down after it cashes out")
	end)

	t.case("spoof under index.v1 + plain.v1: verified-looking, but two cards share a name", function(A)
		local sim = warm(nil, layers("plain.v1", "index.v1"))
		local th = sim:spoof("seller-b")
		local evs = sim:drain()
		local card = lib.first(evs, function(e)
			return e.kind == "card_registered"
		end)
		A.ok(card and card.detail.verified == true, "looks verified")
		A.eq(lib.count(evs, function(e)
			return e.kind == "signature_invalid"
		end), 0)
		local same = 0
		for _, c in sim.cards do
			if c.name == "seller-b" then
				same += 1
			end
		end
		A.eq(same, 2, "the tell: two seller-b cards on the board")
		A.ok(card.price < sim.cfg.LIST_PRICE["seller-a"], "it undercuts, so buyers pick it")
		A.eq(th.state, "live")
	end)

	t.case("spoof caught mid-deal: card withdrawn, escrow refunded, no payout", function(A)
		local sim = warm(nil, layers("plain.v1", "index.v1"))
		local th = sim:spoof("seller-a")
		sim:drain()
		-- run until the impostor's deal has escrow held
		local held = nil
		for _ = 1, 600 do
			lib.run(sim, sim.now + 0.1)
			for _, d in sim.deals do
				if d.threat == th.id and d.escrow then
					held = d
				end
			end
			if held then
				break
			end
		end
		A.ok(held, "a buyer escrowed money for the impostor")
		local buyer, cents = held.buyer, held.escrow
		local before = sim.balances[buyer]
		-- blue flags one of the impostor deal's envelopes
		local ids = sim:threatTargets(th)
		A.ok(#ids >= 1, "the card (and any couriers) are flaggable")
		A.ok(table.find(ids, th.cardId), "the card is one of them")
		A.ok(sim:catch(th.id))
		local evs = sim:drain()
		A.ok(lib.first(evs, function(e)
			return e.kind == "card_withdrawn" and e.card == th.cardId
		end), "card withdrawn")
		A.ok(lib.first(evs, function(e)
			return e.kind == "escrow_refunded" and e.detail.to == buyer
		end), "escrow refunded")
		A.eq(sim.balances[buyer], before + cents)
		local later = lib.run(sim, sim.now + 40)
		A.eq(lib.count(later, function(e)
			return e.kind == "payment_settled" and e.detail.to == RED
		end), 0)
		A.eq(sim.balances[RED], 0)
	end)

	t.case("adopting index.owned.v1 mid-round takes impostor cards down", function(A)
		local sim = warm(nil, layers("hmac.v1", "index.v1"))
		local th = sim:spoof("seller-a")
		sim:drain()
		sim:setLayer("registry", "index.owned.v1")
		local evs = sim:drain()
		A.ok(lib.first(evs, function(e)
			return e.kind == "card_withdrawn" and e.card == th.cardId
		end))
		A.eq(th.state, "blocked")
		A.eq(#sim.cards, 2, "only the honest cards are left")
	end)

	------------------------------------------------------------------ false alarms

	t.case("a false alarm holds an honest envelope FALSE_ALARM_STALL seconds", function(A)
		local sim = warm(nil, layers("plain.v1", "index.v1"))
		local ids = sim:honestTargets()
		A.ok(#ids > 0, "honest envelopes on the road")
		local id = ids[1]
		local m = sim.messages[id]
		local due = m.deliverAt
		A.ok(sim:hold(id))
		local evs = sim:drain()
		local d = lib.first(evs, function(e)
			return e.kind == "message_delayed"
		end)
		A.ok(d and d.subject == id and d.detail.fault == "false_alarm")
		local later = lib.run(sim, due + sim.cfg.FALSE_ALARM_STALL + 0.2)
		local deliv = lib.first(later, function(e)
			return e.kind == "message_delivered" and e.subject == id
		end)
		A.ok(deliv, "still delivered")
		A.near(deliv.at, due + sim.cfg.FALSE_ALARM_STALL, 0.11, "late by the stall")
	end)

	t.case("an honest card flagged is skipped by buyers for the stall", function(A)
		local sim = warm(nil, layers("plain.v1", "index.v1"))
		local honest = sim.cards[1]
		A.ok(sim:hold(honest.id))
		A.ok(honest.stallUntil > sim.now)
	end)
end
