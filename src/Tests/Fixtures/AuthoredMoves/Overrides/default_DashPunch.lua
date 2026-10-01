--!strict
-- FIXTURE: a shipped retune of the standalone DashPunch. Only Damage differs from the built move, which
-- is all an override file needs to carry for DecodeOverride to lay it over the built one.
return {
	Damage = 13,
	MoveId = "default:DashPunch",
	SchemaVersion = 3,
}
