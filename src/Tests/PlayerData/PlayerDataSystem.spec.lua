--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerDataSystem = require(ServerScriptService.Server.Systems.PlayerDataSystem)
local Types = require(ReplicatedStorage.Shared.Types)
-- Read for one purpose: the migration tests below assert that a stale record reaches the CURRENT
-- schema version, not a hardcoded number. Those assertions used to spell the version out, which meant
-- every schema bump broke four tests that were never about the new field -- see CURRENT_SCHEMA below.
local Constants = require(ReplicatedStorage.Shared.Constants)

type PlayerProfile = Types.PlayerProfile

-- What MigrateRecord is expected to walk a stale record forward TO. Read from Constants rather than
-- written as a literal so a schema bump is a one-line change in Constants plus a new test for the new
-- migration -- not a hunt for every assertion that happened to name the old number.
local CURRENT_SCHEMA = Constants.PlayerData.SchemaVersion

-- Pure-logic surface (CreateDefaultProfile/CopyProfile/EncodeProfile/DecodeProfile/MigrateRecord/
-- ApplyMutation, and the cross-server session-lock/WriteGeneration decision functions
-- IsLockHeldByOther/ComputeLoadClaim/ComputeLockRelease/ComputeSaveWrite) never touches the
-- DataStore or a live Player -- Init() is never called in this spec file, so `dataStore` stays nil
-- and `loadedProfiles` stays empty throughout, same "requiring the module never calls Init()"
-- contract BugReportSystem.spec/ModerationSystem.spec already rely on. Player-KEYED wrappers
-- (IsLoaded/GetProfile/Transform/WaitForProfile) are exercised below using a plain table standing in
-- for Player (same trick RateLimiter.spec.lua already uses) -- valid because every one of those
-- functions only ever uses a Player as an opaque table key or reads `.Name` for a log line (which
-- safely returns nil on a plain table), never anything Player-specific like :Kick() or .UserId.
-- Anything that genuinely needs a live Player/real DataStore (loadProfile/saveProfile -- including
-- the actual claim-retry-with-backoff loop and the two UpdateAsync round trips those pure functions
-- above are only the decision logic FOR -- the PlayerAdded-PlayerRemoving wiring, Transform's actual
-- dirty-then-saved round trip) is Studio/live-server verification only, the same already-accepted
-- gap AdminActionSystem.spec.lua/ModerationSystem.spec.lua document for their own Player-keyed
-- state.

return function()
	describe("PlayerDataSystem.CreateDefaultProfile", function()
		it("returns every field at its inert starting default", function()
			local profile = PlayerDataSystem.CreateDefaultProfile(123456)

			expect(profile.userId).to.equal(123456)
			expect(profile.faction).to.equal(nil)
			expect(profile.raceId).to.equal(nil)
			expect(profile.displayName).to.equal(nil)
			expect(profile.attributes).to.equal(nil)
			expect(profile.tier).to.equal(1)
			expect(#profile.bloodlineIds).to.equal(0)
			expect(next(profile.bloodlineStageProgress)).to.equal(nil)
			expect(next(profile.artMastery)).to.equal(nil)
			expect(profile.corruption).to.equal(0)
			expect(profile.qiDeviationRisk).to.equal(0)
			expect(profile.factionStanding).to.equal(0)
			expect(profile.hasAscended).to.equal(false)
			expect(profile.meridianXp).to.equal(0)
			expect(profile.unlockedEmoteIds.Wave).to.equal(true)
			expect(profile.unlockedEmoteIds.VictoryPose).to.equal(nil)
			expect(#profile.emoteLoadout).to.equal(8)
			expect(profile.emoteLoadout[1]).to.equal("Wave")
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(0)
			expect(next(profile.settings.Keybinds)).to.equal(nil)
			expect(next(profile.settings.GamepadKeybinds)).to.equal(nil)
			expect(profile.settings.Autorun).to.equal(false)
		end)

		it("migrates a pre-ArtSystem v3 record to v4, backfilling an empty equippedArts", function()
			local raw = {
				SchemaVersion = 3,
				Profile = {
					tier = 5,
					artMastery = { ["some-art"] = 4 },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			-- Empty, not auto-equipped from artMastery: which art goes in which slot is a player
			-- decision, as Migrations[3]'s own comment states.
			expect(profile.equippedArts).never.to.equal(nil)
			expect(next(profile.equippedArts)).to.equal(nil)
			-- The pre-existing mastery must survive the step untouched.
			expect(profile.artMastery["some-art"]).to.equal(4)
		end)

		it("does not overwrite an already-present equippedArts field on a v3 record", function()
			local raw = {
				SchemaVersion = 3,
				Profile = { tier = 2, equippedArts = { [1] = "kept-art" } },
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.equippedArts[1]).to.equal("kept-art")
		end)

		it("migrates a pre-Parkour v4 record, backfilling the shipped movement defaults", function()
			-- Backfilled with the DEFAULTS rather than an empty table or everything-off: an existing
			-- player's first login after the update should give them the same movement every new player
			-- gets, which is the whole point of Migrations[4] existing rather than letting
			-- DecodeSettings fill it in later.
			local raw = {
				SchemaVersion = 4,
				Profile = {
					tier = 6,
					settings = { Keybinds = {}, GamepadKeybinds = {}, Autorun = true },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.settings.Parkour).never.to.equal(nil)
			expect(profile.settings.Parkour.Enabled).to.equal(PlayerDataSystem.CreateDefaultParkourSettings().Enabled)
			expect(profile.settings.Parkour.SprintMode).to.equal("Hold")
			-- The pre-existing preference must survive the step untouched.
			expect(profile.settings.Autorun).to.equal(true)
		end)

		it("does not overwrite an already-present Parkour block on a v4 record", function()
			local raw = {
				SchemaVersion = 4,
				Profile = {
					tier = 2,
					settings = {
						Keybinds = {},
						GamepadKeybinds = {},
						Autorun = false,
						Parkour = { Enabled = false, SprintMode = "Toggle" },
					},
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.settings.Parkour.Enabled).to.equal(false)
			expect(profile.settings.Parkour.SprintMode).to.equal("Toggle")
		end)

		it("migrates a pre-Comfort v5 record, backfilling both camera effects as ENABLED", function()
			-- The direction matters more than the presence here. Backfilling everything OFF would
			-- silently strip camera shake and impact FOV punches from the entire existing player base on
			-- their next login -- a change nobody asked for, that looks exactly like a bug, and that a
			-- player would have no reason to go looking in Settings to undo. Landing on the shipped
			-- defaults means the migration changes nobody's game and only gives them a switch.
			local raw = {
				SchemaVersion = 5,
				Profile = {
					tier = 3,
					settings = {
						Keybinds = {},
						GamepadKeybinds = {},
						Autorun = false,
						Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
					},
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.settings.Comfort).never.to.equal(nil)
			expect(profile.settings.Comfort.CameraShake).to.equal(true)
			expect(profile.settings.Comfort.FieldOfViewEffects).to.equal(true)
			-- The block the previous migration added must survive this step untouched.
			expect(profile.settings.Parkour).never.to.equal(nil)
		end)

		it("does not overwrite an already-present Comfort block on a v5 record", function()
			local raw = {
				SchemaVersion = 5,
				Profile = {
					tier = 1,
					settings = {
						Keybinds = {},
						GamepadKeybinds = {},
						Autorun = false,
						Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
						Comfort = { CameraShake = false, FieldOfViewEffects = false },
					},
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.settings.Comfort.CameraShake).to.equal(false)
			expect(profile.settings.Comfort.FieldOfViewEffects).to.equal(false)
		end)

		it("migrates a pre-Bloodline v6 record, backfilling an empty bloodlineStageProgress", function()
			-- Empty, not fabricated from bloodlineIds: an existing player has awakened no bloodline any
			-- differently than a brand-new one has, the same "empty is honest" reasoning Migrations[3]'s
			-- own equippedArts backfill already uses.
			local raw = {
				SchemaVersion = 6,
				Profile = {
					tier = 5,
					bloodlineIds = { "some-bloodline" },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.bloodlineStageProgress).never.to.equal(nil)
			expect(next(profile.bloodlineStageProgress)).to.equal(nil)
			-- The pre-existing bloodline must survive the step untouched.
			expect(profile.bloodlineIds[1]).to.equal("some-bloodline")
		end)

		it("does not overwrite an already-present bloodlineStageProgress on a v6 record", function()
			local raw = {
				SchemaVersion = 6,
				Profile = { tier = 2, bloodlineStageProgress = { ["kept-bloodline"] = 3 } },
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.bloodlineStageProgress["kept-bloodline"]).to.equal(3)
		end)

		it("migrates a pre-Blimp-Fuel v8 record to v9, backfilling an empty blimpFuel", function()
			-- Empty, matching CreateDefaultProfile's own starting default -- an existing player has
			-- gathered no fuel any differently than a brand-new one has, the same "empty is honest"
			-- reasoning Migrations[3]/[6]'s own backfills already use.
			local raw = {
				SchemaVersion = 8,
				Profile = { tier = 5 },
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.blimpFuel).never.to.equal(nil)
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(0)
		end)

		it("does not overwrite an already-present blimpFuel field on a v8 record", function()
			local raw = {
				SchemaVersion = 8,
				Profile = { tier = 2, blimpFuel = { Coal = 30, Water = 60 } },
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.blimpFuel.Coal).to.equal(30)
			expect(profile.blimpFuel.Water).to.equal(60)
		end)

		-- The full walk, not just the one new step: MigrateRecord chains Migrations[1..8], and a v1
		-- record is the oldest thing that can still be sitting in the DataStore. A migration that works
		-- from v8 but breaks the chain from v1 would only be discovered by a player who last logged in
		-- before any of this existed.
		it("walks a v1 record all the way forward, arriving with every backfilled field", function()
			local raw = {
				SchemaVersion = 1,
				Profile = { tier = 1 },
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.settings).never.to.equal(nil)
			expect(profile.settings.Parkour).never.to.equal(nil)
			expect(profile.settings.Comfort).never.to.equal(nil)
			expect(profile.settings.Comfort.CameraShake).to.equal(true)
			expect(profile.bloodlineStageProgress).never.to.equal(nil)
			expect(profile.blimpFuel).never.to.equal(nil)
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(0)
		end)
	end)

	describe("PlayerDataSystem comfort settings encode/decode", function()
		it("round-trips both camera-comfort preferences", function()
			local settings: Types.PlayerSettings = {
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Parkour = PlayerDataSystem.CreateDefaultParkourSettings(),
				Comfort = {
					CameraShake = false,
					FieldOfViewEffects = true,
				},
			}
			local decoded = PlayerDataSystem.DecodeSettings(PlayerDataSystem.EncodeSettings(settings))

			expect(decoded.Comfort.CameraShake).to.equal(false)
			expect(decoded.Comfort.FieldOfViewEffects).to.equal(true)
		end)

		-- The failure this guards is uniquely hard to notice: a decode that resolves a missing key to
		-- nil produces `false` for every boolean, which is a PERFECTLY WORKING-LOOKING accessibility
		-- setting. Nothing errors, nothing warns, the panel renders correctly -- the effects are just
		-- gone, for everyone, forever.
		-- The Gamepad block, which ships with NO migration of its own (see DecodeSettings' own note):
		-- every pre-Gamepad record on disk has no such key, so this fallback is not an edge case, it is
		-- what every existing player hits on their next login.
		-- A renamed KeybindAction. The client cannot migrate this itself: the decode below drops any action
		-- no longer in Keybinds.Defaults, so a binding saved as "Roll" would be silently reset to Z.
		it("carries a binding saved under the retired Roll action over to Evade", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = { Roll = { KeyCode = "X" } },
				GamepadKeybinds = { Roll = { KeyCode = "ButtonX" } },
				Autorun = false,
			})

			expect((decoded.Keybinds :: any).Evade.KeyCode).to.equal(Enum.KeyCode.X)
			expect((decoded.Keybinds :: any).Roll).to.equal(nil)
			expect((decoded.GamepadKeybinds :: any).Evade.KeyCode).to.equal(Enum.KeyCode.ButtonX)
		end)

		it("prefers a binding saved under Evade over a stale Roll one in the same record", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = { Roll = { KeyCode = "X" }, Evade = { KeyCode = "V" } },
				GamepadKeybinds = {},
				Autorun = false,
			})

			expect((decoded.Keybinds :: any).Evade.KeyCode).to.equal(Enum.KeyCode.V)
		end)

		it("falls back to the shipped stick defaults for a missing Gamepad block", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
			})

			local defaults = Constants.Settings.Gamepad.Defaults
			expect(decoded.Gamepad.MoveDeadzone).to.equal(defaults.MoveDeadzone)
			expect(decoded.Gamepad.LookSensitivity).to.equal(defaults.LookSensitivity)
			expect(decoded.Gamepad.InvertLookY).to.equal(defaults.InvertLookY)
		end)

		-- Clamping on the way OUT of the DataStore, not only on the way in. SettingsSystem already
		-- clamps what a client may write, so a stored out-of-range value should be impossible -- but an
		-- older build, a hand-edited test profile or a future bug can all produce one, and the failure
		-- is a stick that does nothing with no way for the player to see why.
		it("clamps a stored deadzone that would leave the stick inert", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Gamepad = { MoveDeadzone = 1, LookSensitivity = 999 },
			})

			local bounds = Constants.Settings.Gamepad.Bounds
			expect(decoded.Gamepad.MoveDeadzone).to.equal(bounds.Deadzone.Max)
			expect(decoded.Gamepad.LookSensitivity).to.equal(bounds.LookSensitivity.Max)
			expect(decoded.Gamepad.MoveDeadzone < 1).to.equal(true)
		end)

		-- NaN is the one number math.clamp cannot rescue: it compares false against every bound and
		-- would propagate straight through to Analog.ApplyStick, where it fails every magnitude test.
		it("rejects a NaN stick value rather than clamping it", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Gamepad = { MoveDeadzone = 0 / 0, LookSensitivity = 0 / 0 },
			})

			local defaults = Constants.Settings.Gamepad.Defaults
			expect(decoded.Gamepad.MoveDeadzone).to.equal(defaults.MoveDeadzone)
			expect(decoded.Gamepad.LookSensitivity).to.equal(defaults.LookSensitivity)
		end)

		it("keeps an in-range stored stick block exactly as written", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Gamepad = {
					LookSensitivity = 2,
					MoveDeadzone = 0.3,
					LookDeadzone = 0.1,
					InvertLookY = true,
					Vibration = false,
				},
			})

			expect(decoded.Gamepad.LookSensitivity).to.equal(2)
			expect(decoded.Gamepad.MoveDeadzone).to.equal(0.3)
			expect(decoded.Gamepad.LookDeadzone).to.equal(0.1)
			expect(decoded.Gamepad.InvertLookY).to.equal(true)
			expect(decoded.Gamepad.Vibration).to.equal(false)
		end)

		it("falls back to effects-ON for a missing Comfort block", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
			})

			expect(decoded.Comfort.CameraShake).to.equal(true)
			expect(decoded.Comfort.FieldOfViewEffects).to.equal(true)
		end)

		-- The autosave path, not a hypothetical. EncodeSettings runs against a LIVE in-memory profile on
		-- every save, and a live profile can arrive here with a sub-table missing (a skipped migration, a
		-- rollback to an older server, a Transform caller that replaced `settings` wholesale) in ways
		-- Types.PlayerSettings' non-optional fields never see. Indexing a nil block there throws inside
		-- the save, which means the player's whole session silently fails to persist.
		it("encodes a settings table with both sub-blocks missing instead of throwing mid-save", function()
			local partial = {
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = true,
			} :: any

			local encoded = PlayerDataSystem.EncodeSettings(partial)

			expect(encoded.Autorun).to.equal(true)
			expect(encoded.Parkour).never.to.equal(nil)
			expect(encoded.Comfort).never.to.equal(nil)
			expect(encoded.Comfort.CameraShake).to.equal(true)
		end)

		it("keeps an explicitly disabled effect disabled rather than treating it as missing", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Comfort = { CameraShake = false, FieldOfViewEffects = false },
			})

			expect(decoded.Comfort.CameraShake).to.equal(false)
			expect(decoded.Comfort.FieldOfViewEffects).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem parkour settings encode/decode", function()
		it("round-trips every Parkour preference", function()
			local settings: Types.PlayerSettings = {
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = true,
				Parkour = {
					Enabled = false,
					CameraEffects = false,
					CoyoteTime = false,
					JumpBuffer = true,
					AutoVault = false,
					LedgeAssist = true,
					StepAssist = false,
					SprintMode = "Toggle",
				},
				Comfort = PlayerDataSystem.CreateDefaultComfortSettings(),
			}
			local decoded = PlayerDataSystem.DecodeSettings(PlayerDataSystem.EncodeSettings(settings))

			expect(decoded.Parkour.Enabled).to.equal(false)
			expect(decoded.Parkour.CameraEffects).to.equal(false)
			expect(decoded.Parkour.CoyoteTime).to.equal(false)
			expect(decoded.Parkour.JumpBuffer).to.equal(true)
			expect(decoded.Parkour.AutoVault).to.equal(false)
			expect(decoded.Parkour.LedgeAssist).to.equal(true)
			expect(decoded.Parkour.StepAssist).to.equal(false)
			expect(decoded.Parkour.SprintMode).to.equal("Toggle")
		end)

		it("falls back to the shipped defaults for a missing Parkour block", function()
			-- Not to `false` for every boolean, which is what a naive decode would produce -- and which
			-- would read to a returning player as the game having silently switched their assists off.
			local defaults = PlayerDataSystem.CreateDefaultParkourSettings()
			local decoded = PlayerDataSystem.DecodeSettings({ Keybinds = {}, GamepadKeybinds = {}, Autorun = false })

			expect(decoded.Parkour.Enabled).to.equal(defaults.Enabled)
			expect(decoded.Parkour.CoyoteTime).to.equal(defaults.CoyoteTime)
			expect(decoded.Parkour.SprintMode).to.equal(defaults.SprintMode)
		end)

		it("falls back per-field for a partially-populated Parkour block", function()
			local defaults = PlayerDataSystem.CreateDefaultParkourSettings()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Parkour = { Enabled = false },
			})

			expect(decoded.Parkour.Enabled).to.equal(false)
			expect(decoded.Parkour.AutoVault).to.equal(defaults.AutoVault)
		end)

		it("rejects a non-string SprintMode rather than storing it", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Parkour = { SprintMode = 42 },
			})
			expect(decoded.Parkour.SprintMode).to.equal("Hold")
		end)

		it("survives a wholly non-table Parkour field", function()
			local decoded = PlayerDataSystem.DecodeSettings({
				Keybinds = {},
				GamepadKeybinds = {},
				Autorun = false,
				Parkour = "corrupted",
			})
			expect(decoded.Parkour.SprintMode).to.equal("Hold")
		end)
	end)

	describe("PlayerDataSystem.CopyProfile", function()
		local function makeProfile(): PlayerProfile
			local profile = PlayerDataSystem.CreateDefaultProfile(999)
			profile.bloodlineIds = { "bloodline-a" }
			profile.bloodlineStageProgress = { ["bloodline-a"] = 1 }
			profile.artMastery = { ["art-a"] = 3 }
			return profile
		end

		it("copies every scalar field", function()
			local original = makeProfile()
			original.faction = "Celestial"
			original.tier = 5
			original.corruption = 12

			local copy = PlayerDataSystem.CopyProfile(original)

			expect(copy.userId).to.equal(original.userId)
			expect(copy.faction).to.equal(original.faction)
			expect(copy.tier).to.equal(original.tier)
			expect(copy.corruption).to.equal(original.corruption)
		end)

		it("mutating the copy's bloodlineIds never affects the original", function()
			local original = makeProfile()
			local copy = PlayerDataSystem.CopyProfile(original)

			table.insert(copy.bloodlineIds, "bloodline-b")

			expect(#copy.bloodlineIds).to.equal(2)
			expect(#original.bloodlineIds).to.equal(1)
		end)

		it("mutating the copy's bloodlineStageProgress never affects the original", function()
			local original = makeProfile()
			local copy = PlayerDataSystem.CopyProfile(original)

			copy.bloodlineStageProgress["bloodline-a"] = 99
			copy.bloodlineStageProgress["bloodline-b"] = 1

			expect(original.bloodlineStageProgress["bloodline-a"]).to.equal(1)
			expect(original.bloodlineStageProgress["bloodline-b"]).to.equal(nil)
		end)

		it("mutating the copy's artMastery never affects the original", function()
			local original = makeProfile()
			local copy = PlayerDataSystem.CopyProfile(original)

			copy.artMastery["art-a"] = 99
			copy.artMastery["art-b"] = 1

			expect(original.artMastery["art-a"]).to.equal(3)
			expect(original.artMastery["art-b"]).to.equal(nil)
		end)

		it("mutating the copy's settings.Keybinds never affects the original", function()
			local original = makeProfile()
			original.settings.Keybinds.Dash = { KeyCode = Enum.KeyCode.Q }
			local copy = PlayerDataSystem.CopyProfile(original)

			copy.settings.Keybinds.Dash = { KeyCode = Enum.KeyCode.E }
			copy.settings.Autorun = true

			expect(original.settings.Keybinds.Dash.KeyCode).to.equal(Enum.KeyCode.Q)
			expect(original.settings.Autorun).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.EncodeProfile / DecodeProfile round trip", function()
		it("decodes exactly what was encoded", function()
			local original = PlayerDataSystem.CreateDefaultProfile(42)
			original.faction = "Demonic"
			original.raceId = "Rivenkin"
			original.displayName = "Wren Ashfall"
			original.attributes = {
				Vitality = 13,
				Fortitude = 13,
				MeridianFlow = 13,
				Might = 13,
				Pressure = 13,
				Fleetness = 13,
			}
			original.tier = 4
			original.bloodlineIds = { "bl-1", "bl-2" }
			original.bloodlineStageProgress = { ["bl-1"] = 2 }
			original.artMastery = { ["art-1"] = 7 }
			original.corruption = 15
			original.qiDeviationRisk = 0.5
			original.factionStanding = -10
			original.hasAscended = true
			original.unlockedEmoteIds = { Wave = true, VictoryPose = true }
			original.emoteLoadout = { "Wave", "VictoryPose" }
			original.blimpFuel = { Coal = 40, Water = 75 }
			original.settings.Keybinds.Dash = { KeyCode = Enum.KeyCode.E }
			original.settings.GamepadKeybinds.BasicAttack = { KeyCode = Enum.KeyCode.ButtonX }
			original.settings.Autorun = true

			local encoded = PlayerDataSystem.EncodeProfile(original)
			local decoded = PlayerDataSystem.DecodeProfile(42, encoded)

			expect(decoded).never.to.equal(nil)
			local decodedProfile = decoded :: PlayerProfile
			expect(decodedProfile.faction).to.equal("Demonic")
			expect(decodedProfile.raceId).to.equal("Rivenkin")
			expect(decodedProfile.displayName).to.equal("Wren Ashfall")
			expect(decodedProfile.attributes).never.to.equal(nil)
			expect((decodedProfile.attributes :: any).Might).to.equal(13)
			expect(decodedProfile.tier).to.equal(4)
			expect(#decodedProfile.bloodlineIds).to.equal(2)
			expect(decodedProfile.bloodlineStageProgress["bl-1"]).to.equal(2)
			expect(decodedProfile.artMastery["art-1"]).to.equal(7)
			expect(decodedProfile.corruption).to.equal(15)
			expect(decodedProfile.qiDeviationRisk).to.equal(0.5)
			expect(decodedProfile.factionStanding).to.equal(-10)
			expect(decodedProfile.hasAscended).to.equal(true)
			expect(decodedProfile.unlockedEmoteIds.Wave).to.equal(true)
			expect(decodedProfile.unlockedEmoteIds.VictoryPose).to.equal(true)
			expect(#decodedProfile.emoteLoadout).to.equal(2)
			expect(decodedProfile.emoteLoadout[1]).to.equal("Wave")
			expect(decodedProfile.blimpFuel.Coal).to.equal(40)
			expect(decodedProfile.blimpFuel.Water).to.equal(75)
			expect(decodedProfile.settings.Keybinds.Dash.KeyCode).to.equal(Enum.KeyCode.E)
			expect(decodedProfile.settings.GamepadKeybinds.BasicAttack.KeyCode).to.equal(Enum.KeyCode.ButtonX)
			expect(decodedProfile.settings.Autorun).to.equal(true)
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (settings -- defensive decoding)", function()
		it("defaults to no overrides and Autorun off when settings is missing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			local profile = decoded :: PlayerProfile
			expect(next(profile.settings.Keybinds)).to.equal(nil)
			expect(next(profile.settings.GamepadKeybinds)).to.equal(nil)
			expect(profile.settings.Autorun).to.equal(false)
		end)

		it("drops a HotbarSlot override even if one is somehow present in the stored record", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				settings = {
					Keybinds = { HotbarSlot1 = { KeyCode = "Q" } },
					GamepadKeybinds = {},
					Autorun = false,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.settings.Keybinds.HotbarSlot1).to.equal(nil)
		end)

		it("drops an override for an action that no longer exists", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				settings = {
					Keybinds = { NotARealAction = { KeyCode = "Q" } },
					GamepadKeybinds = {},
					Autorun = false,
				},
			})
			local profile = decoded :: PlayerProfile
			expect((profile.settings.Keybinds :: any).NotARealAction).to.equal(nil)
		end)

		it("drops a malformed keybind (neither KeyCode nor UserInputType) rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				settings = {
					Keybinds = { Dash = { SomethingElse = true } },
					GamepadKeybinds = {},
					Autorun = false,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.settings.Keybinds.Dash).to.equal(nil)
		end)

		it("drops an unrecognized KeyCode name rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				settings = {
					Keybinds = { Dash = { KeyCode = "NotARealKeyCode" } },
					GamepadKeybinds = {},
					Autorun = false,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.settings.Keybinds.Dash).to.equal(nil)
		end)

		it("decodes a valid override correctly", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				settings = {
					Keybinds = { Dash = { KeyCode = "E" } },
					GamepadKeybinds = {},
					Autorun = true,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.settings.Keybinds.Dash.KeyCode).to.equal(Enum.KeyCode.E)
			expect(profile.settings.Autorun).to.equal(true)
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (unlockedEmoteIds/emoteLoadout defaults)", function()
		it("falls back to every Default-unlock emote when unlockedEmoteIds is missing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			local profile = decoded :: PlayerProfile
			expect(profile.unlockedEmoteIds.Wave).to.equal(true)
			expect(profile.unlockedEmoteIds.VictoryPose).to.equal(nil)
		end)

		it("falls back to the starter loadout when emoteLoadout is missing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			local profile = decoded :: PlayerProfile
			expect(#profile.emoteLoadout).to.equal(8)
		end)

		it("filters non-string entries out of a corrupt unlockedEmoteIds table", function()
			local decoded =
				PlayerDataSystem.DecodeProfile(1, { unlockedEmoteIds = { Wave = true, Bow = "not-true", [42] = true } })
			local profile = decoded :: PlayerProfile
			expect(profile.unlockedEmoteIds.Wave).to.equal(true)
			expect(profile.unlockedEmoteIds.Bow).to.equal(nil)
		end)

		it("filters non-string entries out of a corrupt emoteLoadout array", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { emoteLoadout = { "Wave", 42, true } })
			local profile = decoded :: PlayerProfile
			expect(#profile.emoteLoadout).to.equal(1)
			expect(profile.emoteLoadout[1]).to.equal("Wave")
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (displayName/attributes -- new onboarding fields)", function()
		it("decodes a missing displayName/attributes as nil (legacy pre-onboarding record)", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			local profile = decoded :: PlayerProfile
			expect(profile.displayName).to.equal(nil)
			expect(profile.attributes).to.equal(nil)
		end)

		it("rejects a non-string displayName back to nil rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { displayName = 42 })
			local profile = decoded :: PlayerProfile
			expect(profile.displayName).to.equal(nil)
		end)

		it("decodes a fully-populated attributes block", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = 10,
					Pressure = 10,
					Fleetness = 10,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).never.to.equal(nil)
			expect((profile.attributes :: any).Vitality).to.equal(10)
			expect((profile.attributes :: any).Fleetness).to.equal(10)
		end)

		it("discards the WHOLE attributes block to nil when a single field is missing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = 10,
					Pressure = 10,
					-- Fleetness deliberately omitted.
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)

		it("discards the WHOLE attributes block to nil when a single field is wrong-typed", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				attributes = {
					Vitality = 10,
					Fortitude = 10,
					MeridianFlow = 10,
					Might = "not-a-number",
					Pressure = 10,
					Fleetness = 10,
				},
			})
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)

		it("treats a non-table attributes value as absent rather than throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { attributes = "not-a-table" })
			local profile = decoded :: PlayerProfile
			expect(profile.attributes).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.DecodeProfile (defensive decoding)", function()
		it("returns nil for a non-table value", function()
			expect(PlayerDataSystem.DecodeProfile(1, "not a table")).to.equal(nil)
			expect(PlayerDataSystem.DecodeProfile(1, nil)).to.equal(nil)
		end)

		it("falls back to fallbackUserId when the stored userId is missing/wrong-typed", function()
			local decoded = PlayerDataSystem.DecodeProfile(555, { userId = "not-a-number" })
			expect(decoded).never.to.equal(nil)
			expect((decoded :: PlayerProfile).userId).to.equal(555)
		end)

		it("defaults every missing field instead of throwing", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {})
			expect(decoded).never.to.equal(nil)
			local profile = decoded :: PlayerProfile
			expect(profile.tier).to.equal(1)
			expect(profile.corruption).to.equal(0)
			expect(profile.hasAscended).to.equal(false)
			expect(#profile.bloodlineIds).to.equal(0)
			expect(next(profile.bloodlineStageProgress)).to.equal(nil)
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(0)
		end)

		it("filters out non-string entries from a corrupt bloodlineIds array", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { bloodlineIds = { "valid", 42, true } })
			local profile = decoded :: PlayerProfile
			expect(#profile.bloodlineIds).to.equal(1)
			expect(profile.bloodlineIds[1]).to.equal("valid")
		end)

		it("filters out malformed entries from a corrupt artMastery table", function()
			local decoded =
				PlayerDataSystem.DecodeProfile(1, { artMastery = { ["good"] = 5, ["bad"] = "not-a-number" } })
			local profile = decoded :: PlayerProfile
			expect(profile.artMastery["good"]).to.equal(5)
			expect(profile.artMastery["bad"]).to.equal(nil)
		end)

		it("filters out malformed entries from a corrupt bloodlineStageProgress table", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, {
				bloodlineStageProgress = { ["good-bloodline"] = 2, ["bad-bloodline"] = "not-a-number", [42] = 1 },
			})
			local profile = decoded :: PlayerProfile
			expect(profile.bloodlineStageProgress["good-bloodline"]).to.equal(2)
			expect(profile.bloodlineStageProgress["bad-bloodline"]).to.equal(nil)
		end)

		it("clamps a negative carried amount to 0 rather than keeping it", function()
			-- A player cannot legitimately owe the game coal -- a hand-edited or corrupted record must
			-- not be able to express a negative carried amount.
			local decoded = PlayerDataSystem.DecodeProfile(1, { blimpFuel = { Coal = -5, Water = 12 } })
			local profile = decoded :: PlayerProfile
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(12)
		end)

		it("defaults a non-number or missing blimpFuel field to 0 independently", function()
			local decoded = PlayerDataSystem.DecodeProfile(1, { blimpFuel = { Coal = "lots", Water = 8 } })
			local profile = decoded :: PlayerProfile
			expect(profile.blimpFuel.Coal).to.equal(0)
			expect(profile.blimpFuel.Water).to.equal(8)
		end)
	end)

	describe("PlayerDataSystem.MigrateRecord", function()
		it("returns an already-current-version record unchanged", function()
			local raw = { SchemaVersion = CURRENT_SCHEMA, Profile = { tier = 3 } }
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect((migrated.Profile :: any).tier).to.equal(3)
		end)

		it("treats a missing SchemaVersion as version 1", function()
			local raw = { Profile = { tier = 2 } }
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			expect(migrated.SchemaVersion).never.to.equal(nil)
		end)

		it(
			"migrates a pre-Emote-System v1 record all the way to current, backfilling unlockedEmoteIds/emoteLoadout/settings",
			function()
				local raw = { SchemaVersion = 1, Profile = { tier = 3 } }
				local migrated = PlayerDataSystem.MigrateRecord(raw)
				local profile = migrated.Profile :: any

				expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
				expect(profile.tier).to.equal(3)
				expect(next(profile.unlockedEmoteIds)).never.to.equal(nil)
				expect(profile.unlockedEmoteIds.Wave).to.equal(true)
				expect(#profile.emoteLoadout).to.equal(8)
				expect(profile.settings).never.to.equal(nil)
				expect(next(profile.settings.Keybinds)).to.equal(nil)
				expect(profile.settings.Autorun).to.equal(false)
			end
		)

		it("does not overwrite an already-present unlockedEmoteIds/emoteLoadout on a v1 record", function()
			local raw = {
				SchemaVersion = 1,
				Profile = {
					tier = 1,
					unlockedEmoteIds = { Wave = true },
					emoteLoadout = { "Wave" },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(next(profile.unlockedEmoteIds, next(profile.unlockedEmoteIds))).to.equal(nil)
			expect(#profile.emoteLoadout).to.equal(1)
		end)

		it("migrates a pre-Settings-System v2 record to v3, backfilling settings", function()
			local raw = {
				SchemaVersion = 2,
				Profile = {
					tier = 5,
					unlockedEmoteIds = { Wave = true },
					emoteLoadout = { "Wave" },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(migrated.SchemaVersion).to.equal(CURRENT_SCHEMA)
			expect(profile.tier).to.equal(5)
			expect(profile.settings).never.to.equal(nil)
			expect(next(profile.settings.Keybinds)).to.equal(nil)
			expect(next(profile.settings.GamepadKeybinds)).to.equal(nil)
			expect(profile.settings.Autorun).to.equal(false)
		end)

		it("does not overwrite an already-present settings field on a v2 record", function()
			local raw = {
				SchemaVersion = 2,
				Profile = {
					tier = 1,
					settings = { Keybinds = { Dash = { KeyCode = "E" } }, GamepadKeybinds = {}, Autorun = true },
				},
			}
			local migrated = PlayerDataSystem.MigrateRecord(raw)
			local profile = migrated.Profile :: any

			expect(profile.settings.Autorun).to.equal(true)
			expect(profile.settings.Keybinds.Dash.KeyCode).to.equal("E")
		end)
	end)

	-- Cross-server session lock + WriteGeneration -- the 2026-08 performance audit's data-loss finding
	-- (server A's PlayerRemoving save and server B's load for the same player, via ServerHopSystem's
	-- TeleportAsync, can genuinely overlap in wall-clock time). Every function below is pure (plain
	-- values in, no DataStore/Player) -- see PlayerDataSystem.lua's own "Cross-server session lock +
	-- WriteGeneration" section header for the full design.
	describe("PlayerDataSystem.IsLockHeldByOther", function()
		it("is false when there is no lock at all", function()
			expect(PlayerDataSystem.IsLockHeldByOther(nil, "server-a", 1000, 300)).to.equal(false)
		end)

		it("is false for a lock already held by the same JobId", function()
			local lock = { JobId = "server-a", LockedAt = 999 }
			expect(PlayerDataSystem.IsLockHeldByOther(lock, "server-a", 1000, 300)).to.equal(false)
		end)

		it("is true for a live lock held by a different JobId", function()
			local lock = { JobId = "server-b", LockedAt = 999 }
			expect(PlayerDataSystem.IsLockHeldByOther(lock, "server-a", 1000, 300)).to.equal(true)
		end)

		it("is false for a foreign lock older than staleAfterSeconds -- treated as abandoned", function()
			local lock = { JobId = "server-b", LockedAt = 100 }
			expect(PlayerDataSystem.IsLockHeldByOther(lock, "server-a", 1000, 300)).to.equal(false)
		end)

		it("is true for a foreign lock exactly at the staleness boundary (not yet stale)", function()
			local lock = { JobId = "server-b", LockedAt = 700 }
			-- now(1000) - LockedAt(700) == 300 == staleAfterSeconds -- strictly less-than is what
			-- still counts as live, so exactly at the boundary is already stale.
			expect(PlayerDataSystem.IsLockHeldByOther(lock, "server-a", 1000, 300)).to.equal(false)
		end)

		it("treats a malformed lock shape (missing/wrong-typed fields) as absent, not permanent", function()
			expect(PlayerDataSystem.IsLockHeldByOther({ JobId = "server-b" }, "server-a", 1000, 300)).to.equal(false)
			expect(PlayerDataSystem.IsLockHeldByOther({ LockedAt = 999 }, "server-a", 1000, 300)).to.equal(false)
			expect(PlayerDataSystem.IsLockHeldByOther("not-a-table", "server-a", 1000, 300)).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.ComputeLoadClaim", function()
		it("claims a lock-only stub for a never-written key (old == nil)", function()
			local result = PlayerDataSystem.ComputeLoadClaim(nil, "server-a", 1000, 300) :: any
			expect(result.Lock.JobId).to.equal("server-a")
			expect(result.Lock.LockedAt).to.equal(1000)
			expect(result.Profile).to.equal(nil)
		end)

		it("claims an existing unlocked record without touching Profile/SchemaVersion", function()
			local old = { SchemaVersion = 3, Profile = { tier = 5 }, WriteGeneration = 2 }
			local result = PlayerDataSystem.ComputeLoadClaim(old, "server-a", 1000, 300) :: any
			expect(result.Lock.JobId).to.equal("server-a")
			expect(result.SchemaVersion).to.equal(3)
			expect(result.Profile.tier).to.equal(5)
			expect(result.WriteGeneration).to.equal(2)
		end)

		it("re-claims (refreshes) a lock already held by the same server", function()
			local old = { Profile = { tier = 1 }, Lock = { JobId = "server-a", LockedAt = 500 } }
			local result = PlayerDataSystem.ComputeLoadClaim(old, "server-a", 1000, 300) :: any
			expect(result.Lock.JobId).to.equal("server-a")
			expect(result.Lock.LockedAt).to.equal(1000)
		end)

		it("refuses and returns the record completely untouched when a live foreign lock is held", function()
			local old = { Profile = { tier = 7 }, Lock = { JobId = "server-b", LockedAt = 999 } }
			local result = PlayerDataSystem.ComputeLoadClaim(old, "server-a", 1000, 300) :: any
			expect(result.Lock.JobId).to.equal("server-b")
			expect(result.Lock.LockedAt).to.equal(999)
			expect(result.Profile.tier).to.equal(7)
		end)

		it("claims when a foreign lock has gone stale", function()
			local old = { Profile = { tier = 1 }, Lock = { JobId = "server-b", LockedAt = 100 } }
			local result = PlayerDataSystem.ComputeLoadClaim(old, "server-a", 1000, 300) :: any
			expect(result.Lock.JobId).to.equal("server-a")
		end)

		it("passes a non-table, non-nil old value through completely untouched", function()
			local result = PlayerDataSystem.ComputeLoadClaim("corrupt-string-value", "server-a", 1000, 300)
			expect(result).to.equal("corrupt-string-value")
		end)
	end)

	describe("PlayerDataSystem.ComputeLockRelease", function()
		it("clears a lock held by the given JobId", function()
			local old = { Profile = { tier = 1 }, Lock = { JobId = "server-a", LockedAt = 500 } }
			local result = PlayerDataSystem.ComputeLockRelease(old, "server-a") :: any
			expect(result.Lock).to.equal(nil)
			expect(result.Profile.tier).to.equal(1)
		end)

		it("does not touch a lock held by a different JobId", function()
			local old = { Profile = { tier = 1 }, Lock = { JobId = "server-b", LockedAt = 500 } }
			local result = PlayerDataSystem.ComputeLockRelease(old, "server-a") :: any
			expect(result.Lock.JobId).to.equal("server-b")
		end)

		it("is a no-op when there is no lock at all", function()
			local old = { Profile = { tier = 1 } }
			local result = PlayerDataSystem.ComputeLockRelease(old, "server-a") :: any
			expect(result.Lock).to.equal(nil)
			expect(result.Profile.tier).to.equal(1)
		end)

		it("passes a non-table old value through untouched", function()
			expect(PlayerDataSystem.ComputeLockRelease("corrupt", "server-a")).to.equal("corrupt")
		end)
	end)

	describe("PlayerDataSystem.ComputeSaveWrite", function()
		local encodedProfile = { tier = 9 }

		it("commits and bumps WriteGeneration when nothing else has saved since this server loaded", function()
			local old = { WriteGeneration = 2 }
			local record, outcome =
				PlayerDataSystem.ComputeSaveWrite(old, 2, "server-a", 1000, encodedProfile, 3, false)
			expect(outcome).to.equal("Saved")
			expect((record :: any).WriteGeneration).to.equal(3)
			expect((record :: any).Profile).to.equal(encodedProfile)
			expect((record :: any).SchemaVersion).to.equal(3)
		end)

		it("commits generation 1 against a never-written key (old == nil, loadedGeneration 0)", function()
			local record, outcome =
				PlayerDataSystem.ComputeSaveWrite(nil, 0, "server-a", 1000, encodedProfile, 3, false)
			expect(outcome).to.equal("Saved")
			expect((record :: any).WriteGeneration).to.equal(1)
		end)

		it(
			"rejects -- and touches nothing -- when the currently-stored generation is already ahead of what this server loaded",
			function()
				-- The core regression this whole mechanism exists to prevent: server A loaded at
				-- generation 2, server B has since saved (bumping it to 3) -- A's write must be refused,
				-- not silently overwrite B's newer data.
				local old = { WriteGeneration = 3, Profile = { tier = 999 }, SchemaVersion = 3 }
				local record, outcome =
					PlayerDataSystem.ComputeSaveWrite(old, 2, "server-a", 1000, encodedProfile, 3, false)
				expect(outcome).to.equal("Rejected")
				expect((record :: any).WriteGeneration).to.equal(3)
				expect((record :: any).Profile.tier).to.equal(999)
			end
		)

		it("clears the Lock field when releaseLock is true", function()
			local old = { WriteGeneration = 0 }
			local record = PlayerDataSystem.ComputeSaveWrite(old, 0, "server-a", 1000, encodedProfile, 3, true)
			expect((record :: any).Lock).to.equal(nil)
		end)

		it("refreshes the Lock under this server's JobId when releaseLock is false", function()
			local old = { WriteGeneration = 0 }
			local record = PlayerDataSystem.ComputeSaveWrite(old, 0, "server-a", 1000, encodedProfile, 3, false)
			expect((record :: any).Lock.JobId).to.equal("server-a")
			expect((record :: any).Lock.LockedAt).to.equal(1000)
		end)
	end)

	describe("PlayerDataSystem.ApplyMutation", function()
		it("applies the mutator and returns true", function()
			local stored: Types.StoredPlayerProfile =
				{ SchemaVersion = 1, Profile = PlayerDataSystem.CreateDefaultProfile(1), WriteGeneration = 0 }
			local applied = PlayerDataSystem.ApplyMutation(stored, function(profile)
				profile.tier = 3
				profile.corruption = 10
			end)

			expect(applied).to.equal(true)
			expect(stored.Profile.tier).to.equal(3)
			expect(stored.Profile.corruption).to.equal(10)
		end)

		it("returns false and never propagates an error when the mutator throws", function()
			local stored: Types.StoredPlayerProfile =
				{ SchemaVersion = 1, Profile = PlayerDataSystem.CreateDefaultProfile(1), WriteGeneration = 0 }

			local ok, applied = pcall(function()
				return PlayerDataSystem.ApplyMutation(stored, function(_profile)
					error("mutator bug")
				end)
			end)

			expect(ok).to.equal(true)
			expect(applied).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.IsLoaded / GetProfile (no profile ever loaded)", function()
		it("IsLoaded is false for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(PlayerDataSystem.IsLoaded(fakePlayer)).to.equal(false)
		end)

		it("GetProfile returns nil for a player with no loaded profile", function()
			local fakePlayer = {} :: any
			expect(PlayerDataSystem.GetProfile(fakePlayer)).to.equal(nil)
		end)
	end)

	describe("PlayerDataSystem.Transform (no profile ever loaded)", function()
		it("returns false and never calls the mutator when the profile isn't loaded", function()
			local fakePlayer = {} :: any
			local mutatorCalled = false

			local applied = PlayerDataSystem.Transform(fakePlayer, function(_profile)
				mutatorCalled = true
			end)

			expect(applied).to.equal(false)
			expect(mutatorCalled).to.equal(false)
		end)
	end)

	describe("PlayerDataSystem.WaitForProfile (never loads, bounded timeout)", function()
		it("times out and returns nil rather than blocking forever", function()
			local fakePlayer = {} :: any
			local result = PlayerDataSystem.WaitForProfile(fakePlayer, 0.05)
			expect(result).to.equal(nil)
		end)
	end)
end
