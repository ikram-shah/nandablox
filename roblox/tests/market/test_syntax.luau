-- Every Luau file under src/market/ compiles (catches syntax slips in the Roblox-only
-- modules that the other tests cannot require headless).

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local function walk(dir: string, out: { string })
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then
			walk(p, out)
		elseif string.match(name, "%.luau$") then
			table.insert(out, p)
		end
	end
	return out
end

return function(t)
	local files = walk("src/market", {})
	table.sort(files)
	t.case(string.format("all %d files under src/market/ compile", #files), function(A)
		local bad = {}
		for _, p in files do
			local ok, err = pcall(luau.compile, fs.readFile(p))
			if not ok then
				table.insert(bad, p .. ": " .. tostring(err))
			end
		end
		A.eq(#bad, 0, table.concat(bad, "\n"))
	end)
end
