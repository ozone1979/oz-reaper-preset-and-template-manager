-- Oz PTM - Generate Previews for All Unrendered.lua
-- Batch-renders OGG audio previews for all presets that have none yet.
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local ptm = dofile(script_path .. "../Oz PTM Core.lua")
ptm.run_render_all_previews()
