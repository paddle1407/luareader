-- luareader: a small, pretty novel reader for .txt and .epub files.

local layout = require("lib.layout")
local zip = require("lib.zip")
local text = require("lib.text")
local epub = require("lib.epub")
local txt = require("lib.txt")
local cbz = require("lib.cbz")
local comic = require("comic")
local store = require("lib.store")
local keys = require("lib.keys")
local ui = require("lib.ui")
local images = require("lib.images")

local lg = love.graphics
local floor, min, max, abs = math.floor, math.min, math.max, math.abs

local MARGIN_TOP, MARGIN_BOTTOM = 64, 60
local FADE = 18 -- px of soft fade below the page's bottom edge

local function hex(s)
	return { tonumber(s:sub(2, 3), 16) / 255, tonumber(s:sub(4, 5), 16) / 255, tonumber(s:sub(6, 7), 16) / 255, 1 }
end

-- Gruvbox, with its pink (purple) as the accent.
local themes = {
	dark = { bg = hex("#282828"), fg = hex("#ebdbb2"), dim = hex("#928374"), accent = hex("#d3869b"), panel = hex("#3c3836"), image = 0.88 },
	hard = { bg = hex("#1d2021"), fg = hex("#ebdbb2"), dim = hex("#928374"), accent = hex("#d3869b"), panel = hex("#282828"), image = 0.85 },
	light = { bg = hex("#fbf1c7"), fg = hex("#3c3836"), dim = hex("#928374"), accent = hex("#b16286"), panel = hex("#f9f5d7"), image = 1 },
}
local themeorder = { "dark", "hard", "light" }

-- Font families in src/fonts, each with Regular/Italic/Bold/BoldItalic files.
local families = {
	{ id = "notoserif", label = "Noto Serif", file = "NotoSerif" },
	{ id = "dejavuserif", label = "DejaVu Serif", file = "DejaVuSerif" },
	{ id = "notosans", label = "Noto Sans", file = "NotoSans" },
}

local defaults = {
	settings = {
		size = 20, width = 680, lineheight = 1.55, theme = "dark", font = "notoserif", justify = true,
		wpm = 250, fastwpm = 350, automode = "lines", guide = true, guidepos = 35, guidedim = true,
		comicdir = "ltr", comicfit = "page", comicspread = true,
		keys = {},
	},
	books = {},
}

local state         -- persisted: settings + per-book positions
local fonts = {}
local keymap        -- key -> action id, rebuilt when bindings change
local book          -- open book: { path, doc, laid, colw, scroll, target }
local screen = "library"
local overlay       -- nil | "toc" | "settings"
local toast         -- { text, t }
-- Auto-scroll: on/paused, the line held under the guide (line-by-line style),
-- time left on it, the current eased move, and the guide band's height.
local auto = { on = false, paused = false, line = nil, word = 1, timer = 0, anim = nil, bandh = 0 }
-- Fast reader: one word at a time in the middle of the screen.
local fast = { on = false, paused = false, i = 1, timer = 0 }
local W, H
local libsel, libscroll = 1, 0
local tocsel, tocscroll = 1, 0
local settingsui = { tab = "reading", scroll = 0, capture = nil, rect = nil }
-- Library cover thumbnails: loaded thumbnail textures, books waiting for a
-- cover scan (one per frame), and cover images waiting on the decoder.
local thumbs = {}
local coverqueue, coverqueued = {}, {}
local coverwait = {}
local comicbusy = false -- a page slide or scroll is running in the comic view
local settle = 0 -- seconds to keep drawing after window changes (see syncsize)
local debuglog = os.getenv("LUAREADER_DEBUG") ~= nil
local drag -- mouse drag in the comic view: { x, y, moved }

local function theme() return themes[state.settings.theme] or themes.dark end

local function color(c, a) lg.setColor(c[1], c[2], c[3], a or c[4]) end

local function clamp(v, lo, hi) return max(lo, min(hi, v)) end

local function showtoast(text) toast = { text = text, t = 1.6 } end

local function save() store.save(state) end

-- Fonts ----------------------------------------------------------------------

local function font(name, size)
	return lg.newFont("fonts/" .. name .. ".ttf", size, "light")
end

local function family(id)
	for _, f in ipairs(families) do
		if f.id == id then return f end
	end
	return families[1]
end

local function loadfonts()
	local s = state.settings.size
	local hs = floor(s * 1.45 + 0.5)
	local f = family(state.settings.font).file
	fonts.body = {
		r = font(f .. "-Regular", s), i = font(f .. "-Italic", s),
		b = font(f .. "-Bold", s), bi = font(f .. "-BoldItalic", s),
	}
	fonts.head = {
		r = font(f .. "-Regular", hs), i = font(f .. "-Italic", hs),
		b = font(f .. "-Bold", hs), bi = font(f .. "-BoldItalic", hs),
	}
	fonts.fast = font(f .. "-Regular", floor(s * 2.4 + 0.5))
	if not fonts.ui then
		fonts.ui = font("NotoSans-Regular", 13)
		fonts.label = font("NotoSans-Regular", 15)
		fonts.item = font("NotoSerif-Regular", 18)
		fonts.logo = font("NotoSerif-Italic", 46)
		fonts.preview = {}
		for _, fam in ipairs(families) do fonts.preview[fam.id] = font(fam.file .. "-Regular", 14) end
	end
	ui.fonts = fonts
end

local function ellipsize(f, s, w)
	if f:getWidth(s) <= w then return s end
	while #s > 0 and f:getWidth(s .. "…") > w do
		s = s:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
	end
	return s .. "…"
end

-- Reader geometry and navigation ------------------------------------------------

-- Kept positive even if a tiling layout squeezes the window below its minimum
-- size: with a zero-height page, page turns would stop making progress.
local function viewh() return max(60, H - MARGIN_TOP - MARGIN_BOTTOM) end

local function bodylh() return floor(fonts.body.r:getHeight() * state.settings.lineheight) end

-- The last page's start; set by relayout() so pages never run past the end.
local function maxscroll()
	return book.lastpage or 0
end

local function settarget(y, instant)
	book.target = clamp(y, 0, maxscroll())
	if instant then book.scroll = book.target end
end

-- Current reading position as a block index plus fraction through that block,
-- so it survives relayouts (font size, width, window size).
local function position()
	local laid = book.laid
	local i = layout.lineat(laid.lines, book.target + 1)
	if not i then return 1, 0 end
	local b = laid.lines[i].block
	local first = laid.blockline[b]
	local last = (laid.blockline[b + 1] or #laid.lines + 1) - 1
	return b, (i - first) / max(1, last - first + 1)
end

local function gotoblock(b, frac, instant)
	local laid = book.laid
	b = clamp(b, 1, #book.doc.blocks)
	local first = laid.blockline[b]
	local last = (laid.blockline[b + 1] or #laid.lines + 1) - 1
	local i = clamp(first + floor((frac or 0) * max(1, last - first + 1)), 1, #laid.lines)
	settarget(laid.lines[i].y, instant)
end

local function progress()
	if maxscroll() <= 0 then return 1 end
	return clamp(book.target / maxscroll(), 0, 1)
end

local function chapterindex()
	local b = book.doc.comic and book.doc.pages[comic.page(book)].block or position()
	local idx = 1
	for i, c in ipairs(book.doc.chapters) do
		if c.block <= b then idx = i else break end
	end
	return idx
end

-- Y of the first chapter starting below y, and of the chapter containing y.
local function nextchaptery(y)
	for _, cy in ipairs(book.chapterys) do
		if cy > y + 0.5 then return cy end
	end
end

local function chapterstarty(y)
	local found = 0
	for _, cy in ipairs(book.chapterys) do
		if cy <= y + 0.5 then found = cy else break end
	end
	return found
end

-- Start of the page after the one starting at y, or nil at the end of the book.
-- Pages end early when a new chapter begins, so every chapter starts a page.
local function pageafter(y)
	local lines = book.laid.lines
	local bottom = y + viewh()
	local cy = nextchaptery(y)
	if cy and cy <= bottom then return cy end
	local i = layout.lineat(lines, bottom)
	if lines[i].y + lines[i].h <= bottom + 0.5 then i = i + 1 end
	if not lines[i] then return nil end
	if lines[i].y > y + 0.5 then return lines[i].y end
	return y + viewh() -- a single line taller than the window
end

local function relayout()
	if not book then return end
	if book.doc.comic then return comic.regroup(book) end
	auto.line, auto.anim = nil, nil
	local b, frac
	if book.laid then b, frac = position() end
	book.colw = max(120, min(state.settings.width, W - 48))
	book.laid = layout.build(book.doc.blocks, {
		fonts = fonts, width = book.colw, size = state.settings.size,
		lineheight = state.settings.lineheight, justify = state.settings.justify,
		maxh = floor(viewh() * 0.92),
	})

	local laid = book.laid
	book.chapterys = {}
	for _, c in ipairs(book.doc.chapters) do
		local line = laid.lines[laid.blockline[c.block] or 0]
		local ys = book.chapterys
		if line and line.y > (ys[#ys] or -1) then ys[#ys + 1] = line.y end
	end

	local y = book.chapterys[#book.chapterys] or 0
	for _ = 1, #laid.lines do
		local n = pageafter(y)
		if not n then break end
		y = n
	end
	book.lastpage = y

	-- Average words per body line, for the auto-scroll words-per-minute estimate.
	local words, count = 0, 0
	for _, line in ipairs(laid.lines) do
		if line.items and #line.items > 3 then
			words, count = words + #line.items, count + 1
		end
	end
	book.wordsperline = count > 0 and words / count or 10

	if b then gotoblock(b, frac, true) end
end

local function nextpage()
	local n = pageafter(book.target)
	settarget(n or maxscroll())
end

-- Walks forward from the current chapter's start, so going back lands on the
-- same page boundaries as going forward (and on a chapter's last page).
local function prevpage()
	local t = book.target
	local y = chapterstarty(t - 1)
	while true do
		local n = pageafter(y)
		if not n or n >= t - 0.5 then break end
		y = n
	end
	settarget(y)
end

local function scrolllines(n)
	local lines = book.laid.lines
	local lh = bodylh()
	local i = layout.lineat(lines, book.target + n * lh + lh / 2)
	if n > 0 and lines[i].y <= book.target then
		i = min(#lines, i + 1)
	elseif n < 0 and lines[i].y >= book.target then
		i = layout.lineat(lines, book.target - 1)
	end
	local y = lines[i].y
	-- Pause at chapter starts instead of scrolling straight past them.
	local ahead, here = nextchaptery(book.target), chapterstarty(book.target)
	if n > 0 and ahead and y > ahead then y = ahead end
	if n < 0 and book.target > here + 0.5 and y < here then y = here end
	settarget(y)
end

local function gotochapter(i)
	local c = book.doc.chapters[i]
	if not c then return end
	if book.doc.comic then
		for p, page in ipairs(book.doc.pages) do
			if page.block >= c.block then return comic.gotopage(book, p) end
		end
	else
		gotoblock(c.block, 0)
	end
end

local function prevchapter()
	local i = chapterindex()
	local c = book.doc.chapters[i]
	-- Like a media player: first go back to the start of this chapter.
	local into
	if c and book.doc.comic then
		into = book.doc.pages[comic.page(book)].block > c.block
	elseif c then
		into = book.target > book.laid.lines[book.laid.blockline[c.block]].y + 1
	end
	if into then
		gotochapter(i)
	else
		gotochapter(i - 1)
	end
end

-- Books -------------------------------------------------------------------------

local function savepos()
	if not book then return end
	local entry = state.books[book.path]
	if book.doc.comic then
		entry.page = comic.page(book)
		entry.progress = comic.progress(book)
		return
	end
	entry.block, entry.frac = position()
	entry.progress = progress()
end

local function persist()
	savepos()
	save()
end

local function readfile(path)
	local f, err = io.open(path, "rb")
	if not f then return nil, err end
	local data = f:read("*a")
	f:close()
	return data
end

local function bookimage(src)
	return images.get(book.path .. "|" .. src, function() return book.doc.imageraw(src) end)
end

local function thumbname(p)
	return "covers/" .. love.data.encode("string", "hex", love.data.hash("md5", p)) .. ".png"
end

-- Starts decoding a book's cover; updatecovers() turns it into a thumbnail.
local function makecover(p, loader)
	local key = "cover|" .. p
	coverwait[key] = p
	images.get(key, loader, true)
end

-- Renders decoded covers into small thumbnails in the save dir, and scans
-- at most one library book per frame for a cover it doesn't have yet.
local function updatecovers()
	for key, p in pairs(coverwait) do
		local st, img = images.status(key)
		local entry = state.books[p]
		if st == "ready" and entry then
			local tw, th = 80, 116
			local canvas = lg.newCanvas(tw, th)
			lg.push("all")
			lg.setCanvas(canvas)
			lg.clear(0, 0, 0, 0)
			lg.origin()
			lg.setColor(1, 1, 1)
			local iw, ih = img:getDimensions()
			local sc = max(tw / iw, th / ih)
			lg.draw(img, tw / 2, th / 2, 0, sc, sc, iw / 2, ih / 2)
			lg.pop()
			love.filesystem.createDirectory("covers")
			local name = thumbname(p)
			canvas:newImageData():encode("png", name)
			canvas:release()
			thumbs[name] = nil
			entry.cover = name
			save()
		elseif st ~= "pending" and entry then
			entry.cover = false
		end
		if st ~= "pending" then
			images.drop(key)
			coverwait[key] = nil
		end
	end

	local p = table.remove(coverqueue, 1)
	local entry = p and state.books[p]
	if entry and entry.cover == nil then
		local raw, method
		local kind = p:lower():match("%.(%w+)$")
		if kind == "epub" or kind == "cbz" then
			local archive = zip.openfile(p)
			if archive then
				local ok, r, m = pcall(kind == "epub" and epub.coverraw or cbz.coverraw, archive)
				if ok then raw, method = r, m end
				archive.close()
			end
		end
		if raw then makecover(p, function() return raw, method end) else entry.cover = false end
	end
end

local function openbook(path)
	local ext = (path:match("%.(%w+)$") or ""):lower()
	local loaders = { epub = epub.load, cbz = cbz.load, txt = txt.load }
	if not loaders[ext] then
		showtoast("Can only open .txt, .epub and .cbz files")
		return
	end
	local filename = path:match("([^/]+)$") or path
	local doc, err, source
	if ext == "txt" then
		source, err = readfile(path)
	else
		-- EPUB and CBZ are read from disk as needed, not loaded whole.
		source, err = zip.openfile(path)
	end
	if source then
		local ok, res, lerr = pcall(loaders[ext], source, filename)
		if not ok then err = res elseif not res then err = lerr else doc = res end
		if not doc and ext ~= "txt" then source.close() end
	end
	if not doc then
		showtoast("Could not open book: " .. tostring(err))
		return
	end

	persist()
	if book and book.doc.close then book.doc.close() end
	images.clear()
	book = { path = path, doc = doc, scroll = 0, target = 0 }
	auto.on, auto.paused, fast.on = false, false, false

	local entry = state.books[path] or {}
	state.books[path] = entry
	entry.title = doc.title or text.toutf8(filename)
	entry.author = doc.author
	entry.opened = os.time()
	if doc.comic then
		comic.open(book, entry.page)
	else
		relayout()
		if entry.block then gotoblock(entry.block, entry.frac, true) end
	end
	-- Also retries books marked "no cover", in case a cover was lost earlier.
	if type(entry.cover) ~= "string" and doc.imageraw then
		local src = doc.cover
		if not src and doc.blocks[1] and doc.blocks[1].kind == "image" then src = doc.blocks[1].src end
		if src then makecover(path, function() return doc.imageraw(src) end) else entry.cover = false end
	elseif entry.cover == nil then
		entry.cover = false
	end

	screen, overlay = "reader", nil
	love.window.setTitle(entry.title .. " — luareader")
	persist()
	if doc.warning then showtoast(doc.warning) end
end

local function closebook()
	persist()
	if book.doc.close then book.doc.close() end
	images.clear()
	book = nil
	auto.on, auto.paused, fast.on = false, false, false
	screen, overlay = "library", nil
	love.window.setTitle("luareader")
end

local function recentbooks()
	local list = {}
	for path, entry in pairs(state.books) do
		list[#list + 1] = { path = path, entry = entry }
	end
	table.sort(list, function(a, b) return (a.entry.opened or 0) > (b.entry.opened or 0) end)
	return list
end

-- Settings ------------------------------------------------------------------------

local function setsize(delta, quiet)
	state.settings.size = clamp(state.settings.size + delta, 12, 40)
	loadfonts()
	relayout()
	if not quiet then showtoast("Text size " .. state.settings.size) end
end

local function setwidth(delta, quiet)
	state.settings.width = clamp(state.settings.width + delta, 360, 1400)
	relayout()
	if not quiet then showtoast("Column width " .. state.settings.width) end
end

local function setlineheight(delta, quiet)
	state.settings.lineheight = clamp(floor((state.settings.lineheight + delta) * 100 + 0.5) / 100, 1.2, 2.2)
	relayout()
	if not quiet then showtoast(("Line spacing %.2f"):format(state.settings.lineheight)) end
end

local function setfont(id)
	state.settings.font = id
	loadfonts()
	relayout()
end

local function setjustify(on)
	state.settings.justify = on
	relayout()
end

local function cycletheme()
	local cur = 1
	for i, name in ipairs(themeorder) do
		if name == state.settings.theme then cur = i end
	end
	state.settings.theme = themeorder[cur % #themeorder + 1]
	showtoast("Theme: " .. state.settings.theme)
end

-- Words-per-minute steps: 10 up to 300, then 25.
local function stepwpm(v, dir)
	local step = (v > 300 or (v == 300 and dir > 0)) and 25 or 10
	return clamp(v + dir * step, 60, 1500)
end

local function setspeed(dir) state.settings.wpm = stepwpm(state.settings.wpm, dir) end
local function setfastspeed(dir) state.settings.fastwpm = stepwpm(state.settings.fastwpm, dir) end

-- Seconds to show a word: longer words and punctuation get a little extra,
-- which is what makes fast reading feel natural rather than mechanical.
local function wordtime(text, wpm)
	local t = 60 / wpm
	local _, chars = text:gsub("[^\128-\191]", "")
	if chars > 8 then t = t * (1 + (chars - 8) * 0.05) end
	local bare = text:gsub("[%]\"')]+$", ""):gsub("”$", ""):gsub("’$", "")
	if bare:find("[%.!?]$") or bare:find("…$") then
		t = t * 2
	elseif bare:find("[,;:]$") or bare:find("—$") or bare:find("–$") then
		t = t * 1.5
	end
	return t
end

-- Words on a laid-out line with their x extents. Pieces that touch (an italic
-- word and its comma) belong to the same word.
local function linewords(line)
	if line.words then return line.words end
	local ws = {}
	line.words = ws
	if not line.items then return ws end
	for _, it in ipairs(line.items) do
		local f, t, x = it[1], it[2], it[3]
		local w = f:getWidth(t)
		local last = ws[#ws]
		if last and abs(last.x2 - x) < 1.5 then
			last.x2, last.text = x + w, last.text .. t
		else
			ws[#ws + 1] = { x1 = x, x2 = x + w, text = t }
		end
	end
	line.words = ws
	return ws
end

-- Guide center, as an offset from the top of the text area.
local function guidecenter() return viewh() * state.settings.guidepos / 100 end

-- Auto-scroll may go a little past the page bounds so the first and last
-- lines can still reach the guide.
local function autobounds() return -guidecenter(), book.laid.height - guidecenter() end

local function readable(line) return line and (line.image or (line.items and #line.items > 0)) end

local function paragraphend(i)
	local lines = book.laid.lines
	return not lines[i + 1] or lines[i + 1].block ~= lines[i].block
end

local function nextreadable(i, dir)
	local lines = book.laid.lines
	i = i + dir
	while lines[i] and not readable(lines[i]) do i = i + dir end
	return lines[i] and i or nil
end

-- The line currently under the guide.
local function guideline()
	local lines = book.laid.lines
	local i = layout.lineat(lines, book.target + guidecenter()) or 1
	if not readable(lines[i]) then i = nextreadable(i, 1) or i end
	return i
end

-- Scroll position that centers line i on the guide.
local function alignline(i)
	local l = book.laid.lines[i]
	return l.y + l.h / 2 - guidecenter()
end

-- Seconds to hold line i: its share of words at the chosen speed, plus a
-- breath at the end of a paragraph.
local function dwell(i)
	if book.laid.lines[i].image then return 2.5 end
	local t = max(0.6, #linewords(book.laid.lines[i]) * 60 / state.settings.wpm)
	if paragraphend(i) then t = t + 0.4 end
	return t
end

-- Time on word w of line i (word-by-word style).
local function wordwait(i, w)
	local ws = linewords(book.laid.lines[i])
	local t = wordtime(ws[w].text, state.settings.wpm)
	if w == #ws and paragraphend(i) then t = t + 0.3 end
	return t
end

local function animto(y, dur)
	local lo, hi = autobounds()
	auto.anim = { from = book.target, to = clamp(y, lo, hi), t = 0, dur = dur }
end

local function holdline(i, dur)
	auto.line, auto.word = i, 1
	local words = state.settings.automode == "words" and #linewords(book.laid.lines[i]) > 0
	auto.timer = words and wordwait(i, 1) or dwell(i)
	animto(alignline(i), dur)
end

-- Starts from the first line on the page, which glides down to the guide.
local function autostart()
	if not book then return end
	auto.on, auto.paused, auto.line, auto.anim = true, false, nil, nil
	auto.bandh = bodylh()
	local lines = book.laid.lines
	local i = layout.lineat(lines, book.target + 1) or 1
	if lines[i].y < book.target - 0.5 then i = i + 1 end
	if not readable(lines[i]) then i = nextreadable(i, 1) or 1 end
	if state.settings.automode == "smooth" then
		animto(alignline(i), 0.6)
	else
		holdline(i, 0.6)
	end
end

local function autostop()
	auto.on, auto.paused, auto.line, auto.anim = false, false, nil, nil
	settarget(book.target) -- back inside the normal page bounds
end

local function toggleautoscroll()
	if not book or book.doc.comic then return end
	if auto.on then autostop() else autostart() end
end

local function autopause()
	auto.paused = not auto.paused
end

-- Up/Down while auto-scrolling: move a line, and restart that line's timer.
local function autostep(n)
	if state.settings.automode ~= "smooth" then
		local i = auto.line or guideline()
		for _ = 1, abs(n) do i = nextreadable(i, n > 0 and 1 or -1) or i end
		holdline(i, 0.3)
	else
		animto(book.target + n * bodylh(), 0.3)
	end
end

local function setautomode(mode)
	state.settings.automode = mode
	auto.line, auto.anim = nil, nil
end

-- Every word of the book in order, with the block it came from.
local function buildwords()
	if book.words then return end
	local words, first = {}, {}
	for b, block in ipairs(book.doc.blocks) do
		first[b] = #words + 1
		local parts = {}
		for _, run in ipairs(block.runs) do parts[#parts + 1] = run.br and " " or run.text end
		for w in table.concat(parts):gmatch("%S+") do words[#words + 1] = { text = w, block = b } end
	end
	first[#book.doc.blocks + 1] = #words + 1
	book.words, book.blockword = words, first
end

local function faststart()
	if not book then return end
	buildwords()
	if #book.words == 0 then
		showtoast("There's no text here for the fast reader")
		return
	end
	if auto.on then autostop() end
	local b, frac = position()
	local i = book.blockword[b]
	i = i + floor(frac * (book.blockword[b + 1] - i))
	fast.on, fast.paused = true, false
	fast.i = clamp(i, 1, #book.words)
	fast.timer = 0.8 -- a moment to find the word before it starts moving
end

-- Back to the page, at the word the fast reader reached.
local function fastexit()
	local w = book.words[fast.i]
	local first = book.blockword[w.block]
	local n = max(1, book.blockword[w.block + 1] - first)
	fast.on = false
	gotoblock(w.block, (fast.i - first) / n, true)
end

local function faststep(n)
	fast.i = clamp(fast.i + n, 1, #book.words)
	fast.timer = wordtime(book.words[fast.i].text, state.settings.fastwpm)
end

local function togglefast()
	if not book or book.doc.comic then return end
	if fast.on then fastexit() else faststart() end
end

local function toggleguide()
	state.settings.guide = not state.settings.guide
	showtoast("Reading guide " .. (state.settings.guide and "on" or "off"))
end

local function opensettings(tab)
	overlay = "settings"
	settingsui.tab = tab or settingsui.tab
	settingsui.scroll = 0
	settingsui.capture = nil
end

local function togglefullscreen()
	love.window.setFullscreen(not love.window.getFullscreen())
end

-- Keyboard actions. Reader-only ones check for an open book.
local actions = {
	nextpage = function() if book then nextpage() end end,
	prevpage = function() if book then prevpage() end end,
	scrolldown = function() if book then scrolllines(1) end end,
	scrollup = function() if book then scrolllines(-1) end end,
	nextchapter = function() if book then gotochapter(chapterindex() + 1) end end,
	prevchapter = function() if book then prevchapter() end end,
	start = function() if book then settarget(0) end end,
	finish = function() if book then settarget(maxscroll()) end end,
	contents = function()
		if not book then return end
		overlay = "toc"
		tocsel = chapterindex()
		tocscroll = max(0, tocsel - 5)
	end,
	autoscroll = toggleautoscroll,
	fastreader = togglefast,
	slower = function() setspeed(-1) end,
	faster = function() setspeed(1) end,
	guide = toggleguide,
	bigger = function() setsize(1) end,
	smaller = function() setsize(-1) end,
	wider = function() setwidth(40) end,
	narrower = function() setwidth(-40) end,
	morespace = function() setlineheight(0.05) end,
	lessspace = function() setlineheight(-0.05) end,
	theme = cycletheme,
	settings = function() opensettings() end,
	fullscreen = togglefullscreen,
	library = function() if book then closebook() end end,
}

-- Drawing ------------------------------------------------------------------------

-- True while auto-scroll needs frames: running, or finishing a move while paused.
local function autoscrolling()
	if fast.on then return not fast.paused and not overlay end
	return auto.on and book and screen == "reader" and not overlay
		and (not auto.paused or auto.anim ~= nil or abs(auto.bandh - bodylh()) > 0.5)
end

-- Settings cog (and, when reading, the auto-scroll button with its speed readout).
local function drawbuttons()
	local th = theme()
	local cx, r = W - 34, 17

	local hov = ui.hit(cx - r, 34 - r, r * 2, r * 2, function() opensettings() end)
	if hov then color(th.fg, 0.1) lg.circle("fill", cx, 34, r) end
	color(hov and th.fg or th.dim, hov and 1 or 0.8)
	ui.cog(cx, 34, 9, th.bg)

	if screen ~= "reader" or not book or book.doc.comic then return end

	-- Fast reader button (lightning bolt); in the fast reader it's the way out.
	local fy = fast.on and 80 or 126
	hov = ui.hit(cx - r, fy - r, r * 2, r * 2, togglefast)
	if fast.on then
		color(th.accent, hov and 1 or 0.9)
		lg.circle("fill", cx, fy, r)
		color(th.bg)
	else
		if hov then color(th.fg, 0.1) lg.circle("fill", cx, fy, r) end
		color(hov and th.fg or th.dim, hov and 1 or 0.8)
	end
	ui.bolt(cx, fy, 11)
	if fast.on then return end

	local ay = 80
	hov = ui.hit(cx - r, ay - r, r * 2, r * 2, auto.on and autopause or autostart)
	if auto.on then
		color(th.accent, hov and 1 or 0.9)
		lg.circle("fill", cx, ay, r)
		color(th.bg)
		if auto.paused then ui.play(cx, ay, 9) else ui.pause(cx, ay, 9) end
	else
		if hov then color(th.fg, 0.1) lg.circle("fill", cx, ay, r) end
		color(hov and th.fg or th.dim, hov and 1 or 0.8)
		ui.play(cx, ay, 9)
	end

	if auto.on then
		-- Speed pill to the left of the button: − speed + and × to leave auto-scroll.
		local text = ("%s%d wpm"):format(auto.paused and "Paused  ·  " or "", state.settings.wpm)
		local tw = fonts.ui:getWidth(text)
		local pw = tw + 30 * 3 + 30
		local px = cx - r - 10 - pw
		color(th.panel, 0.96)
		lg.rectangle("fill", px, ay - 17, pw, 34, 17, 17)
		ui.button(px + 3, ay - 14, 28, 28, "minus", function() setspeed(-1) end, { radius = 14, icon = true })
		ui.label(text, px + 34, ay - 17, tw + 16, 34, fonts.ui, th.fg)
		ui.button(px + pw - 63, ay - 14, 28, 28, "plus", function() setspeed(1) end, { radius = 14, icon = true })
		ui.button(px + pw - 31, ay - 14, 28, 28, "close", autostop, { radius = 14, icon = true, iconsize = 4 })
	end
end

local function drawguide(x0)
	local th = theme()
	local lh = floor(auto.bandh + 0.5)
	local gy = floor(MARGIN_TOP + guidecenter() - lh / 2)
	local bottom = H - MARGIN_BOTTOM + FADE
	if state.settings.guidedim then
		color(th.bg, 0.55)
		lg.rectangle("fill", 0, MARGIN_TOP, W, gy - MARGIN_TOP)
		lg.rectangle("fill", 0, gy + lh, W, bottom - gy - lh)
	end
	color(th.accent, 0.1)
	lg.rectangle("fill", x0 - 16, gy, book.colw + 32, lh, 6, 6)
	color(th.accent, 0.9)
	lg.rectangle("fill", x0 - 16, gy + 6, 3, lh - 12, 1.5, 1.5)
end

local function drawreader()
	local th = theme()
	local laid = book.laid
	local x0 = floor((W - book.colw) / 2)
	local scroll = floor(book.scroll + 0.5)
	local lines = laid.lines

	-- Text is clipped at the top edge and fades out just past the bottom edge.
	local bottom = H - MARGIN_BOTTOM + FADE
	lg.setScissor(0, MARGIN_TOP, W, bottom - MARGIN_TOP)

	local i = layout.lineat(lines, scroll - 200) or 1
	for li = i, #lines do
		local line = lines[li]
		local y = MARGIN_TOP + line.y - scroll
		if y > bottom then break end
		if y + line.h > MARGIN_TOP then
			if line.image then
				local img = bookimage(line.image)
				if img then
					local k = th.image or 1
					lg.setColor(k, k, k)
					lg.draw(img, x0 + line.x, y, 0, line.w / img:getWidth(), line.h / img:getHeight())
				else
					color(th.fg, 0.05)
					lg.rectangle("fill", x0 + line.x, y, line.w, line.h, 6, 6)
				end
			elseif line.rule then
				color(th.dim, 0.6)
				lg.setLineWidth(1)
				local cx = x0 + book.colw / 2
				lg.line(cx - 40, floor(y + line.h / 2) + 0.5, cx + 40, floor(y + line.h / 2) + 0.5)
			else
				if li == auto.line and auto.on and state.settings.automode == "words" and not auto.anim then
					local w = linewords(line)[auto.word]
					if w then
						color(th.accent, 0.28)
						lg.rectangle("fill", x0 + w.x1 - 5, floor(y + line.h * 0.14), w.x2 - w.x1 + 10,
							floor(line.h * 0.72), 5, 5)
					end
				end
				color(th.fg)
				for _, it in ipairs(line.items) do
					local f = it[1]
					lg.setFont(f)
					lg.print(it[2], x0 + it[3], floor(y + (line.h - f:getHeight()) / 2))
				end
			end
		end
	end

	if auto.on and state.settings.guide then drawguide(x0) end

	-- Start decoding images a screen above and below, so they're ready in time.
	local vh = viewh()
	for li = layout.lineat(lines, scroll - vh) or 1, #lines do
		local line = lines[li]
		if line.y > scroll + vh * 2 then break end
		if line.image then bookimage(line.image) end
	end
	for s = 0, FADE - 1 do
		color(th.bg, (s + 1) / FADE)
		lg.rectangle("fill", 0, bottom - FADE + s, W, 1)
	end
	lg.setScissor()

	-- Header: book title. Footer: chapter, progress bar, percentage.
	lg.setFont(fonts.ui)
	color(th.dim)
	local title = ellipsize(fonts.ui, book.doc.title or "", book.colw)
	lg.printf(title, 0, 24, W, "center")

	local chapter = book.doc.chapters[chapterindex()]
	local pct = floor(progress() * 100 + 0.5) .. "%"
	local fy = H - 36
	lg.print(ellipsize(fonts.ui, chapter and chapter.title or "", book.colw - 60), x0, fy)
	lg.printf(pct, x0, fy, book.colw, "right")
	color(th.dim, 0.25)
	lg.rectangle("fill", x0, H - 14, book.colw, 2)
	color(th.accent, 0.8)
	lg.rectangle("fill", x0, H - 14, floor(book.colw * progress()), 2)

	drawbuttons()
end

-- Splits a word at its focus letter (a bit left of center), which stays put
-- on screen so the eye never has to move.
local openers = { ['"'] = true, ["'"] = true, ["("] = true, ["["] = true, ["“"] = true, ["‘"] = true }

local function focussplit(text)
	local chars = {}
	for c in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = c end
	local n = #chars
	local lead = 0
	while lead < n - 1 do
		local c = chars[lead + 1]
		if not openers[c] then break end
		lead = lead + 1
	end
	local len = n - lead
	local focus = lead + (len <= 1 and 1 or len <= 5 and 2 or len <= 9 and 3 or len <= 13 and 4 or 5)
	focus = min(focus, n)
	return table.concat(chars, "", 1, focus - 1), chars[focus] or "", table.concat(chars, "", focus + 1)
end

local function drawfast()
	local th = theme()
	local f = fonts.fast
	local fh = f:getHeight()
	local cx, cy = floor(W / 2), floor(H * 0.44)
	local word = book.words[fast.i]

	-- Guide lines with a notch marking the focus point.
	local half = min(260, floor(W / 2) - 24)
	color(th.dim, 0.35)
	lg.setLineWidth(1)
	lg.line(cx - half, cy - fh * 0.85, cx + half, cy - fh * 0.85)
	lg.line(cx - half, cy + fh * 0.85, cx + half, cy + fh * 0.85)
	color(th.accent, 0.8)
	lg.setLineWidth(2)
	lg.line(cx, cy - fh * 0.85, cx, cy - fh * 0.6)
	lg.line(cx, cy + fh * 0.6, cx, cy + fh * 0.85)

	local left, mid, right = focussplit(word.text)
	local lw, mw = f:getWidth(left), f:getWidth(mid)
	local x, y = floor(cx - lw - mw / 2), floor(cy - fh / 2)
	lg.setFont(f)
	color(th.fg)
	lg.print(left, x, y)
	color(th.accent)
	lg.print(mid, x + lw, y)
	color(th.fg)
	lg.print(right, x + lw + mw, y)

	-- Speed with − / + and the state.
	local text = ("%s%d wpm"):format(fast.paused and "Paused  ·  " or "", state.settings.fastwpm)
	local tw = fonts.label:getWidth(text) + 20
	local py = floor(cy + fh * 0.85 + 40)
	ui.button(cx - tw / 2 - 36, py, 30, 30, "minus", function() setfastspeed(-1) end, { radius = 15, icon = true })
	ui.label(text, cx - tw / 2, py, tw, 30, fonts.label, th.fg)
	ui.button(cx + tw / 2 + 6, py, 30, 30, "plus", function() setfastspeed(1) end, { radius = 15, icon = true })
	ui.label("Space pause  ·  Left / Right step  ·  Up / Down speed  ·  Esc back to the page",
		0, py + 44, W, 20, fonts.ui, th.dim)

	-- Header and footer like the reader.
	lg.setFont(fonts.ui)
	color(th.dim)
	lg.printf(ellipsize(fonts.ui, book.doc.title or "", W - 120), 0, 24, W, "center")
	local ci = 1
	for i, c in ipairs(book.doc.chapters) do
		if c.block <= word.block then ci = i else break end
	end
	local chapter = book.doc.chapters[ci]
	local colw = min(state.settings.width, W - 48)
	local x0 = floor((W - colw) / 2)
	local p = (fast.i - 1) / max(1, #book.words - 1)
	lg.print(ellipsize(fonts.ui, chapter and chapter.title or "", colw - 60), x0, H - 36)
	lg.printf(floor(p * 100 + 0.5) .. "%", x0, H - 36, colw, "right")
	color(th.dim, 0.25)
	lg.rectangle("fill", x0, H - 14, colw, 2)
	color(th.accent, 0.8)
	lg.rectangle("fill", x0, H - 14, floor(colw * p), 2)

	drawbuttons()
end

local function drawlibrary()
	local th = theme()
	local cw = min(560, W - 48)
	local x0 = floor((W - cw) / 2)

	color(th.accent)
	lg.setFont(fonts.logo)
	lg.printf("luareader", 0, floor(H * 0.1), W, "center")
	color(th.dim)
	lg.setFont(fonts.ui)
	lg.printf("drop a .txt, .epub or .cbz onto the window  ·  press ? for keys", 0, floor(H * 0.1) + 70, W, "center")

	local books = recentbooks()
	libsel = clamp(libsel, 1, max(1, #books))
	local top = floor(H * 0.1) + 120
	local rowh = 76
	local visible = max(1, floor((H - top - 40) / rowh))
	libscroll = clamp(libscroll, max(0, libsel - visible), min(libsel - 1, max(0, #books - visible)))

	if #books == 0 then
		color(th.dim, 0.7)
		lg.setFont(fonts.item)
		lg.printf("No books yet.", 0, top + 40, W, "center")
	end

	for n = libscroll + 1, min(#books, libscroll + visible) do
		local b = books[n]
		local y = top + (n - libscroll - 1) * rowh
		local hovered = ui.hit(x0 - 12, y, cw + 24, rowh - 8, function() openbook(b.path) end)
		if n == libsel or hovered then
			color(th.fg, n == libsel and 0.06 or 0.035)
			lg.rectangle("fill", x0 - 12, y, cw + 24, rowh - 8, 8, 8)
		end
		-- Cover thumbnail, or a plain spine with the title's first letter.
		local cover = b.entry.cover
		if cover == nil and not coverqueued[b.path] then
			coverqueued[b.path] = true
			coverqueue[#coverqueue + 1] = b.path
		end
		local img = cover and thumbs[cover]
		if cover and img == nil then
			img = love.filesystem.getInfo(cover) and lg.newImage(cover, { mipmaps = true }) or false
			if img then img:setMipmapFilter("linear") end
			thumbs[cover] = img
		end
		local tx, ty, tw, tht = x0, y + 5, 40, 58
		if img then
			local k = th.image or 1
			lg.setColor(k, k, k)
			lg.draw(img, tx, ty, 0, tw / img:getWidth(), tht / img:getHeight())
		else
			color(th.fg, 0.07)
			lg.rectangle("fill", tx, ty, tw, tht, 3, 3)
			local initial = text.toutf8(b.entry.title or "?"):match("[%z\1-\127\194-\244][\128-\191]*") or "?"
			ui.label(initial, tx, ty, tw, tht, fonts.item, th.accent)
		end

		local lx, lw = x0 + tw + 16, cw - tw - 16
		color(th.fg)
		lg.setFont(fonts.item)
		lg.print(ellipsize(fonts.item, text.toutf8(b.entry.title or b.path), lw - 60), lx, y + 12)
		color(th.dim)
		lg.setFont(fonts.ui)
		local sub = text.toutf8(b.entry.author or b.path:match("([^/]+)$") or b.path)
		lg.print(ellipsize(fonts.ui, sub, lw - 60), lx, y + 40)
		lg.printf(floor((b.entry.progress or 0) * 100 + 0.5) .. "%", x0, y + 40, cw, "right")
		color(th.dim, 0.2)
		lg.rectangle("fill", cw + x0 - 40, y + 26, 40, 2)
		color(th.accent, 0.8)
		lg.rectangle("fill", cw + x0 - 40, y + 26, floor(40 * (b.entry.progress or 0)), 2)
	end

	drawbuttons()
end

-- Dims the screen and draws an empty panel; overlays own all clicks while open.
local function panel(w, h)
	local th = theme()
	ui.reset()
	color({ 0, 0, 0 }, 0.4)
	lg.rectangle("fill", 0, 0, W, H)
	local x, y = floor((W - w) / 2), floor((H - h) / 2)
	color(th.panel)
	lg.rectangle("fill", x, y, w, h, 12, 12)
	return x, y
end

local function drawtoc()
	local th = theme()
	local chapters = book.doc.chapters
	local rowh = 36
	local w, h = min(520, W - 48), min(H - 96, 84 + max(1, #chapters) * rowh)
	local x, y = panel(w, h)

	color(th.dim)
	lg.setFont(fonts.ui)
	lg.print("CONTENTS", x + 28, y + 24)

	local top = y + 56
	local visible = max(1, floor((h - 72) / rowh))
	tocsel = clamp(tocsel, 1, #chapters)
	tocscroll = clamp(tocscroll, max(0, tocsel - visible), min(tocsel - 1, max(0, #chapters - visible)))
	local current = chapterindex()

	lg.setFont(fonts.item)
	for n = tocscroll + 1, min(#chapters, tocscroll + visible) do
		local ry = top + (n - tocscroll - 1) * rowh
		local hovered = ui.hit(x + 12, ry, w - 24, rowh, function() gotochapter(n); overlay = nil end)
		if n == tocsel or hovered then
			color(th.fg, n == tocsel and 0.07 or 0.04)
			lg.rectangle("fill", x + 12, ry, w - 24, rowh, 6, 6)
		end
		color(n == current and th.accent or th.fg)
		lg.setFont(fonts.item)
		lg.print(ellipsize(fonts.item, chapters[n].title, w - 56), x + 28, ry + floor((rowh - fonts.item:getHeight()) / 2))
	end
	settingsui.rect = { x, y, w, h }
end

-- Settings window ---------------------------------------------------------------

local ROW = 52

-- One labelled settings row; returns the vertical center for the control.
local function settingrow(x, y, w, label, sub)
	local th = theme()
	local cy = y + ROW / 2
	if sub then
		ui.text(label, x, cy - 18, fonts.label, th.fg)
		ui.text(sub, x, cy + 2, fonts.ui, th.dim)
	else
		ui.text(label, x, cy - fonts.label:getHeight() / 2, fonts.label, th.fg)
	end
	color(th.fg, 0.06)
	lg.rectangle("fill", x, y + ROW - 1, w, 1)
	return cy
end

local function drawreadingtab(x, y, w)
	local s = state.settings
	local xr = x + w
	local th = {}
	for _, name in ipairs(themeorder) do th[#th + 1] = { id = name, label = name:sub(1, 1):upper() .. name:sub(2) } end
	ui.segmented(xr, settingrow(x, y, w, "Theme"), th, s.theme, function(id) s.theme = id end)
	y = y + ROW

	local fams = {}
	for _, f in ipairs(families) do fams[#fams + 1] = { id = f.id, label = f.label, font = fonts.preview[f.id] } end
	ui.segmented(xr, settingrow(x, y, w, "Font"), fams, s.font, setfont)
	y = y + ROW

	ui.stepper(xr, settingrow(x, y, w, "Text size"), tostring(s.size),
		function() setsize(-1, true) end, function() setsize(1, true) end)
	y = y + ROW
	ui.stepper(xr, settingrow(x, y, w, "Line spacing"), ("%.2f"):format(s.lineheight),
		function() setlineheight(-0.05, true) end, function() setlineheight(0.05, true) end)
	y = y + ROW
	ui.stepper(xr, settingrow(x, y, w, "Column width"), s.width .. " px",
		function() setwidth(-40, true) end, function() setwidth(40, true) end)
	y = y + ROW
	ui.toggle(xr, settingrow(x, y, w, "Justify text", "Even right edge, like a printed book"), s.justify,
		function() setjustify(not s.justify) end)
	y = y + ROW + 20

	ui.text("COMICS", x, y, fonts.ui, theme().dim)
	y = y + 22
	ui.segmented(xr, settingrow(x, y, w, "Page order", "Right to left for manga"), {
		{ id = "ltr", label = "Left to right" }, { id = "rtl", label = "Right to left" },
	}, s.comicdir, function(id) s.comicdir = id end)
	y = y + ROW
	ui.segmented(xr, settingrow(x, y, w, "Fit", "Width scrolls through tall pages"), {
		{ id = "page", label = "Whole page" }, { id = "width", label = "Width" },
	}, s.comicfit, function(id) s.comicfit = id; relayout() end)
	y = y + ROW
	ui.toggle(xr, settingrow(x, y, w, "Two-page spreads", "Side by side when the window is wide"), s.comicspread,
		function() s.comicspread = not s.comicspread; relayout() end)
	return ROW * 9 + 42
end

local function drawautotab(x, y, w)
	local y0 = y
	local s = state.settings
	local xr = x + w
	local function k(id) return keys.name(s.keys[id][1] or "?") end

	local sub = book and "Starts from the current page" or "Open a book to start"
	ui.toggle(xr, settingrow(x, y, w, "Auto-scroll", sub), auto.on, toggleautoscroll)
	y = y + ROW
	local stylesubs = {
		words = "Highlight each word, then glide to the next line",
		lines = "Rest on each line, then glide to the next",
		smooth = "Scroll at a steady pace",
	}
	ui.segmented(xr, settingrow(x, y, w, "Style", stylesubs[s.automode]), {
		{ id = "words", label = "Word by word" }, { id = "lines", label = "Line by line" },
		{ id = "smooth", label = "Smooth" },
	}, s.automode, setautomode)
	y = y + ROW
	ui.stepper(xr, settingrow(x, y, w, "Speed", "Words per minute"), s.wpm .. " wpm",
		function() setspeed(-1) end, function() setspeed(1) end)
	y = y + ROW
	ui.toggle(xr, settingrow(x, y, w, "Reading guide", "Highlighted band to keep your place"), s.guide,
		function() s.guide = not s.guide end)
	y = y + ROW
	ui.stepper(xr, settingrow(x, y, w, "Guide position", "Distance from the top of the page"), s.guidepos .. "%",
		function() s.guidepos = clamp(s.guidepos - 5, 10, 80) end,
		function() s.guidepos = clamp(s.guidepos + 5, 10, 80) end)
	y = y + ROW
	ui.toggle(xr, settingrow(x, y, w, "Dim around the guide", "Fade the lines above and below it"), s.guidedim,
		function() s.guidedim = not s.guidedim end)
	y = y + ROW + 14

	ui.text(("%s starts  ·  Space or click pauses  ·  Up / Down move a line  ·  Esc or %s stops")
		:format(k("autoscroll"), k("autoscroll")), x, y, fonts.ui, theme().dim)
	y = y + 40

	ui.text("FAST READER", x, y, fonts.ui, theme().dim)
	y = y + 22
	local fsub = "One word at a time in the middle of the screen"
	ui.button(xr - 64, settingrow(x, y, w, "Fast reader", fsub) - 15, 64, 30, "Open", function()
		overlay = nil
		faststart()
	end)
	y = y + ROW
	ui.stepper(xr, settingrow(x, y, w, "Fast reader speed", "Words per minute"), s.fastwpm .. " wpm",
		function() setfastspeed(-1) end, function() setfastspeed(1) end)
	y = y + ROW + 14
	ui.text(("%s opens  ·  Space pauses  ·  Left / Right step a word  ·  Up / Down change speed  ·  Esc returns")
		:format(k("fastreader")), x, y, fonts.ui, theme().dim)
	return y + 30 - y0
end

-- Returns the content height, for scrolling.
local function drawkeystab(x, y, w)
	local th = theme()
	local s = state.settings
	local rowh = 40
	local y0 = y
	for _, a in ipairs(keys.actions) do
		local cy = y + rowh / 2
		ui.text(a.label, x, cy - fonts.label:getHeight() / 2, fonts.label, th.fg)

		-- Key chips, right-aligned: click one to remove it, "+" to add a key.
		local chips = {}
		for _, key in ipairs(s.keys[a.id]) do chips[#chips + 1] = { label = keys.name(key), key = key } end
		local capturing = settingsui.capture == a.id
		chips[#chips + 1] = { label = capturing and "press a key…" or "+", add = true }
		local cx = x + w
		for i = #chips, 1, -1 do
			local c = chips[i]
			-- Room for the "× " shown on hover, so chips don't change size.
			local cw = fonts.ui:getWidth(c.add and c.label or "× " .. c.label) + 20
			cx = cx - cw
			local action = c.add and function() settingsui.capture = a.id end or function()
				for j, key in ipairs(s.keys[a.id]) do
					if key == c.key then table.remove(s.keys[a.id], j) break end
				end
				keymap = keys.map(s.keys)
			end
			local hov = ui.hovered(cx, cy - 13, cw, 26)
			if c.add and capturing then
				ui.button(cx, cy - 13, cw, 26, c.label, action, { active = true })
			elseif c.add then
				ui.button(cx, cy - 13, cw, 26, "plus", action, { icon = true, iconsize = 4 })
			else
				ui.button(cx, cy - 13, cw, 26, hov and "× " .. c.label or c.label, action)
			end
			cx = cx - 6
		end
		color(th.fg, 0.06)
		lg.rectangle("fill", x, y + rowh - 1, w, 1)
		y = y + rowh
	end
	y = y + 14
	ui.button(x, y, 150, 30, "Reset to defaults", function()
		keys.reset(s.keys)
		keymap = keys.map(s.keys)
		showtoast("Keys reset")
	end)
	ui.text("Click a key to remove it  ·  Ctrl+Q always quits", x + 166, y + 8, fonts.ui, th.dim)
	return y + 44 - y0
end

local function drawsettings()
	local th = theme()
	local w, h = min(620, W - 32), min(H - 48, 560)
	local x, y = panel(w, h)
	settingsui.rect = { x, y, w, h }
	local pad = 28

	ui.text("Settings", x + pad, y + 22, fonts.item, th.fg)
	ui.button(x + w - pad - 28, y + 20, 28, 28, "close", function() overlay = nil end, { radius = 14, icon = true })

	local tabs = {
		{ id = "reading", label = "Reading" },
		{ id = "auto", label = "Auto reading" },
		{ id = "keys", label = "Keys" },
	}
	local tx = x + pad
	for _, t in ipairs(tabs) do
		local tw = fonts.label:getWidth(t.label) + 28
		ui.button(tx, y + 62, tw, 32, t.label, function()
			settingsui.tab = t.id
			settingsui.scroll = 0
			settingsui.capture = nil
		end, { active = settingsui.tab == t.id, font = fonts.label })
		tx = tx + tw + 6
	end

	local cx, cy, cw, ch = x + pad, y + 108, w - pad * 2, h - 108 - 16
	ui.setclip(cx - 4, cy, cw + 8, ch)
	local tab = settingsui.tab
	local draw = tab == "reading" and drawreadingtab or tab == "auto" and drawautotab or drawkeystab
	local contenth = draw(cx, cy - settingsui.scroll, cw)
	settingsui.maxscroll = max(0, contenth - ch)
	settingsui.scroll = clamp(settingsui.scroll, 0, settingsui.maxscroll)
	settingsui.contenth = contenth
	ui.setclip()

	if settingsui.maxscroll > 0 then
		local bh = max(30, ch * ch / settingsui.contenth)
		local by = cy + (ch - bh) * settingsui.scroll / settingsui.maxscroll
		color(th.fg, 0.15)
		lg.rectangle("fill", x + w - 12, by, 3, bh, 1.5, 1.5)
	end
end

local function drawtoast()
	if not toast then return end
	local th = theme()
	local a = min(1, toast.t / 0.3)
	lg.setFont(fonts.ui)
	local tw = fonts.ui:getWidth(toast.text) + 32
	local x, y = floor((W - tw) / 2), H - MARGIN_BOTTOM - 44
	color(th.fg, 0.88 * a)
	lg.rectangle("fill", x, y, tw, 30, 15, 15)
	color(th.bg, a)
	lg.print(toast.text, x + 16, y + floor((30 - fonts.ui:getHeight()) / 2))
end

-- LÖVE callbacks -------------------------------------------------------------------

function love.load(args)
	state = store.load(defaults)
	keys.normalize(state.settings.keys)
	keymap = keys.map(state.settings.keys)
	W, H = lg.getDimensions()
	if debuglog then
		print(("start %dx%d, pixels %dx%d, dpi scale %.2f, video driver %s"):format(W, H,
			lg.getPixelWidth(), lg.getPixelHeight(), lg.getDPIScale(), tostring(os.getenv("SDL_VIDEODRIVER"))))
	end
	images.init()
	loadfonts()
	comic.init({
		theme = theme, color = color, fonts = fonts, settings = function() return state.settings end,
		image = function(src) return bookimage(src) end,
	})
	love.keyboard.setKeyRepeat(true)
	if args[1] then openbook(args[1]) end
end

local function ease(p)
	return p < 0.5 and 4 * p * p * p or 1 - (-2 * p + 2) ^ 3 / 2
end

local function updateauto(dt)
	local lines = book.laid.lines
	local a = auto.anim
	if a then
		a.t = a.t + dt
		local p = min(1, a.t / a.dur)
		book.target = a.from + (a.to - a.from) * ease(p)
		if p >= 1 then auto.anim = nil end
	elseif not auto.paused then
		if state.settings.automode ~= "smooth" then
			if not auto.line then
				holdline(guideline(), 0.45)
			else
				auto.timer = auto.timer - dt
				if auto.timer <= 0 then
					local nwords = #linewords(lines[auto.line])
					if state.settings.automode == "words" and auto.word < nwords then
						auto.word = auto.word + 1
						auto.timer = wordwait(auto.line, auto.word)
					else
						local n = nextreadable(auto.line, 1)
						if n then
							holdline(n, state.settings.automode == "words" and 0.35 or 0.5)
						else
							auto.paused = true
							showtoast("End of book")
						end
					end
				end
			end
		else
			local _, hi = autobounds()
			book.target = book.target + state.settings.wpm / book.wordsperline * bodylh() / 60 * dt
			if book.target >= hi then
				book.target = hi
				auto.paused = true
				showtoast("End of book")
			end
		end
	end

	local want = state.settings.automode ~= "smooth" and auto.line and lines[auto.line].h or bodylh()
	auto.bandh = auto.bandh + (want - auto.bandh) * min(1, dt * 10)
end

local function updatefast(dt)
	fast.timer = fast.timer - dt
	if fast.timer > 0 then return end
	if fast.i >= #book.words then
		fast.paused = true
		showtoast("End of book")
		return
	end
	local prev = book.words[fast.i]
	fast.i = fast.i + 1
	fast.timer = wordtime(book.words[fast.i].text, state.settings.fastwpm)
	-- A beat between paragraphs.
	if book.words[fast.i].block ~= prev.block then fast.timer = fast.timer + 0.25 end
end

function love.update(dt)
	settle = max(0, settle - dt)
	images.update()
	updatecovers()
	comicbusy = false
	if book and book.doc.comic then
		comicbusy = comic.update(book, dt)
	elseif book and fast.on then
		if not fast.paused and not overlay then updatefast(dt) end
	elseif book then
		if auto.on then
			if screen == "reader" and not overlay then updateauto(dt) end
			book.scroll = book.target
		else
			local d = book.target - book.scroll
			if abs(d) < 0.5 then
				book.scroll = book.target
			else
				book.scroll = book.scroll + d * min(1, dt * 16)
			end
		end
	end
	if toast then
		toast.t = toast.t - dt
		if toast.t <= 0 then toast = nil end
	end
end

-- Keeps W, H equal to the real drawable size. On some setups (scaled outputs,
-- some SDL builds) the resize event carries a stale size, or the new size
-- lands a moment later, so it's checked every frame rather than trusted.
local function syncsize()
	local w, h = lg.getDimensions()
	if w ~= W or h ~= H then
		if debuglog then
			print(("size %dx%d (was %sx%s), pixels %dx%d, dpi scale %.2f"):format(w, h, tostring(W), tostring(H),
				lg.getPixelWidth(), lg.getPixelHeight(), lg.getDPIScale()))
		end
		W, H = w, h
		relayout()
	end
end

function love.draw()
	syncsize()
	local th = theme()
	lg.clear(unpack(th.bg))
	ui.th = th
	ui.reset()
	settingsui.rect = nil
	if screen == "reader" and book and book.doc.comic then
		comic.draw(book)
		drawbuttons()
		if overlay == "toc" then drawtoc() end
	elseif screen == "reader" and book and fast.on then
		drawfast()
	elseif screen == "reader" and book then
		drawreader()
		if overlay == "toc" then drawtoc() end
	else
		drawlibrary()
	end
	if overlay == "settings" then drawsettings() end
	drawtoast()
end

function love.resize(w, h)
	if debuglog then print(("resize event %dx%d"):format(w, h)) end
	settle = 0.75
	syncsize()
end

function love.focus(f)
	settle = 0.75
	if not f then persist() end
end

function love.visible()
	settle = 0.75
end

function love.quit()
	persist()
	images.shutdown()
end

function love.filedropped(file)
	openbook(file:getFilename())
end

function love.textinput(t)
	if settingsui.swallow then
		settingsui.swallow = false
		return
	end
	if t == "?" and not settingsui.capture then
		if overlay == "settings" then overlay = nil else opensettings("keys") end
	end
end

function love.keypressed(key)
	local ctrl = love.keyboard.isDown("lctrl", "rctrl")
	local shift = love.keyboard.isDown("lshift", "rshift")

	if ctrl and key == "q" then return love.event.quit() end
	settingsui.swallow = false

	-- Waiting for a key to bind in the settings window.
	if settingsui.capture then
		if key ~= "escape" then
			keys.bind(state.settings.keys, settingsui.capture, key)
			keymap = keys.map(state.settings.keys)
			save()
		end
		settingsui.capture = nil
		settingsui.swallow = true -- the text this key types isn't a command
		return
	end

	if key == "f1" then
		if overlay == "settings" then overlay = nil else opensettings("keys") end
		return
	end

	if overlay == "settings" then
		if key == "escape" or keymap[key] == "settings" then overlay = nil
		elseif key == "tab" then
			local order = { reading = "auto", auto = "keys", keys = "reading" }
			settingsui.tab = order[settingsui.tab]
			settingsui.scroll = 0
		elseif key == "down" or key == "j" then settingsui.scroll = settingsui.scroll + 40
		elseif key == "up" or key == "k" then settingsui.scroll = max(0, settingsui.scroll - 40)
		end
		return
	end

	if overlay == "toc" then
		local n = #book.doc.chapters
		if key == "escape" or keymap[key] == "contents" then overlay = nil
		elseif key == "down" or key == "j" then tocsel = min(n, tocsel + 1)
		elseif key == "up" or key == "k" then tocsel = max(1, tocsel - 1)
		elseif key == "pagedown" then tocsel = min(n, tocsel + 10)
		elseif key == "pageup" then tocsel = max(1, tocsel - 10)
		elseif key == "home" then tocsel = 1
		elseif key == "end" then tocsel = n
		elseif key == "return" or key == "kpenter" then gotochapter(tocsel); overlay = nil
		end
		return
	end

	if book and book.doc.comic and screen == "reader" then
		local action = keymap[key]
		if key == "right" then comic.right(book)
		elseif key == "left" then comic.left(book)
		elseif key == "down" or key == "j" then
			if comic.canscroll(book) then comic.scroll(book, 120) else comic.forward(book) end
		elseif key == "up" or key == "k" then
			if comic.canscroll(book) then comic.scroll(book, -120) else comic.backward(book) end
		elseif action == "nextpage" then
			if shift then comic.backward(book) else comic.forward(book) end
		elseif action == "prevpage" then comic.backward(book)
		elseif action == "start" then comic.gotopage(book, 1)
		elseif action == "finish" then comic.gotopage(book, #book.doc.pages)
		elseif action == "bigger" then comic.zoom(book, 1.25)
		elseif action == "smaller" then comic.zoom(book, 0.8)
		elseif key == "0" or key == "kp0" then comic.resetzoom(book)
		elseif action and ({ nextchapter = 1, prevchapter = 1, contents = 1, theme = 1, settings = 1,
			fullscreen = 1, library = 1 })[action] then
			actions[action]()
		end
		return
	end

	if fast.on and screen == "reader" then
		if key == "space" then fast.paused = not fast.paused
		elseif key == "left" then faststep(-1)
		elseif key == "right" then faststep(1)
		elseif key == "up" then setfastspeed(1)
		elseif key == "down" then setfastspeed(-1)
		elseif key == "escape" or keymap[key] == "fastreader" then fastexit()
		elseif keymap[key] == "settings" then opensettings("auto")
		end
		return
	end

	if auto.on and screen == "reader" then
		if key == "up" then autostep(-1)
		elseif key == "down" then autostep(1)
		elseif key == "space" then autopause()
		elseif key == "escape" or keymap[key] == "autoscroll" then autostop()
		elseif keymap[key] == "settings" then opensettings("auto")
		elseif keymap[key] == "fastreader" then faststart()
		end
		return
	end

	if screen == "library" then
		local books = recentbooks()
		if key == "down" or key == "j" then libsel = min(#books, libsel + 1) return
		elseif key == "up" or key == "k" then libsel = max(1, libsel - 1) return
		elseif (key == "return" or key == "kpenter") and books[libsel] then openbook(books[libsel].path) return
		elseif key == "delete" and books[libsel] then
			state.books[books[libsel].path] = nil
			save()
			showtoast("Removed from library")
			return
		end
	end

	local action = keymap[key]
	-- Shift reverses the page-turn key (Shift+Space goes back).
	if shift and action == "nextpage" then action = "prevpage" end
	if action then actions[action]() end
end

function love.wheelmoved(_, y)
	if overlay == "settings" then
		settingsui.scroll = clamp(settingsui.scroll - y * 40, 0, settingsui.maxscroll or 0)
	elseif overlay == "toc" then
		tocsel = clamp(tocsel - y, 1, #book.doc.chapters)
	elseif screen == "reader" and book and book.doc.comic then
		if love.keyboard.isDown("lctrl", "rctrl") then
			local mx, my = love.mouse.getPosition()
			comic.zoom(book, 1.15 ^ y, mx, my)
		elseif comic.canscroll(book) then
			comic.scroll(book, -y * 90)
		elseif y < 0 then
			comic.forward(book)
		else
			comic.backward(book)
		end
	elseif screen == "reader" and book and fast.on then
		faststep(y > 0 and -1 or 1)
	elseif screen == "reader" and book and auto.on then
		autostep(y > 0 and -1 or 1)
	elseif screen == "reader" and book then
		scrolllines(-y * 3)
	elseif screen == "library" then
		libsel = max(1, libsel - y)
	end
end

function love.mousepressed(x, y, button)
	if button == 1 and ui.click(x, y) then return end
	if screen == "reader" and book and book.doc.comic and not overlay then
		if button == 1 then drag = { x = x, y = y, moved = false } end
		if button == 4 then comic.backward(book) end
		if button == 5 then comic.forward(book) end
		return
	end
	if screen == "reader" and book and fast.on and not overlay then
		fast.paused = not fast.paused
		return
	end
	if screen == "reader" and book and auto.on and not overlay then
		-- Any click on the page pauses/resumes; auto-scroll mode stays on.
		return autopause()
	end
	if button == 4 and screen == "reader" and not overlay then return prevpage() end
	if button == 5 and screen == "reader" and not overlay then return nextpage() end
	if button ~= 1 then return end

	if overlay then
		-- Clicking outside the panel closes it.
		local r = settingsui.rect
		if not r or x < r[1] or x >= r[1] + r[3] or y < r[2] or y >= r[2] + r[4] then
			overlay = nil
			settingsui.capture = nil
		end
		return
	end

	-- Reader: click the left third to go back, anywhere else to go forward.
	if screen == "reader" and book then
		if x < W * 0.3 then prevpage() else nextpage() end
	end
end

function love.mousemoved(x, y, dx, dy)
	if drag and book and book.doc.comic then
		if not drag.moved and abs(x - drag.x) + abs(y - drag.y) > 5 then drag.moved = true end
		if drag.moved then comic.drag(book, dx, dy) end
	end
end

function love.mousereleased(x, y, button)
	if button ~= 1 or not drag then return end
	local d = drag
	drag = nil
	if d.moved or not (book and book.doc.comic) or overlay then return end
	if x < W * 0.3 then comic.left(book)
	elseif x > W * 0.7 then comic.right(book)
	else comic.forward(book)
	end
end

-- Event-driven main loop: sleeps until input arrives, and only keeps drawing
-- frames while something is animating (scrolling, auto-scroll, toast fade).
function love.run()
	love.load(love.arg.parseGameArguments(arg), arg)
	love.timer.step()

	local function handle(name, a, b, c, d, e, f)
		if not name then return end
		if name == "quit" then
			if not love.quit() then return a or 0 end
		end
		love.handlers[name](a, b, c, d, e, f)
	end

	-- Wayland only maps a window once it has a frame, so draw before the first wait.
	local drawn = false

	return function()
		local animating = toast ~= nil or autoscrolling() or (book and book.scroll ~= book.target)
			or images.busy() or #coverqueue > 0 or next(coverwait) ~= nil or comicbusy or settle > 0
		if drawn and not animating then
			local exit = handle(love.event.wait())
			if exit then return exit end
			love.timer.step()
		end
		love.event.pump()
		for name, a, b, c, d, e, f in love.event.poll() do
			local exit = handle(name, a, b, c, d, e, f)
			if exit then return exit end
		end

		love.update(love.timer.step())

		if lg.isActive() then
			lg.origin()
			love.draw()
			lg.present()
			drawn = true
		end
		if animating then love.timer.sleep(0.001) end
	end
end
