-- Oz PTM Scanner.lua
-- Enumerates Reaper preset/template search paths and feeds discoveries into the DB.
-- Supported types: FX chains (.rfxchain), Track Templates (.RTrackTemplate),
--                  VST/AU presets (.fxp/.fxb/.vstpreset), Reabanks (.reabank).

local Scanner = {}

-- ─── Path helpers ────────────────────────────────────────────────────────────

--- Returns candidate root directories where Reaper stores presets/templates.
--- Also includes any user-registered extra roots from ext-state.
--- @param config table  Config module
function Scanner.get_search_roots(config)
  local res = reaper.GetResourcePath()
  local roots = {
    { path = res .. "/FXChains",        recurse = true },
    { path = res .. "/TrackTemplates",  recurse = true },
    { path = res .. "/presets",         recurse = true },
    -- Per-plugin preset directories written by Reaper
    { path = res .. "/Presets",         recurse = true },
  }

  -- Also walk the VST scan path for .fxp sidecars if present
  local vst_path = reaper.GetResourcePath() .. "/UserPlugins"
  if reaper.file_exists and reaper.file_exists(vst_path) then
    roots[#roots + 1] = { path = vst_path, recurse = true }
  end

  -- User-defined extra roots stored as JSON array of path strings
  local extra_json = config.get_ext_str(config.KEY_SCAN_ROOTS, "[]")
  local extra = config._json_decode and config._json_decode(extra_json) or {}
  for _, p in ipairs(extra or {}) do
    if type(p) == "string" and p ~= "" then
      roots[#roots + 1] = { path = p, recurse = true }
    end
  end

  return roots
end

--- Recursively lists all files under a directory.
--- Uses reaper.EnumerateFiles / reaper.EnumerateSubdirectories when available,
--- otherwise falls back to io.popen (Windows-safe).
--- @param dir string
--- @param recurse boolean
--- @param results table  accumulator; list of absolute file paths
local function enumerate_files(dir, recurse, results)
  -- Primary method: REAPER API
  if reaper.EnumerateFiles then
    local i = 0
    while true do
      local fname = reaper.EnumerateFiles(dir, i)
      if not fname then break end
      results[#results + 1] = dir .. "/" .. fname
      i = i + 1
    end
    if recurse and reaper.EnumerateSubdirectories then
      local j = 0
      while true do
        local sub = reaper.EnumerateSubdirectories(dir, j)
        if not sub then break end
        enumerate_files(dir .. "/" .. sub, recurse, results)
        j = j + 1
      end
    end
  else
    -- Fallback: io.popen dir listing (Windows)
    local cmd = 'dir /b /s "' .. dir .. '" 2>nul'
    local p = io.popen(cmd)
    if p then
      for line in p:lines() do
        results[#results + 1] = line
      end
      p:close()
    end
  end
end

--- Tests whether a file path should be indexed based on its extension.
--- @param path string
--- @param config table
--- @return string|nil  preset type string, or nil if unsupported
local function get_preset_type(path, config)
  local ext = path:match("(%.[^%.]+)$")
  if not ext then return nil end
  return config.SUPPORTED_EXTS[ext:lower()]
end

-- ─── Scan ────────────────────────────────────────────────────────────────────

--- Full scan: walks all roots, discovers preset files, upserts into DB.
--- @param config table   Config module
--- @param db table       DB module
--- @param on_progress function|nil  called with (current, total, path) for UI feedback
--- @return number  count of newly added / updated records
function Scanner.scan_all(config, db, on_progress)
  local roots = Scanner.get_search_roots(config)
  local all_paths = {}

  for _, root in ipairs(roots) do
    if reaper.file_exists and reaper.file_exists(root.path) then
      enumerate_files(root.path, root.recurse, all_paths)
    elseif not reaper.file_exists then
      -- If file_exists not available, attempt anyway
      enumerate_files(root.path, root.recurse, all_paths)
    end
  end

  local total   = #all_paths
  local updated = 0

  for i, path in ipairs(all_paths) do
    local ptype = get_preset_type(path, config)
    if ptype then
      local record = db.new_preset_record(path, ptype)
      db.upsert_preset(record)
      updated = updated + 1
    end
    if on_progress then
      on_progress(i, total, path)
    end
  end

  return updated
end

--- Incremental scan: only processes paths not already in the DB.
--- @param config table
--- @param db table
--- @param on_progress function|nil
--- @return number  count of new records added
function Scanner.scan_new(config, db, on_progress)
  local roots = Scanner.get_search_roots(config)
  local all_paths = {}

  for _, root in ipairs(roots) do
    if reaper.file_exists and reaper.file_exists(root.path) then
      enumerate_files(root.path, root.recurse, all_paths)
    elseif not reaper.file_exists then
      enumerate_files(root.path, root.recurse, all_paths)
    end
  end

  local total = #all_paths
  local added = 0

  for i, path in ipairs(all_paths) do
    local ptype = get_preset_type(path, config)
    if ptype then
      -- Only upsert if path is not already known
      if not db.find_preset_by_path(path) then
        local record = db.new_preset_record(path, ptype)
        db.upsert_preset(record)
        added = added + 1
      end
    end
    if on_progress then
      on_progress(i, total, path)
    end
  end

  return added
end

--- Removes stale records: DB entries whose file no longer exists on disk.
--- @param db table
--- @return number  count of removed records
function Scanner.remove_stale(db)
  local data = db.get and db.get("") or nil
  if not data then return 0 end
  local removed = 0
  for uuid, p in pairs(data.presets) do
    -- reaper.file_exists available in Reaper ≥ 5.965
    local exists = true
    if reaper.file_exists then
      exists = reaper.file_exists(p.path)
    else
      local f = io.open(p.path, "rb")
      if f then f:close() else exists = false end
    end
    if not exists then
      data.presets[uuid] = nil
      removed = removed + 1
    end
  end
  if removed > 0 then db.mark_dirty() end
  return removed
end

-- ─── Single-file import ───────────────────────────────────────────────────────

--- Imports a single file into the DB (e.g. dropped by user).
--- @param path string
--- @param config table
--- @param db table
--- @return table|nil  the preset record, or nil if unsupported type
function Scanner.import_file(path, config, db)
  local ptype = get_preset_type(path, config)
  if not ptype then return nil end
  local existing = db.find_preset_by_path(path)
  if existing then return existing end
  local record = db.new_preset_record(path, ptype)
  db.upsert_preset(record)
  return record
end

-- ─── Export helper: returns a human-readable type label ───────────────────────

local TYPE_LABELS = {
  fx_chain        = "FX Chain",
  track_template  = "Track Template",
  fx_preset       = "FX Preset",
  instrument_bank = "Instrument Bank",
}

function Scanner.type_label(ptype)
  return TYPE_LABELS[ptype] or ptype
end

return Scanner
