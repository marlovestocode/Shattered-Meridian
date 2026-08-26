--!strict
--[[
	ObjectStunEditor.lua

	Owns: the Move Editor's Object Stun section content -- authoring Types.ObjectStunConfig, the
	reaction a move gets when it knocks a target INTO something.

	Laid out in the order an author actually thinks about it, with each group's heading naming the
	question it answers:

	  * WHAT COUNTS      -- which surface classes, and which parts qualify at all (anchored only, a
	                        required tag, a minimum size).
	  * WHAT PROVES IT   -- the four causation gates. Given a whole prose paragraph of their own,
	                        because this is the part of the feature that is not obvious: a wall-slam
	                        that fires whenever someone happens to be near a wall feels random, and
	                        these four fields are the difference. See Types.ObjectStunConfig's own
	                        header for the model.
	  * WHAT HAPPENS     -- stun, ragdoll, bonus damage/posture, rebound, pin, clips, sound, colour,
	                        camera shake.
	  * HOW OFTEN        -- cooldown and per-throw trigger cap.
	  * FOLLOW-UP        -- the optional second attack, with its own full hitbox/timing/damage block.

	Every numeric field's Min/Max comes from Constants.MoveEditor.ObjectStun.Limits, which is the
	same table MoveRegistryManager.Validate clamps against server-side, so this panel cannot offer a
	value the server would silently rewrite. Enabling either the block or its follow-up populates it
	from that same Constants table's Defaults/FollowUpDefaults, so "on" always means a coherent,
	immediately-testable configuration rather than a pile of zeroes.

	NOT CURRENTLY WIRED TO THE LIVE COMBAT STACK (2026-08-19 note, added during the Move Editor repair
	pass -- see Client/DevTools/MoveEditor/MoveEditorClient.lua's own header for the sibling fix that DID restore
	live test-firing). Server/Combat/ObjectStunResolver.lua was deleted in the same combat rewrite that
	replaced CombatSystem.lua with the current HitboxEngine -> DefenseSystem -> DamageSystem ->
	AttackRequestSystem stack, and nothing has been rebuilt against the new stack to consume this
	block since -- MoveRegistryManager.Validate still encodes/decodes it (the schema stayed alive on
	purpose, see that module's own header), so authoring here is fully preserved and will take effect
	the moment a resolver exists again, but until then every field below has zero effect on a real hit.
	This is already independently reported: MoveTypes.ToEngineAttackDefinition's own `notes` mechanism
	flags "ObjectStun is authored but ignored" for any move carrying one, and AttackCatalog.Get logs it
	server-side -- see this section's own top-of-list notice below, which surfaces the SAME fact to the
	person actually authoring it, matching the honesty bar Client/DevTools/MoveEditor/MoveEditorClient.lua's own
	header already holds Test-on-Dummy to. Rebuilding a minimal resolver (subscribing to
	DamageSystem.OnApplied the way GrabSystem.lua's own header shows) is a real option for a future
	pass, deliberately left undone here -- reintroducing wall-slam detection is a bigger feature-design
	question than a "fix what's broken, don't relitigate design" pass should absorb on its own.

	Does not own: detection or resolution -- see the notice immediately above -- or the preview's
	wall/trajectory rendering (PreviewViewport.lua, which also does not draw one -- there is nothing
	live to preview either).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Types = require(ReplicatedStorage.Shared.Types)
local HitboxShapes = require(ReplicatedStorage.Shared.HitboxShapes)
local MoveTypes = require(ReplicatedStorage.Shared.MoveTypes)
local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Dropdown = require(script.Parent.Parent.Parent.Parent.Components.Dropdown)
local NumericField = require(script.Parent.Parent.Parent.Parent.Components.NumericField)
local TrackedLabel = require(script.Parent.Parent.Parent.Parent.Components.TrackedLabel)
local DraftBinding = require(script.Parent.DraftBinding)
local Inset = require(script.Parent.Parent.Parent.Parent.Components.Inset)

local Children = Fusion.Children

type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type MoveDefinition = MoveTypes.MoveDefinition
type ObjectStunConfig = Types.ObjectStunConfig
type FollowUp = Types.ObjectStunFollowUp
type DraftContext = DraftBinding.DraftContext

local Config = Constants.MoveEditor.ObjectStun
local Limits = Config.Limits
-- Same clamp band the parent move's own timing/damage fields use -- the follow-up validator calls
-- straight into MoveRegistryManager's CLAMP_MIN/MAX_SECONDS and CLAMP_MIN/MAX_DAMAGE for these, so
-- mirroring the numbers here rather than inventing a second, subtly-different band is what keeps
-- the two in agreement. See Constants.MoveEditor.ObjectStun.Limits' own comment.
local FOLLOWUP_MIN_SECONDS, FOLLOWUP_MAX_SECONDS = 0.01, 5
local FOLLOWUP_MIN_DAMAGE, FOLLOWUP_MAX_DAMAGE = 0, 200
local FOLLOWUP_MIN_OFFSET, FOLLOWUP_MAX_OFFSET = -5, 10

local ObjectStunEditorModule = {}

-- Builds a fresh, fully-populated config from Constants defaults. Written out field by field rather
-- than table.clone'd off the Constants table so the live config can never end up sharing a
-- reference with it -- an author editing one move's Surfaces would otherwise edit the DEFAULTS,
-- and so every move enabled afterwards this session.
local function defaultConfig(): ObjectStunConfig
	local defaults = Config.Defaults
	return {
		Enabled = true,
		Surfaces = {
			Walls = defaults.Surfaces.Walls,
			Floors = defaults.Surfaces.Floors,
			Ceilings = defaults.Surfaces.Ceilings,
			Props = defaults.Surfaces.Props,
		},
		RequireAnchored = defaults.RequireAnchored,
		RequirePartTag = defaults.RequirePartTag,
		MinSurfaceExtentStuds = defaults.MinSurfaceExtentStuds,
		ProbeDistanceStuds = defaults.ProbeDistanceStuds,
		RequiredClearanceStuds = defaults.RequiredClearanceStuds,
		MinTravelStuds = defaults.MinTravelStuds,
		MinImpactSpeed = defaults.MinImpactSpeed,
		MaxImpactAngleDegrees = defaults.MaxImpactAngleDegrees,
		MaxTravelSeconds = defaults.MaxTravelSeconds,
		StunSeconds = defaults.StunSeconds,
		RagdollSeconds = defaults.RagdollSeconds,
		BonusDamage = defaults.BonusDamage,
		BonusPostureDamage = defaults.BonusPostureDamage,
		ReboundVelocity = defaults.ReboundVelocity,
		PinSeconds = defaults.PinSeconds,
		VictimAnimationId = defaults.VictimAnimationId,
		AttackerAnimationId = defaults.AttackerAnimationId,
		SoundId = defaults.SoundId,
		EffectColor = defaults.EffectColor,
		CameraShakeScale = defaults.CameraShakeScale,
		CooldownSeconds = defaults.CooldownSeconds,
		MaxTriggersPerMove = defaults.MaxTriggersPerMove,
		FollowUp = nil,
	}
end

local function defaultFollowUp(): FollowUp
	local defaults = Config.FollowUpDefaults
	local shape = defaults.Shape :: HitboxShapes.ShapeId
	return {
		Enabled = true,
		DelaySeconds = defaults.DelaySeconds,
		AnimationId = defaults.AnimationId,
		WindupSeconds = defaults.WindupSeconds,
		ActiveSeconds = defaults.ActiveSeconds,
		RecoverySeconds = defaults.RecoverySeconds,
		Damage = defaults.Damage,
		PostureDamage = defaults.PostureDamage,
		MaxTargets = defaults.MaxTargets,
		Shape = shape,
		Dimensions = HitboxShapes.DefaultDimensions(shape),
		Offset = CFrame.new(defaults.OffsetX, defaults.OffsetY, defaults.OffsetZ),
		OffsetRotation = Vector3.zero,
		TeleportAttacker = defaults.TeleportAttacker,
		TeleportDistanceStuds = defaults.TeleportDistanceStuds,
		Knockback = nil,
	}
end

-- Mutates the move's ObjectStun sub-table, cloning it (and Surfaces, which callers routinely touch)
-- first. See DraftBinding.Apply's own header for why the clone is not optional.
local function applyStun(context: DraftContext, mutate: (ObjectStunConfig) -> ()): ()
	DraftBinding.Apply(context, function(draft)
		local current = draft.ObjectStun
		if not current then
			return
		end
		local updated = table.clone(current)
		updated.Surfaces = table.clone(current.Surfaces)
		mutate(updated)
		draft.ObjectStun = updated
	end)
end

local function applyFollowUp(context: DraftContext, mutate: (FollowUp) -> ()): ()
	applyStun(context, function(config)
		local current = config.FollowUp
		if not current then
			return
		end
		local updated = table.clone(current)
		updated.Dimensions = table.clone(current.Dimensions)
		mutate(updated)
		config.FollowUp = updated
	end)
end

function ObjectStunEditorModule.Build(scope: Scope, context: DraftContext): { Instance }
	local hasStun = DraftBinding.Field(context, scope, function(draft)
		return draft.ObjectStun ~= nil and draft.ObjectStun.Enabled
	end, false)
	local hasFollowUp = DraftBinding.Field(context, scope, function(draft)
		return draft.ObjectStun ~= nil and draft.ObjectStun.FollowUp ~= nil and draft.ObjectStun.FollowUp.Enabled
	end, false)

	-- Reads one field off the config, defaulting while the block is off -- the ObjectStun-scoped
	-- counterpart of DraftBinding.Field.
	local function stunField<T>(getter: (ObjectStunConfig) -> T, default: T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local draft = use(context.Draft)
			local config = if draft then draft.ObjectStun else nil
			return if config then getter(config) else default
		end)
	end

	local function followUpField<T>(getter: (FollowUp) -> T, default: T): Fusion.Computed<T>
		return scope:Computed(function(use)
			local draft = use(context.Draft)
			local followUp = if draft and draft.ObjectStun then draft.ObjectStun.FollowUp else nil
			return if followUp then getter(followUp) else default
		end)
	end

	local function stunNumber(
		labelText: string,
		unit: string,
		layoutOrder: number,
		limit: { Min: number, Max: number },
		steps: { number },
		decimals: number,
		getter: (ObjectStunConfig) -> number,
		setter: (ObjectStunConfig, number) -> ()
	)
		return NumericField.Mount(scope, {
			Label = labelText,
			Unit = unit,
			Value = stunField(getter, limit.Min),
			Min = limit.Min,
			Max = limit.Max,
			Steps = steps,
			Decimals = decimals,
			LayoutOrder = layoutOrder,
			Visible = hasStun,
			OnChanged = function(value: number)
				applyStun(context, function(config)
					setter(config, value)
				end)
			end,
		})
	end

	local function followUpNumber(
		labelText: string,
		unit: string,
		layoutOrder: number,
		minimum: number,
		maximum: number,
		steps: { number },
		decimals: number,
		getter: (FollowUp) -> number,
		setter: (FollowUp, number) -> ()
	)
		return NumericField.Mount(scope, {
			Label = labelText,
			Unit = unit,
			Value = followUpField(getter, minimum),
			Min = minimum,
			Max = maximum,
			Steps = steps,
			Decimals = decimals,
			LayoutOrder = layoutOrder,
			Visible = hasFollowUp,
			OnChanged = function(value: number)
				applyFollowUp(context, function(followUp)
					setter(followUp, value)
				end)
			end,
		})
	end

	-- Toggle.lua has no Visible prop of its own, so every conditionally-shown toggle is wrapped --
	-- the same idiom the rest of this screen uses for a component that lacks one.
	local function toggleRow(
		name: string,
		layoutOrder: number,
		visible: UsedAs<boolean>,
		labelText: string,
		value: UsedAs<boolean>,
		onChanged: (boolean) -> ()
	): Frame
		return scope:New "Frame" {
			Name = name,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = layoutOrder,
			Visible = visible,

			[Children] = Toggle(scope, { Label = labelText, Value = value, OnChanged = onChanged }),
		} :: Frame
	end

	local function heading(text: string, layoutOrder: number, visible: UsedAs<boolean>): Frame
		return scope:New "Frame" {
			Name = text,
			Size = UDim2.new(1, 0, 0, 22),
			BackgroundTransparency = 1,
			LayoutOrder = layoutOrder,
			Visible = visible,

			[Children] = TrackedLabel(scope, {
				Text = text,
				Scale = "Action",
				Color = Tokens.Color.AccentPrimaryBright,
			}),
		} :: Frame
	end

	-- The `height` parameter this used to take is gone: every one of the seven call sites below was
	-- hand-counting wrapped Detail lines (20/22/30/34/44) against text it also owned, so any edit to
	-- the prose silently clipped it until someone re-counted. Label.lua's AutoHeight mode (see its own
	-- header) makes the number the text's business instead of the caller's.
	local function note(text: string, layoutOrder: number, visible: UsedAs<boolean>): Instance
		return Label(scope, {
			Text = text,
			Scale = "Detail",
			Color = Tokens.Color.TextSecondary,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = layoutOrder,
			Visible = visible,
		})
	end

	-- A string field on the config (an animation id, a sound id, a tag). The row itself is
	-- DraftBinding.TextRow -- this is only the adapter that narrows its draft-level Get/OnCommit down to
	-- the ObjectStun sub-table, so the four call sites below keep reading and writing an
	-- ObjectStunConfig rather than each unpacking the draft themselves. The reseed-on-draft-change and
	-- mount-both/Visible-toggle machinery it used to hand-roll is shared now; see TextRow's own header
	-- for why none of it can be a Computed.
	local function stunTextRow(
		labelText: string,
		placeholder: string,
		layoutOrder: number,
		getter: (ObjectStunConfig) -> string,
		setter: (ObjectStunConfig, string) -> ()
	): Frame
		return DraftBinding.TextRow(scope, context, {
			Label = labelText,
			Placeholder = placeholder,
			LayoutOrder = layoutOrder,
			Visible = hasStun,
			Get = function(draft)
				local config = draft.ObjectStun
				return if config then getter(config) else ""
			end,
			OnCommit = function(text: string)
				applyStun(context, function(config)
					setter(config, text)
				end)
			end,
		})
	end

	local children: { Instance } = {
		-- ALWAYS visible (LayoutOrder 1, ahead of even the section's own intro note) and independent of
		-- the Enable toggle below -- an admin should learn this BEFORE spending time configuring a block
		-- that currently does nothing in real combat, not after. See this file's own header for why this
		-- is a notice rather than a rebuild or a removal: the schema and this whole panel are preserved
		-- on purpose, only the runtime consumer (Server/Combat/ObjectStunResolver.lua) is gone.
		scope:New "Frame" {
			Name = "NotWiredNotice",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = Tokens.Wash.AccentFill.Color,
			BackgroundTransparency = Tokens.Wash.AccentFill.Transparency,
			BorderSizePixel = 0,
			LayoutOrder = 1,

			[Children] = {
				scope:New "UICorner" { CornerRadius = Tokens.Radius.Sharp },
				scope:New "UIStroke" {
					Color = Tokens.Color.Warning,
					Thickness = 1,
					Transparency = 0.5,
				},
				Inset(scope, Tokens.Space.S),
				Label(scope, {
					Text = "NOT WIRED TO THE LIVE COMBAT STACK -- the resolver that used to consume this block was "
						.. "removed in this week's combat rewrite and has not been rebuilt against the new engine. "
						.. "Everything below is saved and validated, but has no effect on a real hit until a resolver "
						.. "exists again.",
					Scale = "Detail",
					Color = Tokens.Color.Warning,
					AutoHeight = true,
					LineHeight = Tokens.Leading.Prose,
					Size = UDim2.fromScale(1, 0),
				}),
			},
		} :: Frame,

		note(
			"Reacts when this move knocks a target into the world -- a wall, the floor, a pillar, a prop. "
				.. "Everything below is about proving the move actually put them there, and what happens when it did.",
			2,
			true
		),

		scope:New "Frame" {
			Name = "EnableRow",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 3,

			[Children] = Toggle(scope, {
				Label = "Enable Object Stun",
				Value = hasStun,
				OnChanged = function(enabled: boolean)
					DraftBinding.Apply(context, function(draft)
						draft.ObjectStun = if enabled then defaultConfig() else nil
					end)
				end,
			}),
		},

		note(
			"Needs knockback to do anything -- a move that doesn't move its target can't throw them into a surface. "
				.. "Turn on Knockback in its own section first.",
			4,
			scope:Computed(function(use)
				local draft = use(context.Draft)
				return use(hasStun) and (draft == nil or draft.Knockback == nil)
			end)
		),

		--
		-- WHAT COUNTS
		--
		heading("WHAT COUNTS AS AN IMPACT", 10, hasStun),
		toggleRow(
			"Walls",
			11,
			hasStun,
			"Walls",
			stunField(function(config)
				return config.Surfaces.Walls
			end, false),
			function(enabled)
				applyStun(context, function(config)
					config.Surfaces.Walls = enabled
				end)
			end
		),
		toggleRow(
			"Floors",
			12,
			hasStun,
			"Floors",
			stunField(function(config)
				return config.Surfaces.Floors
			end, false),
			function(enabled)
				applyStun(context, function(config)
					config.Surfaces.Floors = enabled
				end)
			end
		),
		toggleRow(
			"Ceilings",
			13,
			hasStun,
			"Ceilings",
			stunField(function(config)
				return config.Surfaces.Ceilings
			end, false),
			function(enabled)
				applyStun(context, function(config)
					config.Surfaces.Ceilings = enabled
				end)
			end
		),
		toggleRow(
			"Props",
			14,
			hasStun,
			"Props (loose objects)",
			stunField(function(config)
				return config.Surfaces.Props
			end, false),
			function(enabled)
				applyStun(context, function(config)
					config.Surfaces.Props = enabled
				end)
			end
		),
		toggleRow(
			"RequireAnchored",
			15,
			hasStun,
			"Anchored geometry only",
			stunField(function(config)
				return config.RequireAnchored
			end, true),
			function(enabled)
				applyStun(context, function(config)
					config.RequireAnchored = enabled
				end)
			end
		),
		note(
			"Props are unanchored parts, so 'Props' only ever fires with 'Anchored geometry only' turned off.",
			16,
			scope:Computed(function(use)
				local draft = use(context.Draft)
				local config = if draft then draft.ObjectStun else nil
				return use(hasStun) and config ~= nil and config.Surfaces.Props and config.RequireAnchored
			end)
		),
		stunTextRow("Required Tag (blank = any part)", "SlamSurface", 17, function(config)
			return config.RequirePartTag
		end, function(config, value)
			config.RequirePartTag = value
		end),
		stunNumber("Minimum Surface Size", "studs", 18, Limits.MinSurfaceExtentStuds, { 0.5, 2 }, 1, function(config)
			return config.MinSurfaceExtentStuds
		end, function(config, value)
			config.MinSurfaceExtentStuds = value
		end),

		--
		-- WHAT PROVES IT
		--
		heading("WHAT PROVES THE MOVE CAUSED IT", 20, hasStun),
		note(
			"All four must pass. Clearance is checked the instant the hit lands: if a qualifying surface is already "
				.. "closer than this behind the target, nothing is watched at all -- that is what stops this firing for "
				.. "someone who simply happens to be standing against a wall.",
			21,
			hasStun
		),
		stunNumber(
			"Required Clearance At Hit",
			"studs",
			22,
			Limits.RequiredClearanceStuds,
			{ 0.5, 2 },
			1,
			function(config)
				return config.RequiredClearanceStuds
			end,
			function(config, value)
				config.RequiredClearanceStuds = value
			end
		),
		stunNumber("Minimum Travel Before Impact", "studs", 23, Limits.MinTravelStuds, { 0.5, 2 }, 1, function(config)
			return config.MinTravelStuds
		end, function(config, value)
			config.MinTravelStuds = value
		end),
		stunNumber("Minimum Impact Speed", "studs/s", 24, Limits.MinImpactSpeed, { 1, 10 }, 0, function(config)
			return config.MinImpactSpeed
		end, function(config, value)
			config.MinImpactSpeed = value
		end),
		stunNumber("Maximum Impact Angle", "degrees", 25, Limits.MaxImpactAngleDegrees, { 1, 10 }, 0, function(config)
			return config.MaxImpactAngleDegrees
		end, function(config, value)
			config.MaxImpactAngleDegrees = value
		end),
		note(
			"0 degrees is dead-on into the surface, 90 is sliding along it. Lower values reject glancing scrapes.",
			26,
			hasStun
		),
		stunNumber(
			"Watch Window After The Hit",
			"seconds",
			27,
			Limits.MaxTravelSeconds,
			{ 0.1, 0.5 },
			2,
			function(config)
				return config.MaxTravelSeconds
			end,
			function(config, value)
				config.MaxTravelSeconds = value
			end
		),
		stunNumber("Contact Probe Distance", "studs", 28, Limits.ProbeDistanceStuds, { 0.25, 1 }, 2, function(config)
			return config.ProbeDistanceStuds
		end, function(config, value)
			config.ProbeDistanceStuds = value
		end),

		--
		-- WHAT HAPPENS
		--
		heading("WHAT HAPPENS ON IMPACT", 30, hasStun),
		DraftBinding.Row(scope, 31, 2, {
			stunNumber("Stun", "seconds", 1, Limits.StunSeconds, { 0.1, 0.5 }, 2, function(config)
				return config.StunSeconds
			end, function(config, value)
				config.StunSeconds = value
			end),
			stunNumber("Extra Ragdoll", "seconds", 2, Limits.RagdollSeconds, { 0.1, 0.5 }, 2, function(config)
				return config.RagdollSeconds
			end, function(config, value)
				config.RagdollSeconds = value
			end),
		}),
		DraftBinding.Row(scope, 32, 2, {
			stunNumber("Bonus Damage", "", 1, Limits.BonusDamage, { 1, 5 }, 0, function(config)
				return config.BonusDamage
			end, function(config, value)
				config.BonusDamage = value
			end),
			stunNumber("Bonus Posture", "", 2, Limits.BonusPostureDamage, { 1, 5 }, 0, function(config)
				return config.BonusPostureDamage
			end, function(config, value)
				config.BonusPostureDamage = value
			end),
		}),
		DraftBinding.Row(scope, 33, 2, {
			stunNumber("Pin Against Surface", "seconds", 1, Limits.PinSeconds, { 0.1, 0.5 }, 2, function(config)
				return config.PinSeconds
			end, function(config, value)
				config.PinSeconds = value
			end),
			stunNumber("Rebound Off Surface", "studs/s", 2, Limits.ReboundVelocity, { 5, 20 }, 0, function(config)
				return config.ReboundVelocity
			end, function(config, value)
				config.ReboundVelocity = value
			end),
		}),
		note(
			"Pin holds them against the surface -- that pause is what gives a follow-up something to hit. "
				.. "Rebound bounces them back off it instead.",
			34,
			hasStun
		),
		stunTextRow("Victim Animation Id", "rbxassetid://0", 35, function(config)
			return config.VictimAnimationId
		end, function(config, value)
			config.VictimAnimationId = value
		end),
		stunTextRow("Attacker Animation Id", "rbxassetid://0", 36, function(config)
			return config.AttackerAnimationId
		end, function(config, value)
			config.AttackerAnimationId = value
		end),
		stunTextRow("Impact Sound Id", "rbxassetid://0", 37, function(config)
			return config.SoundId
		end, function(config, value)
			config.SoundId = value
		end),
		stunNumber("Camera Shake", "x", 38, Limits.CameraShakeScale, { 0.1, 0.5 }, 2, function(config)
			return config.CameraShakeScale
		end, function(config, value)
			config.CameraShakeScale = value
		end),

		--
		-- HOW OFTEN
		--
		heading("HOW OFTEN", 40, hasStun),
		DraftBinding.Row(scope, 41, 2, {
			stunNumber("Cooldown", "seconds", 1, Limits.CooldownSeconds, { 0.5, 2 }, 2, function(config)
				return config.CooldownSeconds
			end, function(config, value)
				config.CooldownSeconds = value
			end),
			stunNumber("Max Triggers Per Throw", "", 2, Limits.MaxTriggersPerMove, { 1, 1 }, 0, function(config)
				return config.MaxTriggersPerMove
			end, function(config, value)
				config.MaxTriggersPerMove = math.floor(value)
			end),
		}),

		--
		-- FOLLOW-UP
		--
		heading("FOLLOW-UP ATTACK", 50, hasStun),
		note(
			"An optional second attack thrown once they are pinned. This is what turns a slam into a sequence: "
				.. "hit, knock them into the wall, wall-stun, then punish.",
			51,
			hasStun
		),
		scope:New "Frame" {
			Name = "EnableFollowUpRow",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 52,
			Visible = hasStun,

			[Children] = Toggle(scope, {
				Label = "Enable Follow-Up",
				Value = hasFollowUp,
				OnChanged = function(enabled: boolean)
					applyStun(context, function(config)
						config.FollowUp = if enabled then defaultFollowUp() else nil
					end)
				end,
			}),
		},
		DraftBinding.Row(scope, 53, 2, {
			followUpNumber(
				"Delay After Impact",
				"seconds",
				1,
				Limits.FollowUpDelaySeconds.Min,
				Limits.FollowUpDelaySeconds.Max,
				{
					0.05,
					0.25,
				},
				2,
				function(followUp)
					return followUp.DelaySeconds
				end,
				function(followUp, value)
					followUp.DelaySeconds = value
				end
			),
			followUpNumber(
				"Max Targets",
				"",
				2,
				Limits.FollowUpMaxTargets.Min,
				Limits.FollowUpMaxTargets.Max,
				{
					1,
					1,
				},
				0,
				function(followUp)
					return followUp.MaxTargets
				end,
				function(followUp, value)
					followUp.MaxTargets = math.floor(value)
				end
			),
		}),
		DraftBinding.Row(scope, 54, 2, {
			followUpNumber(
				"Windup",
				"seconds",
				1,
				FOLLOWUP_MIN_SECONDS,
				FOLLOWUP_MAX_SECONDS,
				{ 0.01, 0.1 },
				2,
				function(followUp)
					return followUp.WindupSeconds
				end,
				function(followUp, value)
					followUp.WindupSeconds = value
				end
			),
			followUpNumber(
				"Active",
				"seconds",
				2,
				FOLLOWUP_MIN_SECONDS,
				FOLLOWUP_MAX_SECONDS,
				{ 0.01, 0.1 },
				2,
				function(followUp)
					return followUp.ActiveSeconds
				end,
				function(followUp, value)
					followUp.ActiveSeconds = value
				end
			),
		}),
		DraftBinding.Row(scope, 55, 2, {
			followUpNumber(
				"Recovery",
				"seconds",
				1,
				FOLLOWUP_MIN_SECONDS,
				FOLLOWUP_MAX_SECONDS,
				{ 0.01, 0.1 },
				2,
				function(followUp)
					return followUp.RecoverySeconds
				end,
				function(followUp, value)
					followUp.RecoverySeconds = value
				end
			),
			followUpNumber("Damage", "", 2, FOLLOWUP_MIN_DAMAGE, FOLLOWUP_MAX_DAMAGE, { 1, 5 }, 0, function(followUp)
				return followUp.Damage
			end, function(followUp, value)
				followUp.Damage = value
			end),
		}),
		followUpNumber(
			"Posture Damage",
			"",
			56,
			FOLLOWUP_MIN_DAMAGE,
			FOLLOWUP_MAX_DAMAGE,
			{ 1, 5 },
			0,
			function(followUp)
				return followUp.PostureDamage
			end,
			function(followUp, value)
				followUp.PostureDamage = value
			end
		),

		toggleRow(
			"TeleportAttacker",
			57,
			hasFollowUp,
			"Close the gap first (teleport)",
			followUpField(function(followUp)
				return followUp.TeleportAttacker
			end, false),
			function(enabled)
				applyFollowUp(context, function(followUp)
					followUp.TeleportAttacker = enabled
				end)
			end
		),
		followUpNumber(
			"Teleport Distance",
			"studs",
			58,
			Limits.FollowUpTeleportDistanceStuds.Min,
			Limits.FollowUpTeleportDistanceStuds.Max,
			{ 0.5, 2 },
			1,
			function(followUp)
				return followUp.TeleportDistanceStuds
			end,
			function(followUp, value)
				followUp.TeleportDistanceStuds = value
			end
		),
	}

	-- The follow-up's own hitbox. Its own shape and dimensions, not the parent move's -- see
	-- Types.ObjectStunFollowUp's header for why a follow-up is a different attack rather than a
	-- repeat of the launcher.
	local followUpShape = followUpField(function(followUp): string
		return followUp.Shape
	end, "Box")

	local shapeOptions: { { Value: string, Text: string } } = {}
	for _, spec in ipairs(HitboxShapes.ListShapes()) do
		table.insert(shapeOptions, { Value = spec.Id, Text = spec.DisplayName })
	end

	table.insert(
		children,
		scope:New "Frame" {
			Name = "FollowUpShapeSlot",
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 59,
			Visible = hasFollowUp,

			[Children] = Dropdown.Mount(scope, {
				Label = "Follow-Up Shape",
				Options = shapeOptions,
				Value = followUpShape,
				OnChanged = function(newShape: string)
					if not HitboxShapes.IsShapeId(newShape) then
						return
					end
					local shape = newShape :: HitboxShapes.ShapeId
					applyFollowUp(context, function(followUp)
						followUp.Shape = shape
						-- Re-sanitized rather than reset, same reasoning as HitboxEditor's own shape
						-- picker: the author's numbers survive a round trip through another shape.
						followUp.Dimensions = HitboxShapes.Sanitize(shape, followUp.Dimensions)
					end)
				end,
			}),
		}
	)

	-- All eight dimension fields mounted once, Visible/LayoutOrder driven by the follow-up's own
	-- current shape -- the same arrangement HitboxEditor.lua uses for the parent move, and for the
	-- same reasons (see that file's header).
	local dimensionFields: { HitboxShapes.DimensionField } =
		{ "Width", "Height", "Depth", "Length", "Thickness", "Radius", "InnerRadius", "AngleDegrees" }
	for _, field in ipairs(dimensionFields) do
		local spec = HitboxShapes.GetFieldSpec(field)
		table.insert(
			children,
			NumericField.Mount(scope, {
				Label = "Follow-Up " .. spec.Label,
				Unit = spec.Unit,
				Value = followUpField(function(followUp): number
					return followUp.Dimensions[field]
				end, spec.Default),
				Min = spec.Min,
				Max = spec.Max,
				Steps = spec.Steps,
				Decimals = spec.Decimals,
				Visible = scope:Computed(function(use)
					if not use(hasFollowUp) then
						return false
					end
					return HitboxShapes.UsesField(use(followUpShape) :: HitboxShapes.ShapeId, field)
				end),
				LayoutOrder = scope:Computed(function(use)
					for index, candidate in ipairs(HitboxShapes.FieldsFor(use(followUpShape) :: HitboxShapes.ShapeId)) do
						if candidate == field then
							return 60 + index
						end
					end
					return 99
				end),
				OnChanged = function(value: number)
					applyFollowUp(context, function(followUp)
						local dimensions = table.clone(followUp.Dimensions)
						dimensions[field] = value
						followUp.Dimensions = HitboxShapes.Sanitize(followUp.Shape, dimensions)
					end)
				end,
			})
		)
	end

	-- Follow-up offset. Only the translation is exposed: a follow-up is thrown at a pinned target
	-- from a known distance and facing, so an aimed rotation has nothing to aim relative to that the
	-- teleport hasn't already fixed.
	local offsetAxes: { { Axis: string, Label: string, Get: (FollowUp) -> number } } = {
		{
			Axis = "X",
			Label = "Follow-Up Offset X",
			Get = function(followUp)
				return followUp.Offset.X
			end,
		},
		{
			Axis = "Y",
			Label = "Follow-Up Offset Y",
			Get = function(followUp)
				return followUp.Offset.Y
			end,
		},
		{
			Axis = "Z",
			Label = "Follow-Up Offset Z (negative = in front)",
			Get = function(followUp)
				return followUp.Offset.Z
			end,
		},
	}
	for index, axis in ipairs(offsetAxes) do
		table.insert(
			children,
			NumericField.Mount(scope, {
				Label = axis.Label,
				Unit = "studs",
				Value = followUpField(axis.Get, 0),
				Min = FOLLOWUP_MIN_OFFSET,
				Max = FOLLOWUP_MAX_OFFSET,
				Steps = { 0.1, 1 },
				Decimals = 2,
				Visible = hasFollowUp,
				LayoutOrder = 70 + index,
				OnChanged = function(value: number)
					applyFollowUp(context, function(followUp)
						local current = followUp.Offset
						if axis.Axis == "X" then
							followUp.Offset = CFrame.new(value, current.Y, current.Z)
						elseif axis.Axis == "Y" then
							followUp.Offset = CFrame.new(current.X, value, current.Z)
						else
							followUp.Offset = CFrame.new(current.X, current.Y, value)
						end
					end)
				end,
			})
		)
	end

	return children
end

return ObjectStunEditorModule
