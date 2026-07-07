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
}

-- game/apps/**, test/*.lua, raytower.lua etc. are all top-level scripts
-- (dofile'd or run directly, not required as modules) - unused-self-return
-- and similar module-style warnings don't apply here.
allow_defined_top = true

exclude_files = {
    "windows/sim/**",  -- gitignored per-node copies, not source
}
