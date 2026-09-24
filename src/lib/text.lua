-- Text helpers: UTF-8 encoding/validation, legacy encoding fallback, entities.

local text = {}

local char, byte, floor = string.char, string.byte, math.floor

function text.utf8char(cp)
	-- Surrogates aren't characters on their own; LÖVE rejects them.
	if cp >= 0xD800 and cp <= 0xDFFF then return "\239\191\189" end
	if cp < 0x80 then
		return char(cp)
	elseif cp < 0x800 then
		return char(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
	elseif cp < 0x10000 then
		return char(0xE0 + floor(cp / 0x1000), 0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	elseif cp < 0x110000 then
		return char(0xF0 + floor(cp / 0x40000), 0x80 + floor(cp / 0x1000) % 0x40,
			0x80 + floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return "\239\191\189" -- U+FFFD
end

-- Length of the valid UTF-8 sequence starting at byte i, or nil if it's
-- invalid. Strict like LÖVE's decoder: no overlongs, surrogates or > U+10FFFF.
local function seqlen(s, i)
	local c = byte(s, i)
	if c < 0x80 then return 1 end
	local len, lo, hi
	if c >= 0xC2 and c <= 0xDF then len, lo, hi = 2, 0x80, 0xBF
	elseif c == 0xE0 then len, lo, hi = 3, 0xA0, 0xBF
	elseif c == 0xED then len, lo, hi = 3, 0x80, 0x9F
	elseif c >= 0xE1 and c <= 0xEF then len, lo, hi = 3, 0x80, 0xBF
	elseif c == 0xF0 then len, lo, hi = 4, 0x90, 0xBF
	elseif c >= 0xF1 and c <= 0xF3 then len, lo, hi = 4, 0x80, 0xBF
	elseif c == 0xF4 then len, lo, hi = 4, 0x80, 0x8F
	else return nil end
	local c2 = byte(s, i + 1)
	if not c2 or c2 < lo or c2 > hi then return nil end
	for j = i + 2, i + len - 1 do
		local cc = byte(s, j)
		if not cc or cc < 0x80 or cc > 0xBF then return nil end
	end
	return len
end

function text.isutf8(s)
	local i, n = 1, #s
	while i <= n do
		local len = seqlen(s, i)
		if not len then return false end
		i = i + len
	end
	return true
end

-- Windows-1252 bytes 0x80-0x9F (smart quotes, dashes, ...), rest is Latin-1.
local cp1252 = {
	[0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026,
	[0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160,
	[0x8B] = 0x2039, [0x8C] = 0x0152, [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019,
	[0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
	[0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A, [0x9C] = 0x0153,
	[0x9E] = 0x017E, [0x9F] = 0x0178,
}

-- Returns valid UTF-8 and strips a BOM. Only the bytes that aren't valid UTF-8
-- are converted (as Windows-1252), so a legacy file converts completely while a
-- UTF-8 file with a stray byte keeps the rest of its text intact.
function text.toutf8(s)
	s = s:gsub("^\239\187\191", "")
	if text.isutf8(s) then return s end
	local out, i, run, n = {}, 1, 1, #s
	while i <= n do
		local len = seqlen(s, i)
		if len then
			i = i + len
		else
			if i > run then out[#out + 1] = s:sub(run, i - 1) end
			local b = byte(s, i)
			out[#out + 1] = text.utf8char(cp1252[b] or b)
			i = i + 1
			run = i
		end
	end
	if run <= n then out[#out + 1] = s:sub(run) end
	return table.concat(out)
end

local entities = {
	amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
	mdash = "—", ndash = "–", hellip = "…", lsquo = "‘", rsquo = "’",
	ldquo = "“", rdquo = "”", laquo = "«", raquo = "»", copy = "©", reg = "®",
	trade = "™", shy = "", thinsp = " ", ensp = " ", emsp = " ", middot = "·",
	bull = "•", deg = "°", eacute = "é", egrave = "è", aacute = "á", agrave = "à",
	iacute = "í", oacute = "ó", uacute = "ú", ntilde = "ñ", ccedil = "ç",
	auml = "ä", ouml = "ö", uuml = "ü", szlig = "ß", times = "×", dagger = "†",
}

function text.decodeentities(s)
	return (s:gsub("&(#?[xX]?)(%w+);", function(kind, v)
		if kind == "#" then
			return text.utf8char(tonumber(v) or 0xFFFD)
		elseif kind == "#x" or kind == "#X" then
			return text.utf8char(tonumber(v, 16) or 0xFFFD)
		elseif kind == "" then
			return entities[v]
		end
	end))
end

return text
