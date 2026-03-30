-- Oz PTM - Cleanup Stale Actions.lua
-- Unregisters any PTM actions whose script files no longer exist.

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")

local actions = {
  "actions/Oz PTM - Open Browser Panel.lua",
  "actions/Oz PTM - Rebuild Library Index.lua",
  "actions/Oz PTM - Generate Preview for Selected Preset.lua",
  "actions/Oz PTM - Generate Previews for All Unrendered.lua",
  "actions/Oz PTM - Sync NKS for All Presets.lua",
}

local removed = 0
for _, rel in ipairs(actions) do
  local full = script_path .. rel
  local f = io.open(full, "rb")
  if not f then
    -- File gone — unregister
    reaper.AddRemoveReaScript(false, 0, full, true)
    removed = removed + 1
  else
    f:close()
  end
end

reaper.ShowMessageBox(
  string.format("Stale actions removed: %d", removed),
  "Oz PTM Cleanup", 0)
