-- Small, forgiving XML/XHTML parser producing a plain tree:
--   element = { tag = "p", attrs = { class = "..." }, children = { ... } }
--   text    = string (entities already decoded)
-- Tag and attribute names are lowercased with any namespace prefix removed.

local text = require("lib.text")

local xml = {}

local function localname(name)
	return (name:match(":([^:]+)$") or name):lower()
end

local function parseattrs(s)
	local attrs = {}
	for name, _, value in s:gmatch("([%w_:%-%.]+)%s*=%s*([\"'])(.-)%2") do
		attrs[localname(name)] = text.decodeentities(value)
	end
	return attrs
end

-- Elements that never have children in HTML, even when written without "/>".
local void = { br = true, hr = true, img = true, meta = true, link = true, input = true }

function xml.parse(s)
	s = text.toutf8(s) -- books in legacy encodings, or with a stray byte, stay readable
	local root = { tag = "#root", attrs = {}, children = {} }
	local stack = { root }
	local pos, n = 1, #s

	local function add(node)
		local kids = stack[#stack].children
		kids[#kids + 1] = node
	end

	while pos <= n do
		local lt = s:find("<", pos, true)
		if not lt then
			add(text.decodeentities(s:sub(pos)))
			break
		end
		if lt > pos then add(text.decodeentities(s:sub(pos, lt - 1))) end

		if s:sub(lt, lt + 3) == "<!--" then
			local e = s:find("-->", lt + 4, true)
			pos = e and e + 3 or n + 1
		elseif s:sub(lt, lt + 8) == "<![CDATA[" then
			local e = s:find("]]>", lt + 9, true)
			add(s:sub(lt + 9, (e or n + 1) - 1))
			pos = e and e + 3 or n + 1
		elseif s:sub(lt + 1, lt + 1) == "?" or s:sub(lt + 1, lt + 1) == "!" then
			local e = s:find(">", lt, true)
			pos = e and e + 1 or n + 1
		else
			-- The tag ends at the first ">" outside a quoted attribute value.
			local gt
			local j = lt + 1
			while true do
				local k = s:find("[>\"']", j)
				if not k then break end
				local c = s:sub(k, k)
				if c == ">" then
					gt = k
					break
				end
				local close = s:find(c, k + 1, true)
				if not close then break end
				j = close + 1
			end
			if not gt then break end
			local inner = s:sub(lt + 1, gt - 1)
			pos = gt + 1

			local closing = inner:match("^%s*/%s*([^%s>]+)")
			if closing then
				local tag = localname(closing)
				-- Pop up to the matching element; ignore stray close tags.
				for i = #stack, 2, -1 do
					if stack[i].tag == tag then
						for _ = #stack, i, -1 do stack[#stack] = nil end
						break
					end
				end
			else
				local name, rest = inner:match("^%s*([^%s/>]+)(.*)$")
				if name then
					local selfclose = rest:match("/%s*$") ~= nil
					local node = { tag = localname(name), attrs = parseattrs(rest), children = {} }
					add(node)
					if not selfclose and not void[node.tag] then
						stack[#stack + 1] = node
					end
				end
			end
		end
	end

	return root
end

-- Depth-first search for the first element with the given tag.
function xml.find(node, tag)
	if type(node) ~= "table" then return nil end
	if node.tag == tag then return node end
	for _, child in ipairs(node.children) do
		local found = xml.find(child, tag)
		if found then return found end
	end
end

-- Collect all elements with the given tag.
function xml.findall(node, tag, out)
	out = out or {}
	if type(node) == "table" then
		if node.tag == tag then out[#out + 1] = node end
		for _, child in ipairs(node.children) do xml.findall(child, tag, out) end
	end
	return out
end

-- Concatenated text content of a node.
function xml.text(node)
	if type(node) == "string" then return node end
	local parts = {}
	for _, child in ipairs(node.children) do parts[#parts + 1] = xml.text(child) end
	return table.concat(parts)
end

return xml
