-- Dev-only: runs PURE Luau modules + TestEZ-style specs headless under Lune (https://lune-org.github.io/docs). Usage, from the repo root: lune run scripts/dev/lune-spec-harness.luau -- src/Tests/Domain/DomainTypes.spec.lua. Add --fake-dom for a spec that mounts Fusion UI (structure only; see FAKE_DOM below); Packages/ must be installed for those. Cannot run specs that need a real Workspace/Instances (HitboxEngine, Projectile, DomainStrike) -- those need Studio. Patches Lune's CFrame.lookAt, which is wrong along the Z axis.
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
-- Datatypes Lune does not model, as plain records: enough for a module to build its constants at load.
for _, name in { "TweenInfo", "PhysicalProperties", "DockWidgetPluginGuiInfo" } do
	if env[name] == nil then
		env[name] = { new = function(...) return table.pack(...) end }
	end
end
-- carry over standard globals
for _, name in { "math", "string", "table", "os", "tostring", "tonumber", "type", "typeof", "pairs", "ipairs", "next", "select", "pcall", "xpcall", "error", "assert", "print", "warn", "setmetatable", "getmetatable", "rawget", "rawset", "rawequal", "unpack", "utf8", "buffer", "bit32", "coroutine", "task", "require" } do
	env[name] = (_G :: any)[name]
end
env.task = { spawn = function(f, ...) return coroutine.wrap(f)(...) end, defer = function(f, ...) return coroutine.wrap(f)(...) end, wait = function() return 0 end, delay = function() end }
env.warn = function(...) end

-- `--fake-dom`: a pure-Lua stand-in for Roblox's Instance tree, for specs that MOUNT UI (Fusion screens). Lune's
-- own Instances have properties but no events, and Fusion connects Activated, SelectionGained, ... on every
-- control it builds. This one has a signal for any event name, a parent/child tree with FindFirstChild /
-- GetChildren / GetDescendants, attributes and Destroy. It lays nothing out and renders nothing: what a spec
-- can assert with it is STRUCTURE (what was built, what is visible), never geometry. Off by default, so specs
-- that build real Parts and CFrames keep Lune's Instances.
local FAKE_DOM = table.find(process.args, "--fake-dom") ~= nil
if FAKE_DOM then
	local KIND = {} -- marker key: "Instance" | "RBXScriptSignal" | "RBXScriptConnection"
	local function newSignal(): any
		local handlers: { [any]: (...any) -> () } = {}
		local signal: any = { [KIND] = "RBXScriptSignal" }
		function signal:Connect(fn: (...any) -> ())
			local connection: any = { [KIND] = "RBXScriptConnection", Connected = true }
			handlers[connection] = fn
			function connection:Disconnect()
				connection.Connected = false
				handlers[connection] = nil
			end
			return connection
		end
		signal.Once = signal.Connect
		function signal:Fire(...)
			for _, fn in handlers do
				fn(...)
			end
		end
		function signal:Wait() end
		return signal
	end

	-- Members that are events, not properties: read, they give a signal.
	local EVENTS: { [string]: boolean } = {}
	for _, name in {
		"Activated", "MouseEnter", "MouseLeave", "MouseMoved", "MouseButton1Down", "MouseButton1Up",
		"MouseButton1Click", "MouseButton2Click", "MouseWheelForward", "MouseWheelBackward", "SelectionGained",
		"SelectionLost", "SelectionChanged", "FocusLost", "Focused", "InputBegan", "InputChanged", "InputEnded",
		"Changed", "Destroying", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving",
		"AncestryChanged", "AttributeChanged", "Event", "OnClientEvent", "OnServerEvent", "Touched",
		"ReturnPressedFromOnScreenKeyboard", "Ended", "Completed", "Played", "Stopped", "DidLoop",
	} do
		EVENTS[name] = true
	end
	-- Read-only measurements nothing here computes.
	local MEASURED: { [string]: any } = {
		AbsoluteSize = roblox.Vector2.new(0, 0),
		AbsolutePosition = roblox.Vector2.new(0, 0),
		AbsoluteCanvasSize = roblox.Vector2.new(0, 0),
		AbsoluteWindowSize = roblox.Vector2.new(0, 0),
		TextBounds = roblox.Vector2.new(0, 0),
		TextFits = true,
	}
	local GUI_CLASSES: { [string]: boolean } = {
		Frame = true, TextLabel = true, TextButton = true, TextBox = true, ImageLabel = true, ImageButton = true,
		ScrollingFrame = true, ViewportFrame = true, CanvasGroup = true, VideoFrame = true,
	}

	local function isA(className: string, ancestor: string): boolean
		if className == ancestor or ancestor == "Instance" then
			return true
		end
		if ancestor == "GuiObject" or ancestor == "GuiBase2d" then
			return GUI_CLASSES[className] == true
		end
		if ancestor == "GuiButton" then
			return className == "TextButton" or className == "ImageButton"
		end
		if ancestor == "LayerCollector" or ancestor == "GuiBase2d" then
			return className == "ScreenGui" or className == "SurfaceGui" or className == "BillboardGui"
		end
		if ancestor == "BasePart" then
			return className == "Part" or className == "MeshPart" or className == "WedgePart"
		end
		return false
	end

	local function newInstance(className: string): any
		local props: { [string]: any } = { Name = className }
		local children: { any } = {}
		local signals: { [string]: any } = {}
		local changed: { [string]: any } = {}
		local attributes: { [string]: any } = {}
		local instance: any = {}
		local methods: { [string]: any } = {}

		local function signalFor(name: string)
			signals[name] = signals[name] or newSignal()
			return signals[name]
		end
		function methods:GetChildren()
			return table.clone(children)
		end
		function methods:GetDescendants()
			local out = {}
			local function walk(node: any)
				for _, child in node:GetChildren() do
					table.insert(out, child)
					walk(child)
				end
			end
			walk(instance)
			return out
		end
		function methods:FindFirstChild(name: string, recursive: boolean?)
			for _, child in children do
				if child.Name == name then
					return child
				end
			end
			if recursive then
				for _, child in children do
					local found = child:FindFirstChild(name, true)
					if found then
						return found
					end
				end
			end
			return nil
		end
		function methods:WaitForChild(name: string)
			return instance:FindFirstChild(name)
		end
		function methods:FindFirstChildOfClass(name: string)
			for _, child in children do
				if child.ClassName == name then
					return child
				end
			end
			return nil
		end
		function methods:FindFirstChildWhichIsA(name: string, recursive: boolean?)
			for _, child in (if recursive then instance:GetDescendants() else children) do
				if child:IsA(name) then
					return child
				end
			end
			return nil
		end
		function methods:FindFirstAncestorOfClass(name: string)
			local node = props.Parent
			while node do
				if node.ClassName == name then
					return node
				end
				node = node.Parent
			end
			return nil
		end
		function methods:FindFirstAncestorWhichIsA(name: string)
			local node = props.Parent
			while node do
				if node:IsA(name) then
					return node
				end
				node = node.Parent
			end
			return nil
		end
		function methods:IsA(name: string)
			return isA(className, name)
		end
		function methods:IsDescendantOf(other: any)
			local node = props.Parent
			while node do
				if node == other then
					return true
				end
				node = node.Parent
			end
			return false
		end
		function methods:GetPropertyChangedSignal(name: string)
			changed[name] = changed[name] or newSignal()
			return changed[name]
		end
		function methods:GetAttribute(name: string)
			return attributes[name]
		end
		function methods:GetAttributes()
			return table.clone(attributes)
		end
		function methods:SetAttribute(name: string, value: any)
			attributes[name] = value
			signalFor("AttributeChanged"):Fire(name)
		end
		function methods:GetAttributeChangedSignal(name: string)
			return methods.GetPropertyChangedSignal(instance, "@" .. name)
		end
		function methods:Destroy()
			signalFor("Destroying"):Fire()
			for _, child in table.clone(children) do
				child:Destroy()
			end
			instance.Parent = nil
		end
		function methods:ClearAllChildren()
			for _, child in table.clone(children) do
				child:Destroy()
			end
		end
		function methods:GetFullName()
			return props.Name
		end
		-- A BindableEvent's Fire reaches its Event; a BindableFunction is not modelled.
		function methods:Fire(...)
			signalFor("Event"):Fire(...)
		end
		function methods:_adopt(child: any)
			table.insert(children, child)
		end
		function methods:_release(child: any)
			local index = table.find(children, child)
			if index then
				table.remove(children, index)
			end
		end

		setmetatable(instance, {
			__index = function(_, key)
				if key == KIND then
					return "Instance"
				elseif key == "ClassName" then
					return className
				end
				local method = methods[key]
				if method then
					return method
				end
				local value = props[key]
				if value ~= nil then
					return value
				end
				if EVENTS[key] then
					return signalFor(key)
				end
				if MEASURED[key] ~= nil then
					return MEASURED[key]
				end
				return nil
			end,
			__newindex = function(_, key, value)
				if key == "Parent" then
					local old = props.Parent
					if old == value then
						return
					end
					if old then
						old:_release(instance)
					end
					props.Parent = value
					if value then
						value:_adopt(instance)
					end
					signalFor("AncestryChanged"):Fire(instance, value)
				else
					props[key] = value
				end
				local signal = changed[key]
				if signal then
					signal:Fire()
				end
			end,
			__tostring = function()
				return props.Name
			end,
		})
		return instance
	end

	env.Instance = {
		new = function(className: string, parent: any?)
			local instance = newInstance(className)
			if parent then
				instance.Parent = parent
			end
			return instance
		end,
	}
	local realTypeof = env.typeof or typeof
	env.typeof = function(value: any): string
		if type(value) == "table" then
			local kind = rawget(value, KIND)
			if kind then
				return kind
			end
			local mt = getmetatable(value)
			if mt and type(mt) == "table" and type(mt.__index) == "function" then
				local ok, indexed = pcall(mt.__index, value, KIND)
				if ok and indexed == "Instance" then
					return "Instance"
				end
			end
		end
		return realTypeof(value)
	end
end

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
-- Wally's Packages folder (when installed), reached as ReplicatedStorage.Packages -- the place layout.
local PACKAGES = REPO .. "Packages"
if fs.isDir(PACKAGES) then scan(PACKAGES) end
local function exists(p: string): boolean
	return files[p] == true or dirs[p] == true
end

local function resolveChild(path: string, name: string): string?
	if path == ROOTS.ReplicatedStorage and name == "Packages" and dirs[PACKAGES] then
		return PACKAGES
	end
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
		if dirs[p] then p = if files[p .. "/init.luau"] then p .. "/init.luau" else p .. "/init.lua" end
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
				if path:match("/init%.luau?$") then
					parent = path:match("^(.*)/[^/]+/init%.luau?$")
				end
				return if parent then proxyOf(parent) else nil
			elseif key == "Name" then
				return path:match("([^/]+)$"):gsub("%.luau?$", "")
			end
			local dir = path
			if path:match("%.luau?$") then
				dir = path:gsub("%.luau?$", "")
				if not dirs[dir] then
					-- init.lua module: children are siblings in its dir
					if path:match("/init%.luau?$") then dir = path:match("^(.*)/init%.luau?$") end
				end
			end
			local child = resolveChild(dir, key)
			if child then
				if child:match("%.luau?$") == nil and dirs[child] then
					if files[child .. "/init.luau"] then
						return proxyOf(child .. "/init.luau")
					elseif files[child .. "/init.lua"] then
						return proxyOf(child .. "/init.lua")
					end
				end
				return proxyOf(child)
			end
			return nil
		end,
	})
	proxyCache[path] = p
	return p
end

-- Anything a module touches on a service this harness does not model (RunService.Heartbeat:Connect(...), say):
-- indexable and callable, all the way down, and inert.
local STUB: any
STUB = setmetatable({}, {
	__index = function()
		return STUB
	end,
	__call = function()
		return STUB
	end,
})

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
		-- Workspace's camera, at the reference resolution (Client/UI/ViewportScale), so a screen that scales
		-- itself to the viewport mounts at scale 1 rather than reading a stub as a size. Everything else on the
		-- camera stays inert.
		if name == "Workspace" then
			local camera = setmetatable({ ViewportSize = env.Vector2.new(1366, 768) }, {
				__index = function()
					return STUB
				end,
			})
			services[name] = setmetatable({ CurrentCamera = camera }, { __index = function() return STUB end })
			return services[name]
		end
		local guid = 0
		services[name] = setmetatable({
			-- Fusion keys its listeners by these.
			GenerateGUID = function()
				guid += 1
				return `guid-{guid}`
			end,
		}, { __index = function(_, k) return STUB end })
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
	if specPath == "--" or specPath == "--fake-dom" then continue end
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
