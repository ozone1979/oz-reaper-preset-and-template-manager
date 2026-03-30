-- Oz PTM - Rebuild Library Index.lua
-- Walks all preset/template paths and rebuilds the library database.
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local ptm = dofile(script_path .. "../libs/Oz PTM Core.lua")
ptm.run_rebuild_index()
