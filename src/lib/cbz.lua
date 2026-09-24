-- CBZ (zipped comic) loader. Produces the common document shape with every
-- block an image, plus doc.comic = true and doc.pages = { { src, block } ... }.
-- Nothing is decoded here, so even huge comics open instantly.
-- Loaders take an archive from lib/zip; doc.close() releases it.

local xml = require("lib.xml")
local text = require("lib.text")

local cbz = {}

-- What LÖVE can decode, and common page formats it can't (reported, not shown).
local imageext = { png = true, jpg = true, jpeg = true, bmp = true }
local unsupported = { webp = true, gif = true, avif = true, jxl = true }

-- "page", "unsupported" or nil for a zip entry.
local function pagekind(name)
	if name:sub(-1) == "/" or name:find("__MACOSX/", 1, true) then return nil end
	local base = name:match("([^/]+)$") or name
	if base:sub(1, 1) == "." then return nil end
	local ext = (base:match("%.(%w+)$") or ""):lower()
	if imageext[ext] then return "page" end
	if unsupported[ext] then return "unsupported" end
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
	local pages, skipped = {}, 0
	for _, name in ipairs(archive.names) do
		local kind = pagekind(name)
		if kind == "page" then pages[#pages + 1] = name end
		if kind == "unsupported" then skipped = skipped + 1 end
	end
	table.sort(pages, natural)
	return pages, skipped
end

function cbz.load(archive, filename)
	local names, skipped = sortedpages(archive)
	if #names == 0 then
		if skipped > 0 then return nil, "its pages are WebP/GIF, which luareader can't show yet" end
		return nil, "no images in this comic"
	end

	local doc = { blocks = {}, chapters = {}, pages = {}, comic = true,
		imageraw = archive.raw, close = archive.close }
	if skipped > 0 then
		doc.warning = ("%d WebP/GIF page%s skipped (not supported yet)"):format(skipped, skipped == 1 and "" or "s")
	end
	doc.title = text.toutf8(filename):gsub("%.[^.]+$", ""):gsub("[_]+", " ")

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
			local title = dir ~= "" and (dir:match("([^/]+)$") or dir) or "Pages"
			doc.chapters[#doc.chapters + 1] = { title = text.toutf8(title), block = i }
			lastdir = dir
		end
	end
	doc.cover = names[1]
	return doc
end

-- The first page's still-compressed bytes, for library thumbnails.
function cbz.coverraw(archive)
	local first = sortedpages(archive)[1]
	if first then return archive.raw(first) end
end

return cbz
