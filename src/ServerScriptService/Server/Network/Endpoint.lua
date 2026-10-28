--!strict
--[[
	Endpoint.lua

	Owns: how a System puts a remote on the wire. One declaration creates the remote, rate-limits it, applies the admin gate if
	asked, decodes the untrusted arguments through Shared/Schema, wraps the handler in a pcall that answers with the System's
	own error result, logs every refusal, and DECLARES the remote to BootManifest. A System writes what the remote does; it no
	longer re-assembles the same five parts around it.

	WHY (coworking plan, 2026-10-25, F2). 73 server handlers each hand-assembled NetworkBridge + RateLimiter + RemoteHandler +
	AdminGate + per-argument `typeof` checks, slightly differently each time, and BootManifest kept a second, hand-maintained copy
	of which remotes each System creates. Endpoint composes the parts that already exist -- it does not replace them, and it keeps
	every guarantee their headers document (NetworkBridge's memoised, claim-once creation; RateLimiter's per-category buckets;
	RemoteHandler's catch-log-answer boundary; AdminGate's auth-then-limit order and reason strings).

	USE. A System makes ONE scope in its file and declares through it:

		local endpoint = Endpoint.Scope("SettingsSystem", logger)
		endpoint.Function({
			Name = RemoteNames.GetSettings,
			Limiter = getRateLimiter,
			ErrorResult = DEFAULT_SETTINGS,
			Handler = handleGetSettings,
		})
		endpoint.Event({
			Name = RemoteNames.UpdateAutorun,
			Limiter = rateLimiter,
			Args = { Schema.Boolean },
			Handler = function(player, enabled) ... end,
		})
		local pushed = endpoint.Push(RemoteNames.SomethingUpdated)   -- a server -> client remote the System FireClients

	`Event`/`Function` return `{ Remote, Handle }`; `Handle(player, ...)` is the composed handler, for specs (the harness cannot
	`FireServer`). An Event's result also carries its `Connection`, for a System that tears its handlers down in a `Stop` and may
	Init again (DomainSystem adds it to its Trove); a Function has none to give, since OnServerInvoke is a property. `Push` returns the RemoteEvent (or UnreliableRemoteEvent with `Unreliable = true`: traffic that is SAFE TO LOSE,
	see NetworkBridge).

	THE LIMITER IS REQUIRED and is always the System's own `RateLimiter.New(...)`, created in its own file: RateLimiter reports
	where a limiter was made, and one category of traffic must not share a bucket with another (EmoteSystem's play vs stop split).
	Endpoint never constructs one. A System that clears buckets on PlayerRemoving keeps doing so.

	ORDER OF REFUSAL, fixed so every System answers the same way: rate limit (admin: auth first, then rate limit, AdminGate's order),
	then argument decode, then the handler. A refused Event is silently dropped (logged at debug); a refused Function answers:
	`OnLimited(player)` when rate limited (default `ErrorResult`), `Invalid` when arguments fail decode (a value, or a function of the failing argument's index; default `ErrorResult`), and
	for an admin Function `Denied(reason)` with AdminGate's "NotAuthorized"/"RateLimited". A handler that throws answers
	`ErrorResult` (Function) or is logged (Event) -- it never throws across the remote boundary.

	`Args` is a list of Schema shapes, one per argument after the player. A shape that FAILS refuses the call; a shape that clamps
	(Schema.Number) hands the handler the clamped value. Extra arguments a client sends are ignored. A handler whose argument
	validation answers with a bespoke reason per argument (and so cannot be one `Invalid`) leaves `Args` off and validates inside
	with Schema itself; it still gets the limiter, the pcall, the logging and the declaration.

	DECLARING. Every remote made here is declared to BootManifest under the scope's owner, so the manifest's hand-kept `Remotes`
	list for that System can be empty. AssertBootComplete still fails on a declared remote that never appeared and on a created
	one nobody declared.

	Does not own: what a remote does, who may call it beyond the admin whitelist (the handler), the shape of a System's result, or
	remotes a System only RESOLVES (NetworkBridge.Get*). `ServerHopSystem`'s `(boolean, string?)` return is the one shape
	WrapInvoke could not express and Endpoint.Function does not either; it is listed in scripts/check-endpoints.py's exemptions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BootManifest = require(script.Parent.Parent.Config.BootManifest)
local Logger = require(ReplicatedStorage.Shared.Logger)
local NetworkBridge = require(ReplicatedStorage.Shared.NetworkBridge)
local RateLimiter = require(ReplicatedStorage.Shared.RateLimiter)
local Schema = require(ReplicatedStorage.Shared.Schema)
local AdminGate = require(script.Parent.AdminGate)

local Endpoint = {}

export type Limiter = RateLimiter.RateLimiterInstance

export type EventSpec = {
	Name: string,
	Limiter: Limiter,
	-- One shape per argument after the player. Absent: the handler receives the raw arguments and decodes them itself.
	Args: { Schema.Shape<any> }?,
	-- Requires the player to be on the admin whitelist (AdminGate.Check, which also applies the limiter).
	Admin: boolean?,
	Handler: (player: Player, ...any) -> (),
}

export type FunctionSpec = {
	Name: string,
	Limiter: Limiter,
	Args: { Schema.Shape<any> }?,
	Admin: boolean?,
	-- What the caller gets when the handler throws, and the default for every refusal below.
	ErrorResult: any,
	-- Called instead of answering ErrorResult when the player is rate limited. May return nil.
	OnLimited: ((player: Player) -> any)?,
	-- The answer when `Args` fails to decode: a value, or a function of the player and the 1-based index of the argument that
	-- failed, for a remote whose callers are told WHICH argument was wrong (ArtSystem's InvalidSlot / InvalidArtId).
	Invalid: any?,
	-- For an admin Function: the answer for AdminGate's "NotAuthorized" / "RateLimited".
	Denied: ((reason: string) -> any)?,
	Handler: (player: Player, ...any) -> any,
}

export type Bound = {
	Remote: Instance,
	-- The composed handler (limiter, decode, pcall around Handler). What the remote's connection calls.
	Handle: (player: Player, ...any) -> any,
	-- Event only: the OnServerEvent connection, for a System whose Stop must disconnect it.
	Connection: RBXScriptConnection?,
}

export type Scope = {
	Owner: string,
	Event: (spec: EventSpec) -> Bound,
	Function: (spec: FunctionSpec) -> Bound,
	Push: (name: string, options: { Unreliable: boolean? }?) -> RemoteEvent,
}

-- Decodes `raw` against `shapes`. Returns the decoded list, or nil with the reason and the index of the argument that failed.
local function decodeArgs(shapes: { Schema.Shape<any> }, ...: any): ({ any }?, string?, number?)
	local decoded: { any } = {}
	local raw = { ... }
	for index, shape in shapes do
		local value, reason = shape(raw[index])
		if reason ~= nil then
			local text = tostring(if Schema.IsTable(reason) then (reason :: any).Code else reason)
			return nil, `argument {index}: {text}`, index
		end
		decoded[index] = value
	end
	return decoded, nil, nil
end

-- AdminGate (auth, then limiter) or the limiter alone. Returns nil when the call may proceed, else the refusal reason.
local function refusal(player: Player, name: string, limiter: Limiter, admin: boolean?): string?
	if admin then
		local ok, reason = AdminGate.Check(player, name, limiter)
		if not ok then
			return reason or "Refused"
		end
		return nil
	end
	if limiter:IsLimited(player) then
		return "RateLimited"
	end
	return nil
end

function Endpoint.Scope(owner: string, logger: Logger.LoggerScope): Scope
	assert(
		Schema.IsString(owner) and owner ~= "",
		"Endpoint.Scope: an owner (the System's BootManifest name) is required"
	)

	local scope = {} :: Scope
	scope.Owner = owner

	local function declare(name: string): ()
		BootManifest.DeclareRemote(owner, name)
	end

	function scope.Event(spec: EventSpec): Bound
		assert(spec.Limiter ~= nil, `Endpoint.Event("{spec.Name}"): every public remote needs a RateLimiter`)
		declare(spec.Name)
		local remote = NetworkBridge.CreateRemoteEvent(spec.Name)

		local function handle(player: Player, ...: any): ()
			if refusal(player, spec.Name, spec.Limiter, spec.Admin) ~= nil then
				return
			end
			local ok, err
			if spec.Args then
				local decoded, reason = decodeArgs(spec.Args, ...)
				if decoded == nil then
					logger:debug(`{spec.Name} rejected: {reason}`, { player = player.Name })
					return
				end
				ok, err = pcall(spec.Handler, player, table.unpack(decoded, 1, #spec.Args))
			else
				ok, err = pcall(spec.Handler, player, ...)
			end
			if not ok then
				logger:error(`{spec.Name} handler errored`, { player = player.Name, errorMessage = tostring(err) })
			end
		end

		local connection = remote.OnServerEvent:Connect(handle)
		return { Remote = remote, Handle = handle, Connection = connection }
	end

	function scope.Function(spec: FunctionSpec): Bound
		assert(spec.Limiter ~= nil, `Endpoint.Function("{spec.Name}"): every public remote needs a RateLimiter`)
		declare(spec.Name)
		local remote = NetworkBridge.CreateRemoteFunction(spec.Name)

		local function handle(player: Player, ...: any): any
			local ok, result = pcall(function(...: any): any
				local reason = refusal(player, spec.Name, spec.Limiter, spec.Admin)
				if reason ~= nil then
					if spec.Admin and spec.Denied then
						return spec.Denied(reason)
					end
					if reason == "RateLimited" and spec.OnLimited then
						return spec.OnLimited(player)
					end
					return spec.ErrorResult
				end
				if spec.Args then
					local decoded, why, argumentIndex = decodeArgs(spec.Args, ...)
					if decoded == nil then
						logger:debug(`{spec.Name} rejected: {why}`, { player = player.Name })
						if Schema.IsFunction(spec.Invalid) then
							return (spec.Invalid :: any)(player, argumentIndex)
						end
						if spec.Invalid ~= nil then
							return spec.Invalid
						end
						return spec.ErrorResult
					end
					return spec.Handler(player, table.unpack(decoded, 1, #spec.Args))
				end
				return spec.Handler(player, ...)
			end, ...)
			if not ok then
				logger:error(`{spec.Name} handler errored`, { player = player.Name, errorMessage = tostring(result) })
				return spec.ErrorResult
			end
			return result
		end

		remote.OnServerInvoke = handle
		return { Remote = remote, Handle = handle }
	end

	function scope.Push(name: string, options: { Unreliable: boolean? }?): RemoteEvent
		declare(name)
		if options and options.Unreliable then
			return NetworkBridge.CreateUnreliableRemoteEvent(name) :: any
		end
		return NetworkBridge.CreateRemoteEvent(name)
	end

	return scope
end

return Endpoint
