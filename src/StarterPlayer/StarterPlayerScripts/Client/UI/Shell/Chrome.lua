--!strict
--[[
	Shell/Chrome.lua

	Owns: what the client's UI is currently DOING -- playing, in a menu, or dead -- as one derived
	value, plus the two presentation facts the ambient layer reads off it.

	Does NOT own: any of the underlying facts. Every input here is published by whoever already owns
	it -- Components/ModalScreen.lua owns the modal count, Screens/DeathFeed owns whether the local
	player is down -- and this file only names the combination. Nothing sets the mode; if a mode ever
	needs a fact nobody publishes, the answer is to publish that fact at its owner, not to let a
	screen assert a mode.

	THE MODE IS A Computed, AND THAT IS THE POINT rather than a style rule. The failure it forecloses
	is the one every hand-rolled UI-state flag reaches eventually: two screens each setting "menu
	mode" on their own open edge, one of them forgetting the close edge, and the HUD staying dimmed
	for the rest of the session with nothing in the log. A value derived from a count and a nil check
	cannot get stuck, because there is no edge to miss -- it is the count and the nil check.

	THREE MODES, NOT THE FIVE THIS PHASE WAS SPECCED WITH, and the two that are gone were not dropped
	for being unused -- they are unreachable. docs/architecture/2026-08-25-hud-shell-plan.md 3.4 lists
	Playing | Menu | Cinematic | Dead | Boot, with Cinematic and Boot coming off Onboarding and Intro.
	Client/Main.client.lua runs StartMenuClient.Run(), then LoadingClient.Run(), then IntroClient.Run()
	-- which BLOCKS through the entire cinematic and character creator -- and only then calls
	UI.Mount(). So by the time this module exists, every surface those two modes describe has already
	been torn down, and the dock they would have hidden was never built. The plan's own 2.5 says the
	dock "renders at full opacity ... during the intro cinematic"; it does not, because there is no
	dock yet.

	Declaring them anyway would have meant two branches no session can enter and no spec can drive.
	The day something runs a cinematic AFTER boot -- a cutscene, a scripted set piece -- it publishes
	that fact at its own owner and this file grows a fourth mode, one Computed branch and one line in
	Tests/UI/Chrome.spec.lua. That is a smaller change than the two dead branches would have been to
	keep honest in the meantime.

	DEAD OUTRANKS MENU, and the cost of that is worth stating rather than discovering. The mode is one
	value, so a player killed with the character menu open reads as Dead: the ambient corner tiles
	drop (right -- they describe a world that player is no longer standing in) and the scrim goes with
	Menu (wrong -- the panel is still up, now over an undimmed screen, until it is closed or the
	respawn lands). The alternative -- deriving each binding from the raw facts instead of from the
	mode -- composes correctly and was rejected because it leaves the mode with no consumer at all,
	which is how a value that Phase 4's Escape stack depends on quietly rots before Phase 4 arrives.
	A few seconds of an undimmed menu during a respawn countdown is the cheaper wrong.

	WHY THE MODAL GATE IS READ FROM AN Attribute RATHER THAN FROM ModalScreen DIRECTLY. The count is
	module-scope state inside a Component, published to Constants.Attributes.UiModalOpen -- which is
	already the seam Client/Combat/AttackInputClient.lua, GrabInputClient.lua, DefenseClient.lua and
	Client/Blimp/BlimpController.lua all read as a hard input gate. This codebase's rule is that
	cross-system influence travels through an Attribute seam rather than a require, and adding a
	parallel Fusion counter here would be a second answer to a question that already has one. So
	ObserveModalGate below is an ADAPTER over that seam and nothing more: it is the only thing in this
	file that touches an Instance, it is a separate function so a spec can hand New a plain Value
	instead, and it is the only place a LocalPlayer is looked up.

	NO RunService CONNECTION, per plan 11 rule 1. Both inputs change on edges that already exist (an
	Attribute write, a Fusion Value set), so the mode recomputes when something happens and costs
	exactly nothing when nothing does. The motion that carries the dim is a tween, and it lives in
	Shell/Regions.lua next to the pixels rather than here -- which is also what leaves this file
	testable without a render pass.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

-- Playing: the ordinary state, and the only one in which every surface is at full strength.
-- Menu:    at least one ModalScreen is open. Combat input is already hard-gated here.
-- Dead:    the local player is down and the respawn overlay is up.
export type Mode = "Playing" | "Menu" | "Dead"

export type ChromeHandle = {
	-- What the UI is doing. Derived; nothing writes it. Phase 4's Escape stack reads this to decide
	-- whether Escape belongs to a panel or to Roblox's own menu.
	Mode: Fusion.Computed<Mode>,
	-- 0..1, a GOAL rather than an animated value -- see the tween note in this file's header.
	Dim: Fusion.Computed<number>,
	-- Whether the ambient corner tiles are on screen at all.
	AmbientVisible: Fusion.Computed<boolean>,
}

export type ChromeProps = {
	-- Whether any ModalScreen is open. In the client this is ObserveModalGate's Value; a spec passes
	-- its own so the Menu branch is drivable without a LocalPlayer.
	ModalOpen: UsedAs<boolean>,
	-- Whether the local player is dead. Screens/DeathFeed's handle exposes this off the same Value
	-- that drives the respawn overlay, so the two can never disagree about it.
	Dead: UsedAs<boolean>,
}

local Chrome = {}

-- The one adapter between Constants.Attributes.UiModalOpen and Fusion. Returns a Value that mirrors
-- the Attribute for as long as the scope lives.
--
-- RETURNS A PERMANENTLY-false VALUE WHEN THERE IS NO LocalPlayer, rather than erroring. That is not
-- defensive coding for its own sake: this module is require()d on the server by
-- scripts/run-tests.lua's client load-check, where Players.LocalPlayer is nil -- the same window
-- Components/ModalScreen.lua's own publishModalGate guards for, and for the same reason (the
-- Attribute exists to gate a local player's input, and there is no local player).
function Chrome.ObserveModalGate(scope: Scope): Fusion.Value<boolean>
	local open: Fusion.Value<boolean> = scope:Value(false)

	local player = Players.LocalPlayer
	if player == nil then
		return open
	end

	local function read(): ()
		open:set(player:GetAttribute(Constants.Attributes.UiModalOpen) == true)
	end

	-- Read once before connecting, not only on the next change. A modal open at the moment this is
	-- constructed would otherwise leave the mode reading Playing until the player closed it -- and
	-- while UI.Mount() is not a window in which a modal can already be open today, "the first value
	-- arrives on the first edge" is exactly the assumption that breaks the day one can be.
	read()
	table.insert(scope, player:GetAttributeChangedSignal(Constants.Attributes.UiModalOpen):Connect(read))

	return open
end

-- Builds the mode and the two bindings that read off it. Takes its facts as arguments and holds
-- nothing globally, the same posture Shell/Surface.lua and Shell/Regions.lua take -- see the
-- memoization note in Regions' header for the hot-reload failure a module-level cache causes here.
function Chrome.New(scope: Scope, props: ChromeProps): ChromeHandle
	local mode = scope:Computed(function(use): Mode
		-- Order is the precedence, and it is the whole of the arbitration -- see the DEAD OUTRANKS
		-- MENU note in this file's header for what it costs.
		if use(props.Dead) then
			return "Dead"
		end
		if use(props.ModalOpen) then
			return "Menu"
		end
		return "Playing"
	end)

	return {
		Mode = mode,
		-- Full dim behind a panel, none otherwise. How dark "full" actually is belongs to
		-- Shell/Regions.lua (SCRIM_TRANSPARENCY), not here: this file says WHEN the layer steps back,
		-- never how far.
		Dim = scope:Computed(function(use): number
			return if use(mode) == "Menu" then 1 else 0
		end),
		-- The corner readouts describe the world around the player. A dead player is not in it.
		AmbientVisible = scope:Computed(function(use): boolean
			return use(mode) ~= "Dead"
		end),
	}
end

return Chrome
