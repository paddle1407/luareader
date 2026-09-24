-- EPUB (2 and 3) loader. Produces the common document shape:
--   { title, author, blocks = { block... }, chapters = { { title, block } ... } }
-- block = { kind = "p"|"h"|"quote"|"center"|"rule", runs = { { text, style } | { br = true } } }
-- style is one of "r", "i", "b", "bi". The book's CSS is ignored on purpose.

local zip = require("lib.zip")
local xml = require("lib.xml")

local epub = {}

local function dirname(path)
	return path:match("^(.*/)") or ""
end

-- Join a relative href onto a base directory, handling ".." and %-escapes.
local function resolve(base, href)
	href = href:gsub("#.*$", ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)
	local parts = {}
	for p in (base .. href):gmatch("[^/]+") do
		if p == ".." then parts[#parts] = nil
		elseif p ~= "." then parts[#parts + 1] = p end
	end
	return table.concat(parts, "/")
end

local function fragment(href)
	return href:match("#(.+)$")
end

local function clean(s)
	return (s:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local blocktags = {
	p = true, div = true, blockquote = true, li = true, ul = true, ol = true,
	section = true, article = true, header = true, footer = true, aside = true,
	figure = true, figcaption = true, pre = true, table = true, tr = true, td = true,
	th = true, dl = true, dt = true, dd = true, nav = true, main = true, body = true,
	center = true, address = true, h1 = true, h2 = true, h3 = true, h4 = true,
	h5 = true, h6 = true,
}
local italictags = { em = true, i = true, cite = true, dfn = true, var = true }
local boldtags = { strong = true, b = true }
local skiptags = { head = true, script = true, style = true, svg = true, math = true, title = true }

local function stylename(italic, bold)
	if italic and bold then return "bi" end
	return italic and "i" or bold and "b" or "r"
end

local function iscentered(node)
	if node.tag == "center" then return true end
	local style = (node.attrs.style or ""):lower()
	local class = (node.attrs.class or ""):lower()
	return style:find("text%-align%s*:%s*center") ~= nil or class:find("center") ~= nil
end

-- Scene breaks like "* * *" or "#" are centered rather than justified.
local function isscenebreak(block)
	if #block.runs ~= 1 or block.runs[1].br then return false end
	local t = block.runs[1].text
	return #t <= 12 and t:find("^[%*%s#~•·—%-]+$") ~= nil
end

-- Converts one XHTML body into blocks appended to doc.blocks.
-- anchors maps element ids to chapter titles found in the TOC for this file.
local function convert(body, doc, anchors)
	local blocks = doc.blocks
	local cur

	local function flush()
		if not cur then return end
		local runs = cur.runs
		-- Trim the paragraph edges.
		while #runs > 0 and not runs[1].br and runs[1].text:find("^%s*$") do table.remove(runs, 1) end
		while #runs > 0 and (runs[#runs].br or runs[#runs].text:find("^%s*$")) do table.remove(runs) end
		if #runs > 0 then
			runs[1].text = runs[1].text:gsub("^%s+", "")
			runs[#runs].text = runs[#runs].text:gsub("%s+$", "")
			if cur.kind == "p" and isscenebreak(cur) then cur.kind = "center" end
			blocks[#blocks + 1] = cur
		end
		cur = nil
	end

	local function ensure(ctx)
		if not cur then cur = { kind = ctx.kind, level = ctx.level, runs = {} } end
	end

	local function walk(node, ctx)
		if type(node) == "string" then
			local s = ctx.pre and node or node:gsub("%s+", " ")
			if s == "" or (not cur and s == " ") then return end
			ensure(ctx)
			local style = stylename(ctx.italic, ctx.bold)
			local last = cur.runs[#cur.runs]
			if last and not last.br and last.style == style then
				last.text = last.text .. s
			else
				cur.runs[#cur.runs + 1] = { text = s, style = style }
			end
			return
		end

		local tag = node.tag
		if skiptags[tag] then return end

		local id = node.attrs.id
		if id and anchors[id] then
			flush()
			doc.chapters[#doc.chapters + 1] = { title = anchors[id], block = #blocks + 1 }
			anchors[id] = nil
		end

		if tag == "br" then
			ensure(ctx)
			cur.runs[#cur.runs + 1] = { br = true }
			return
		elseif tag == "hr" then
			flush()
			blocks[#blocks + 1] = { kind = "rule", runs = {} }
			return
		end

		local sub = setmetatable({}, { __index = ctx })
		if italictags[tag] then sub.italic = not ctx.italic end
		if boldtags[tag] then sub.bold = true end
		if tag == "pre" then sub.pre = true end

		local isblock = blocktags[tag]
		if isblock then
			flush()
			local level = tag:match("^h(%d)$")
			if level then
				sub.kind, sub.level = "h", tonumber(level)
			elseif tag == "blockquote" then
				sub.kind = "quote"
			elseif iscentered(node) then
				sub.kind = "center"
			end
		end

		for _, child in ipairs(node.children) do walk(child, sub) end
		if isblock then flush() end
	end

	walk(body, { kind = "p" })
	flush()
end

-- Table of contents as an ordered list of { file, frag, title }.
local function readtoc(archive, manifest, opfdir, spinetoc)
	local entries = {}

	-- EPUB 3: XHTML nav document with epub:type="toc".
	for _, item in pairs(manifest) do
		if (item.properties or ""):find("%f[%w]nav%f[%W]") then
			local src = archive.read(item.path)
			if src then
				local tree = xml.parse(src)
				local navdir = dirname(item.path)
				for _, nav in ipairs(xml.findall(tree, "nav")) do
					if (nav.attrs.type or "toc") == "toc" then
						for _, a in ipairs(xml.findall(nav, "a")) do
							if a.attrs.href then
								entries[#entries + 1] = {
									file = resolve(navdir, a.attrs.href),
									frag = fragment(a.attrs.href),
									title = clean(xml.text(a)),
								}
							end
						end
						if #entries > 0 then return entries end
					end
				end
			end
		end
	end

	-- EPUB 2: NCX file.
	local ncx = spinetoc and manifest[spinetoc]
	if not ncx then
		for _, item in pairs(manifest) do
			if item.mediatype == "application/x-dtbncx+xml" then ncx = item end
		end
	end
	local src = ncx and archive.read(ncx.path)
	if src then
		local tree = xml.parse(src)
		local ncxdir = dirname(ncx.path)
		for _, point in ipairs(xml.findall(tree, "navpoint")) do
			local label = xml.find(point, "navlabel")
			local content = xml.find(point, "content")
			if label and content and content.attrs.src then
				entries[#entries + 1] = {
					file = resolve(ncxdir, content.attrs.src),
					frag = fragment(content.attrs.src),
					title = clean(xml.text(label)),
				}
			end
		end
	end
	return entries
end

function epub.load(data)
	local archive, err = zip.open(data)
	if not archive then return nil, err end

	local container = archive.read("META-INF/container.xml")
	if not container then return nil, "missing META-INF/container.xml" end
	local rootfile = xml.find(xml.parse(container), "rootfile")
	local opfpath = rootfile and rootfile.attrs["full-path"]
	if not opfpath then return nil, "no rootfile in container.xml" end

	local opfsrc = archive.read(opfpath)
	if not opfsrc then return nil, "missing " .. opfpath end
	local opf = xml.parse(opfsrc)
	local opfdir = dirname(opfpath)

	local doc = { blocks = {}, chapters = {} }
	local title = xml.find(opf, "title")
	local creator = xml.find(opf, "creator")
	doc.title = title and clean(xml.text(title)) or nil
	doc.author = creator and clean(xml.text(creator)) or nil

	local manifest = {}
	for _, item in ipairs(xml.findall(opf, "item")) do
		if item.attrs.id and item.attrs.href then
			manifest[item.attrs.id] = {
				path = resolve(opfdir, item.attrs.href),
				mediatype = item.attrs["media-type"],
				properties = item.attrs.properties,
			}
		end
	end

	local spine = xml.find(opf, "spine")
	if not spine then return nil, "no spine in " .. opfpath end
	local toc = readtoc(archive, manifest, opfdir, spine.attrs.toc)

	-- Group TOC entries by file: file-start chapters and in-file anchors.
	local byfile = {}
	for _, e in ipairs(toc) do
		local t = byfile[e.file] or { starts = {}, anchors = {} }
		byfile[e.file] = t
		if e.frag then
			if not t.anchors[e.frag] then t.anchors[e.frag] = e.title end
		else
			t.starts[#t.starts + 1] = e.title
		end
	end

	local section = 0
	for _, ref in ipairs(xml.findall(spine, "itemref")) do
		local item = manifest[ref.attrs.idref or ""]
		local src = item and archive.read(item.path)
		if src then
			local tree = xml.parse(src)
			local body = xml.find(tree, "body") or tree
			local first = #doc.blocks + 1
			local info = byfile[item.path] or { starts = {}, anchors = {} }

			local nchapters = #doc.chapters
			if #toc == 0 then
				-- No TOC: every spine file is a chapter.
				section = section + 1
				local h = xml.find(body, "h1") or xml.find(body, "h2") or xml.find(body, "h3")
				local htitle = h and clean(xml.text(h)) or ""
				doc.chapters[#doc.chapters + 1] = {
					title = htitle ~= "" and htitle or ("Section " .. section),
					block = first,
				}
			elseif info.starts[1] then
				doc.chapters[#doc.chapters + 1] = { title = info.starts[1], block = first }
			end

			convert(body, doc, info.anchors)

			-- Anchors that never matched an element point at the file start.
			for _, t in pairs(info.anchors) do
				table.insert(doc.chapters, nchapters + 1, { title = t, block = first })
			end
			info.anchors = {}

			if doc.blocks[first] then doc.blocks[first].chapterstart = true end
		end
	end

	-- Drop chapters that point past the end or duplicate an earlier position.
	table.sort(doc.chapters, function(a, b) return a.block < b.block end)
	local chapters = {}
	for _, c in ipairs(doc.chapters) do
		local prev = chapters[#chapters]
		if c.block <= #doc.blocks and not (prev and prev.block == c.block) then
			chapters[#chapters + 1] = c
		end
	end
	doc.chapters = chapters

	if #doc.blocks == 0 then return nil, "no readable text found" end
	return doc
end

return epub
