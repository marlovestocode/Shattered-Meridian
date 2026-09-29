--!strict
--[[
	ComponentPage.lua

	Owns: the Storybook page that shows the shared components, each in the states that actually differ
	-- not one default instance apiece.

	A GALLERY OF DEFAULTS IS WORTH ALMOST NOTHING. Every bug this page is meant to catch lives in a
	state that is not the default: a disabled button that still reads as pressable, a badge that
	became indistinguishable from a control, a meter at 0% that looks identical to a meter at 100%,
	a locked row whose refusal text is too dim to read. So every specimen here shows a RANGE, and the
	note under each says what the range is.

	The interactive specimens are live. The buttons hover, the toggles flip, the tabs select -- they
	are driven by scope-local Values that go nowhere, so pressing them proves the interaction without
	touching a remote or any real state. That is the point: hover and press feedback is precisely
	what cannot be verified from source.

	NOT EVERY COMPONENT IS HERE YET. The ones missing are the ones that need real domain data to say
	anything (AbilitySlot, ActionIcon, VitalIcon, DamageNumberLabel) -- each needs a fixture
	that is a small design decision of its own rather than a line in this file. Adding one once its
	fixture exists is a single Specimen call.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Fusion = require(ReplicatedStorage.Packages.Fusion)

local Tokens = require(script.Parent.Parent.Parent.Parent.Tokens)
local Label = require(script.Parent.Parent.Parent.Parent.Components.Label)
local Stack = require(script.Parent.Parent.Parent.Parent.Components.Stack)
local Button = require(script.Parent.Parent.Parent.Parent.Components.Button)
local Tab = require(script.Parent.Parent.Parent.Parent.Components.Tab)
local Bar = require(script.Parent.Parent.Parent.Parent.Components.Bar)
local Toggle = require(script.Parent.Parent.Parent.Parent.Components.Toggle)
local Stepper = require(script.Parent.Parent.Parent.Parent.Components.Stepper)
local Divider = require(script.Parent.Parent.Parent.Parent.Components.Divider)
local StatRow = require(script.Parent.Parent.Parent.Parent.Components.StatRow)
local StatusTag = require(script.Parent.Parent.Parent.Parent.Components.StatusTag)
local VitalPill = require(script.Parent.Parent.Parent.Parent.Components.VitalPill)
local SegmentMeter = require(script.Parent.Parent.Parent.Parent.Components.SegmentMeter)
local SectionHeading = require(script.Parent.Parent.Parent.Parent.Components.SectionHeading)
local CharacterPortrait = require(script.Parent.Parent.Parent.Parent.Components.CharacterPortrait)
local MeridianField = require(script.Parent.Parent.Parent.Parent.Components.MeridianField)
local Reveal = require(script.Parent.Parent.Parent.Parent.Components.Reveal)

local Notify = require(script.Parent.Parent.Parent.Parent.Shell.Notify)
local NotificationsModule = require(script.Parent.Parent.Parent.Notifications)

local Specimen = require(script.Parent.Specimen)

local peek = Fusion.peek

type Scope = Fusion.Scope<typeof(Fusion)>

local Players = game:GetService("Players")

-- Specimen copy for the notification kinds. Real-shaped rather than lorem, so the specimen also
-- answers "does a tier name fit on one line" -- which is the only question about this tile that a
-- screenshot can settle. Progression's is the exact shape UI/init.lua's producer pushes.
local NOTIFY_SPECIMEN_TITLE: { [Notify.Kind]: string } = {
	Progression = "Opened Meridian",
	Acquisition = "Ninth Rain Talisman",
	World = "The Vermilion Gate has fallen",
	Warning = "Qi deviation imminent",
}

local NOTIFY_SPECIMEN_DETAIL: { [Notify.Kind]: string? } = {
	Progression = "Tier 3 ascended",
	Acquisition = "Rare -- from a sealed cache",
	-- Deliberately nil, so the gallery shows the detail-less layout too. The tile is a fixed height
	-- and the rows are centred, so a missing third line is a real visual case rather than a shrug.
	World = nil,
	Warning = "Cultivate to steady your channels",
}

local function ComponentPage(scope: Scope, layoutOrder: number, visible: Fusion.UsedAs<boolean>, width: number): Frame
	-- Scope-local drive state for the live specimens. None of it leaves this page.
	local selectedTab = scope:Value(1)
	local toggleOn = scope:Value(true)
	local stepperValue = scope:Value(14)
	local meterValue = scope:Value(60)
	local revealVisible: Fusion.Value<boolean> = scope:Value(true)

	-- One Reveal specimen: a small panel wearing the shared entrance at a given depth, driven by the
	-- shared toggle above so the two depths are watched side by side rather than one after the other.
	-- Local to this function because it closes over revealVisible; a two-caller helper is not a
	-- component.
	local function revealSpecimen(specimenScope: Scope, caption: string, depth: number): Frame
		local reveal = Reveal(specimenScope, { Visible = revealVisible, Depth = depth })

		return Stack.New(specimenScope, {
			Name = "RevealStage",
			Size = UDim2.fromOffset(180, 84),
			BackgroundColor3 = Tokens.Color.Surface,
			BackgroundTransparency = 0,
			-- Reveal's own guard, on the specimen exactly as a real tile uses it -- the stage stays
			-- drawn through the exit, then goes.
			Visible = reveal.Mounted,
			Children = {
				reveal.Scale,
				Label(specimenScope, {
					Text = caption,
					Scale = "Detail",
					Color = Tokens.Color.TextSecondary,
					TextTransparency = reveal.Transparency,
					Size = UDim2.fromScale(1, 1),
					TextXAlignment = Enum.TextXAlignment.Center,
				}),
			},
		})
	end

	-- A REAL Shell/Notify CHANNEL, not four static tiles. The specimen has to demonstrate the queue --
	-- priority ordering, coalescing, one-at-a-time -- and the only honest way to do that is to build
	-- the actual thing and push into it. Scope-local like every other drive value on this page: this
	-- is a second channel, entirely separate from the one UI/init.lua mounts into TopCentre.
	local storybookNotify = Notify.New(scope)
	local notifyTile = NotificationsModule.Mount(scope, storybookNotify)

	local notifyButtons: { Instance } = {}
	for index, kind in Notify.Kinds do
		table.insert(
			notifyButtons,
			Button(scope, {
				Text = kind,
				Variant = "Secondary",
				Size = UDim2.fromOffset(112, 36),
				LayoutOrder = index,
				OnActivated = function()
					storybookNotify:Push({
						Kind = kind,
						Title = NOTIFY_SPECIMEN_TITLE[kind],
						Detail = NOTIFY_SPECIMEN_DETAIL[kind],
						-- Short, so a curious reader can watch the queue drain rather than waiting out
						-- four full reads. The real durations are per kind in Shell/Notify.lua.
						Duration = 2,
					})
				end,
			})
		)
	end

	local localPlayer = Players.LocalPlayer

	local entries: { Instance } = {
		Specimen(scope, {
			Title = "Button",
			Note = "Primary, Secondary and the legacy variant, each enabled and disabled. Hover them.",
			Height = 56,
			LayoutOrder = 1,
			Children = {
				Button(scope, { Text = "Primary", Variant = "Primary", Size = UDim2.fromOffset(130, 36) }),
				Button(scope, {
					Text = "Primary",
					Variant = "Primary",
					Disabled = true,
					Size = UDim2.fromOffset(130, 36),
				}),
				Button(scope, { Text = "Secondary", Variant = "Secondary", Size = UDim2.fromOffset(130, 36) }),
				Button(scope, {
					Text = "Secondary",
					Variant = "Secondary",
					Disabled = true,
					Size = UDim2.fromOffset(130, 36),
				}),
				Button(scope, { Text = "Legacy", Size = UDim2.fromOffset(120, 36) }),
			},
		}),

		Specimen(scope, {
			Title = "Tab",
			Note = "Boxed chips versus the underline strip. Click either -- both drive the same value.",
			Height = 96,
			Direction = "Vertical",
			Gap = Tokens.Space.S,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 2,
			Children = {
				Stack.Row(scope, {
					Gap = Tokens.Space.XS,
					Size = UDim2.new(1, 0, 0, 34),
					LayoutOrder = 1,
					Children = {
						Tab(scope, {
							Text = "1. shattered_palm",
							Size = UDim2.fromOffset(150, 34),
							LayoutOrder = 1,
							Selected = scope:Computed(function(use)
								return use(selectedTab) == 1
							end),
							OnActivated = function()
								selectedTab:set(1)
							end,
						}),
						Tab(scope, {
							Text = "2. empty",
							Size = UDim2.fromOffset(150, 34),
							LayoutOrder = 2,
							Selected = scope:Computed(function(use)
								return use(selectedTab) == 2
							end),
							OnActivated = function()
								selectedTab:set(2)
							end,
						}),
					},
				}),
				Stack.Row(scope, {
					Size = UDim2.new(1, 0, 0, 44),
					LayoutOrder = 2,
					Children = {
						Tab(scope, {
							Text = "Character",
							Variant = "Underline",
							TrackedCaps = true,
							Size = UDim2.fromScale(0.5, 1),
							LayoutOrder = 1,
							Selected = scope:Computed(function(use)
								return use(selectedTab) == 1
							end),
							OnActivated = function()
								selectedTab:set(1)
							end,
						}),
						Tab(scope, {
							Text = "Arts",
							Variant = "Underline",
							TrackedCaps = true,
							Size = UDim2.fromScale(0.5, 1),
							LayoutOrder = 2,
							Selected = scope:Computed(function(use)
								return use(selectedTab) == 2
							end),
							OnActivated = function()
								selectedTab:set(2)
							end,
						}),
					},
				}),
			},
		}),

		Specimen(scope, {
			Title = "StatusTag",
			Note = "Filled, no outline, leading edge -- deliberately nothing like a Button above.",
			Height = 44,
			LayoutOrder = 3,
			Children = {
				StatusTag(scope, { Label = "Hollowborn", Color = Tokens.Color.AccentPrimary, Tracked = true }),
				StatusTag(scope, { Label = "Unaligned", Tracked = true }),
				StatusTag(scope, { Label = "Marked", Color = Tokens.Color.Danger, Tracked = true }),
				StatusTag(scope, { Label = "Deviation rising", Color = Tokens.Color.Warning, Tracked = true }),
				StatusTag(scope, { Label = "At rest", Color = Tokens.VitalColor.Qi, Tracked = true }),
			},
		}),

		Specimen(scope, {
			Title = "VitalPill",
			Note = "Full, partial and nearly empty -- the accent hairline is the only fraction cue.",
			Height = 76,
			LayoutOrder = 4,
			Children = {
				VitalPill(scope, {
					Caption = "Health",
					Value = 460,
					Max = 460,
					Color = Tokens.VitalColor.Health,
					Size = UDim2.fromOffset(150, 62),
				}),
				VitalPill(scope, {
					Caption = "Qi",
					Value = 310,
					Max = 380,
					Color = Tokens.VitalColor.Qi,
					Size = UDim2.fromOffset(150, 62),
				}),
				VitalPill(scope, {
					Caption = "Posture",
					Value = 12,
					Max = 200,
					Color = Tokens.VitalColor.Posture,
					Size = UDim2.fromOffset(150, 62),
				}),
			},
		}),

		Specimen(scope, {
			Title = "SegmentMeter",
			Note = "Empty, first sliver, mid and full. The first sliver must light block one.",
			Height = 92,
			Direction = "Vertical",
			Gap = Tokens.Space.S,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 5,
			Children = {
				SegmentMeter(scope, { Value = 0, Max = 150, LayoutOrder = 1 }),
				SegmentMeter(scope, { Value = 1, Max = 150, LayoutOrder = 2 }),
				SegmentMeter(scope, { Value = meterValue, Max = 150, LayoutOrder = 3 }),
				SegmentMeter(scope, { Value = 150, Max = 150, LayoutOrder = 4 }),
			},
		}),

		Specimen(scope, {
			Title = "Bar",
			Note = "Flat, gradient-plus-glow, and below the critical threshold (stroke, not colour alone).",
			Height = 76,
			Direction = "Vertical",
			Gap = Tokens.Space.M,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 6,
			Children = {
				Bar(scope, {
					Value = 14,
					Max = 20,
					FillColor = Tokens.AttributeColor.Vitality,
					Size = UDim2.new(1, 0, 0, 6),
					LayoutOrder = 1,
				}),
				Bar(scope, {
					Value = 16,
					Max = 20,
					FillColor = Tokens.VitalColor.Qi,
					FillColorSecondary = Tokens.VitalColor.Qi,
					Glow = true,
					Size = UDim2.new(1, 0, 0, 6),
					LayoutOrder = 2,
				}),
				Bar(scope, {
					Value = 3,
					Max = 20,
					FillColor = Tokens.VitalColor.Health,
					CriticalBelow = 0.25,
					Size = UDim2.new(1, 0, 0, 6),
					LayoutOrder = 3,
				}),
			},
		}),

		Specimen(scope, {
			Title = "StatRow",
			Note = "Hairline rows stack into a list; framed cells sit in a grid.",
			Height = 104,
			Direction = "Vertical",
			Gap = Tokens.Space.XS,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 7,
			Children = {
				StatRow(scope, { Caption = "Arts mastered", Value = "3", LayoutOrder = 1 }),
				StatRow(scope, { Caption = "Rerolls left", Value = "0", LayoutOrder = 2 }),
				StatRow(scope, { Caption = "Max qi", Value = "380", Variant = "Framed", LayoutOrder = 3 }),
			},
		}),

		Specimen(scope, {
			Title = "SectionHeading",
			Note = "Alone, with a right-aligned note, and with a badge accessory.",
			Height = 96,
			Direction = "Vertical",
			Gap = Tokens.Space.S,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 8,
			Children = {
				SectionHeading(scope, { Text = "Attributes", LayoutOrder = 1 }),
				SectionHeading(scope, { Text = "Arts", Note = "3 / 5 known", LayoutOrder = 2 }),
				SectionHeading(scope, {
					Text = "Active Bounties",
					LayoutOrder = 3,
					Accessory = StatusTag(scope, { Label = "2 marked", Color = Tokens.Color.Danger, Tracked = true }),
				}),
			},
		}),

		Specimen(scope, {
			Title = "Divider",
			Note = "Plain, one-sided fade, symmetric fade, and the flourish.",
			Height = 88,
			Direction = "Vertical",
			Gap = Tokens.Space.M,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 9,
			Children = {
				Divider.Plain(scope, { LayoutOrder = 1 }),
				Divider.Gradient(scope, { LayoutOrder = 2 }),
				Divider.Gradient(scope, { Fade = "Both", Tint = Tokens.Border.Standard, LayoutOrder = 3 }),
				Divider.Flourish(scope, { LayoutOrder = 4 }),
			},
		}),

		Specimen(scope, {
			Title = "Toggle & Stepper",
			Note = "Both live. The toggle drives its own state; the stepper clamps at 10 and 20.",
			Height = 96,
			Direction = "Vertical",
			Gap = Tokens.Space.S,
			AlignY = Enum.VerticalAlignment.Top,
			LayoutOrder = 10,
			Children = {
				Toggle(scope, {
					Label = "Enable Forward Lunge",
					Value = toggleOn,
					LayoutOrder = 1,
					OnChanged = function(newValue: boolean)
						toggleOn:set(newValue)
					end,
				}),
				-- .Mount, not a bare call: Stepper exports a table so it can also publish its own WIDTH
				-- (Screens/Onboarding/Attributes.lua sizes a column off it). Being the one component on
				-- this page with that shape is exactly the kind of thing a gallery finds.
				Stepper.Mount(scope, {
					Value = stepperValue,
					Min = 10,
					Max = 20,
					LayoutOrder = 2,
					OnChanged = function(newValue: number)
						stepperValue:set(newValue)
					end,
				}),
			},
		}),

		Specimen(scope, {
			Title = "CharacterPortrait",
			Note = "Your own avatar, and the drawn fallback used when there is no UserId.",
			Height = 180,
			LayoutOrder = 11,
			Children = {
				CharacterPortrait(scope, {
					Width = 200,
					Height = 156,
					UserId = if localPlayer then localPlayer.UserId else nil,
				}),
				CharacterPortrait(scope, { Width = 200, Height = 156 }),
			},
		}),

		Specimen(scope, {
			Title = "MeridianField",
			Note = "The panel surface texture, at its authored strength and at double.",
			Height = 140,
			LayoutOrder = 12,
			Children = {
				Stack.New(scope, {
					Size = UDim2.fromOffset(240, 116),
					BackgroundColor3 = Tokens.Color.Surface,
					BackgroundTransparency = 0,
					Children = { MeridianField(scope, { ZIndex = 1 }) },
				}),
				Stack.New(scope, {
					Size = UDim2.fromOffset(240, 116),
					BackgroundColor3 = Tokens.Color.Surface,
					BackgroundTransparency = 0,
					Children = { MeridianField(scope, { ZIndex = 1, Intensity = 2 }) },
				}),
			},
		}),

		-- THE ONE SPECIMEN ON THIS PAGE THAT CANNOT BE JUDGED FROM A SCREENSHOT, which is exactly why
		-- it is here: Reveal is a motion component, and the gallery is the only place in the client
		-- where you can watch one arrive on demand rather than by boarding a blimp. Press the button
		-- and both panels leave together, press it again and they come back.
		--
		-- TWO DEPTHS SIDE BY SIDE, because the number that matters is the one nobody can pick from
		-- source: 0.02 is the shipped default and reads as arrival; 0.12 is well past it and reads as
		-- the "pop" docs/ui-ux-philosophy.md's Animation Philosophy section rules out. Having the
		-- wrong one next to the right one is what makes the right one legible.
		Specimen(scope, {
			Title = "Reveal",
			Note = "The shared ambient-tile entrance. Left is the shipped 0.02 depth, right is an exaggerated 0.12 -- press to send both out and back. Note that neither MOVES: a region tile's Position belongs to its region's UIListLayout, so Reveal animates scale and transparency only (see its header).",
			Height = 132,
			Direction = "Horizontal",
			LayoutOrder = 13,
			Children = {
				Button(scope, {
					Text = "Toggle",
					Variant = "Secondary",
					Size = UDim2.fromOffset(110, 36),
					OnActivated = function()
						revealVisible:set(not peek(revealVisible))
					end,
				}),
				revealSpecimen(scope, "Depth 0.02", 0.02),
				revealSpecimen(scope, "Depth 0.12", 0.12),
			},
		}),

		-- ALL FOUR NOTIFICATION KINDS, WHICH IS THE ONLY PLACE THREE OF THEM CAN BE SEEN. Shell/Notify
		-- declares Progression, Acquisition, World and Warning because the philosophy doc names four
		-- kinds; only Progression has a producer, so the other three would otherwise be code nobody
		-- has ever laid eyes on. The gallery is exactly the answer to that -- and it is also where the
		-- accessibility contract gets checked, since what has to be true is that the four are tellable
		-- apart from the EYEBROW alone, with the accent ignored.
		--
		-- A live channel, not four static tiles: the buttons push into one real Shell/Notify queue, so
		-- pressing several in a row demonstrates the queueing and the priority (a Warning pushed
		-- behind three World notices comes out first) rather than only the styling.
		Specimen(scope, {
			Title = "Notify",
			Note = "The one notification channel, live. Press several -- they queue rather than stacking, highest kind first, and a repeat of the one on screen restarts its read instead of queueing a copy. Only Progression has a real producer; the other three are here because this is the only place they exist.",
			Height = 148,
			Direction = "Vertical",
			LayoutOrder = 14,
			Children = {
				Stack.Row(scope, {
					Size = UDim2.new(1, 0, 0, 36),
					Gap = Tokens.Space.S,
					Children = notifyButtons,
				}),
				notifyTile,
			},
		}),

		Label(scope, {
			Text = "AbilitySlot, ActionIcon, VitalIcon and DamageNumberLabel are not here yet -- each needs a data fixture. See this file's header.",
			Scale = "Detail",
			Color = Tokens.Color.TextDisabled,
			AutoHeight = true,
			LineHeight = Tokens.Leading.Prose,
			Size = UDim2.fromScale(1, 0),
			LayoutOrder = 15,
		}),
	}

	return Stack.New(scope, {
		Name = "ComponentPage",
		Gap = Tokens.Space.L,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = layoutOrder,
		Visible = visible,
		Children = entries,
	})
end

return ComponentPage
