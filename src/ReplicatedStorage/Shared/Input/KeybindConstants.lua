--!strict
--[[
	KeybindConstants.lua

	Owns: every DEFAULT input binding in the game, for both devices -- the keyboard/mouse map, the
	plain gamepad map, the chord layer that reaches the actions no plain button was left for, the
	chord modifier itself, and the remote names the rebinding round trip uses.

	Lifted out of Constants.lua. Constants.Keybinds re-exports this module, so all eighty-three
	existing Constants.Keybinds.X call sites keep working unchanged; new code should require this
	module directly. Moved verbatim -- the four `:: { [Types.KeybindAction]: Types.Keybind }`
	annotations came with it, which is why this module requires Types.

	DEFAULTS ONLY, never live state. Client/Input/KeybindManager.lua CLONES these tables at boot and
	applies the player's persisted overrides on top; nothing here is ever mutated, and a module that
	starts writing to it has confused the default map with the player's own. The live map is
	KeybindManager's, the persisted overrides are Types.PlayerSettings' (see SettingsConstants.lua
	for the remote surface that carries them).

	Does not own: what an action DOES (each System binds its own through Client/Input/InputRouter),
	the device-resolution rules that decide which column is showing (Client/Input/InputDevice.lua),
	the glyph drawn for a binding (Client/Input/Glyph.lua), or any contextual map that temporarily
	displaces these while a player is mounted (BlimpHelmControls is the live example, and it is
	checked against this file by its own spec rather than duplicating it).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage.Shared.Types)

-- Default keybind per Types.KeybindAction -- Client/Input/KeybindManager.lua clones this into its
-- own mutable table at load, so KeybindManager.Rebind() never mutates this shared table itself
-- (Constants.lua is read-only tunable data per this file's header). Purely client-side data: the
-- server never needs to know what key a player pressed, only the resulting request remote, so
-- nothing here crosses NetworkBridge -- it lives in Constants.lua rather than a client-only module
-- only because it's static default data every input-consuming client module needs to agree on.
-- UserInputType (not KeyCode) is used for MouseButton1/MouseButton2 -- Roblox's InputObject has no
-- KeyCode for mouse buttons, only a UserInputType.
local KeybindConstants = {
	Defaults = {
		BasicAttack = { UserInputType = Enum.UserInputType.MouseButton1 },
		-- Block and Parry share this one input -- see Constants.Combat's Parry* fields' header for
		-- why (timed block: a press opens a short parry window, holding past it is a plain block).
		Block = { KeyCode = Enum.KeyCode.F },
		HeavyAttack = { KeyCode = Enum.KeyCode.R },
		LockOn = { KeyCode = Enum.KeyCode.CapsLock },
		-- Space is Roblox's default jump key, already spoken for, and LeftControl belongs to
		-- ShiftLock below -- Q is the conventional dodge/evade key this genre has left. Read by
		-- Client/Parkour/ParkourInput.lua, which buffers the press for States/Dashing.lua: the
		-- four-way, facing-relative dash. (It named CombatSystem.lua's handleDashRequest for a while
		-- after that system was deleted, with nothing reading the binding at all -- a rebind row in
		-- the Settings panel for a key that did nothing.)
		Dash = { KeyCode = Enum.KeyCode.Q },
		-- Sprint is a hold (press = sprint on, release = off, like Block). LeftShift is the
		-- conventional "run" key this genre already trains players to expect.
		Sprint = { KeyCode = Enum.KeyCode.LeftShift },
		-- Slide only fires while Sprint is held (CombatClient.lua gates the press client-side, and
		-- CombatSystem.lua's handleSlideRequest independently re-checks state.sprinting server-side)
		-- -- C is the conventional slide key in this genre, and unbound elsewhere in this table.
		Slide = { KeyCode = Enum.KeyCode.C },
		-- LeftControl stands in for shift lock here since LeftShift is already Sprint above. The
		-- engine's own mouse-lock switch is disabled in default.project.json
		-- (StarterPlayer.EnableMouseLockOption = false) so only the bespoke camera mode
		-- (Client/Camera/ShiftLockCamera.lua) responds to it -- two systems toggling on one key press
		-- would fight over MouseBehavior every frame.
		ShiftLock = { KeyCode = Enum.KeyCode.LeftControl },
		DevMenuToggle = { KeyCode = Enum.KeyCode.Equals },
		-- T is the conventional "draw/sheath" key in the genre. Fires Weapon_ToggleDraw --
		-- Server/Combat/Weapon/WeaponInventorySystem.lua pulls out the selected weapon, or puts it
		-- away if it is already out. A one-shot toggle like Dash.
		--
		-- USED TO BE SwapWeapon (cycle between two hardcoded loadout slots), which stopped meaning
		-- anything once weapons became an open roster you pick up: there are no slots to swap between,
		-- there is an inventory to draw FROM. Cycling which weapon is selected moved to ToggleWeapon's
		-- neighbour below rather than staying on this key, because "put my sword away" is the action a
		-- player reaches for constantly and "switch to my other sword" is the one they reach for
		-- occasionally.
		ToggleWeapon = { KeyCode = Enum.KeyCode.T },
		-- Cycles which owned weapon T will draw, applying immediately if one is already out. Y sits
		-- next to T and is unbound elsewhere in this table -- the two weapon actions stay adjacent.
		SelectNextWeapon = { KeyCode = Enum.KeyCode.Y },
		-- Right-click is otherwise unbound in this table (MouseButton1 is BasicAttack, Block/Parry
		-- already lives on F) -- fires Attack_Feint (AttackRequestSystem.Feint), the conventional
		-- "cancel/reposition" slot this genre leaves free next to the primary attack button.
		Feint = { UserInputType = Enum.UserInputType.MouseButton2 },
		-- Opens the player-facing bug report form (Client/BugReport/BugReportClient.lua). F8 reads
		-- as a "system/meta" function-row key rather than a gameplay key -- unlike the letter/mouse
		-- binds above, there's low risk of an accidental press mid-combat, and it's unclaimed
		-- elsewhere in this table.
		OpenBugReport = { KeyCode = Enum.KeyCode.F8 },
		-- Move Creation System editor toggle -- unbound elsewhere in this table, sits next to
		-- DevMenuToggle's Equals key in the same "secondary system action" row of the keyboard.
		-- Admin-only (MoveEditorClient.lua's own authorization round-trip, same as DevMenuToggle).
		OpenMoveEditor = { KeyCode = Enum.KeyCode.Minus },
		-- Kit Editor toggle (Race Traits + Bloodline Abilities plan) -- unbound elsewhere in this
		-- table, sits directly next to OpenMoveEditor's Minus key in the same "secondary system
		-- action" row of the keyboard (DevMenuToggle = Equals, OpenMoveEditor = Minus, this =
		-- LeftBracket). Admin-only, same authorization contract as OpenMoveEditor above.
		OpenKitEditor = { KeyCode = Enum.KeyCode.LeftBracket },
		-- Opens the Live Admin Console (Client/DevTools/LiveConsole/LiveConsoleClient.lua,
		-- Client/UI/Screens/DevTools/LiveConsole/init.lua) for an authorized admin -- a bespoke live log
		-- stream, not Roblox's own native Developer Console. It used to open the native one via
		-- StarterGui:SetCore("DevConsoleVisible") until it was replaced: that panel only ever showed
		-- anything in Studio, since Shared/Logger.lua never calls print()/warn() outside
		-- RunService:IsStudio() by design, so on a live server the one key meant to surface logs
		-- opened an empty panel. The Live Admin Console reads Logger.lua's always-on capture buffer
		-- instead, which works regardless of IsStudio -- see that module's own header.
		--
		-- F5 rather than the engine's own F9: F9 is bound by Roblox itself only for accounts with
		-- edit access to the place and does nothing for anyone else, so reusing it would leave a key
		-- that works for some admins and silently not for others.
		--
		-- And NOT F6, which is where this first went: F6 is already the parkour debug overlay's raw
		-- toggle (ParkourConstants.Debug.ToggleKeyCode). That binding is not in this table -- it is
		-- deliberately raw so it never shows up in the player-facing rebind list -- so nothing here
		-- flagged the collision, and the two handlers simply both fired on the same press. If another
		-- "developer tooling" key is ever added, check ParkourConstants.Debug as well as this table.
		--
		-- This was F7 until it was moved here by request. One caveat that comes with F5 and did not
		-- come with F7: in Studio, F5 is Studio's own Play/Resume shortcut, so a press that lands on
		-- the Studio window rather than the running game view will drive Studio instead of this panel.
		-- In a live client F5 is unclaimed by the engine, so shipped behaviour is unaffected.
		OpenDevConsole = { KeyCode = Enum.KeyCode.F5 },
		-- The 5 hotbar slots (see Types.KeybindAction's own header) -- the obvious number-row keys,
		-- unclaimed elsewhere in this table (BasicAttack/HeavyAttack/Block/etc. all live on letters or
		-- the mouse).
		HotbarSlot1 = { KeyCode = Enum.KeyCode.One },
		HotbarSlot2 = { KeyCode = Enum.KeyCode.Two },
		HotbarSlot3 = { KeyCode = Enum.KeyCode.Three },
		HotbarSlot4 = { KeyCode = Enum.KeyCode.Four },
		HotbarSlot5 = { KeyCode = Enum.KeyCode.Five },
		-- Held to open the radial emote wheel (Client/Emotes/EmoteWheelClient.lua) -- B is unclaimed
		-- elsewhere in this table and sits comfortably under the same hand already on WASD, away from
		-- the mouse-driven combat cluster (BasicAttack/Feint on the mouse buttons, Block/HeavyAttack on
		-- F/R) the wheel's own mouse-steered selection needs to stay clear of.
		EmoteWheel = { KeyCode = Enum.KeyCode.B },
		-- Opens the Settings panel (Client/Settings/SettingsClient.lua). Deliberately NOT Escape: this
		-- repo never disables Roblox's own native Escape/Menu overlay, and layering a persistent panel
		-- toggle onto that same key would open both at once every press -- see OpenBugReport's
		-- ButtonSelect comment below for the same conflict already avoided on the gamepad side. Was
		-- O ("Options", the obvious mnemonic) until a Studio playtest showed the I/O/P cluster never
		-- reaching UserInputService at all on at least one dev machine -- not consumed with
		-- gameProcessed=true, simply absent -- so the toggle was unreachable with no in-game way to
		-- rebind it (the rebind UI lives behind this very key). K is unclaimed elsewhere in this
		-- table, sits on the home row, and is verified to register; players who prefer O can rebind
		-- it in the panel itself.
		SettingsToggle = { KeyCode = Enum.KeyCode.K },
		-- Opens the character menu (Client/CharacterMenu/CharacterMenuClient.lua). M is the key this
		-- screen has always opened on -- it was a hard-coded UserInputService check inside the screen
		-- itself until the panel became the real character hub -- so this entry keeps the key players
		-- already know while finally making it rebindable like every other action in this table.
		-- Unclaimed elsewhere here, and far enough from the WASD/mouse combat cluster that an
		-- accidental mid-fight press is unlikely.
		CharacterMenuToggle = { KeyCode = Enum.KeyCode.M },
		-- Parkour dodge/roll (Client/Parkour/States/Rolling.lua). LeftAlt is unclaimed elsewhere in
		-- this table, sits under the same hand already on WASD (a roll has to be reachable without
		-- leaving the movement keys, unlike the panel toggles above), and -- unlike every letter key
		-- left -- carries no risk of colliding with Roblox's own chat-focus behavior on a stray press.
		Roll = { KeyCode = Enum.KeyCode.LeftAlt },
		-- Parkour committed leap (Client/Parkour/States/Leaping.lua). Used to fire on a double-tap of
		-- jump; E is unclaimed elsewhere in this table, sits under the same hand already on WASD (same
		-- reachability requirement as Roll's own comment above), and is the conventional "interact/use"
		-- key this genre trains players to reach for on a deliberate single press.
		Leap = { KeyCode = Enum.KeyCode.E },
		-- Board/leave a blimp station (Client/Blimp/BlimpController.lua, and the KeyboardKeyCode that
		-- module writes onto each server-created ProximityPrompt so a rebind carries to the prompt too).
		--
		-- DELIBERATELY SHARES E WITH Leap ABOVE, which is the only doubled key in this table and so needs
		-- saying out loud -- the F5/F6 collision OpenDevConsole's own comment records is what happens when
		-- a doubled key is NOT written down. It is safe in both directions and neither is an accident:
		--   * Pressing E to BOARD also buffers a leap, but Leaping's own CanEnter refuses a standing
		--     character, and the mount sets RootControlLocked a frame later, which parks parkour outright.
		--   * Pressing E to LEAVE cannot buffer a leap at all -- ParkourInput skips the Leap branch while
		--     Constants.Attributes.Mounted is set, which is the one case that would otherwise have fired
		--     (a buffered press surviving the release and launching the player off the deck).
		-- E is the conventional interact key this genre trains players to reach for, which is the same
		-- argument Leap's own comment makes; if the overlap ever stops being acceptable, MOVE Leap -- a
		-- prompt is the more discoverable of the two and the one a new player meets first.
		Interact = { KeyCode = Enum.KeyCode.E },
		-- Grab layer's follow-up throw input (Client/Combat/GrabInputClient.lua). G is unbound
		-- elsewhere in this table and sits under the same hand already on WASD -- a throw has to be
		-- reachable the instant a hold lands, the same "no leaving the movement keys" requirement
		-- Roll/Leap's own comments give.
		GrabThrow = { KeyCode = Enum.KeyCode.G },
	} :: { [Types.KeybindAction]: Types.Keybind },

	-- Gamepad defaults -- a SEPARATE table, not a wider Keybind, so a player can have a keyboard
	-- bind AND a gamepad bind live for the same action at once (Client/Input/KeybindManager.lua's
	-- Matches() checks both). Roblox has no PlayStation-specific input API -- every gamepad's
	-- buttons (DualSense included) come through as the same Enum.KeyCode.ButtonA/B/X/Y/L1/R1/L2/
	-- R2/L3/R3/DPad* regardless of manufacturer, and UserInputService:GetImageForKeyCode already
	-- swaps in PlayStation-style glyphs at the engine level once it detects a DualSense -- nothing
	-- to build for that part. Mapped to this genre's own Souls-like convention family, the same
	-- reasoning the keyboard Defaults above already use per-key:
	GamepadDefaults = {
		-- R1/R2 light/heavy attack is the standard split in this genre (Elden Ring/Dark Souls).
		BasicAttack = { KeyCode = Enum.KeyCode.ButtonR1 },
		HeavyAttack = { KeyCode = Enum.KeyCode.ButtonR2 },
		-- L1 guard, same genre convention.
		Block = { KeyCode = Enum.KeyCode.ButtonL1 },
		-- B (Circle on a DualSense) is the near-universal roll/dash button in this genre. Same
		-- consumer as the keyboard entry above -- KeybindManager.Matches checks both device maps in
		-- one call, so States/Dashing.lua needs no per-device branching.
		Dash = { KeyCode = Enum.KeyCode.ButtonB },
		-- R3 (click right stick) is the standard lock-on button (Souls, Zelda). This line used to say
		-- exactly that and then bind ButtonL2 -- a doc/code mismatch recorded, but not fixed, by
		-- Feint's own comment below. It is fixed now, and the fix was forced rather than tidy: L2 had
		-- to come free to become GamepadModifier below, and the button this comment always claimed
		-- LockOn should be on is the one Feint was sitting on.
		LockOn = { KeyCode = Enum.KeyCode.ButtonR3 },
		-- L3 (click left stick) is a common third-person sprint convention.
		Sprint = { KeyCode = Enum.KeyCode.ButtonL3 },
		-- X (Square) -- a free face button, pressed while already holding L3 for Sprint.
		Slide = { KeyCode = Enum.KeyCode.ButtonX },
		-- DPadLeft. A face button would be nicer, but ShiftLock is the one action here that can afford
		-- NOT to have one: it is a MODE TOGGLE, pressed once and then lived in for minutes, so the cost
		-- of taking a thumb off the left stick to reach it is paid at a moment the player chose. It sat
		-- on ButtonY until Roll took that button below -- read Roll's comment for why that trade is not
		-- symmetric.
		ShiftLock = { KeyCode = Enum.KeyCode.DPadLeft },
		-- D-pad item/weapon-swap is a standard convention in this genre.
		ToggleWeapon = { KeyCode = Enum.KeyCode.DPadRight },
		-- Bug report form, gamepad side -- ButtonA is Roblox's own native Jump (would double-fire on
		-- every jump), ButtonStart is the engine's native Escape/Menu button (would fight this
		-- panel), D-pad is already this game's "quick select" semantic (SwapWeapon owns DPadRight).
		-- ButtonSelect (Share/View/Touchpad-click depending on controller family) is unclaimed, has
		-- no competing engine-level binding, and reads as the same "secondary system action"
		-- category DevMenuToggle's own comment below reserves for admin tooling -- just applied to a
		-- player-facing feature here. Needs a real controller playtest: Share/View/Touchpad-click
		-- behavior varies slightly by controller family.
		OpenBugReport = { KeyCode = Enum.KeyCode.ButtonSelect },
		-- DPadDown -- this genre's conventional "hold for a quick-select wheel" gamepad slot.
		-- DPadRight is already SwapWeapon above; DPadUp/DPadLeft are the only other unclaimed D-pad
		-- directions among the KeyCode values in this table, so DPadDown is free with no live
		-- conflict to check for.
		EmoteWheel = { KeyCode = Enum.KeyCode.DPadDown },
		-- DPadUp -- the last unclaimed D-pad direction (DPadRight is SwapWeapon, DPadDown is
		-- EmoteWheel above) and a natural "open a menu" convention on its own. Unlike DevMenuToggle/
		-- HotbarSlot1-5 below, Settings is NOT admin-only, so it earns a real gamepad default rather
		-- than staying keyboard-only.
		SettingsToggle = { KeyCode = Enum.KeyCode.DPadUp },
		-- Y (Triangle). THE ROLL GOT ITS FACE BUTTON, and this is the one binding in this table that
		-- was a genuine BUG rather than a compromise.
		--
		-- It sat on DPadLeft, under a comment that said "not ideal -- a roll deserves a face button"
		-- and treated that as taste. It was not taste. States/Rolling.lua's whole reason to exist is
		-- the LANDING ROLL: a roll pressed within ParkourConstants.Roll.LandingWindowSeconds (0.2s) of
		-- ground contact converts a hard landing into a full-speed continuation. That is a reflex input
		-- on a two-tenths-of-a-second window, and it is pressed while the player is IN THE AIR STEERING
		-- -- which on a gamepad means the left thumb is on Thumbstick1 and cannot also be on the D-pad.
		-- The binding did not make the landing roll hard on a controller, it made it unreachable, and
		-- with it the timing skill the parkour system is built around.
		--
		-- WHAT PAID FOR IT was ShiftLock, which moved to DPadLeft above. That trade is not symmetric
		-- and that is the point: a mode toggle can afford a thumb-off-stick reach because the player
		-- picks the moment, and a 0.2s landing window cannot afford one at all. Dash (ButtonB) stays
		-- put -- doubling roll onto it would make two distinct mechanics indistinguishable, which is
		-- what the old comment here was right to refuse.
		Roll = { KeyCode = Enum.KeyCode.ButtonY },
		-- Leap, Interact, GrabThrow and HotbarSlot1-5 have no entry in THIS table and are not
		-- unbound: they live one table down, in GamepadChords, reached by holding GamepadModifier.
		-- This comment used to say there was "genuinely nowhere left to put" Leap without doubling up
		-- two distinct mechanics on one button, and that was true of the single-press map and only of
		-- the single-press map -- every face/shoulder/stick-click/D-pad value in this genre's own
		-- convention family really is claimed above. A held modifier is the way out of that wall
		-- rather than an admission of defeat: see GamepadChords' own header below.
		--
		-- DevMenuToggle deliberately has NO gamepad default -- admin-only, keyboard already covers
		-- it, and exposing a stray always-live single-button dev-menu toggle to every controller
		-- user isn't something to do by default. KeybindManager.Matches simply never matches for an
		-- action with no bound gamepad input. Value type is Keybind? (unlike Defaults' Keybind
		-- above), honestly reflecting that this map is deliberately partial -- every consumer that
		-- reads it must nil-check. HotbarSlot1-5 are absent from THIS map for the reason Leap is
		-- (they are on the chord layer below), not for the admin-only reason this comment used to
		-- give.
	} :: { [Types.KeybindAction]: Types.Keybind? },

	-- The held button that switches the gamepad onto GamepadChords below. ButtonL2 -- free only
	-- because LockOn moved to the ButtonR3 its own comment always claimed, which freed ButtonR3 for
	-- Feint, which is now on the chord layer anyway.
	--
	-- WHY L2 AND NOT A FACE BUTTON. A modifier has to be holdable without giving up any of the four
	-- buttons a thumb needs DURING the hold, which rules out every face button and both stick
	-- clicks. That leaves the four shoulders: R1/R2 are light/heavy attack and L1 is guard, all
	-- three of which must stay single-press in combat. L2 is the only one left, and it is the one a
	-- player's index finger is already resting on.
	--
	-- REBINDABLE, like everything else here -- Types.GamepadSettings.ChordModifier is the persisted
	-- override, and Client/Input/Chord.lua reads through that rather than off this constant directly.
	GamepadModifier = { KeyCode = Enum.KeyCode.ButtonL2 } :: Types.Keybind,

	-- The ALTERNATE gamepad layer: what each button means while GamepadModifier is held. A third
	-- map rather than a wider Keybind, for the same reason GamepadDefaults is a second one -- an
	-- action can be live on keyboard, on a plain gamepad button, and on a gamepad chord at once, and
	-- collapsing them would force every consumer to branch on device and on modifier state.
	--
	-- THIS EXISTS BECAUSE THE BUTTON BUDGET IS GENUINELY FULL, not because chords are nice. Read
	-- GamepadDefaults above: Roll's comment and Leap's comment independently hit the same wall --
	-- every face, shoulder, stick-click and D-pad direction in this genre's convention family is
	-- already spoken for -- and Leap, Interact and GrabThrow are live gameplay actions, not admin
	-- tooling. The choice was doubling two distinct mechanics onto one button (which makes them
	-- indistinguishable) or adding a layer. A layer also means the NEXT action to need a binding
	-- gets one without re-litigating any of this.
	--
	-- EACH PAIRING IS THE MODIFIED FORM OF WHAT THE PLAIN BUTTON ALREADY MEANS, so the layer is
	-- learnable rather than arbitrary -- and Client/Input/Glyph.lua swaps every on-screen legend to
	-- this map while the modifier is held, so it is discoverable rather than secret.
	--
	-- FLAGGED FOR A REAL CONTROLLER PLAYTEST, the same standing OpenBugReport's ButtonSelect note and
	-- Roll's DPadLeft note already take in the map above. These are reasoned, not measured.
	GamepadChords = {
		-- R1 is BasicAttack; a feint is the cancel of exactly that, so it reads as a modified attack.
		Feint = { KeyCode = Enum.KeyCode.ButtonR1 },
		-- B is Dash; a leap is the committed version of the same "get clear of here" idea.
		Leap = { KeyCode = Enum.KeyCode.ButtonB },
		-- X is Slide; both are "engage with the ground/world in front of you".
		Interact = { KeyCode = Enum.KeyCode.ButtonX },
		-- Y. Its plain binding is Roll, which is a TAP with a 0.2s window; this is a modified tap, so
		-- the two never compete for a press (the same hold-versus-tap argument HotbarSlot5 makes about
		-- sharing L1 with Block). This comment used to justify the button by saying Y was ShiftLock,
		-- "the least combat-critical face button" -- that is stale, ShiftLock moved to DPadLeft when
		-- Roll took this button, and the reasoning is now the modifier rather than what it displaces.
		GrabThrow = { KeyCode = Enum.KeyCode.ButtonY },
		-- The D-pad is already this game's quick-select semantic (ToggleWeapon/EmoteWheel/Settings
		-- all live there unmodified), so the modified D-pad is the natural home for the slot picker.
		HotbarSlot1 = { KeyCode = Enum.KeyCode.DPadUp },
		HotbarSlot2 = { KeyCode = Enum.KeyCode.DPadRight },
		HotbarSlot3 = { KeyCode = Enum.KeyCode.DPadDown },
		HotbarSlot4 = { KeyCode = Enum.KeyCode.DPadLeft },
		-- The fifth slot has no fifth D-pad direction to take, so it goes to the one shoulder that is
		-- neither the modifier nor an attack: L1. Guard is a HOLD and this is a modified TAP, so the
		-- two never compete for the same press.
		HotbarSlot5 = { KeyCode = Enum.KeyCode.ButtonL1 },
	} :: { [Types.KeybindAction]: Types.Keybind? },

	-- NO DoubleTapDashWindowSeconds HERE ANY MORE, and it should not come back. It configured a
	-- double-tap-W alternate trigger for the dash, read only by CombatClient.lua's InputBegan, and it
	-- outlived that file by the whole combat rewrite with no consumer at all. The dash is on a
	-- dedicated, rebindable key now (Defaults.Dash above), which is the same conclusion
	-- States/Leaping.lua reached when the leap stopped being a double-tap of jump: a gesture built out
	-- of another action's key can never be independently rebound, and it silently steals presses from
	-- the key it is layered on.
}

return KeybindConstants
