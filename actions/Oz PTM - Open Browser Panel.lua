-- Oz PTM - Open Browser Panel.lua
-- Opens the main Preset & Template Manager browser window.
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
local ptm = dofile(script_path .. "libs/Oz PTM Core.lua")

local _, _, section_id, command_id = reaper.get_action_context()
local function toggle(state)
  if section_id and command_id and command_id ~= 0 then
    reaper.SetToggleCommandState(section_id, command_id, state and 1 or 0)
    reaper.RefreshToolbar2(section_id, command_id)
  end
end

toggle(true)
reaper.atexit(function() toggle(false) end)

ptm.run_browser_panel()
