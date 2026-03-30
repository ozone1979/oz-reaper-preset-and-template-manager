-- Oz PTM - Sync NKS for All Presets.lua
-- Writes .nks_meta.json sidecar files for all presets in the library.
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local ptm = dofile(script_path .. "../libs/Oz PTM Core.lua")
ptm.run_sync_nks()
