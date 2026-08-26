--!strict
--[[
	Onboarding/Types.lua

	Owns: every type Cinematic.lua/RaceSelect.lua/Attributes.lua/NameEntry.lua/Confirmation.lua/
	init.lua share -- the Stage enum driving which of the five is currently mounted, and each
	screen's own prop shape. Same "shared leaf, no Screen<->Screen require cycle" role
	Screens/DevMenu/Types.lua already plays for Sidebar.lua/ContentArea.lua -- see that file's own
	header for the precedent this follows.

	Does not own any Mount()/rendering logic, and does not own validation (Server/Systems/
	CharacterCreationSystem.lua re-validates everything regardless of what these screens show) or
	remote calls (Client/Onboarding/OnboardingClient.lua owns both) -- see init.lua's own header for
	the full ownership boundary this screen folder operates under.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

-- Which of the five onboarding screens is currently mounted -- init.lua's active-stage switch reads
-- this; OnboardingClient.lua (outside, driving this Handle) is the only writer, the same
-- "screen exposes state, client module drives from outside" split BugReportClient.lua/DevMenuClient.
-- lua already establish for their own screens. No "Done" stage: OnboardingClient.Run() simply
-- returns (and tears down this Handle's Fusion scope) the instant CharacterCreation_Finalize
-- succeeds, rather than the Handle ever representing a sixth, already-finished stage.
-- BloodlineSpin is an EPILOGUE, after the seal -- it carries no StepRail entry, exactly as the
-- Cinematic prologue carries none (see StepRail.lua's own "3 steps + a seal" header). It has to
-- come after Confirmation rather than anywhere earlier: BloodlineSystem.Spin refuses until the
-- profile has a raceId, and nothing writes one until Finalize succeeds at Confirmation.
export type Stage = "Cinematic" | "RaceSelect" | "Attributes" | "NameEntry" | "Confirmation" | "BloodlineSpin"

export type CinematicProps = {
	-- Which staged text line is currently revealed (0 = none yet) -- advanced by
	-- OnboardingClient.lua's own timer, never this screen's own clock, so the reveal pacing has one
	-- authority.
	RevealIndex: Fusion.Value<number>,
	-- 0-1 hold-to-skip progress -- see HoldProgress's shared header on ConfirmationProps below for
	-- why this is the same Value passed to both screens rather than two separate ones.
	HoldProgress: Fusion.Value<number>,
	-- False until Constants.CharacterCreation.SkipHintRevealSeconds elapses, then stays true --
	-- gates the "Hold to skip" affordance's own fade-in. Same "OnboardingClient.lua's timer is the
	-- one authority" reasoning as RevealIndex above, kept as a separate field rather than derived
	-- from RevealIndex since the two are tuned independently (skip-hint delay vs. per-line pacing).
	SkipHintRevealed: Fusion.Value<boolean>,
}

-- ContinueRequested/BackRequested are typed as the raw BindableEvent (not just its .Event signal)
-- throughout this file -- deliberately, since ownership crosses a file boundary here: init.lua
-- creates and owns the Instance, the screen component (RaceSelect.lua/Attributes.lua/etc.) calls
-- :Fire() on it directly from a button's OnActivated, and OnboardingClient.lua (the driver, holding
-- the same reference via OnboardingHandle) listens via its .Event property. A plain RBXScriptSignal
-- prop would give the screen component no way to actually fire it -- BugReport/init.lua's own
-- submitRequestedEvent avoids this only because that screen builds its whole tree in one file and
-- fires the SAME local BindableEvent it later returns; splitting across files (per this feature's
-- explicit per-screen file layout) needs the Instance itself threaded through as the prop instead.

export type RaceSelectProps = {
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	-- Reset to that race's default block (BaseValuePerAttribute + Constants.CharacterCreation.
	-- RacePrefills) the instant a card is picked -- this screen owns that reset directly (a pure,
	-- presentation-scoped computation, not something that needs to round-trip through
	-- OnboardingClient) per this feature's "switching race resets to that race's default prefill +
	-- remaining free pool" rule.
	Attributes: Fusion.Value<Types.AttributeBlock>,
	ContinueRequested: BindableEvent,
	-- See StepRailNavigateRequested's own comment on OnboardingHandle below -- the SAME Instance
	-- reference is threaded onto every creator screen's Props (same shared-Value precedent
	-- CinematicProps/ConfirmationProps.HoldProgress already establishes), since CreatorFrame builds
	-- a StepRail inside each of the four screens and each needs a way to fire it. RaceSelect never
	-- actually fires this itself (nothing precedes step 1 to jump back to), but still takes the prop
	-- so CreatorFrame's own signature doesn't need a screen-by-screen special case.
	StepRailNavigateRequested: BindableEvent,
}

export type AttributesProps = {
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	Attributes: Fusion.Value<Types.AttributeBlock>,
	ContinueRequested: BindableEvent,
	BackRequested: BindableEvent,
	StepRailNavigateRequested: BindableEvent,
}

export type NameEntryProps = {
	-- Read-only here -- RaceSelect.lua/OriginCard.lua own writing it. NameEntry needs it live for its
	-- own identity line ("KAELEN / FIRMBORN -- Heirs of the Stonepath"), read-only for the same
	-- reason ConfirmationProps.SelectedRaceId below is.
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	-- Two-way bound, written directly by this screen's own TextBox (not Components/TextField.lua --
	-- see NameEntry.lua's own header for why) -- OnboardingClient.lua never writes this directly,
	-- only reads it (peek) at Finalize time.
	DisplayName: Fusion.Value<string>,
	ContinueRequested: BindableEvent,
	BackRequested: BindableEvent,
	StepRailNavigateRequested: BindableEvent,
}

export type ConfirmationProps = {
	-- Read-only summary inputs -- Confirmation.lua only ever reads these (Computed display strings),
	-- never mutates them; RaceSelect/Attributes/NameEntry above own the actual editing.
	SelectedRaceId: Fusion.Value<Types.RaceId?>,
	Attributes: Fusion.Value<Types.AttributeBlock>,
	DisplayName: Fusion.Value<string>,
	-- 0-1 held-commit progress, written by OnboardingClient.lua's own UserInputService hold-tracking
	-- -- the same "held input, ~1s" interaction language and the same Value identity as
	-- CinematicProps.HoldProgress (only one of the two screens is ever mounted at a time, so sharing
	-- one Value across both is safe and avoids a second near-identical field).
	HoldProgress: Fusion.Value<number>,
	-- Empty string = no error currently shown. Set by OnboardingClient.lua on a Finalize
	-- Success = false response; cleared on the next held-commit attempt.
	StatusText: Fusion.Value<string>,
	-- Disables the hold gesture and shows a submitting state while Finalize is in flight -- same
	-- "driven from outside while a request is in flight" contract BugReport's IsSubmitting already
	-- establishes.
	IsSubmitting: Fusion.Value<boolean>,
	-- True from the moment Finalize resolves Success = true until this whole screen tears down.
	-- Drives the success beat (docs/design/intro-redesign-handoff.md's designer direction: "on
	-- Success = true, fracture-out everything except the name, hold it alone in the void for
	-- ~1.2s") -- Confirmation.lua fades everything but the name label out when this flips true;
	-- OnboardingClient.lua sets it and holds for the beat's duration before tearing the scope down,
	-- so the fade has time to finish before the Instance disappears out from under it.
	IsSucceeding: Fusion.Value<boolean>,
	-- True while a mouse/touch press is being held ON THE COMMIT CONTROL specifically. This is the
	-- one prop in this file the screen WRITES and OnboardingClient.lua reads, which is the reverse of
	-- every other field here -- deliberately, because the information only exists at the control.
	--
	-- OnboardingClient's hold gesture used to accept mouse/touch from anywhere on screen with no
	-- hit-testing, which meant a held click over empty space (or a resting thumb on a phone)
	-- permanently created the character -- the least reversible write in the game on the loosest
	-- possible trigger. Routing pointer input through the button that visibly says "hold to confirm"
	-- is the fix; see runHoldGesture's own note for why keyboard/gamepad stay global.
	CommitPointerHeld: Fusion.Value<boolean>,
	-- No BackRequested here (unlike Attributes/NameEntry above) -- the designer's "three labeled
	-- escape hatches instead of one generic BACK" replaces it entirely with three buttons that fire
	-- StepRailNavigateRequested directly (the same signal the step rail's own clickable-completed-
	-- steps use), one per earlier stage. See Confirmation.lua's own header.
	StepRailNavigateRequested: BindableEvent,
}

-- Handle returned by Onboarding.Mount(scope, playerGui) -- OnboardingClient.lua drives every field
-- here from outside, per this folder's "screen exposes state/signals, client module drives from
-- outside" convention (init.lua's own header).
-- Every field here is written by OnboardingClient.lua from the Spin remote's own response --
-- including RerollsRemaining, which rides on every response (success AND refusal) precisely so
-- this never has to be decremented locally and drift from the profile that owns it. See
-- BloodlineTypes.BloodlineSpinResult.
export type BloodlineSpinProps = {
	-- "" until something has been rolled -- which is also how the screen knows to show its empty
	-- state and whether the next press is a free roll or a paid reroll.
	ResultName: Fusion.Value<string>,
	ResultRarity: Fusion.Value<string>,
	ResultFlavor: Fusion.Value<string>,
	RerollsRemaining: Fusion.Value<number>,
	-- Disables the Spin button while a roll is in flight, the same "driven from outside while a
	-- request is in flight" contract ConfirmationProps.IsSubmitting already establishes.
	IsSpinning: Fusion.Value<boolean>,
	-- Empty string = nothing to report. Carries the server's refusal in plain words -- including
	-- the one every player gets until bloodline content is authored.
	StatusText: Fusion.Value<string>,
	SpinRequested: BindableEvent,
	-- Ends the intro. Always available, even before a first spin -- see BloodlineSpin.lua's header
	-- on why a player must never be trapped here.
	ContinueRequested: BindableEvent,
}

export type OnboardingHandle = {
	Stage: Fusion.Value<Stage>,
	Cinematic: CinematicProps,
	RaceSelect: RaceSelectProps,
	Attributes: AttributesProps,
	NameEntry: NameEntryProps,
	Confirmation: ConfirmationProps,
	BloodlineSpin: BloodlineSpinProps,
	Root: ScreenGui,
	-- Fired by StepRail.lua (embedded via CreatorFrame in each of the four creator screens) when the
	-- player clicks an already-completed step to jump straight there, bypassing the linear
	-- Continue/Back chain. Fires with the target Stage as its one argument. ONE shared event, not one
	-- per screen: unlike Continue/Back (screen-specific, next/prev only), "jump to an arbitrary
	-- earlier stage" is the identical action from every screen -- see StepRail.lua's own header for
	-- why this couldn't just reuse BackRequested. Also threaded onto each screen's own Props (same
	-- reference) since a screen only ever sees its own Props slice, not this whole Handle.
	StepRailNavigateRequested: BindableEvent,
}

return {}
