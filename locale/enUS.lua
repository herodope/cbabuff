local ADDON, CBAB = ...

-- enUS is the base locale: always loaded (see the TOC), and every other
-- locale falls back to it for any key it doesn't override. Keys are
-- grouped by the module that owns the string they replace.

CBAB.L = CBAB.L or {}
local L = CBAB.L

-- Core.lua
L.VERSION_LINE = "v%s (%s)"
L.UNKNOWN_TOPIC = "unknown topic"
L.HANDLER_ERROR = "|cffff4444error|r in handler for %s (%s): %s"

-- DB.lua
L.NO_SUCH_PROFILE = "no such profile: %s"
L.PROFILE_NAME_REQUIRED = "profile name must be a non-empty string"
L.PROFILE_ALREADY_EXISTS = "a profile named '%s' already exists"
L.IMPORT_EMPTY = "nothing to import"
L.IMPORT_BAD_ENCODING = "not a valid CBA Buff export string"
L.IMPORT_BAD_COMPRESSION = "failed to decompress data"
L.IMPORT_BAD_SERIALIZATION = "failed to deserialize data"

-- Comm.lua
L.PUSH_NOT_COORDINATOR = "only the leader or an assist can push"
L.PUSH_RATE_LIMITED = "push is rate-limited -- try again in a moment"
L.PUSH_NOTHING_TO_PUSH = "nothing to push -- run /cbab solve first"
L.PUSH_NOT_IN_GROUP = "not in a group -- nothing to push to"
L.PUSH_SENT = "pushed epoch %d to %s"
L.PUSH_RECEIVED = "received assignment push from %s (epoch %d)"
L.PUSH_SUPERSEDED = "your push (epoch %s) was superseded by %s"
L.CHECK_CHECKING = "checking for paladin responses..."
L.CHECK_ALL_RESPONDED = "all paladins responded"
L.CHECK_NO_RESPONSE = "no response from: %s"

-- Solve.lua
L.SOLVE_COMBAT_BLOCKED = "|cffff4444cannot solve in combat|r -- Solve is manual-only and gated out of combat (spec 11.1)"
L.SOLVE_NO_PROFILE = "no active profile -- create one with the roster page first"
L.SOLVE_HEADER = "-- Solved: epoch %d by %s --"
L.SOLVE_OVERRIDE_COUNT = "  %d override(s):"
L.SOLVE_RESULT_ERRORS = "|cffff4444%d error(s)|r, %d warning(s) -- push would be blocked"
L.SOLVE_RESULT_WARNINGS = "clean plan with %d warning(s)"
L.SOLVE_RESULT_CLEAN = "clean plan, no findings"
L.PLAN_OUT_OF_DATE = "|cffffcc00plan may be out of date:|r"
L.PLAN_RESOLVE_HINT = "  run |cff3399ff/cbab solve|r to re-solve, or ignore to keep the current plan"

-- UI/Bar.lua
L.PALLYPOWER_COLLISION = "CBA Buff and PallyPower are both loaded. Both addons use the same "
	.. "secure button names (PallyPowerC1-C9, PallyPowerRF) for macro compatibility, so raid "
	.. "macros clicking those names will behave unpredictably with both active. Disable one."
L.BAR_TOOLTIP_TITLE = "CBA Buff"
L.BAR_TOOLTIP_NO_ASSIGNMENTS = "No assignments."
L.BAR_TOOLTIP_GREATER = "Greater %s -> %s"
L.BAR_TOOLTIP_OVERRIDE = "%s -> %s (%s)"

-- UI/Alert.lua
L.ALERT_NO_GREATER = "%s -- no Greater %s"
L.ALERT_EXPIRING_CLASS = "%s expiring %s (%s)"
L.ALERT_MISSING_INDIVIDUAL = "%s -- missing %s"
L.ALERT_EXPIRING_INDIVIDUAL = "%s -- %s expiring %s"
L.ALERT_PET_LABEL = "%s's pet"
L.ALERT_TANK_LABEL = "%s (tank)"
L.ALERT_WHISPER_PREFIX = "CBA Buff: %s"
L.ALERT_RAID_WARN_NOT_OFFICER = "only the leader or an assist can post a raid warning"
L.ALERT_RAID_WARN_NOTHING = "nothing to warn about"
L.ALERT_RAID_WARN_PREFIX = "CBA Buff: %s"

-- UI/RosterPage.lua
L.ROSTER_NO_ACTIVE_PROFILE = "no active profile"
L.ROSTER_NO_ACTIVE_PROFILE_EXPORT = "no active profile to export"
L.ROSTER_IMPORT_SUCCESS = "import succeeded"
L.ROSTER_IMPORT_FAILED = "import failed: %s"
L.ROSTER_ACTIVE_LABEL = "Active: %s"
L.ROSTER_NO_ACTIVE_LABEL = "No active profile"
L.ROSTER_PROFILE_LIST = "Profiles: %s"
L.ROSTER_NO_PROFILES = "No profiles yet"
L.ROSTER_PET_TOGGLE_WARNING = "This is saved on the active PROFILE, not this character. "
	.. "Changing it alters the plan every paladin in the raid receives on the next "
	.. "solve/push -- it is not a personal display setting."

-- Debug.lua
L.DEBUG_ENABLED = "debug logging enabled"
L.DEBUG_DISABLED = "debug logging disabled"
L.DEBUG_VERBOSE_ENABLED = "debug logging enabled (verbose)"
L.DEBUG_USAGE = "usage: /cbab debug on|off|verbose"

-- Sim.lua
L.SIM_NO_FIXTURE = "no such fixture: %s"
L.SIM_USAGE = "usage: /cbab sim <fixture> | all"
L.SIM_SUMMARY = "-- %d/%d fixtures passed --"

return L
