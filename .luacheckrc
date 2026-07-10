-- Static analysis config for the Lua side (game/, test/). Run with:
--   luacheck game test
-- (needs `luarocks install luacheck` - not a dependency of the project
-- itself, just a dev-time tool, same as flake8 for the Python side - see
-- windows/setup.cfg)

std = "lua51+lua52"

-- Real CC:Tweaked/CraftOS globals this codebase uses everywhere, plus
-- test/cc_mocks.lua's and windows/craftos_shim.lua's own additions
-- (colors/fs/os.*/peripheral/rednet/textutils/gps/sublevel/shell) - without
-- these, luacheck would flag every single one as an undefined global.
globals = {
    "fs", "os", "term", "colors", "colours", "peripheral", "rednet",
    "textutils", "http", "gps", "sublevel", "shell", "fleetos",
    "_G", "_CC_DEFAULT_SETTINGS", "CRAFTOS_EMULATION",
    "redstone", -- apps/drone/drone_control.lua's motor/tilt output
    "sleep",    -- real CraftOS global (raytower.lua's poll loop)
}

-- game/apps/**, test/*.lua, raytower.lua etc. are all top-level scripts
-- (dofile'd or run directly, not required as modules) - unused-self-return
-- and similar module-style warnings don't apply here.
allow_defined_top = true

-- This codebase's comments are deliberately long-form prose explaining the
-- WHY behind a decision - same reasoning windows/setup.cfg already applies
-- to flake8's line length on the Python side. Disabled rather than left at
-- the default 120 and mechanically rewrapped everywhere, which would fight
-- that style on every future edit.
max_line_length = false

-- Several mock/stub functions (test/cc_mocks.lua's peripheral/textutils
-- stubs especially) intentionally keep a parameter unused so their
-- signature still matches the real CC:Tweaked API they're standing in for -
-- flagging that as a bug would be noise, not signal. Unused LOCAL
-- variables (a real category of bug) are a separate check and stay on.
unused_args = false

exclude_files = {
    "windows/sim/**",  -- gitignored per-node copies, not source
}
