-- Minimal read-only zip reader (stored + deflate), enough for EPUB files.

local zip = {}

local function u16(s, pos) return (love.data.unpack("<I2", s, pos)) end
local function u32(s, pos) return (love.data.unpack("<I4", s, pos)) end

-- Returns an archive object: { names = {...}, read = function(name) }
function zip.open(data)
	-- The end-of-central-directory record sits in the last 64KB (+22 bytes).
	local eocd
	local from = math.max(1, #data - 65557)
	local pos = from
	while true do
		local found = data:find("PK\5\6", pos, true)
		if not found then break end
		eocd, pos = found, found + 1
	end
	if not eocd then return nil, "not a zip file" end

	local count = u16(data, eocd + 10)
	local cdpos = u32(data, eocd + 16) + 1

	local entries, names = {}, {}
	for _ = 1, count do
		if data:sub(cdpos, cdpos + 3) ~= "PK\1\2" then
			return nil, "corrupt central directory"
		end
		local method = u16(data, cdpos + 10)
		local csize = u32(data, cdpos + 20)
		local nlen = u16(data, cdpos + 28)
		local elen = u16(data, cdpos + 30)
		local clen = u16(data, cdpos + 32)
		local lhpos = u32(data, cdpos + 42) + 1
		local name = data:sub(cdpos + 46, cdpos + 45 + nlen)
		entries[name] = { method = method, csize = csize, lhpos = lhpos }
		names[#names + 1] = name
		cdpos = cdpos + 46 + nlen + elen + clen
	end

	local archive = { names = names }

	function archive.read(name)
		local e = entries[name]
		if not e then return nil, "missing entry: " .. name end
		-- Local header has its own name/extra lengths, which may differ.
		local nlen = u16(data, e.lhpos + 26)
		local elen = u16(data, e.lhpos + 28)
		local start = e.lhpos + 30 + nlen + elen
		local raw = data:sub(start, start + e.csize - 1)
		if e.method == 0 then
			return raw
		elseif e.method == 8 then
			local ok, out = pcall(love.data.decompress, "string", "deflate", raw)
			if ok then return out end
			return nil, "inflate failed: " .. tostring(out)
		end
		return nil, "unsupported compression method " .. e.method
	end

	return archive
end

return zip
