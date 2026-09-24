-- Background image loading with a bounded texture cache.
--
-- Inflating and decoding happen on worker threads, so the main thread only
-- uploads finished pixels to the GPU. Textures that haven't been drawn or
-- prefetched recently are released once the cache goes over its budget.

local images = {}

local WORKERS = 2
local BUDGET = 192 * 1024 * 1024 -- bytes of texture memory to keep around

local worker = [[
require("love.data")
require("love.filesystem")
require("love.image")
local jobs = love.thread.getChannel((...)) -- this worker's own queue
local results = love.thread.getChannel("luareader_img_results")
while true do
	local key = jobs:demand()
	if key == "quit" then break end
	local raw, method = jobs:demand(), jobs:demand()
	local ok, data = pcall(function()
		if method == 8 then raw = love.data.decompress("string", "deflate", raw) end
		return love.image.newImageData(love.filesystem.newFileData(raw, "image"))
	end)
	results:performAtomic(function(ch)
		ch:push(key)
		ch:push(ok and data or false)
	end)
end
]]

-- Each worker has its own job queue: a job is three values, and with a
-- shared queue two workers could each grab part of the same job.
local queues, results
local nextworker = 1
local threads = {}
local cache = {} -- key -> { img, pending, failed, used, bytes }
local pending = 0
local frame = 0
local total = 0

function images.init()
	results = love.thread.getChannel("luareader_img_results")
	queues = {}
	for i = 1, WORKERS do
		local name = "luareader_img_jobs_" .. i
		queues[i] = love.thread.getChannel(name)
		threads[i] = love.thread.newThread(worker)
		threads[i]:start(name)
	end
end

-- Returns the texture for key if it's ready. Otherwise starts loading it:
-- loader() must return the raw (possibly deflated) bytes and zip method.
function images.get(key, loader)
	local e = cache[key]
	if e then
		e.used = frame
		return e.img
	end
	local raw, method = loader()
	if not raw then
		cache[key] = { failed = true, used = frame }
		return nil
	end
	cache[key] = { pending = true, used = frame }
	pending = pending + 1
	local q = queues[nextworker]
	nextworker = nextworker % WORKERS + 1
	q:performAtomic(function(ch)
		ch:push(key)
		ch:push(raw)
		ch:push(method or 0)
	end)
	return nil
end

function images.busy() return pending > 0 end

-- "ready" and the texture, "pending", "failed", or nil if never requested.
function images.status(key)
	local e = cache[key]
	if not e then return nil end
	if e.img then return "ready", e.img end
	return e.pending and "pending" or "failed"
end

local function free(key)
	local e = cache[key]
	if e and e.img then
		e.img:release()
		total = total - e.bytes
	end
	cache[key] = nil
end

images.drop = free

function images.clear()
	for key, e in pairs(cache) do
		-- Keep pending entries so their results are recognised and freed.
		if e.pending then e.orphan = true else free(key) end
	end
end

-- Call once per frame: picks up decoded images and trims the cache.
function images.update()
	frame = frame + 1
	while true do
		local key = results:pop()
		if key == nil then break end
		local data = results:pop()
		pending = pending - 1
		local e = cache[key]
		if e and not e.orphan and data then
			e.img = love.graphics.newImage(data, { mipmaps = true })
			e.img:setFilter("linear", "linear")
			e.img:setMipmapFilter("linear")
			e.bytes = data:getWidth() * data:getHeight() * 4 * 4 / 3
			total = total + e.bytes
			e.pending = false
		elseif e then
			if e.orphan then cache[key] = nil else e.pending, e.failed = false, true end
		end
		if data then data:release() end
	end

	if total > BUDGET then
		local old = {}
		for key, e in pairs(cache) do
			if e.img and e.used < frame - 1 then old[#old + 1] = key end
		end
		table.sort(old, function(a, b) return cache[a].used < cache[b].used end)
		for _, key in ipairs(old) do
			if total <= BUDGET then break end
			free(key)
		end
	end
end

function images.shutdown()
	for i = 1, #threads do queues[i]:push("quit") end
end

return images
