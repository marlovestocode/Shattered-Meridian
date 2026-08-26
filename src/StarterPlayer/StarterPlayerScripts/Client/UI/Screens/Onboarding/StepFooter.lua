--!strict
--[[
	Onboarding/StepFooter.lua

	Owns: the two buttons every character creation step's footer is made of -- Back and Continue.

	NameEntry and Attributes held twenty-two byte-identical lines building both; RaceSelect held the
	Continue half of the same. The variant, the width, the disabled gate and the peek-before-firing
	guard were each written out three times, which is three places for one of them to drift -- and
	the guard in particular is the kind of line that looks redundant next to a `Disabled` prop and
	gets "cleaned up" by somebody who has not noticed that a Disabled button still fires Activated on
	a gamepad if the selection was already on it.

	Returns the BUTTONS, not a footer frame: CreatorFrame.lua already owns the footer band and its
	FooterHint, and each step composes its own FooterButtons list -- Confirmation's is a single commit
	button that belongs to nothing here. So this is the two shared pieces, not a shape to fit into.

	Does not own: the footer band or hint (CreatorFrame.lua), what Back and Continue MEAN (each step
	fires its own BindableEvent), or when Continue is allowed (each step computes its own
	`continueDisabled` from its own validity rules).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Tokens)
local Button = require(script.Parent.Parent.Parent.Components.Button)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>

local StepFooter = {}

-- Secondary, narrower than Continue, and never disabled -- going back is always allowed, including
-- from a step whose own input is invalid. That asymmetry is the reason the two are separate
-- functions rather than one call with a flag.
function StepFooter.Back(scope: Scope, onActivated: () -> ()): TextButton
	return Button(scope, {
		Text = "Back",
		Variant = "Secondary",
		Size = UDim2.fromOffset(120, Tokens.Control.RowHeight),
		OnActivated = onActivated,
	})
end

-- Primary, and gated twice on purpose. `Disabled` is what makes it LOOK unavailable; the peek inside
-- OnActivated is what makes it BE unavailable -- a disabled Button still receives Activated if a
-- gamepad's selection was already sitting on it when the gate closed, so dropping the guard would
-- let a player advance out of a step they have not satisfied.
function StepFooter.Continue(scope: Scope, disabled: UsedAs<boolean>, onActivated: () -> ()): TextButton
	return Button(scope, {
		Text = "Continue",
		Variant = "Primary",
		Size = UDim2.fromOffset(160, Tokens.Control.RowHeight),
		Disabled = disabled,
		OnActivated = function()
			if peek(disabled) then
				return
			end
			onActivated()
		end,
	})
end

return StepFooter
