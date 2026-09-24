-- Rebindable reader actions and their default keys (LÖVE key constants).

local keys = {}

keys.actions = {
	{ id = "nextpage", label = "Next page", default = { "space", "right", "pagedown" } },
	{ id = "prevpage", label = "Previous page", default = { "left", "pageup", "backspace" } },
	{ id = "scrolldown", label = "Scroll down", default = { "down", "j" } },
	{ id = "scrollup", label = "Scroll up", default = { "up", "k" } },
	{ id = "nextchapter", label = "Next chapter", default = { "n" } },
	{ id = "prevchapter", label = "Previous chapter", default = { "p" } },
	{ id = "start", label = "Start of book", default = { "home" } },
	{ id = "finish", label = "End of book", default = { "end" } },
	{ id = "contents", label = "Contents", default = { "c", "tab" } },
	{ id = "autoscroll", label = "Auto reader on/off", default = { "a" } },
	{ id = "fastreader", label = "Fast reader", default = { "r" } },
	{ id = "slower", label = "Auto reader slower", default = { "z" } },
	{ id = "faster", label = "Auto reader faster", default = { "x" } },
	{ id = "guide", label = "Reading guide on/off", default = { "g" } },
	{ id = "bigger", label = "Bigger text", default = { "=", "kp+" } },
	{ id = "smaller", label = "Smaller text", default = { "-", "kp-" } },
	{ id = "wider", label = "Wider column", default = { "]" } },
	{ id = "narrower", label = "Narrower column", default = { "[" } },
	{ id = "morespace", label = "More line spacing", default = { "." } },
	{ id = "lessspace", label = "Less line spacing", default = { "," } },
	{ id = "theme", label = "Next theme", default = { "t" } },
	{ id = "settings", label = "Settings", default = { "s" } },
	{ id = "fullscreen", label = "Fullscreen", default = { "f", "f11" } },
	{ id = "library", label = "Back to library", default = { "escape", "q" } },
}

-- Fills in any action missing from saved bindings.
function keys.normalize(bindings)
	for _, a in ipairs(keys.actions) do
		if type(bindings[a.id]) ~= "table" then
			bindings[a.id] = { unpack(a.default) }
		end
	end
	return bindings
end

function keys.reset(bindings)
	for _, a in ipairs(keys.actions) do bindings[a.id] = { unpack(a.default) } end
end

-- key -> action id
function keys.map(bindings)
	local map = {}
	for _, a in ipairs(keys.actions) do
		for _, k in ipairs(bindings[a.id]) do map[k] = a.id end
	end
	return map
end

-- Binds key to action, taking it away from any other action.
function keys.bind(bindings, action, key)
	for _, list in pairs(bindings) do
		for i = #list, 1, -1 do
			if list[i] == key then table.remove(list, i) end
		end
	end
	table.insert(bindings[action], key)
end

local names = {
	space = "Space", pagedown = "PgDn", pageup = "PgUp", right = "Right", left = "Left",
	up = "Up", down = "Down", escape = "Esc", backspace = "Bksp", ["return"] = "Enter",
	tab = "Tab", home = "Home", ["end"] = "End", ["kp+"] = "Num +", ["kp-"] = "Num −",
	kpenter = "Num Enter", delete = "Del", insert = "Ins", lshift = "LShift", rshift = "RShift",
	lctrl = "LCtrl", rctrl = "RCtrl", lalt = "LAlt", ralt = "RAlt",
}

function keys.name(k)
	if names[k] then return names[k] end
	if k:match("^f%d+$") then return k:upper() end
	if #k == 1 then return k:upper() end
	return k:sub(1, 1):upper() .. k:sub(2)
end

return keys
