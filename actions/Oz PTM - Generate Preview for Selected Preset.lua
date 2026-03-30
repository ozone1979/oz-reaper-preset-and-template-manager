-- Oz PTM - Generate Preview for Selected Preset.lua
-- Renders an OGG preview for the preset currently selected in the browser panel.
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local ptm = dofile(script_path .. "../Oz PTM Core.lua")
ptm.run_render_selected_preview()
