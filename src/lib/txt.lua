-- Plain-text loader. Produces the same document shape as lib/epub.lua.

local text = require("lib.text")

local txt = {}

local function isheading(p)
	if #p > 70 or p:find("\n") then return false end
	local l = p:lower()
	return l:find("^chapter%f[%W]") or l:find("^prologue%f[%W]") or l:find("^epilogue%f[%W]")
		or l:find("^part%s+[%w]+") or l:find("^book%s+[%w]+$")
		or p:find("^[IVXLC]+%.?$") or p:find("^%d+%.?$")
end

-- _underscored_ text is the usual plain-text (and Project Gutenberg) italics.
local function runs(p)
	local _, count = p:gsub("_", "")
	if count < 2 or count % 2 ~= 0 then return { { text = p, style = "r" } } end
	local out, italic = {}, false
	for part in (p .. "_"):gmatch("(.-)_") do
		if part ~= "" then out[#out + 1] = { text = part, style = italic and "i" or "r" } end
		italic = not italic
	end
	return out
end

function txt.load(data, filename)
	local s = text.toutf8(data):gsub("\r\n?", "\n")

	-- Project Gutenberg metadata and boilerplate.
	local title = s:match("\nTitle:%s*([^\n]+)") or s:match("^Title:%s*([^\n]+)")
	local author = s:match("\nAuthor:%s*([^\n]+)")
	local start = s:find("%*%*%* ?START OF[^\n]*\n")
	if start then s = s:sub(s:find("\n", start) + 1) end
	local stop = s:find("%*%*%* ?END OF")
	if stop then s = s:sub(1, stop - 1) end

	local paragraphs = {}
	if s:find("\n[ \t]*\n") then
		-- Blank-line separated paragraphs; single newlines are hard wraps.
		for chunk in (s .. "\n\n"):gmatch("(.-)\n[ \t]*\n") do
			local lines = {}
			for line in chunk:gmatch("[^\n]+") do lines[#lines + 1] = line end
			local p = table.concat(lines, " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
			if p ~= "" then paragraphs[#paragraphs + 1] = p end
		end
	else
		for line in s:gmatch("[^\n]+") do
			local p = line:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
			if p ~= "" then paragraphs[#paragraphs + 1] = p end
		end
	end

	local doc = { blocks = {}, chapters = {} }
	doc.title = title or text.toutf8(filename):gsub("%.[^.]+$", ""):gsub("[_%-]+", " ")
	doc.author = author

	for _, p in ipairs(paragraphs) do
		local block = { kind = "p", runs = runs(p) }
		if isheading(p) then
			block.kind = "h"
			block.chapterstart = true
			doc.chapters[#doc.chapters + 1] = { title = p, block = #doc.blocks + 1 }
		elseif #p <= 12 and p:find("^[%*%s#~•·—%-]+$") then
			block.kind = "center"
		end
		doc.blocks[#doc.blocks + 1] = block
	end

	if #doc.blocks == 0 then return nil, "file is empty" end
	if not doc.chapters[1] or doc.chapters[1].block > 1 then
		table.insert(doc.chapters, 1, { title = "Beginning", block = 1 })
	end
	return doc
end

return txt
