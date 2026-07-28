--!strict
--[[
	LiveTuningContract.lua

	Shared plumbing for HitboxTuning.spec.lua and FlightTuning.spec.lua -- both spec files test a
	"live-tuning module" (Server/Combat/HitboxTuning.lua and Server/DevMenu/FlightTuning.lua) that
	mutates a REAL, shared Constants table by reference (that's the whole point of both modules --
	see either one's own header). Because TestEZ runs every spec file in one Lua VM/session, a
	mutation that leaks out of one `it()` would silently change combat/flight behavior for whatever
	OTHER spec happens to read that same Constants table afterward. Both spec files independently
	adopted the same discipline to guard against that: mutate, assert against the result, then call
	the module's own Reset function inline before the test returns, rather than relying on an
	afterEach hook (which would need HitboxTuning/FlightTuning-specific knowledge of what to reset,
	and wouldn't run before a later `it` in the same describe block if TestEZ's afterEach ordering
	ever changed).

	withRestore is that shared "mutate+assert, then GUARANTEE the reset still runs" mechanic --
	nothing more. It deliberately does NOT try to unify the two modules' differing AdjustField/
	ResetStage/ResetField signatures (weapon/category/stageIndex/field vs. field/deltaFraction) into
	one parametrized contract-test generator: the two spec files' test shapes diverge in how many
	"returns nil" cases exist and how the Finisher sentinel-index case works, so forcing a single
	generator would either drop coverage or grow more special-casing than the duplication it removes.
	A thin wrapper lets each spec keep authoring its own mutate/assert body and just hand the cleanup
	off.
]]

local LiveTuningContract = {}

-- Runs `mutateAndAssert` (expected to call the module's AdjustField and `expect()` against the
-- result) inside a pcall, then ALWAYS runs `reset` (expected to call the module's own Reset
-- function) before returning -- even if an assertion inside `mutateAndAssert` failed and threw.
-- Without this, a failing assertion would skip the inline reset call that used to follow it
-- directly in the test body, leaking a mutated Constants value into whatever spec runs next. Once
-- `reset` has run, the original error (if any) is re-raised so the test still reports as failed
-- exactly as it would have without this wrapper.
function LiveTuningContract.withRestore(mutateAndAssert: () -> (), reset: () -> ()): ()
	local ok, err = pcall(mutateAndAssert)
	reset()
	if not ok then
		error(err, 0)
	end
end

return LiveTuningContract
