--!strict
--[[
	UI/init.lua

	Owns: the UI framework's single entry point -- creates the root Fusion scope, builds
	ClientState, and mounts every Screens surface (HUD, Menus, DeathFeed, BugReport) into
	the local player's PlayerGui. Called once from Main.client.lua, which now also gets back the
	handles client-side integration modules need (ClientState for read access, DeathFeed's handle to
	drive the death-to-respawn overlay, the DevTools bundle to drive the whitelist-gated dev tooling
	panels, BugReport's handle to drive the player-facing report form) -- see
	Client/DevTools/init.lua and Client/BugReport/BugReportClient.lua. UI/init.lua itself
	still never sends or receives a remote; it only hands each mounted handle to the module that does.

	ShiftLockEngaged: a plain Fusion.Value<boolean> on the root scope, not a Screen's own handle --
	Client/Camera/ShiftLockCamera.lua writes it on every engage/disengage transition and
	UI/Components/ShiftLockCrosshair.lua reads it to draw the crosshair. It used to live on the
	CombatFeedback screen's own handle (Client/UI/Screens/CombatFeedback/init.lua, removed alongside
	the rest of the combat system) purely because that screen happened to be the thing ShiftLockCamera
	was already being handed -- it never had anything to do with combat feedback itself, so it moved
	here instead of needing a new single-purpose screen just to hold one Value.

	Nothing else in the UI tree should create its own root scope or mount directly into
	PlayerGui -- one entry point is what keeps teardown well-defined if this ever needs to unmount
	(e.g. hot-reloading in Studio), per ui-ux-philosophy.md's Framework section.

	SIX SCREENS NO LONGER MOUNT A ScreenGui AT ALL. CarriedResources, Announcement, DeathFeed's kill
	feed, BlimpFuel, WeaponInventory and BlimpHelm each return a TILE, and this file hands each one to
	Shell/Regions.lua with the region and order it belongs at. Those six used to place themselves at
	absolute screen coordinates, and two pairs of them placed themselves at IDENTICAL ones while each
	carrying a comment asserting its corner was free -- see Shell/Regions.lua's header for the
	specific lines. The order numbers passed below are now the entire layout: no panel owns a corner,
	and a seventh tile joins a stack rather than guessing at a free one.

	The region host is mounted BEFORE any of the six, and is held on a local that is passed down --
	never on a module-level upvalue. Shell/Regions.lua's header has the reason in full; the short
	version is that a cached host would survive this file's own :doCleanup() as a reference to a
	destroyed Instance and swallow every tile on a second Mount(), showing a blank screen and logging
	nothing.

	THE UI HAS A MODE NOW, AND IT IS BUILT BETWEEN THE DEATH FEED AND THE REGION HOST. Shell/Chrome.lua
	derives Playing / Menu / Dead from the modal count and DeathFeed's own death state, and the region
	host reads it to dim the ambient layer behind an open panel and to drop the corner tiles while the
	player is down. That ordering is the only thing about it that constrains this file: Chrome's inputs
	must exist before Chrome, and Chrome must exist before the host that yields to it -- which is why
	DeathFeed is mounted several blocks earlier than it used to be. Its tile still joins TopRight at
	order 10, unchanged.

	FIVE SCREENS ARE NEITHER MOUNTED NOR EVEN REQUIRED HERE -- Dev Menu, Move Editor, Kit Editor,
	Live Console and the Storybook live behind Screens/DevTools/init.lua, which this file resolves by
	FindFirstChild rather than by path, and which a build config is allowed to omit entirely. They are
	still handed out as Shared/Lazy.lua thunks and still only actually built the first time the module
	that drives each one decides this player has earned it. Between them the first three alone built
	roughly 257 Instances (105/143/9) on the synchronous boot path, for every player, the overwhelming
	majority of whom will never pass the admin check.

	Deferring the mount was the first half of that fix and is unchanged. The second half is that a
	Lazy defers the MOUNT and cannot defer the `require` that produces the Mount function it closes
	over -- roughly 18.5k lines of admin-only Luau that every client still parsed and closure-built at
	boot, for the same panels nobody can open. Only not shipping the modules removes that, and only
	putting them behind one path lets a build config not ship them. Hence the bundle, and hence the
	single nil-able DevTools field on UIHandles below: five fields that each claim to be present would
	be five lies in a build that omits them, where one honest optional is the truth.

	The mount itself is UNCHANGED and still happens on this file's own root scope -- a deferred screen
	is built later, not built differently, so the teardown story above still holds for all five.
	Nothing else about the boot order moves: DevMenuClient and MoveEditorClient were ALREADY doing
	their real work on their own thread behind a server authorization round trip (see their own
	headers), so the force point is one line further into work that was already deferred. Live Console
	is the one that binds input unconditionally, and it forces on the first open rather than on boot,
	which is the same open-time-not-boot-time gate LiveConsoleSystem's own Subscribe already keeps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Lazy = require(ReplicatedStorage.Shared.Lazy)
local Logger = require(ReplicatedStorage.Shared.Logger)

local ClientStateModule = require(script.State.ClientState)
local HUD = require(script.Screens.HUD)
local Menus = require(script.Screens.Menus)
local DeathFeed = require(script.Screens.DeathFeed)
local CombatFeedbackModule = require(script.Screens.CombatFeedback)
local BugReportModule = require(script.Screens.BugReport)
local AnnouncementModule = require(script.Screens.Announcement)
local NotificationsModule = require(script.Screens.Notifications)
local EmoteWheelModule = require(script.Screens.EmoteWheel)
local SettingsModule = require(script.Screens.Settings)
local BlimpFuelModule = require(script.Screens.BlimpFuel)
local BlimpHelmModule = require(script.Screens.BlimpHelm)
local CarriedResourcesModule = require(script.Screens.CarriedResources)
local FurnacePromptModule = require(script.Screens.FurnacePrompt)
local LockOnMarkerModule = require(script.Screens.LockOnMarker)
local WeaponInventoryModule = require(script.Screens.WeaponInventory)
local ShiftLockCrosshair = require(script.Components.ShiftLockCrosshair)
local ViewportScale = require(script.ViewportScale)
local Chrome = require(script.Shell.Chrome)
local Layers = require(script.Shell.Layers)
local Notify = require(script.Shell.Notify)
local Regions = require(script.Shell.Regions)
local Surface = require(script.Shell.Surface)

-- Structurally identical to Screens/DevTools/init.lua's own DevToolScreens, and RESTATED rather
-- than required: requiring that module here would reintroduce exactly the boot-time require this
-- split exists to remove, and would hard-fail a build that omits the subtree. The handle type
-- parameters are erased to `any` for the same reason -- naming DevMenuHandle needs the module that
-- defines it. This file hands the table straight through to Client/DevTools/init.lua, which DOES
-- have the real types in scope and is the only thing that ever calls into one of them.
type DevToolScreens = {
	DevMenu: Lazy.Lazy<any>,
	MoveEditor: Lazy.Lazy<any>,
	KitEditor: Lazy.Lazy<any>,
	LiveConsole: Lazy.Lazy<any>,
	Storybook: Lazy.Lazy<any>,
}

export type UIHandles = {
	ClientState: ClientStateModule.ClientState,
	-- See this file's header -- ShiftLockCamera.lua's own engaged flag, drawn by
	-- UI/Components/ShiftLockCrosshair.lua.
	ShiftLockEngaged: Fusion.Value<boolean>,
	DeathFeed: DeathFeed.DeathFeedHandle,
	-- What the UI is currently doing -- Playing / Menu / Dead -- derived from the modal count and
	-- DeathFeed's own state, never set (Shell/Chrome.lua). Returned because Phase 4's Escape stack
	-- lives on this handle and because Client/ modules that want to know whether a panel is up should
	-- read one derived value rather than each re-deriving it from the Attribute.
	Chrome: Chrome.ChromeHandle,
	-- Damage numbers and the outcome banner, driven by Client/Combat/CombatFeedbackClient.lua from
	-- the damage layer's Combat_Feedback event.
	CombatFeedback: CombatFeedbackModule.CombatFeedbackHandle,
	-- The five deferred dev-tool screens, or nil in a build that does not ship them -- see this
	-- file's header and Screens/DevTools/init.lua. THE ONLY nil-able field on this table, and
	-- deliberately: a build variant is a different thing from a screen that failed to mount, so it
	-- gets one honest optional rather than five fields that each lie about being present.
	DevTools: DevToolScreens?,
	Menus: Menus.MenusHandle,
	BugReport: BugReportModule.BugReportHandle,
	Announcement: AnnouncementModule.AnnouncementHandle,
	-- The one notification channel (Shell/Notify.lua). Returned so a future producer can reach it
	-- from a driver module the way every other handle here is reached -- the only one wired today is
	-- the tier promotion below, which lives in this file because ClientState is already in hand.
	Notify: Notify.NotifyHandle,
	EmoteWheel: EmoteWheelModule.EmoteWheelHandle,
	Settings: SettingsModule.SettingsHandle,
	-- The Driver fuel HUD (Screens/BlimpFuel/init.lua) -- always mounted (it is one small panel, not
	-- worth a Lazy the way the admin screens are), visibility driven by Client/Blimp/BlimpController.lua
	-- off the same FuelUpdated remote/mount broadcast that module already tracks.
	BlimpFuel: BlimpFuelModule.BlimpFuelHandle,
	-- The ship's own console (Screens/BlimpHelm/init.lua) -- role, the control legend, the engine
	-- telegraph and a live speed/altitude/heading row, in one bottom-left panel. Always mounted for
	-- the same reason BlimpFuel above is, and driven by the same module -- but shown to PASSENGERS as
	-- well as the pilot, which is the whole difference between the two panels (see that screen's own
	-- header, including why the controls are a SECTION of it rather than a surface of their own).
	BlimpHelm: BlimpHelmModule.BlimpHelmHandle,
	-- The player's own carried-coal/water readout (Screens/CarriedResources/init.lua) -- always
	-- mounted, self-hiding at 0/0. Also driven by Client/Blimp/BlimpController.lua, off the
	-- CarriedFuelUpdated remote -- unrelated to a blimp's own tank (BlimpFuel above), just the same
	-- driving module for convenience.
	CarriedResources: CarriedResourcesModule.CarriedResourcesHandle,
	-- The furnace's custom interaction prompt (Screens/FurnacePrompt/init.lua) -- driven by
	-- Client/Blimp/FurnacePromptClient.lua, which owns the ProximityPromptService wiring behind it.
	FurnacePrompt: FurnacePromptModule.FurnacePromptHandle,
	-- The lock-on target's marker and guard bar (Screens/LockOnMarker/init.lua) -- driven by
	-- Client/Combat/LockOnController.lua, which owns the target and projects it every frame.
	LockOnMarker: LockOnMarkerModule.LockOnMarkerHandle,
	-- The one viewport multiplier, exposed because FurnacePromptClient projects a world point into a
	-- scaled surface's own space and has to divide by exactly the scale that surface was built with --
	-- computing a second one would open a second ViewportSize connection, which is the specific cost
	-- Shell/Surface.lua's own header exists to prevent.
	ViewportScale: Fusion.UsedAs<number>,
	-- Multiplies ViewportScale above by the player's own UI-size preference
	-- (Types.UISettings.Scale) -- called once by Client/Settings/SettingsClient.RestoreSettings after
	-- it fetches the persisted value, and again on every live change from the Settings panel's own
	-- Stepper. Not itself the scale a surface builds against; see ViewportScale's own field comment.
	SetUIScale: (scale: number) -> (),
	-- The player's own picked-up weapons, which one T will draw and whether it is out
	-- (Screens/WeaponInventory/init.lua) -- always mounted, hidden until the first pickup, driven by
	-- Client/Combat/WeaponInventoryClient.lua.
	WeaponInventory: WeaponInventoryModule.WeaponInventoryHandle,
	-- The root Fusion scope Mount() created, exposed so a future re-Mount() (Studio hot-reload) has
	-- something to call :doCleanup() on before mounting a fresh tree -- see this file's header on
	-- why nothing else should ever create its own root scope. Previously created and discarded
	-- locally, which made teardown impossible despite the header's own claim that one entry point
	-- "keeps teardown well-defined."
	Scope: Fusion.Scope<typeof(Fusion)>,
}

local logger = Logger.scope("UI")

local UI = {}

function UI.Mount(): UIHandles
	local player = Players.LocalPlayer
	local playerGui = player.PlayerGui

	local scope = Fusion.scoped(Fusion)
	logger:debug("Root Fusion scope created")

	local clientState = ClientStateModule.new(scope)
	logger:debug("ClientState created")

	logger:debug("ClientState bootstrap start")
	ClientStateModule.Bootstrap(clientState)
	logger:debug("ClientState bootstrap end")

	-- ONE ViewportScale.Compute FOR THE WHOLE CLIENT, and it is hoisted here rather than called at
	-- each surface because each call opens its own Camera.ViewportSize connection. Before Phase 2
	-- there were exactly two callers -- Components/ModalScreen.lua and Screens/HUD -- and every
	-- ambient panel had no UIScale at all, which is why at 2560x1440 the dock grew to 1.5 and the
	-- fuel gauge, weapon rack, helm console and carried-resources tile beside it did not (plan 2.4).
	-- The fix is not "call Compute everywhere"; that would be seventeen connections recomputing
	-- seventeen Computeds on every window resize, which is the idle cost plan 11 rule 2 forbids.
	-- One value, passed down.
	local baseViewportScale = ViewportScale.Compute(scope)

	-- THE USER'S OWN UI-SIZE PREFERENCE, composed into that ONE value rather than given a second
	-- UIScale of its own -- every surface below already reads `viewportScale` alone, so multiplying
	-- the user's own preference into it here is what makes "resize the hotbar/menus/everything" reach
	-- every one of them for free, with no per-surface change. Defaults to 1 (today's only size) until
	-- Client/Settings/SettingsClient.RestoreSettings calls the setter below with the player's real
	-- persisted Types.UISettings.Scale -- that call happens after Mount() returns (Main.client.lua's
	-- own boot order), so this Value exists and this setter is already valid the instant it does.
	local uiScalePreference = scope:Value(Constants.Settings.UI.Defaults.Scale)
	local viewportScale = scope:Computed(function(use)
		return use(baseViewportScale) * use(uiScalePreference)
	end)
	local function setUIScalePreference(scale: number): ()
		uiScalePreference:set(scale)
	end

	-- clientState is passed through so CharacterTab/EmotesTab can read the HUD-wide fields they don't
	-- duplicate (see Menus/init.lua's header on that split). The handle is returned below --
	-- Client/CharacterMenu/CharacterMenuClient.lua is what actually drives it (the M keybind, the
	-- sheet/catalogue fetches, Unlock/Equip), the same "screen exposes state, client module drives
	-- it" split every other Screens/ handle here already follows.
	local menus = Menus.Mount(scope, playerGui, clientState)
	logger:debug("Menus mounted")

	-- DEATH FEED FIRST, AND ONLY BECAUSE CHROME NEEDS ITS FACT. This screen is mounted here rather
	-- than in the ambient cluster below because the UI mode is derived from whether the local player
	-- is down, and a derived value cannot be wired to a handle that does not exist yet. Nothing about
	-- the screen itself moved: it still builds one Surface for the death overlay and hands back a
	-- tile, and that tile is added to TopRight in the same order relative to the fuel gauge as before
	-- -- an Add is a separate call from a Mount, which is exactly why the two can be separated here.
	local deathFeed, killFeedTile = DeathFeed.Mount(scope, playerGui, viewportScale)
	logger:debug("DeathFeed mounted")

	-- THE UI MODE, DERIVED FROM TWO FACTS THAT ALREADY EXIST. Nothing sets it -- see Shell/Chrome.lua
	-- on why a mode a screen can assert is a mode that eventually gets stuck on. The modal half comes
	-- through the AttributeConstants.UiModalOpen seam that combat input already reads, rather than
	-- through a second count of this file's own.
	local chrome = Chrome.New(scope, {
		ModalOpen = Chrome.ObserveModalGate(scope),
		Dead = deathFeed.Dead,
	})
	logger:debug("Chrome mode wired")

	-- THE REGION HOST GOES UP BEFORE ANY REGION-HOSTED SCREEN, because each of those returns a tile
	-- that has to be handed somewhere. Held on a local and passed down, never cached at module scope
	-- -- see Shell/Regions.lua's header for the hot-reload failure that rules the module-level cache
	-- out (a destroyed-Instance reference that swallows every tile on the second Mount, with no error).
	--
	-- `chrome` is passed as the host's yield, and it satisfies Regions' own RegionYield structurally
	-- rather than by import -- neither module requires the other. That is the whole of plan 2.5: the
	-- dock and the ambient tiles finally have something to step back FOR.
	local regions = Regions.Mount(scope, playerGui, viewportScale, chrome)
	regions:Add("TopRight", 10, killFeedTile)
	logger:debug("Region host mounted")

	-- THE ARMAMENT STATE IS BUILT BEFORE THE DOCK THAT RENDERS IT, which is the only ordering
	-- constraint between these two lines. What comes back is three Fusion Values, not a tile: the
	-- weapon readout used to be a Shell/Regions BottomLeft panel in the opposite corner, and is now
	-- a plate bolted to the hotbar dock's left edge (Screens/HUD/ArmamentIsland.lua), built by the
	-- file that owns the dock because the two share a seam.
	--
	-- Moving it out of BottomLeft also empties that region down to the helm console alone, which
	-- retires the last of the left-edge crowding docs/architecture/2026-08-25-hud-shell-plan.md
	-- section 2.1a is about -- two content-sized stacks sharing one screen edge with nothing
	-- arbitrating between them. There is now one.
	local weaponInventory, armament = WeaponInventoryModule.Mount(scope)
	logger:debug("WeaponInventory mounted")

	-- THE DOCK IS A TILE NOW, and it is mounted here rather than first because a tile needs somewhere
	-- to go. BottomCentre has been reserved for it since Phase 1; Screens/HUD no longer owns a
	-- ScreenGui, a ViewportScale.Compute or a hand-scaled bottom margin -- see that file's Mount
	-- comment for what each of those three turned out to be a restatement of.
	-- chrome.DockVisible: the dock steps out while a panel is open (Shell/Chrome.lua).
	regions:Add("BottomCentre", 10, HUD.Mount(scope, clientState, armament, chrome.DockVisible))
	logger:debug("HUD mounted")

	-- ITS OUTCOME BANNER IS A TopCentre TILE AT ORDER 5 -- ahead of the announcement (10) and the
	-- notification channel (20), which is where it already sat visually. The damage numbers stay on
	-- CombatFeedback's own Overlay surface, because they are world-anchored and have nothing to stack
	-- against. That split is what let Shell/Regions.lua delete COMBAT_BANNER_BAND_BOTTOM, the one
	-- constant in that file whose own comment admitted it could rot silently -- and had.
	local combatFeedback, combatBannerTile = CombatFeedbackModule.Mount(scope, playerGui, viewportScale)
	regions:Add("TopCentre", 5, combatBannerTile)
	logger:debug("CombatFeedback mounted")

	-- No longer part of a Screen's own handle -- see this file's header. A bare surface here (not a
	-- whole Screens/ module) since ShiftLockCrosshair is the only content it will ever hold.
	--
	-- Layers.World, the bottom of the ladder, because this is drawn ON the world rather than on top of
	-- the UI -- a reticle that covers a panel is wrong. It used to be at the default 0 like twelve
	-- other surfaces and, being mounted late, therefore drew over every panel mounted before it.
	--
	-- Scaled = false, and unlike most of the unscaled surfaces this one is not full-bleed: it is a
	-- world-space aim point. The crosshair marks where the camera is pointing, and growing it with the
	-- viewport would make it a bigger mark on the same pixel rather than a truer one.
	local shiftLockEngaged: Fusion.Value<boolean> = scope:Value(false)
	Surface.New(scope, {
		Name = "ShiftLockCrosshair",
		Layer = Layers.World,
		Parent = playerGui,
		Scaled = false,
		Children = ShiftLockCrosshair(scope, { Engaged = shiftLockEngaged }),
	})
	logger:debug("ShiftLockCrosshair mounted")

	-- DEFERRED, not mounted, and now also OPTIONAL -- see this file's header. The five thunks
	-- themselves are unchanged and still live on this scope; what moved is the require, into
	-- Screens/DevTools/init.lua, so that a build config can leave the whole subtree out. This is the
	-- one place in the UI tree that resolves a module by name instead of by path, and it has to be:
	-- `script.Screens.DevTools` would throw in a build that omits it, which is the entire point.
	local devToolsModule = script.Screens:FindFirstChild("DevTools")
	local devTools: DevToolScreens? = nil
	if devToolsModule then
		devTools = (require(devToolsModule :: ModuleScript) :: any).Mount(scope, playerGui)
		logger:debug("DevTools screens bound (five deferred panels)")
	else
		logger:info("DevTools screens absent -- this build does not ship dev tooling")
	end

	local bugReport = BugReportModule.Mount(scope, playerGui)
	logger:debug("BugReport mounted")

	local announcement, announcementTile = AnnouncementModule.Mount(scope)
	regions:Add("TopCentre", 10, announcementTile)
	logger:debug("Announcement mounted")

	-- THE NOTIFICATION CHANNEL, at TopCentre/20 -- behind the announcement banner, which is the whole
	-- of the arbitration between them. An admin broadcast and a rank-up in the same second queue in a
	-- stack instead of racing for one strip, which is the thing plan 2.1 is about.
	local notify = Notify.New(scope)
	regions:Add("TopCentre", 20, NotificationsModule.Mount(scope, notify))
	logger:debug("Notify mounted")

	-- THE ONE WIRED PRODUCER, and the restraint is the point. Shell/Notify.lua declares four kinds
	-- because docs/ui-ux-philosophy.md's Notification Design section names four; exactly one of them
	-- has a real, server-driven fact behind it today. Everything else on that list is blocked on a
	-- System that publishes nothing, and inventing content ahead of the server is how a UI ends up
	-- with a toast that fires off a client guess.
	--
	-- HERE RATHER THAN IN A DRIVER MODULE because both halves are already in this function and
	-- neither is anybody else's: ClientState is constructed above, and Notify a few lines up. A
	-- producer that needed a remote of its own would belong at that remote's owner instead.
	--
	-- TierBadge's promotion flare is untouched. That is the FELT cue -- a colour surge in the corner
	-- of the eye during a fight -- and this is the READABLE one. See Screens/HUD/init.lua's
	-- promotionPulse, which observes this same value for its own reason.
	scope:Observer(clientState.TierPromotion):onChange(function()
		local promotion = Fusion.peek(clientState.TierPromotion)
		if promotion == nil then
			return
		end
		notify:Push({
			Kind = "Progression",
			-- The tier's NAME, not its number. TierName is the server's authoritative identity for
			-- the tier the player has just reached, and "Opened Meridian" is the thing they will tell
			-- someone about; "Tier 3" is a number they would then have to translate.
			Title = Fusion.peek(clientState.TierName),
			Detail = string.format("Tier %d ascended", promotion.To),
		})
	end)
	logger:debug("TierPromotion notification producer wired")

	-- DEFERRED, the same Shared/Lazy.lua shape Screens/DevTools/init.lua uses for the admin panels --
	-- and for a sharper reason than theirs. The wheel's state is three Values and a Computed and is
	-- built here and now, because Client/Emotes/EmoteWheelClient.lua binds Escape to IsOpen at boot;
	-- its TREE is ~130 Instances (a graduated dial, eight chamfered tiles, a hub, a legend) plus a
	-- dozen Fusion springs, and Fusion 0.3's springs never sleep -- the sleep in Spring.luau is
	-- commented out behind a TODO -- so every one of them re-integrates every frame for the whole
	-- session whether or not the wheel has ever been opened.
	--
	-- The trade is one frame of build cost on a player's FIRST open, against every player who never
	-- opens it paying nothing at all.
	local emoteWheelState = EmoteWheelModule.NewState(scope, viewportScale)
	local emoteWheel: EmoteWheelModule.EmoteWheelHandle = {
		State = emoteWheelState,
		Screen = Lazy.new("EmoteWheel", function()
			EmoteWheelModule.Mount(scope, playerGui, clientState, viewportScale, emoteWheelState)
			logger:debug("EmoteWheel mounted (deferred until first open)")
		end),
	}
	logger:debug("EmoteWheel state ready, tree deferred")

	local settings = SettingsModule.Mount(scope, playerGui)
	logger:debug("Settings mounted")

	-- The four remaining ambient tiles. The ORDER NUMBERS ARE THE LAYOUT, and they are all that
	-- decides who sits where now -- no panel carries a corner of its own any more. Lower sits nearer
	-- its region's anchored edge, at both ends of the screen (Regions.lua handles the sign).
	-- THE TWO BLIMP INSTRUMENTS ARE ONE TILE NOW, IN THE BOTTOM-RIGHT CORNER (owner, 2026-08-25).
	-- They were in opposite bottom corners for a day and neither reached one: BottomRight was
	-- carrying a clearance it never needed, and BottomLeft carries one it does -- the armament island
	-- is 224px pinned left of an 870px centred dock, which puts its edge 24px from the screen edge at
	-- every ordinary 16:9 resolution, and a 220px console does not fit in 24px.
	--
	-- So both moved right, where nothing is bolted to the dock, and they are ASSEMBLED rather than
	-- stacked: the furnace plate shares the console's top edge the way the armament island shares the
	-- dock's left edge, with one rule at the seam, one width, one content baseline, and a bronze bead
	-- through the joint. Screens/BlimpHelm/FurnacePlate.lua has the five rules; the geometry lives
	-- with the console because a joint has exactly one owner.
	--
	-- FUEL FIRST, AND ONLY BECAUSE THE CONSOLE NEEDS ITS STATE. Screens/BlimpFuel draws nothing now;
	-- it returns the extrapolated furnace state and the console renders it on the plate. Identical
	-- ordering, for the identical reason, to Screens/WeaponInventory ahead of Screens/HUD above.
	local blimpFuel, furnace = BlimpFuelModule.Mount(scope)
	logger:debug("BlimpFuel mounted")

	local blimpHelm, blimpConsoleTile = BlimpHelmModule.Mount(scope, furnace)
	regions:Add("BottomRight", 10, blimpConsoleTile)
	logger:debug("BlimpHelm mounted")

	local carriedResources, carriedResourcesTile = CarriedResourcesModule.Mount(scope)
	regions:Add("TopLeft", 10, carriedResourcesTile)
	logger:debug("CarriedResources mounted")

	-- NOT a region tile, unlike everything else in this cluster: it tracks a point in the WORLD (a
	-- blimp's furnace) rather than a corner of the screen, so it owns its own surface on the World
	-- band. Screens/FurnacePrompt's own Mount header has the argument; Shell/Regions is not involved
	-- and deliberately does not know it exists.
	local furnacePrompt = FurnacePromptModule.Mount(scope, playerGui, viewportScale)

	-- Same shape as the furnace prompt just above: it tracks a point in the world, so it owns a World-band
	-- surface rather than a region tile.
	local lockOnMarker = LockOnMarkerModule.Mount(scope, playerGui, viewportScale)
	logger:debug("FurnacePrompt mounted")

	return {
		ClientState = clientState,
		ViewportScale = viewportScale,
		SetUIScale = setUIScalePreference,
		ShiftLockEngaged = shiftLockEngaged,
		DeathFeed = deathFeed,
		Chrome = chrome,
		CombatFeedback = combatFeedback,
		DevTools = devTools,
		Menus = menus,
		BugReport = bugReport,
		Announcement = announcement,
		Notify = notify,
		EmoteWheel = emoteWheel,
		Settings = settings,
		BlimpFuel = blimpFuel,
		BlimpHelm = blimpHelm,
		CarriedResources = carriedResources,
		FurnacePrompt = furnacePrompt,
		LockOnMarker = lockOnMarker,
		WeaponInventory = weaponInventory,
		Scope = scope,
	}
end

return UI
