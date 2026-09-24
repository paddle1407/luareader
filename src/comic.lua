-- Comic view: one page (or a two-page spread) at a time, fitted to the window.
--
-- book.comic = { groups, view, zoom, panx, pany, scrolly, scrolltarget, slide }
--   groups: the page indexes shown together; view: the current group.
-- Settings used: comicdir ("ltr" | "rtl"), comicfit ("page" | "width"), comicspread.

local comic = {}

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local PAD, FOOT = 10, 30
local SLIDE = 0.28 -- seconds per page slide
local ctx -- { theme(), color(c, a), fonts, settings(), image(src) }

function comic.init(c) ctx = c end

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end
local function ease(p) return p < 0.5 and 4 * p * p * p or 1 - (-2 * p + 2) ^ 3 / 2 end
local function rtl() return ctx.settings().comicdir == "rtl" end
local function fitwidth() return ctx.settings().comicfit == "width" end

local function area()
	local W, H = lg.getDimensions()
	return PAD, PAD, W - PAD * 2, H - PAD - FOOT
end

-- The cover alone, then pairs, when spreads are on and the window is wide.
local function makegroups(n)
	local W, H = lg.getDimensions()
	local g = {}
	if ctx.settings().comicspread and W > H * 1.15 and n > 2 then
		g[1] = { 1 }
		for i = 2, n, 2 do g[#g + 1] = i < n and { i, i + 1 } or { i } end
	else
		for i = 1, n do g[i] = { i } end
	end
	return g
end

local function groupof(c, page)
	for gi, g in ipairs(c.groups) do
		if page >= g[1] and page <= g[#g] then return gi end
	end
	return 1
end

local function texture(book, i)
	local p = book.doc.pages[i]
	return p and ctx.image(p.src)
end

-- Pages of a group side by side at one common height, in reading order.
-- Pages still loading are assumed to be 2:3 until their texture arrives.
local function layoutgroup(book, gi)
	local _, _, aw, ah = area()
	local pages = {}
	local ratio = 0
	for _, i in ipairs(book.comic.groups[gi]) do
		local t = texture(book, i)
		local r = t and t:getWidth() / t:getHeight() or 2 / 3
		pages[#pages + 1] = { t = t, r = r }
		ratio = ratio + r
	end
	if rtl() then
		for i = 1, floor(#pages / 2) do pages[i], pages[#pages + 1 - i] = pages[#pages + 1 - i], pages[i] end
	end
	local h = fitwidth() and aw / ratio or min(ah, aw / ratio)
	local x = 0
	for _, p in ipairs(pages) do
		p.x, p.w, p.h = x, h * p.r, h
		x = x + p.w
	end
	return pages, x, h
end

local function maxscroll(book)
	local _, _, _, ah = area()
	local _, _, h = layoutgroup(book, book.comic.view)
	return max(0, h - ah)
end

local function clamppan(book)
	local c = book.comic
	local _, _, aw, ah = area()
	local _, w, h = layoutgroup(book, c.view)
	local mx = max(0, (w * c.zoom - aw) / 2)
	local my = max(0, (min(h, ah) * c.zoom - ah) / 2)
	c.panx, c.pany = clamp(c.panx, -mx, mx), clamp(c.pany, -my, my)
end

function comic.open(book, page)
	local c = { zoom = 1, panx = 0, pany = 0, scrolly = 0, scrolltarget = 0 }
	book.comic = c
	c.groups = makegroups(#book.doc.pages)
	c.view = groupof(c, clamp(page or 1, 1, #book.doc.pages))
end

-- After a resize or a settings change: same page, new grouping.
function comic.regroup(book)
	local c = book.comic
	local page = c.groups[c.view][1]
	c.groups = makegroups(#book.doc.pages)
	c.view = groupof(c, page)
	c.slide, c.zoom, c.panx, c.pany = nil, 1, 0, 0
end

function comic.page(book) return book.comic.groups[book.comic.view][1] end

function comic.progress(book)
	local n = #book.doc.pages
	return n > 1 and (comic.page(book) - 1) / (n - 1) or 1
end

-- Moves to group gi; the new page slides in from the side it lies on.
local function go(book, gi, backwards)
	local c = book.comic
	gi = clamp(gi, 1, #c.groups)
	if gi == c.view then return end
	local forward = gi > c.view
	c.slide = { from = c.view, t = 0, dir = (forward ~= rtl()) and 1 or -1 }
	c.view = gi
	c.zoom, c.panx, c.pany = 1, 0, 0
	c.scrolly, c.scrolltarget = 0, 0
	c.tobottom = backwards and fitwidth() -- coming back lands on the page's end
end

function comic.gotopage(book, page)
	local c = book.comic
	go(book, groupof(c, page), groupof(c, page) < c.view)
end

function comic.next(book) go(book, book.comic.view + 1) end
function comic.prev(book) go(book, book.comic.view - 1, true) end

-- Arrow keys and click zones follow the page order on screen.
function comic.left(book) if rtl() then comic.next(book) else comic.prev(book) end end
function comic.right(book) if rtl() then comic.prev(book) else comic.next(book) end end

-- Space / Page Down: in fit-width mode, scroll through a tall page first.
function comic.forward(book)
	local c = book.comic
	local _, _, _, ah = area()
	if fitwidth() and c.zoom == 1 and c.scrolltarget < maxscroll(book) - 1 then
		c.scrolltarget = min(maxscroll(book), c.scrolltarget + ah * 0.85)
	else
		comic.next(book)
	end
end

function comic.backward(book)
	local c = book.comic
	local _, _, _, ah = area()
	if fitwidth() and c.zoom == 1 and c.scrolltarget > 1 then
		c.scrolltarget = max(0, c.scrolltarget - ah * 0.85)
	else
		comic.prev(book)
	end
end

-- Wheel / arrow scrolling within a tall page (fit width) or a zoomed one.
function comic.scroll(book, dy)
	local c = book.comic
	if c.zoom > 1 then
		c.pany = c.pany - dy
		clamppan(book)
	else
		c.scrolltarget = clamp(c.scrolltarget + dy, 0, maxscroll(book))
	end
end

function comic.canscroll(book)
	return book.comic.zoom > 1 or maxscroll(book) > 0
end

function comic.drag(book, dx, dy)
	local c = book.comic
	if c.zoom > 1 then
		c.panx, c.pany = c.panx + dx, c.pany + dy
		clamppan(book)
	else
		c.scrolltarget = clamp(c.scrolltarget - dy, 0, maxscroll(book))
		c.scrolly = c.scrolltarget
	end
end

-- Zooms by factor f, keeping the point under (mx, my) in place.
function comic.zoom(book, f, mx, my)
	local c = book.comic
	local ax, ay, aw, ah = area()
	local cx, cy = ax + aw / 2, ay + ah / 2
	mx, my = mx or cx, my or cy
	local old = c.zoom
	c.zoom = clamp(old * f, 1, 5)
	local k = c.zoom / old
	c.panx = (mx - cx) * (1 - k) + k * c.panx
	c.pany = (my - cy) * (1 - k) + k * c.pany
	if c.zoom <= 1.001 then c.zoom, c.panx, c.pany = 1, 0, 0 end
	clamppan(book)
end

function comic.resetzoom(book)
	local c = book.comic
	c.zoom, c.panx, c.pany = 1, 0, 0
end

-- Returns true while something is moving.
function comic.update(book, dt)
	local c = book.comic
	local busy = false
	if c.slide then
		c.slide.t = c.slide.t + dt / SLIDE
		if c.slide.t >= 1 then c.slide = nil else busy = true end
	end

	-- Coming back into a tall page starts at its end, once its size is known.
	if c.tobottom then
		local ready = true
		for _, i in ipairs(c.groups[c.view]) do
			if not texture(book, i) then ready = false end
		end
		if ready then
			c.scrolly = maxscroll(book)
			c.scrolltarget = c.scrolly
			c.tobottom = false
		end
	end

	c.scrolltarget = clamp(c.scrolltarget, 0, maxscroll(book))
	local d = c.scrolltarget - c.scrolly
	if abs(d) > 0.5 then
		c.scrolly = c.scrolly + d * min(1, dt * 14)
		busy = true
	else
		c.scrolly = c.scrolltarget
	end

	-- Keep the next few pages (and the previous one) decoded ahead of time.
	for gi = c.view - 1, c.view + 3 do
		local g = c.groups[gi]
		if g then
			for _, i in ipairs(g) do texture(book, i) end
		end
	end
	return busy
end

local function drawgroup(book, gi, ox, current)
	local c = book.comic
	local th = ctx.theme()
	local ax, ay, aw, ah = area()
	local pages, w, h = layoutgroup(book, gi)
	local x0 = ax + (aw - w) / 2
	local y0 = h <= ah and ay + (ah - h) / 2 or ay - (current and c.scrolly or 0)

	lg.push()
	lg.translate(ox, 0)
	if current and c.zoom ~= 1 then
		local cx, cy = ax + aw / 2, ay + ah / 2
		lg.translate(cx + c.panx, cy + c.pany)
		lg.scale(c.zoom)
		lg.translate(-cx, -cy)
	end
	for _, p in ipairs(pages) do
		if p.t then
			local k = th.image or 1
			lg.setColor(k, k, k)
			lg.draw(p.t, floor(x0 + p.x), floor(y0), 0, p.w / p.t:getWidth(), p.h / p.t:getHeight())
		else
			ctx.color(th.fg, 0.05)
			lg.rectangle("fill", x0 + p.x, y0, p.w, p.h, 4, 4)
		end
	end
	lg.pop()
end

function comic.draw(book)
	local c = book.comic
	local th = ctx.theme()
	local W, H = lg.getDimensions()

	lg.setScissor(0, 0, W, H - FOOT)
	if c.slide then
		local e = ease(c.slide.t)
		drawgroup(book, c.slide.from, -c.slide.dir * W * e, false)
		drawgroup(book, c.view, c.slide.dir * W * (1 - e), true)
	else
		drawgroup(book, c.view, 0, true)
	end
	lg.setScissor()

	-- Page counter and a thin progress line.
	local g = c.groups[c.view]
	local n = #book.doc.pages
	local label = #g > 1 and ("%d–%d / %d"):format(g[1], g[#g], n) or ("%d / %d"):format(g[1], n)
	if c.zoom > 1 then label = label .. ("  ·  %d%%"):format(floor(c.zoom * 100 + 0.5)) end
	lg.setFont(ctx.fonts.ui)
	ctx.color(th.dim)
	lg.printf(label, 0, H - FOOT + 6, W, "center")
	local bw = min(240, W - 48)
	local bx = floor((W - bw) / 2)
	local p = comic.progress(book)
	if rtl() then p = 1 - p end
	ctx.color(th.dim, 0.25)
	lg.rectangle("fill", bx, H - 5, bw, 2)
	ctx.color(th.accent, 0.8)
	if rtl() then
		lg.rectangle("fill", bx + floor(bw * p), H - 5, bw - floor(bw * p), 2)
	else
		lg.rectangle("fill", bx, H - 5, floor(bw * p), 2)
	end
end

return comic
