# Shattered Meridian — working notes

Roblox Luau project. Rojo-managed, TestEZ specs, selene + stylua gates. Full style rules live in
[`docs/luau-coding-standards.md`](docs/luau-coding-standards.md) (amendments to the studio bible) and
[`docs/ui-ux-philosophy.md`](docs/ui-ux-philosophy.md). Architecture/performance findings are tracked
in dated audits under `docs/architecture/` — read the latest one before a large change, and don't
restate a finding it already covers without re-verifying against current source first (audits date
fast on this branch; most of the tree is uncommitted at any given time).

## Shared modules — reach for these before hand-rolling

Every one of these exists because the pattern it replaces was independently hand-written wrong, or
inconsistently, at 3+ call sites first. If you're about to write one of the patterns on the left,
stop and use the module on the right instead.

| If you're about to... | Use | Not... |
|---|---|---|
| track connections/instances to tear down together | [`Shared/Trove.lua`](src/ReplicatedStorage/Shared/Trove.lua) — `Trove.New()`, `:Add()`, `:Connect(signal, fn)`, `:Extend()` for a nested scope, `:Clean()` | a bare `local conn: RBXScriptConnection? = nil` field that someone has to remember to nil-check and disconnect |
| bind to a player's/local player's successive characters | [`Shared/PlayerLifecycle.lua`](src/ReplicatedStorage/Shared/PlayerLifecycle.lua) — `BindLocalCharacter` (client) / `BindAllPlayers` (server) | raw `CharacterAdded`/`CharacterRemoving`/`Players.PlayerAdded` wiring — it silently loses 3 races: Humanoid-not-replicated-yet, binding on the synchronous boot thread, and a fast respawn during the wait leaving you bound to a corpse |
| build something expensive only for the players who'll use it (admin UI, etc.) | [`Shared/Lazy.lua`](src/ReplicatedStorage/Shared/Lazy.lua) — `Lazy.new(name, buildFn)`, `:Get()`, `:IsResolved()` | building it unconditionally at boot for every player |
| sweep a per-Model table every frame just to drop entries whose Model despawned, with no other per-entry work | [`Shared/AmortizedReclaim.lua`](src/ReplicatedStorage/Shared/AmortizedReclaim.lua) — `AmortizedReclaim.New()`, `:Step(map)` | a full `for key in map do ... end` scan every tick. **Only for reclaim-only sweeps** — a loop that also does per-entry work (advances physics, releases holds, calls `Humanoid:Move`) must keep its full walk; skipping entries there drops a frame of gameplay, not just delays cleanup |
| look up a Model's/Player's Humanoid or HumanoidRootPart | [`Shared/CharacterUtil.lua`](src/ReplicatedStorage/Shared/CharacterUtil.lua) — `HumanoidOf`, `LiveHumanoidOf` (excludes dead), `RootOf`, `LiveRig(player)` | `model:FindFirstChildOfClass("Humanoid")` copy-pasted at the call site |
| find-or-create an Animator to load an AnimationTrack onto | [`Shared/AnimatorUtil.lua`](src/ReplicatedStorage/Shared/AnimatorUtil.lua) — `GetOrCreateAnimator(character)` | duplicating the Humanoid→Animator lookup in every FX/animator module |
| create or resolve a RemoteEvent/RemoteFunction | [`Shared/NetworkBridge.lua`](src/ReplicatedStorage/Shared/NetworkBridge.lua) — owning System calls `Create*` once in `Init()`; both sides call `Get*` at point of use (lookups are memoized, so this is cheap now — no need to hoist into a module-scope cache yourself) | instancing a Remote ad hoc outside the owning System, or hand-rolling a resolution cache |
| rate-limit a RemoteEvent/RemoteFunction handler | [`Shared/RateLimiter.lua`](src/ReplicatedStorage/Shared/RateLimiter.lua) — `RateLimiter.New(maxPerSecond)`, `:IsLimited(player)`, `:Clear(player)` on `PlayerRemoving` | no bucket at all — every public remote in this codebase has one; a new one without it is a gap, not a style choice |
| pcall-wrap a `RemoteFunction.OnServerInvoke` handler so an internal error can't throw across the remote boundary | [`Shared/RemoteHandler.lua`](src/ReplicatedStorage/Shared/RemoteHandler.lua) — `RemoteHandler.WrapInvoke(logger, name, errorResult, handler)` | a bare `pcall(handler, player, ...)` hand-written per System — this was independently duplicated at 4+ call sites before being collapsed here |
| push a value to clients only when it actually changed | [`Shared/ChangeNotifier.lua`](src/ReplicatedStorage/Shared/ChangeNotifier.lua) — `:New()`, `:Update(player, value)` returns whether it changed, `:Clear(player)` | firing a remote unconditionally every tick |
| write to a DataStore | [`Shared/DataStoreRetry.lua`](src/ReplicatedStorage/Shared/DataStoreRetry.lua) — `DataStoreRetry.Attempt(...)` | a bare `pcall` around one `SetAsync`/`GetAsync` with no retry |
| add a new server System | Add an entry to [`Server/Config/BootManifest.lua`](src/ServerScriptService/Server/Config/BootManifest.lua) (`Name`, `Path`, `Remotes`) — checked at boot (`AssertBootComplete`) and in `Tests/Boot/BootManifest.spec.lua` | leaving it boot-list-only — a System dropped from `Main.server.lua` or never declared here fails silently: clients `WaitForChild`-timeout one at a time instead of the boot itself erroring |
| log inside a module | [`Shared/Logger.lua`](src/ReplicatedStorage/Shared/Logger.lua) — `Logger.scope("ModuleName")`, then `:info/:warn/:error/:debug` | `print`/`warn` directly — scoped logs feed the Live Console (F5) capture ring |

Full rationale for each module (why it exists, what it deliberately does NOT own, the specific bugs
it closes) is in that module's own header comment — read it before extending one, not just before
calling it.

Two more of these live outside `ReplicatedStorage/Shared` because of who's allowed to require them,
not because they're less canonical — the same "reach for this before hand-rolling" bar applies:

- Gating a remote handler behind the admin whitelist (auth check + rate limit + rejection logging)?
  Use [`Server/Network/AdminGate.lua`](src/ServerScriptService/Server/Network/AdminGate.lua) —
  `AdminGate.Check(player, actionName, limiter)` — not a hand-copied `isAuthorized` +
  `checkXPreconditions` pair per System (this exact pair was independently duplicated in three
  Systems before being collapsed here). Lives under `Server/`, not `Shared/`, because it requires
  `Server/Config/AdminConfig.lua`, which must never be reachable from a client-decompilable module.
  Always pass your own `RateLimiterInstance` — it never constructs or defaults one itself.
- Calling `RemoteFunction:InvokeServer(...)` from a client module and turning the result (or a
  thrown error) into a status string? Use
  [`Client/Network/RemoteInvoker.lua`](src/StarterPlayer/StarterPlayerScripts/Client/Network/RemoteInvoker.lua)
  — `RemoteInvoker.Invoke(remote, ...)` returns `(ok, Result...)`; `RemoteInvoker.InvokeAndReport(setStatus, remote, args, describe, errorStatus?)`
  wraps that plus the invoke→describe→setStatus shape every dev-tool client hand-wrote separately —
  not a bare `pcall(function() return remote:InvokeServer(...) end)` at the call site.

## Combat stack layering

`HitboxEngine → DefenseSystem → DamageSystem → AttackRequestSystem` — all four layers are built and
wired (`Main.server.lua` boots them in that order; each `Init()` asserts the layer below is already
available). Each layer is ignorant of the one above it and gets **exactly one narrow upward seam**
into the layer below when it needs something new (e.g. `DamageSystem.DrainGuard` reaching into
`DefenseSystem`'s guard pool). If a change seems to need more than one new seam, the layer boundary
is probably in the wrong place — don't widen the seam to fit it.

`GrabSystem` is a **sibling of `AttackRequestSystem`, not a fifth layer** stacked on top of it — it
subscribes to `DamageSystem.OnApplied` (that function's own documented extension point) and is read by
`AttackRequestSystem.Throw` as a third `CanAttack`-shaped gate, the same way `DefenseSystem.CanAttack`/
`DamageSystem.CanAttack` already are. It boots immediately after `AttackRequestSystem`. Extending combat
with a new interaction kind should default to this sibling shape (subscribe to an existing extension
point, get read through a narrow gate) before assuming it needs to become a fifth stacked layer.

## Before claiming something is "wired" or "done"

Bootstrap tracing (`Main.server.lua`/`Main.client.lua`/`UI/init.lua` call it) proves the app *starts*
it, not that a player can *reach* it. For any new module: `grep -rn "require(.*<Name>)" src/` and
confirm a non-zero inbound-require count from outside its own folder. Zero means dead code no matter
how complete or well-commented the file is (this codebase's header comments describe intended
integration as prose, which reads deceptively like a finished one). For a data/animation path
specifically, follow the SPECIFIC runtime call path a player's action takes end-to-end — two
components independently agreeing with each other is not evidence a third consumer was updated.

## Toolchain

- **Lint:** `selene src/` — must be 0/0. Needs `selene generate-roblox-std` run once locally first
  (machine-specific, not checked in).
- **Format:** `stylua src/` then `stylua --check src/`. Tree-wide `--check` is **not a reliable gate**
  on this branch — CRLF/LF churn is intermittent (see `stylua.toml`'s `line_endings = "Unix"` vs. the
  Windows CRLF checkout). Prefer `stylua --check` on just the files you touched. If a plain
  `stylua src/` leaves far more files `M` than you edited, diff `git diff --name-only` against your
  edit set and `git checkout --` the rest rather than assuming you broke something.
- **Test:** TestEZ specs under `src/Tests/**/*.spec.lua`. The suite runs on this machine — try it
  before assuming it can't:
  ```
  rojo build test.project.json -o <absolute scratchpad path>.rbxl
  run-in-roblox --place <that path> --script scripts/run-tests.lua
  ```
  Don't pipe the output through `tail` — per-failure assertion detail scrolls off. `test.project.json`
  maps each top-level folder under `Server/` and `Client/` individually (e.g. `Combat`, `Systems`,
  `DevMenu` are each their own `$path` entry) — a new *file* inside one of those already-mapped
  folders (a new System under `Server/Systems`, say) needs no update, but a brand-new top-level
  folder (a new `Server/<Something>` or `Client/<Something>` directory) does, or a broken require only
  surfaces in Studio, not the suite.
- **Strip the BOM on `ParkourConstants.lua` before every build** — something outside Claude Code
  periodically rewrites it with a UTF-8 BOM, which is a hard Luau parse error. ~47 modules require
  `ParkourConstants` directly, so this cascades into most of the combat/parkour require graph failing
  to load and the whole suite silently reporting 0 tests:
  ```
  python -c "p='src/ReplicatedStorage/Shared/Parkour/ParkourConstants.lua'; d=open(p,'rb').read(); open(p,'wb').write(d[3:]) if d.startswith(b'\xef\xbb\xbf') else None"
  ```
- If `run-in-roblox` panics instantly, it's almost always environment/registry skew, not your change
  — see the toolchain notes rather than re-running blind more than once.
