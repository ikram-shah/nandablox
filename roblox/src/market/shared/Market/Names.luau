-- Stall names: "Rosa's Bakery", "Tomas's Lamps". Honest sellers and scam
-- storefronts draw from the same list, so a name gives nothing away. An
-- impostor copies an existing seller's name exactly.

local Names = {}

Names.FIRST = {
	"Rosa", "Tomas", "Amara", "Ivan", "Leila", "Mateo", "Noor", "Kenji", "Freya", "Omar",
	"Ines", "Pablo", "Sana", "Hugo", "Yara", "Felix", "Mina", "Diego", "Asha", "Lars",
	"Elena", "Kofi", "Zara", "Bruno", "Lina", "Rafael", "Hana", "Otto", "Priya", "Emil",
	"Nadia", "Joaquin", "Aiko", "Tariq", "Greta", "Marco", "Selin", "Arjun", "Clara", "Idris",
	"Vera", "Luca", "Maya", "Sami", "Ada", "Nico", "Lucia", "Ravi", "Eva", "Karim",
	"Sofia", "Jonas", "Talia", "Yusuf", "Mara", "Anton", "Dalia", "Pedro", "Ingrid", "Malik",
}

Names.SHOP = {
	bread = { "Bakery", "Bread", "Loaves", "Oven" },
	cloth = { "Cloth", "Weavers", "Linens", "Textiles" },
	lamp = { "Lamps", "Lanterns", "Lights", "Brass" },
	spice = { "Spices", "Spice House", "Saffron", "Pepper" },
}

-- a name not in `taken` (a set); falls back to a numbered one
function Names.fresh(rng, good: string, taken: { [string]: boolean }): string
	local shops = Names.SHOP[good]
	for _ = 1, 40 do
		local name = rng:pick(Names.FIRST) .. "'s " .. rng:pick(shops)
		if not taken[name] then
			return name
		end
	end
	local i = 2
	while true do
		local name = rng:pick(Names.FIRST) .. "'s " .. rng:pick(shops) .. " " .. i
		if not taken[name] then
			return name
		end
		i += 1
	end
end

return Names
