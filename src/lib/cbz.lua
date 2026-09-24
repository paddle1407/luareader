-- CBZ (zipped comic) loader. Produces the common document shape with every
-- block an image, plus doc.comic = true and doc.pages = { { src, block } ... }.
-- Nothing is decoded here, so even huge comics open instantly.

local zip = require("lib.zip")
local xml = require("lib.xml")

local cbz = {}

local imageext = { png = true, jpg = true, jpeg = true, bmp = true }

local function ispage(name)
	if name:sub(-1) == "/" or name:find("__MACOSX/", 1, true) then return false end
	local base = name:match("([^/]+)$") or name
	if base:sub(1, 1) == "." then return false end
	return imageext[(base:match("%.(%w+)$") or ""):lower()] == true
end

-- "page2" sorts before "page10": digit runs compare as numbers.
local function chunks(s)
	local out = {}
	for text, num in s:lower():gmatch("(%D*)(%d*)") do
		if text ~= "" then out[#out + 1] = text end
		if num ~= "" then out[#out + 1] = tonumber(num) end
	end
	return out
end

local function natural(a, b)
	local ca, cb = chunks(a), chunks(b)
	for i = 1, math.min(#ca, #cb) do
		local x, y = ca[i], cb[i]
		if x ~= y then
			if type(x) == type(y) then return x < y end
			return type(x) == "number" -- numbers before text
		end
	end
	return #ca < #cb
end

local function sortedpages(archive)
	local pages = {}
	for _, name in ipairs(archive.names) do
		if ispage(name) then pages[#pages + 1] = name end
	end
	table.sort(pages, natural)
	return pages
end

function cbz.load(data, filename)
	local archive, err = zip.open(data)
	if not archive then return nil, err end
	local names = sortedpages(archive)
	if #names == 0 then return nil, "no images in this comic" end

	local doc = { blocks = {}, chapters = {}, pages = {}, comic = true, imageraw = archive.raw }
	doc.title = filename:gsub("%.[^.]+$", ""):gsub("[_]+", " ")

	-- ComicInfo.xml (ComicRack metadata), when present.
	local info = archive.read("ComicInfo.xml")
	if info then
		local tree = xml.parse(info)
		local function field(tag)
			local node = xml.find(tree, tag)
			local text = node and xml.text(node):gsub("^%s+", ""):gsub("%s+$", "")
			return text ~= "" and text or nil
		end
		local series, number, title = field("series"), field("number"), field("title")
		if series then
			doc.title = series .. (number and (" #" .. number) or "") .. (title and (": " .. title) or "")
		elseif title then
			doc.title = title
		end
		doc.author = field("writer")
	end

	-- Folders inside the archive become chapters.
	local lastdir
	for i, name in ipairs(names) do
		doc.blocks[i] = { kind = "image", src = name, runs = {} }
		doc.pages[i] = { src = name, block = i }
		local dir = name:match("^(.*)/[^/]*$") or ""
		if dir ~= lastdir then
			doc.chapters[#doc.chapters + 1] = { title = dir ~= "" and (dir:match("([^/]+)$") or dir) or "Pages", block = i }
			lastdir = dir
		end
	end
	doc.cover = names[1]
	return doc
end

-- The first page's still-compressed bytes, for library thumbnails.
function cbz.coverraw(data)
	local archive = zip.open(data)
	if not archive then return nil end
	local first = sortedpages(archive)[1]
	if first then return archive.raw(first) end
end

return cbz
