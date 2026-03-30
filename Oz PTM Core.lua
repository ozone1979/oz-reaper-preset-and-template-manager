-- Oz PTM Core.lua
-- Compatibility loader that forwards to libs/Oz PTM Core.lua
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
return dofile(script_path .. "libs/Oz PTM Core.lua")
