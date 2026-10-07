-- Dev-only: runs PURE Luau modules + TestEZ-style specs headless under Lune (https://lune-org.github.io/docs). Usage, from the repo root: lune run scripts/dev/lune-spec-harness.luau -- src/Tests/Domain/DomainTypes.spec.lua. Cannot run specs that need a real Workspace/Instances (HitboxEngine, Projectile, DomainStrike) -- those need Studio. Patches Lune's CFrame.lookAt, which is wrong along the Z axis.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local REPO = process.cwd
local ROOTS = {
	ReplicatedStorage = REPO .. "src/ReplicatedStorage",
	ServerScriptService = REPO .. "src/ServerScriptService",
	StarterPlayer = REPO .. "src/StarterPlayer",
}

local env: { [string]: any } = {}
for k, v in roblox :: any do
	env[k] = v
end
for _, name in { "Vector3", "Vector2", "CFrame", "Color3", "UDim", "UDim2", "Enum", "Instance", "Random", "NumberRange", "Rect" } do
	env[name] = (roblox :: any)[name]
end
-- Lune's CFrame.lookAt is wrong along the Z axis (and for an up vector); Roblox's is not. Replace it so specs
-- see Roblox's behaviour.
do
	local R3, RC = roblox.Vector3, roblox.CFrame
	local function lookAt(from: any, to: any, up: any?)
		local z = (from - to)
		if z.Magnitude < 1e-9 then return RC.new(from) end
		z = z.Unit
		local upv = up or R3.new(0, 1, 0)
		local x = upv:Cross(z)
		if x.Magnitude < 1e-6 then
			x = R3.new(0, 0, 1):Cross(z)
			if x.Magnitude < 1e-6 then x = R3.new(1, 0, 0) end
		end
		x = x.Unit
		local y = z:Cross(x)
		return RC.fromMatrix(from, x, y, z)
	end
	env.CFrame = setmetatable({ lookAt = lookAt }, { __index = RC })
end
-- carry over standard globals
for _, name in { "math", "string", "table", "os", "tostring", "tonumber", "type", "typeof", "pairs", "ipairs", "next", "select", "pcall", "xpcall", "error", "assert", "print", "warn", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "unpack", "utf8", "buffer", "bit32", "coroutine", "task", "require" } do
	env[name] = (_G :: any)[name]
end
env.task = { spawn = function(f, ...) return coroutine.wrap(f)(...) end, defer = function(f, ...) return coroutine.wrap(f)(...) end, wait = function() return 0 end, delay = function() end }
env.warn = function(...) end

local loaded: { [string]: any } = {}
local proxyOf

local files: { [string]: boolean } = {}
local dirs: { [string]: boolean } = {}
local function scan(dir: string)
	dirs[dir] = true
	for _, name in fs.readDir(dir) do
		local p = dir .. "/" .. name
		if fs.isDir(p) then scan(p) else files[p] = true end
	end
end
for _, root in ROOTS do scan(root) end
local function exists(p: string): boolean
	return files[p] == true or dirs[p] == true
end

local function resolveChild(path: string, name: string): string?
	for _, cand in { path .. "/" .. name .. ".lua", path .. "/" .. name .. ".luau", path .. "/" .. name } do
		if exists(cand) then return cand end
	end
		return nil
end

local fileCache: { [string]: any } = {}
local function loadFile(path: string)
	if loaded[path] ~= nil then return loaded[path] end
	local src = fs.readFile(path)
	local fenv = table.clone(env)
	fenv.script = proxyOf(path)
	fenv.game = env.game
	fenv.require = function(m: any)
		local p = rawget(m, "__path")
		assert(p, "require of non-module proxy")
		if dirs[p] then p = p .. "/init.lua" end
		return loadFile(p)
	end
	local chunk = luau.load(src, { debugName = path, environment = fenv })
	local result = chunk()
	loaded[path] = if result == nil then true else result
	return loaded[path]
end

local proxyCache: { [string]: any } = {}
function proxyOf(path: string): any
	if proxyCache[path] then return proxyCache[path] end
	local p = setmetatable({ __path = path }, {
		__index = function(_, key)
			if key == "Parent" then
				local parent = path:match("^(.*)/[^/]+$")
				if path:match("/init%.lua$") then
					parent = path:match("^(.*)/[^/]+/init%.lua$")
				end
				return if parent then proxyOf(parent) else nil
			elseif key == "Name" then
				return path:match("([^/]+)$"):gsub("%.lua$", "")
			end
			local dir = path
			if path:match("%.lua$") then
				dir = path:gsub("%.lua$", "")
				if not dirs[dir] then
					-- init.lua module: children are siblings in its dir
					if path:match("/init%.lua$") then dir = path:match("^(.*)/init%.lua$") end
				end
			end
			local child = resolveChild(dir, key)
			if child then
				if child:match("%.lua$") == nil and dirs[child] and files[child .. "/init.lua"] then
					return proxyOf(child .. "/init.lua")
				end
				return proxyOf(child)
			end
			return nil
		end,
	})
	proxyCache[path] = p
	return p
end

local services: { [string]: any } = {}
env.game = {
	GetService = function(_, name: string)
		if services[name] then return services[name] end
		local root = ROOTS[name]
		if root then
			local s = setmetatable({ __path = root }, getmetatable(proxyOf(root)))
			services[name] = proxyOf(root)
			return services[name]
		end
		services[name] = setmetatable({}, { __index = function(_, k) return function() return nil end end })
		return services[name]
	end,
}

-- Minimal TestEZ -------------------------------------------------------------------------------------
local stats = { pass = 0, fail = 0, failures = {} :: { string } }
local stack: { string } = {}
local befores: { { () -> () } } = { {} }
local afters: { { () -> () } } = { {} }

local function deepEqual(a: any, b: any): boolean
	if typeof(a) ~= typeof(b) then return false end
	if typeof(a) ~= "table" then return a == b end
	for k, v in a do if not deepEqual(v, b[k]) then return false end end
	for k in b do if a[k] == nil then return false end end
	return true
end

local function expect(value: any)
	local negate = false
	local function check(ok: boolean, msg: string)
		if negate then ok = not ok; msg = "NOT " .. msg end
		if not ok then error(msg, 3) end
	end
	local api: any = {}
	local mt: any = {}
	local self = {}
	self.to = self
	self.be = self
	self.a = nil
	local function matcher(name, fn) self[name] = fn end
	setmetatable(self, { __index = function(t, k)
		if k == "never" then negate = not negate; return t end
		return nil
	end })
	rawset(self, "equal", function(expected: any) check(value == expected, `expected {tostring(expected)}, got {tostring(value)}`); return self end)
	rawset(self, "ok", function() check(value ~= nil and value ~= false, `expected truthy, got {tostring(value)}`); return self end)
	rawset(self, "near", function(expected: number, limit: number?) check(math.abs(value - expected) <= (limit or 1e-5), `expected ~{expected}, got {value}`); return self end)
	rawset(self, "a", function(t: string) check(typeof(value) == t, `expected {t}, got {typeof(value)}`); return self end)
	rawset(self, "an", rawget(self, "a"))
	rawset(self, "throw", function(sub: string?)
		local ok, err = pcall(value)
		if negate then
			if not ok then error("expected no throw: " .. tostring(err), 2) end
		else
			if ok then error("expected a throw", 2) end
			if sub and not string.find(tostring(err), sub, 1, true) then error(`error {tostring(err)} lacks {sub}`, 2) end
		end
		return self
	end)
	rawset(self, "contain", function(x: any) check(table.find(value, x) ~= nil, `expected table to contain {tostring(x)}`); return self end)
	rawset(self, "deepEqual", function(x: any) check(deepEqual(value, x), "deep equal failed"); return self end)
	rawset(self, "greaterThan", function(x) check(value > x, `expected {value} > {x}`); return self end)
	rawset(self, "lessThan", function(x) check(value < x, `expected {value} < {x}`); return self end)
	rawset(self, "never", nil)
	return setmetatable(self, { __index = function(t, k)
		if k == "never" then negate = not negate; return t end
		return nil
	end })
end

env.expect = expect
env.describe = function(name: string, fn: () -> ())
	table.insert(stack, name)
	table.insert(befores, {}); table.insert(afters, {})
	fn()
	table.remove(befores); table.remove(afters)
	table.remove(stack)
end
env.beforeEach = function(fn) table.insert(befores[#befores], fn) end
env.afterEach = function(fn) table.insert(afters[#afters], fn) end
env.beforeAll = env.beforeEach
env.afterAll = env.afterEach
local function it(name: string, fn: () -> ())
	local full = table.concat(stack, " > ") .. " > " .. name
	for _, group in befores do for _, b in group do b() end end
	local ok, err = pcall(fn)
	for _, group in afters do for _, a in group do a() end end
	if ok then stats.pass += 1 else stats.fail += 1; table.insert(stats.failures, full .. "\n    " .. tostring(err)) end
end
env.it = it
env.itFOCUS = it
env.itSKIP = function() end
env.SKIP = function() end
env.FOCUS = function() end
env.describeSKIP = function() end
env.describeFOCUS = env.describe

for _, specPath in process.args do
	if specPath == "--" then continue end
	local ok, err = pcall(loadFile, REPO .. specPath)
	if not ok then
		stats.fail += 1
		table.insert(stats.failures, specPath .. " LOAD ERROR\n    " .. tostring(err))
	else
		local spec = err
		if typeof(spec) == "function" then
			local ok2, err2 = pcall(spec)
			if not ok2 then stats.fail += 1; table.insert(stats.failures, specPath .. " RUN ERROR\n    " .. tostring(err2)) end
		end
	end
end
print(`pass {stats.pass} fail {stats.fail}`)
for _, f in stats.failures do print("FAIL: " .. f) end
if stats.fail > 0 then process.exit(1) end
