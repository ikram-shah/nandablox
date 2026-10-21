-- Agent decisions, behind one small interface, so something other than a
-- script can make them later (an LLM harness over HttpService; see
-- roblox/README.md, "Red vs. Blue (live)"). TownSim calls a policy at each
-- decision point with a read-only `view` and uses only the returned value:
--
--   buyer.chooseCard(view, cards)        -> card       which listing to buy from
--   buyer.offer(view, quoteCents)        -> cents      the opening offer
--   buyer.accept(view, counterCents)     -> boolean    take the counter?
--   buyer.payInvoice(view, invoice)      -> boolean    pay an invoice that arrived?
--   seller.quote(view, request)          -> cents      unit price for a quote request
--   seller.counter(view, offerCents)     -> cents      the counter-offer
--
-- view = { name, now, balance, reputation = {name -> score}, layers,
--          openOrders = {order_id -> {seller, cents}} }
-- A card is { id, name, capabilities, publisher, verified, price }.
--
-- The scripted policies below are the spike's only implementation. They are
-- deterministic: a remote policy would receive the same view as JSON and
-- answer with the same value.

local Policy = {}

Policy.ScriptedBuyer = {}

-- The cheapest listing wins; ties go to the better reputation, then the newer
-- card (a newer listing for a name replaces the older one, as in index.v1).
function Policy.ScriptedBuyer.chooseCard(view, cards)
	local best = nil
	for _, c in cards do
		if not best then
			best = c
		else
			local rb, rc = view.reputation[best.name] or 0, view.reputation[c.name] or 0
			if c.price < best.price or (c.price == best.price and (rc > rb or (rc == rb and c.seq > best.seq))) then
				best = c
			end
		end
	end
	return best
end

function Policy.ScriptedBuyer.offer(_view, quoteCents: number): number
	return math.floor(quoteCents * 0.8 + 0.5)
end

function Policy.ScriptedBuyer.accept(view, counterCents: number): boolean
	return counterCents * 2 <= view.balance
end

-- Pays any invoice that names an order id the buyer knows. A forged invoice
-- copies a real order id, so the scripted buyer pays it: catching it is the
-- humans' job (or the guards', under hmac.v1).
function Policy.ScriptedBuyer.payInvoice(view, invoice): boolean
	return invoice.order_id ~= nil and view.knownOrders[invoice.order_id] == true
end

Policy.ScriptedSeller = {}

function Policy.ScriptedSeller.quote(view, _request): number
	return view.listPrice
end

function Policy.ScriptedSeller.counter(view, offerCents: number): number
	return math.max(offerCents, math.floor(view.listPrice * 0.9 + 0.5))
end

-- red's impostor stall (behind a spoofed card) answers like a seller, cheaply
Policy.Impostor = {
	quote = function(view, _request): number
		return view.listPrice
	end,
	counter = function(_view, offerCents: number): number
		return offerCents
	end,
}

return Policy
