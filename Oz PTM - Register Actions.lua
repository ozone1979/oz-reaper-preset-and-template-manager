-- Oz PTM - Register Actions.lua
-- Registers all PTM actions in the Reaper action list so they appear under
-- "Oz Preset & Template Manager" in the action list and can have keyboard shortcuts.
-- Run this script once after installing the tool.

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")

local actions = {
  "actions/Oz PTM - Open Browser Panel.lua",
  "actions/Oz PTM - Rebuild Library Index.lua",
  "actions/Oz PTM - Generate Preview for Selected Preset.lua",
  "actions/Oz PTM - Generate Previews for All Unrendered.lua",
  "actions/Oz PTM - Sync NKS for All Presets.lua",
}

local registered = 0
local skipped    = 0

for _, rel in ipairs(actions) do
  local full = script_path .. rel
  -- reaper.AddRemoveReaScript(add, sectionID, scriptfile, commit)
  local ok = reaper.AddRemoveReaScript(true, 0, full, true)
  if ok ~= 0 then
    registered = registered + 1
  else
    skipped = skipped + 1
    reaper.ShowConsoleMsg("  Already registered or not found: " .. full .. "\n")
  end
end

reaper.ShowMessageBox(
  string.format(
    "Oz PTM actions registered: %d\nSkipped (already present): %d\n\n" ..
    "Search for 'Oz PTM' in the Reaper Action List to assign shortcuts.",
    registered, skipped),
  "Oz Preset & Template Manager", 0)
