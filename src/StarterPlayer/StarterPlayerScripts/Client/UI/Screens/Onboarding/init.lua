--!strict
--[[
	Onboarding/init.lua

	Owns: the root Screen for first-time-player onboarding -- a ScreenGui plus an active-stage switch
	between Cinematic/RaceSelect/Attributes/NameEntry/Confirmation (Types.Stage), and the single
	OnboardingHandle every one of those five screens' props are sliced from. Mounted and torn down
	entirely by Client/Onboarding/OnboardingClient.lua, which creates its OWN temporary Fusion scope
	for this -- see that module's own header for why that's a deliberate, narrow exception to
	UI/init.lua's "nothing else creates its own root scope" rule.

	Follows every other multi-screen Screen's "screen exposes state/signals, client module drives
	from outside" convention (BugReport/init.lua, Screens/DevMenu/init.lua) -- every Fusion.Value and
	BindableEvent making up OnboardingHandle is created here, but OnboardingClient.lua is the only
	thing that ever writes Stage/HoldProgress/StatusText/IsSubmitting/IsSucceeding or listens to the
	*Requested signals; this module only wires the five sub-screens to their slice of the Handle and
	switches which one is Visible.

	Cinematic gets a fully transparent backdrop (the sky-facing camera OnboardingClient.lua points
	the real Camera at during that stage needs to show through); the four "creator" stages share one
	dimming backdrop + centered content area, reading as "a system of the world" per
	docs/ui-ux-philosophy.md's Menu Design section ("larger panels... still maintain the same
	palette/geometry/typography").

	Does not own: any remote call, timer, or input handling -- all three live in OnboardingClient.lua
	exclusively.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Types = require(ReplicatedStorage.Shared.Types)

local Tokens = require(script.Parent.Parent.Tokens)
local OnboardingTypes = require(script.Types)
local Cinematic = require(script.Cinematic)
local RaceSelect = require(script.RaceSelect)
local Attributes = require(script.Attributes)
local NameEntry = require(script.NameEntry)
local Confirmation = require(script.Confirmation)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
export type OnboardingHandle = OnboardingTypes.OnboardingHandle
-- Re-exported so OnboardingClient.lua (which already requires this module for OnboardingHandle) can
-- name a target Stage for its own auto-jump-on-repeated-failure logic without a second require of
-- Types.lua under a different alias.
export type Stage = OnboardingTypes.Stage

local function Onboarding(scope: Scope, playerGui: PlayerGui): OnboardingHandle
	local stage: Fusion.Value<OnboardingTypes.Stage> = scope:Value("Cinematic")

	local selectedRaceId: Fusion.Value<Types.RaceId?> = scope:Value(nil :: Types.RaceId?)
	local attributes: Fusion.Value<Types.AttributeBlock> = scope:Value({
		Vitality = 0,
		Fortitude = 0,
		MeridianFlow = 0,
		Might = 0,
		Pressure = 0,
		Fleetness = 0,
	} :: Types.AttributeBlock)
	local displayName = scope:Value("")
	local holdProgress = scope:Value(0)
	local cinematicRevealIndex = scope:Value(0)
	local skipHintRevealed = scope:Value(false)
	local statusText = scope:Value("")
	local isSubmitting = scope:Value(false)
	local isSucceeding = scope:Value(false)
	-- Written by Confirmation.lua's commit control, read by OnboardingClient.lua's hold gesture --
	-- the one prop in this Handle that flows screen -> client rather than the other way. See
	-- Types.lua's own note on ConfirmationProps.CommitPointerHeld.
	local commitPointerHeld = scope:Value(false)

	-- Plain Instance.new(...), not scope:New(...) (these are BindableEvents, not GuiObjects) -- each
	-- one is still registered into `scope` explicitly (a Fusion scope is itself just an array of
	-- cleanup tasks; an Instance pushed directly into it gets :Destroy()'d the same as anything
	-- scope:New built) so OnboardingClient.lua's scope:doCleanup() actually destroys these instead of
	-- leaking them once chargen completes and this whole screen tears down -- unlike BugReport/
	-- init.lua's own submitRequestedEvent, which never needs this because that screen's scope is the
	-- session-long one and is never torn down.
	local raceContinueRequestedEvent = Instance.new("BindableEvent")
	local attributesContinueRequestedEvent = Instance.new("BindableEvent")
	local attributesBackRequestedEvent = Instance.new("BindableEvent")
	local nameContinueRequestedEvent = Instance.new("BindableEvent")
	local nameBackRequestedEvent = Instance.new("BindableEvent")
	-- ONE shared event across all four creator screens, not one each -- see this file's own
	-- OnboardingHandle field comment (Types.lua) for why "jump to an arbitrary earlier stage" is a
	-- single cross-cutting action rather than a per-screen next/prev pair like Continue/Back. No
	-- confirmationBackRequestedEvent -- Confirmation's three labeled escape hatches fire this
	-- instead (see Types.lua's own ConfirmationProps comment).
	local stepRailNavigateRequestedEvent = Instance.new("BindableEvent")
	table.insert(scope, raceContinueRequestedEvent)
	table.insert(scope, attributesContinueRequestedEvent)
	table.insert(scope, attributesBackRequestedEvent)
	table.insert(scope, nameContinueRequestedEvent)
	table.insert(scope, nameBackRequestedEvent)
	table.insert(scope, stepRailNavigateRequestedEvent)

	local cinematicProps: OnboardingTypes.CinematicProps = {
		RevealIndex = cinematicRevealIndex,
		HoldProgress = holdProgress,
		SkipHintRevealed = skipHintRevealed,
	}
	local raceSelectProps: OnboardingTypes.RaceSelectProps = {
		SelectedRaceId = selectedRaceId,
		Attributes = attributes,
		ContinueRequested = raceContinueRequestedEvent,
		StepRailNavigateRequested = stepRailNavigateRequestedEvent,
	}
	local attributesProps: OnboardingTypes.AttributesProps = {
		SelectedRaceId = selectedRaceId,
		Attributes = attributes,
		ContinueRequested = attributesContinueRequestedEvent,
		BackRequested = attributesBackRequestedEvent,
		StepRailNavigateRequested = stepRailNavigateRequestedEvent,
	}
	local nameEntryProps: OnboardingTypes.NameEntryProps = {
		SelectedRaceId = selectedRaceId,
		DisplayName = displayName,
		ContinueRequested = nameContinueRequestedEvent,
		BackRequested = nameBackRequestedEvent,
		StepRailNavigateRequested = stepRailNavigateRequestedEvent,
	}
	local confirmationProps: OnboardingTypes.ConfirmationProps = {
		SelectedRaceId = selectedRaceId,
		Attributes = attributes,
		DisplayName = displayName,
		HoldProgress = holdProgress,
		StatusText = statusText,
		IsSubmitting = isSubmitting,
		IsSucceeding = isSucceeding,
		CommitPointerHeld = commitPointerHeld,
		StepRailNavigateRequested = stepRailNavigateRequestedEvent,
	}

	local function isStage(target: OnboardingTypes.Stage): Fusion.Computed<boolean>
		return scope:Computed(function(use)
			return use(stage) == target
		end)
	end

	local isCinematic = isStage("Cinematic")
	local isCreatorStage = scope:Computed(function(use)
		return use(stage) ~= "Cinematic"
	end)

	-- Whole-screen slide-up entrance (docs/design/intro-redesign-figma-spec.md's Motion section:
	-- "slide-up: opacity 0->1, translateY(16px->0)... screen enter, .35s ease"). scope:Spring, not
	-- TweenService + Tokens.Motion.EnterTween, despite that tween existing for exactly this: every
	-- other motion anywhere in this UI framework is a spring (Tokens.Motion's own *Spring entries),
	-- and FadeSpring is already the precedented choice for "a one-shot entrance fade"
	-- (PostureBreakBanner/StatusBanner) -- introducing the first TweenService+Observer pairing into
	-- this Fusion tree for one cosmetic transition isn't worth breaking that consistency, and a
	-- spring at FadeSpring's speed/damping settles in almost exactly the same ~0.3s the design's own
	-- tween would take.
	--
	-- ⚠️ UNVERIFIED, per the redesign handoff's own caution: this session has no Studio access, so
	-- neither CanvasGroup risk it names -- TextBox focus, and UIStroke rendering inside a CanvasGroup
	-- -- could be checked live. The TextBox risk is handled below (NameEntryLayer stays a plain
	-- Frame). The UIStroke risk is accepted as-is on the other four layers (every component in this
	-- tree leans on UIStroke for its borders, so avoiding CanvasGroup everywhere would mean
	-- abandoning the slide-up entrance across the whole flow, a bigger deviation than one
	-- unconfirmed visual glitch) -- worth an early look in the in-Studio pass this task still needs.
	local SLIDE_OFFSET = 16
	local function slideUpSettled(isActive: Fusion.Computed<boolean>): Fusion.Computed<number>
		local revealed = scope:Computed(function(use)
			return if use(isActive) then 1 else 0
		end)
		return scope:Spring(revealed, Tokens.Motion.FadeSpring.Speed, Tokens.Motion.FadeSpring.Damping)
	end
	local function slideUpPosition(settled: Fusion.Computed<number>): Fusion.Computed<UDim2>
		return scope:Computed(function(use)
			return UDim2.fromOffset(0, (1 - use(settled)) * SLIDE_OFFSET)
		end)
	end

	local cinematicSettled = slideUpSettled(isCinematic)
	local raceSelectSettled = slideUpSettled(isStage("RaceSelect"))
	local attributesSettled = slideUpSettled(isStage("Attributes"))
	local nameEntrySettled = slideUpSettled(isStage("NameEntry"))
	local confirmationSettled = slideUpSettled(isStage("Confirmation"))

	local root = scope:New "Frame" {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,

		[Children] = {
			scope:New "CanvasGroup" {
				Name = "CinematicLayer",
				Size = UDim2.fromScale(1, 1),
				Position = slideUpPosition(cinematicSettled),
				BackgroundTransparency = 1,
				GroupTransparency = scope:Computed(function(use)
					return 1 - use(cinematicSettled)
				end),
				Visible = isCinematic,

				[Children] = Cinematic(scope, cinematicProps),
			},

			-- Shared dimming backdrop for every "creator" stage (RaceSelect/Attributes/NameEntry/
			-- Confirmation) -- see this file's header. Only one child Frame is ever Visible at once,
			-- determined by `stage` below. Plain Frame, not CanvasGroup -- it's just a dimming
			-- backdrop with no entrance motion of its own; each stage layer inside it animates
			-- independently.
			scope:New "Frame" {
				Name = "CreatorLayer",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Tokens.Color.Background,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Visible = isCreatorStage,

				[Children] = {
					scope:New "CanvasGroup" {
						Name = "RaceSelectLayer",
						Size = UDim2.fromScale(1, 1),
						Position = slideUpPosition(raceSelectSettled),
						BackgroundTransparency = 1,
						GroupTransparency = scope:Computed(function(use)
							return 1 - use(raceSelectSettled)
						end),
						Visible = isStage("RaceSelect"),

						[Children] = RaceSelect(scope, raceSelectProps),
					},
					scope:New "CanvasGroup" {
						Name = "AttributesLayer",
						Size = UDim2.fromScale(1, 1),
						Position = slideUpPosition(attributesSettled),
						BackgroundTransparency = 1,
						GroupTransparency = scope:Computed(function(use)
							return 1 - use(attributesSettled)
						end),
						Visible = isStage("Attributes"),

						[Children] = Attributes.Mount(scope, attributesProps),
					},
					-- Plain Frame, not CanvasGroup -- Position-only slide (no fade). This is the one
					-- stage with a live TextBox (its own name field), and the redesign handoff flags
					-- CanvasGroup as a real, untested risk to TextBox focus here specifically; this
					-- session has no way to verify it in Studio, so the position-only fallback the
					-- handoff itself authorizes is the safer default rather than an unverifiable bet.
					scope:New "Frame" {
						Name = "NameEntryLayer",
						Size = UDim2.fromScale(1, 1),
						Position = slideUpPosition(nameEntrySettled),
						BackgroundTransparency = 1,
						Visible = isStage("NameEntry"),

						[Children] = NameEntry(scope, nameEntryProps),
					},
					scope:New "CanvasGroup" {
						Name = "ConfirmationLayer",
						Size = UDim2.fromScale(1, 1),
						Position = slideUpPosition(confirmationSettled),
						BackgroundTransparency = 1,
						GroupTransparency = scope:Computed(function(use)
							return 1 - use(confirmationSettled)
						end),
						Visible = isStage("Confirmation"),

						[Children] = Confirmation(scope, confirmationProps),
					},
				},
			},
		},
	} :: Frame

	local screenGui = scope:New "ScreenGui" {
		Name = "Onboarding",
		ResetOnSpawn = false,
		Enabled = true,
		DisplayOrder = 10, -- Above the normal HUD stack (which isn't even mounted yet at this point).
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = playerGui,

		[Children] = root,
	} :: ScreenGui

	return {
		Stage = stage,
		Cinematic = cinematicProps,
		RaceSelect = raceSelectProps,
		Attributes = attributesProps,
		NameEntry = nameEntryProps,
		Confirmation = confirmationProps,
		Root = screenGui,
		StepRailNavigateRequested = stepRailNavigateRequestedEvent,
	}
end

return { Mount = Onboarding }
