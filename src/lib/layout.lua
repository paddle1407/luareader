-- Lays out document blocks into positioned lines for a given column width.
--   line = { y, h, block, items = { { font, text, x } ... } } or { y, h, block, rule = true }

local layout = {}

local floor = math.floor

local widthcache = setmetatable({}, { __mode = "k" })
local function width(font, s)
	local cache = widthcache[font]
	if not cache then
		cache = {}
		widthcache[font] = cache
	end
	local w = cache[s]
	if not w then
		w = font:getWidth(s)
		cache[s] = w
	end
	return w
end

-- Splits runs into words. A word is a list of pieces that must stay together,
-- e.g. an italic word followed by a regular comma.
local function words(block, fonts)
	local out, word, space = {}, nil, false
	local function endword()
		if word then out[#out + 1] = word end
		word = nil
	end
	for _, run in ipairs(block.runs) do
		if run.br then
			endword()
			out[#out + 1] = { br = true }
			space = false
		else
			local font = fonts[run.style] or fonts.r
			for sp, tok in run.text:gmatch("(%s*)(%S+)") do
				if sp ~= "" then
					endword()
					space = true
				end
				if not word then
					word = { pieces = {}, w = 0, space = space }
					space = false
				end
				local w = width(font, tok)
				word.pieces[#word.pieces + 1] = { font = font, text = tok, w = w }
				word.w = word.w + w
			end
			if run.text:find("%s$") then
				endword()
				space = true
			end
		end
	end
	endword()
	return out
end

-- Vertical space around block kinds, in body lines.
local before = { h = 1.4, quote = 0.5, center = 0.6, rule = 0.8 }
local after = { h = 0.9, quote = 0.5, center = 0.6, rule = 0.8 }

-- opts: fonts = { body = {r,i,b,bi}, head = {r,i,b,bi} }, width, size, lineheight, justify
function layout.build(blocks, opts)
	local lines, blockline = {}, {}
	local W = opts.width
	local em = opts.size
	local bodylh = floor(opts.fonts.body.r:getHeight() * opts.lineheight)
	local y = 0
	local prev

	for bi, block in ipairs(blocks) do
		local kind = block.kind

		if bi > 1 then
			local gap = math.max(prev and after[prev.kind] or 0, before[kind] or 0)
			if block.chapterstart then gap = 4 end
			-- Two blocks of the same kind (e.g. consecutive centered lines) sit tighter.
			if prev and prev.kind == kind and kind ~= "p" and kind ~= "rule" then gap = gap * 0.4 end
			y = y + floor(gap * bodylh)
		end
		blockline[bi] = #lines + 1

		if kind == "rule" then
			lines[#lines + 1] = { y = y, h = bodylh, block = bi, rule = true }
			y = y + bodylh
		else
			local heading = kind == "h"
			local fonts = heading and opts.fonts.head or opts.fonts.body
			local lh = heading and floor(fonts.r:getHeight() * 1.3) or bodylh
			local inset = kind == "quote" and em * 2 or 0
			local avail = W - inset * 2
			local indent = 0
			if kind == "p" and prev and prev.kind == "p" and not block.chapterstart then
				indent = em * 1.5
			end
			local align = (heading or kind == "center") and "center" or (opts.justify and "justify" or "left")
			local spacew = width(fonts.r, " ")

			local cur, curw, gaps, first = {}, 0, 0, true

			local function emit(last)
				local x0 = inset + (first and indent or 0)
				local extra = avail - (first and indent or 0) - curw
				local gapw = spacew
				if align == "center" then
					x0 = x0 + extra / 2
				elseif align == "justify" and not last and gaps > 0 and extra > 0 then
					gapw = spacew + extra / gaps
				end
				local items, x = {}, x0
				for i, word in ipairs(cur) do
					if i > 1 and word.space then x = x + gapw end
					for _, p in ipairs(word.pieces) do
						items[#items + 1] = { p.font, p.text, floor(x + 0.5) }
						x = x + p.w
					end
				end
				lines[#lines + 1] = { y = y, h = lh, block = bi, items = items }
				y = y + lh
				cur, curw, gaps, first = {}, 0, 0, false
			end

			for _, word in ipairs(words(block, fonts)) do
				if word.br then
					if #cur > 0 then emit(true) else y = y + lh end
				else
					local sp = (#cur > 0 and word.space) and spacew or 0
					if #cur > 0 and curw + sp + word.w > avail - (first and indent or 0) then
						emit(false)
						sp = 0
					end
					cur[#cur + 1] = word
					curw = curw + sp + word.w
					if sp > 0 then gaps = gaps + 1 end
				end
			end
			if #cur > 0 then emit(true) end
		end
		prev = block
	end

	return { lines = lines, blockline = blockline, height = y }
end

-- Index of the last line starting at or above y (binary search).
function layout.lineat(lines, y)
	local lo, hi = 1, #lines
	if hi == 0 then return nil end
	while lo < hi do
		local mid = floor((lo + hi + 1) / 2)
		if lines[mid].y <= y then lo = mid else hi = mid - 1 end
	end
	return lo
end

return layout
