-- Persists a plain Lua table (settings, reading positions) in the LÖVE save dir.

local store = {}

local FILE = "state.lua"

local function serialize(v, indent, out)
	local t = type(v)
	if t == "table" then
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		out[#out + 1] = "{\n"
		for _, k in ipairs(keys) do
			local kt = type(v[k])
			if kt == "table" or kt == "string" or kt == "number" or kt == "boolean" then
				local key = type(k) == "string" and string.format("%q", k) or tostring(k)
				out[#out + 1] = indent .. "\t[" .. key .. "] = "
				serialize(v[k], indent .. "\t", out)
				out[#out + 1] = ",\n"
			end
		end
		out[#out + 1] = indent .. "}"
	elseif t == "string" then
		out[#out + 1] = string.format("%q", v)
	else
		out[#out + 1] = tostring(v)
	end
end

-- Loads saved state, filling in anything missing from defaults.
function store.load(defaults)
	local data
	local src = love.filesystem.read(FILE)
	if src then
		local chunk = loadstring(src, FILE)
		if chunk then
			setfenv(chunk, {})
			local ok, v = pcall(chunk)
			if ok and type(v) == "table" then data = v end
		end
	end
	data = data or {}
	for k, v in pairs(defaults) do
		if type(data[k]) ~= type(v) then
			data[k] = v
		elseif type(v) == "table" then
			for k2, v2 in pairs(v) do
				if type(data[k][k2]) ~= type(v2) then data[k][k2] = v2 end
			end
		end
	end
	return data
end

function store.save(data)
	local out = { "return " }
	serialize(data, "", out)
	out[#out + 1] = "\n"
	local content = table.concat(out)

	-- Write a temporary file and rename it over the old one: a rename is atomic,
	-- so a crash mid-save can't leave a half-written state (and lose every
	-- reading position). The first save has nothing to lose and also creates
	-- the save directory, so it goes through love.filesystem.
	if love.filesystem.getInfo(FILE) then
		local path = love.filesystem.getSaveDirectory() .. "/" .. FILE
		local f = io.open(path .. ".tmp", "wb")
		if f then
			local ok = f:write(content)
			f:close()
			if ok and os.rename(path .. ".tmp", path) then return end
			os.remove(path .. ".tmp")
		end
	end
	love.filesystem.write(FILE, content)
end

return store
