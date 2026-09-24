-- Reads an image's pixel size from its header, without decoding it.
-- Supports the formats LÖVE can decode: PNG, JPEG, BMP.

local function be16(s, i) return (love.data.unpack(">I2", s, i)) end
local function be32(s, i) return (love.data.unpack(">I4", s, i)) end
local function le32(s, i) return (love.data.unpack("<i4", s, i)) end

return function(s)
	if not s or #s < 24 then return nil end

	if s:sub(1, 8) == "\137PNG\r\n\26\n" then
		return be32(s, 17), be32(s, 21)
	end

	if s:sub(1, 2) == "BM" and #s >= 26 then
		return le32(s, 19), math.abs(le32(s, 23))
	end

	if s:sub(1, 2) == "\255\216" then
		-- Walk the JPEG segments until a start-of-frame marker.
		local i, n = 3, #s
		while i + 8 <= n do
			if s:byte(i) ~= 0xFF then
				i = i + 1
			else
				local m = s:byte(i + 1)
				if m == 0xFF then
					i = i + 1
				elseif m == 0xD8 or m == 0x01 or (m >= 0xD0 and m <= 0xD7) then
					i = i + 2
				elseif m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
					return be16(s, i + 7), be16(s, i + 5)
				else
					i = i + 2 + be16(s, i + 2)
				end
			end
		end
	end
end
