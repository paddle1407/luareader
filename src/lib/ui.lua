-- Tiny immediate-mode widgets. Drawing a widget registers its clickable rect;
-- ui.click() dispatches to the topmost rect under the mouse.
-- Set ui.th (theme) and ui.fonts before drawing, and call ui.reset() per frame.

local ui = { rects = {} }

local lg = love.graphics
local floor = math.floor

function ui.color(c, a) lg.setColor(c[1], c[2], c[3], a or c[4] or 1) end

function ui.reset()
	ui.rects = {}
	ui.clip = nil
end

local function inside(x, y, w, h, px, py)
	return px >= x and px < x + w and py >= y and py < y + h
end

local function inclip(clip, px, py)
	return not clip or inside(clip[1], clip[2], clip[3], clip[4], px, py)
end

-- Clickable areas only register inside the current clip (for scrolled lists).
function ui.setclip(x, y, w, h)
	ui.clip = x and { x, y, w, h } or nil
	if x then lg.setScissor(x, y, w, h) else lg.setScissor() end
end

function ui.hovered(x, y, w, h)
	local mx, my = love.mouse.getPosition()
	return inclip(ui.clip, mx, my) and inside(x, y, w, h, mx, my)
end

function ui.hit(x, y, w, h, action)
	ui.rects[#ui.rects + 1] = { x, y, w, h, action, ui.clip }
	return ui.hovered(x, y, w, h)
end

function ui.click(px, py)
	for i = #ui.rects, 1, -1 do
		local r = ui.rects[i]
		if inside(r[1], r[2], r[3], r[4], px, py) and inclip(r[6], px, py) then
			r[5]()
			return true
		end
	end
	return false
end

function ui.text(s, x, y, font, c, a)
	lg.setFont(font)
	ui.color(c, a)
	lg.print(s, floor(x), floor(y))
end

-- Text centered in a box.
function ui.label(s, x, y, w, h, font, c, a)
	lg.setFont(font)
	ui.color(c, a)
	lg.print(s, floor(x + (w - font:getWidth(s)) / 2), floor(y + (h - font:getHeight()) / 2))
end

-- Vector glyphs, so they sit exactly in the middle of their buttons.
local function icon(name, cx, cy, r)
	lg.setLineWidth(1.6)
	lg.setLineStyle("smooth")
	if name == "close" then
		lg.line(cx - r, cy - r, cx + r, cy + r)
		lg.line(cx - r, cy + r, cx + r, cy - r)
	else
		lg.line(cx - r, cy, cx + r, cy)
		if name == "plus" then lg.line(cx, cy - r, cx, cy + r) end
	end
end

-- label is text, or an icon name when opts.icon is set ("close", "minus", "plus").
function ui.button(x, y, w, h, label, action, opts)
	opts = opts or {}
	local th = ui.th
	local hov = ui.hit(x, y, w, h, action)
	if opts.active then
		ui.color(th.accent, hov and 1 or 0.9)
	else
		ui.color(th.fg, hov and 0.14 or 0.07)
	end
	lg.rectangle("fill", x, y, w, h, opts.radius or 7, opts.radius or 7)
	if opts.icon then
		ui.color(opts.active and th.bg or th.fg)
		icon(label, x + w / 2, y + h / 2, opts.iconsize or 4.5)
	else
		ui.label(label, x, y, w, h, opts.font or ui.fonts.ui, opts.active and th.bg or th.fg)
	end
	return hov
end

-- Controls below are laid out right-aligned against xr, vertically centered on cy.
-- Each returns its width.

function ui.stepper(xr, cy, value, dec, inc)
	local bw, vw = 30, 110
	local x = xr - bw * 2 - vw
	ui.button(x, cy - bw / 2, bw, bw, "minus", dec, { icon = true })
	ui.label(value, x + bw, cy - bw / 2, vw, bw, ui.fonts.label, ui.th.fg)
	ui.button(x + bw + vw, cy - bw / 2, bw, bw, "plus", inc, { icon = true })
	return bw * 2 + vw
end

-- options = { { id, label, font } ... }
function ui.segmented(xr, cy, options, current, pick)
	local widths, total = {}, 0
	for i, o in ipairs(options) do
		widths[i] = (o.font or ui.fonts.ui):getWidth(o.label) + 24
		total = total + widths[i] + (i > 1 and 4 or 0)
	end
	local x, h = xr - total, 30
	for i, o in ipairs(options) do
		ui.button(x, cy - h / 2, widths[i], h, o.label, function() pick(o.id) end,
			{ active = o.id == current, font = o.font })
		x = x + widths[i] + 4
	end
	return total
end

function ui.toggle(xr, cy, on, action)
	local th = ui.th
	local w, h = 44, 24
	local x, y = xr - w, cy - h / 2
	local hov = ui.hit(x, y, w, h, action)
	if on then ui.color(th.accent, hov and 1 or 0.9) else ui.color(th.fg, hov and 0.22 or 0.15) end
	lg.rectangle("fill", x, y, w, h, h / 2, h / 2)
	if on then ui.color(th.bg) else ui.color(th.fg, 0.7) end
	lg.circle("fill", on and x + w - h / 2 or x + h / 2, cy, h / 2 - 4)
	return w
end

-- Icons ------------------------------------------------------------------------

function ui.cog(cx, cy, r, bg)
	for i = 0, 7 do
		lg.push()
		lg.translate(cx, cy)
		lg.rotate(i * math.pi / 4)
		lg.rectangle("fill", -r * 0.2, -r, r * 0.4, r * 0.5, 1, 1)
		lg.pop()
	end
	lg.circle("fill", cx, cy, r * 0.72)
	ui.color(bg)
	lg.circle("fill", cx, cy, r * 0.3)
end

function ui.play(cx, cy, r)
	lg.polygon("fill", cx - r * 0.45, cy - r * 0.6, cx - r * 0.45, cy + r * 0.6, cx + r * 0.6, cy)
end

-- Lightning bolt. The outline is concave, and LÖVE only fills convex
-- polygons correctly, so it's split into triangles first.
local boltshape = { 0.3, -1, -0.55, 0.12, -0.02, 0.12, -0.3, 1, 0.55, -0.12, 0.02, -0.12 }
local bolttris = love.math.triangulate(boltshape)

function ui.bolt(cx, cy, r)
	for _, t in ipairs(bolttris) do
		lg.polygon("fill", cx + t[1] * r, cy + t[2] * r, cx + t[3] * r, cy + t[4] * r, cx + t[5] * r, cy + t[6] * r)
	end
end

function ui.pause(cx, cy, r)
	lg.rectangle("fill", cx - r * 0.5, cy - r * 0.55, r * 0.35, r * 1.1, 1, 1)
	lg.rectangle("fill", cx + r * 0.15, cy - r * 0.55, r * 0.35, r * 1.1, 1, 1)
end

return ui
