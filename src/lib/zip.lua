-- Minimal read-only zip reader (stored + deflate), enough for EPUB and CBZ.
--
-- zip.openfile(path) reads straight from disk: only the directory at the end
-- of the file up front, then each entry when it's asked for, so a 1 GB comic
-- doesn't have to sit in memory. zip.open(data) does the same over a string.
--
-- archive = { names, has(name), raw(name), head(name, n), read(name), close() }

local zip = {}

local function u16(s, pos) return (love.data.unpack("<I2", s, pos)) end
local function u32(s, pos) return (love.data.unpack("<I4", s, pos)) end

-- readat(pos, len) returns len bytes starting at 1-based pos.
local function parse(size, readat)
	-- The end-of-central-directory record sits in the last 64KB (+22 bytes).
	local tailsize = math.min(size, 65557)
	local tailstart = size - tailsize + 1
	local tail = readat(tailstart, tailsize)
	if not tail then return nil, "could not read file" end
	local eocd
	local pos = 1
	while true do
		local found = tail:find("PK\5\6", pos, true)
		if not found then break end
		eocd, pos = found, found + 1
	end
	if not eocd or eocd + 21 > #tail then return nil, "not a zip file" end

	local count = u16(tail, eocd + 10)
	local cdsize = u32(tail, eocd + 12)
	local cdoffset = u32(tail, eocd + 16)
	if count == 0xFFFF or cdoffset == 0xFFFFFFFF or cdsize == 0xFFFFFFFF then
		return nil, "very large (ZIP64) archives aren't supported"
	end
	local cd = readat(cdoffset + 1, cdsize)
	if not cd or #cd < cdsize then return nil, "corrupt central directory" end

	local entries, names = {}, {}
	local cdpos = 1
	for _ = 1, count do
		if cd:sub(cdpos, cdpos + 3) ~= "PK\1\2" then
			return nil, "corrupt central directory"
		end
		local nlen = u16(cd, cdpos + 28)
		local elen = u16(cd, cdpos + 30)
		local clen = u16(cd, cdpos + 32)
		local name = cd:sub(cdpos + 46, cdpos + 45 + nlen)
		entries[name] = {
			method = u16(cd, cdpos + 10),
			csize = u32(cd, cdpos + 20),
			lhpos = u32(cd, cdpos + 42) + 1,
		}
		names[#names + 1] = name
		cdpos = cdpos + 46 + nlen + elen + clen
	end

	local archive = { names = names }

	-- Where an entry's data starts: the local header has its own name/extra
	-- lengths, which may differ from the central directory's.
	local function datastart(e)
		if not e.start then
			local header = readat(e.lhpos, 30)
			if not header or #header < 30 then return nil end
			e.start = e.lhpos + 30 + u16(header, 27) + u16(header, 29)
		end
		return e.start
	end

	function archive.has(name) return entries[name] ~= nil end

	-- Still-compressed bytes and the compression method (0 stored, 8 deflate),
	-- so the inflating can happen somewhere else (e.g. a worker thread).
	function archive.raw(name)
		local e = entries[name]
		local start = e and datastart(e)
		if not start then return nil end
		return readat(start, e.csize), e.method
	end

	function archive.read(name)
		local e = entries[name]
		if not e then return nil, "missing entry: " .. name end
		local raw, method = archive.raw(name)
		if not raw then return nil, "could not read " .. name end
		if method == 0 then
			return raw
		elseif method == 8 then
			local ok, out = pcall(love.data.decompress, "string", "deflate", raw)
			if ok then return out end
			return nil, "inflate failed: " .. tostring(out)
		end
		return nil, "unsupported compression method " .. method
	end

	-- The first n bytes of an entry; cheap for stored entries, which is how
	-- most EPUB images are kept.
	function archive.head(name, n)
		local e = entries[name]
		if e and e.method == 0 then
			local start = datastart(e)
			return start and readat(start, math.min(n, e.csize))
		end
		return archive.read(name)
	end

	function archive.close() end

	return archive
end

function zip.open(data)
	return parse(#data, function(pos, len) return data:sub(pos, pos + len - 1) end)
end

function zip.openfile(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local size = f:seek("end")
	local archive, perr = parse(size, function(pos, len)
		if len <= 0 then return "" end
		if not f or not f:seek("set", pos - 1) then return nil end
		return f:read(len)
	end)
	if not archive then
		f:close()
		return nil, perr
	end
	function archive.close()
		if f then f:close() end
		f = nil
	end
	return archive
end

return zip
