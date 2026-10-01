--!strict
--[[
	PresentationPreview.lua

	Owns: the Move Editor's per-moment Preview (the Presentation tab) -- playing ONE moment of the open
	DRAFT's presentation on this client, before it is saved or even previewed to the server.

	THROUGH THE RUNTIME'S OWN PATH, NEVER A COPY OF IT. Each moment group hands the draft's cue to the same
	function a real event reaches:

	    Swing       SwingPresentation.Preview -> SwingPresentation.PlayCue (+ CombatAudio.PlaySwing for
	                Active, the whoosh), exactly what a thrown swing's scheduler calls
	    Hit         CombatFeedbackClient.PresentHit -- the cosmetic half of onFeedback -- with a local
	                payload: this admin as the attacker, the nearest combatant in front of them as the
	                defender (a bench dummy or bot, so the flash has a body to land on; the admin's own body
	                when there is none, which HitFlash skips by design), the contact at the defender
	    Projectile  ProjectileFX.Preview -- a short local shot through onLaunch for Launch and In flight,
	                the point cue a few studs ahead for Bounce, World impact and End
	    Domain      DomainFX.Preview -- the point cue, and for the three shell moments a local realm in the
	                draft's own shape and colours, unfurling / holding / folding on a short scripted clock

	so a preview can only disagree with the game where the game itself would. Nothing here reaches the
	server; a preview decides nothing and hits nothing. The trail (Active's TrailColor) is the one channel
	it cannot show -- it needs a real swing's anchor -- so Test is the way to see it.

	Lives under DevTools (omitted from live.project.json with the editor); every module it calls is
	runtime and ships in both builds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AttackTypes = require(ReplicatedStorage.Shared.Attack.AttackTypes)
local CharacterUtil = require(ReplicatedStorage.Shared.CharacterUtil)
local DamageTypes = require(ReplicatedStorage.Shared.Damage.DamageTypes)
local MovePresentationTypes = require(ReplicatedStorage.Shared.Combat.MovePresentationTypes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)

local CombatFeedbackClient = require(script.Parent.Parent.Parent.Combat.CombatFeedbackClient)
local DomainFX = require(script.Parent.Parent.Parent.FX.DomainFX)
local CombatTargets = require(script.Parent.Parent.Parent.Combat.CombatTargets)
local MovePresentation = require(script.Parent.Parent.Parent.FX.MovePresentation)
local ProjectileFX = require(script.Parent.Parent.Parent.FX.ProjectileFX)
local SwingPresentation = require(script.Parent.Parent.Parent.FX.SwingPresentation)

local PresentationPreview = {}

-- How far in front of the admin a bench body may stand and still be the preview's defender.
local DEFENDER_RANGE_STUDS = 20
local DEFENDER_CONE_DEGREES = 60

export type Context = {
	-- A Default move's stage ("Heavy" whooshes like a heavy) and weapon (whose own SFX answer when the
	-- cue leaves the sound unset); nil for a custom move.
	Stage: string?,
	WeaponId: string?,
}

-- Plays `moment` of `draft`'s presentation. Returns the status line for the editor's footer.
function PresentationPreview.Play(draft: MoveTypes.MoveDefinition, moment: string, context: Context): string
	local definition = MovePresentationTypes.Moment(moment)
	if definition == nil then
		return "Preview: that moment does not exist."
	end
	local character = Players.LocalPlayer.Character
	local root = if character then CharacterUtil.RootOf(character) else nil
	if character == nil or root == nil then
		return "Preview: you have no character to play it on."
	end
	local presentation = draft.Presentation
	local cue = MovePresentation.CueFrom(presentation, moment)

	if definition.Group == "Swing" then
		local kind: AttackTypes.AttackKind = if context.Stage == "Heavy"
			then "Heavy"
			elseif context.Stage ~= nil then "Basic"
			else "Hotbar"
		SwingPresentation.Preview(cue, moment, kind, context.WeaponId)
	elseif definition.Group == "Hit" then
		local defender = CombatTargets.NearestInCone(
			root.Position,
			root.CFrame.LookVector,
			DEFENDER_RANGE_STUDS,
			DEFENDER_CONE_DEGREES,
			character
		) or character
		local defenderRoot = CharacterUtil.RootOf(defender)
		local contact = if defender ~= character and defenderRoot
			then defenderRoot.Position
			else root.Position + root.CFrame.LookVector * 3
		local payload: DamageTypes.CombatFeedback = {
			Kind = definition.Outcome :: any,
			Role = "Attacker",
			Attacker = character,
			Defender = defender,
			Damage = 0,
			GuardDrain = 0,
			ComboStage = 1,
			MoveId = draft.MoveId,
			ContactPosition = contact,
			Perfect = definition.Perfect,
		} :: any
		CombatFeedbackClient.PresentHit(payload, cue)
	elseif definition.Group == "Domain" then
		local domain = draft.Domain
		if domain == nil then
			return "Preview: realm moments only play for a move that opens a realm."
		end
		DomainFX.Preview(presentation, domain, moment, root.CFrame)
	else
		if not MoveTypes.IsProjectile(draft) then
			return "Preview: projectile moments only play for a projectile move."
		end
		ProjectileFX.Preview(presentation, moment, root.CFrame)
	end

	if cue == nil then
		return `Previewed "{definition.Label}" -- nothing authored, so this is the default.`
	end
	return `Previewed "{definition.Label}".`
end

return PresentationPreview
