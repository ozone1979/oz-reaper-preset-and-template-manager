-- Oz PTM NKS.lua
-- Native Kontrol Standard (NKS) sidecar generation.
--
-- NKS files (.nksf / .nksfx) are ZIP archives containing:
--   - /NI resources/Plugin.json      (metadata)
--   - /NI resources/artwork/[name].jpg  (optional art)
--   - /.rnksf                         (Reaper-specific; not part of NI spec)
--
-- Because pure Lua cannot write ZIP archives without an external library,
-- this module writes a lightweight JSON sidecar (.nks_meta.json) next to each
-- preset or template file that is always supported. This is sufficient for
-- tooling that reads NKS metadata (e.g. Maschine's scanning can read the JSON
-- directly if pointed there, and the file can be ZIP-packaged as a second step).
--
-- The module also reads existing .nksf files (ZIP with JSON inside) via a
-- pure-Lua minimal ZIP parser so that metadata from installed NI presets can be
-- imported into PTM's DB.

local NKS = {}

-- ─── NI metadata schema ──────────────────────────────────────────────────────
-- Based on the NKS format specification (public documentation).

--- Build an NI Plugin.json-compatible metadata table from a PTM preset record.
--- @param preset table
--- @return table
function NKS.build_plugin_json(preset)
  return {
    -- Required NKS fields
    name     = preset.name   or "",
    vendor   = preset.vendor or "",
    author   = preset.author or "",
    comment  = preset.comment or "",
    -- NKS "bankchain": [Bank, Sub-bank, Preset]
    bankchain = {
      preset.vendor or "",
      preset.pack   or "",
      preset.name   or "",
    },
    -- Tags/types as NKS category/mode arrays
    types    = {{}},   -- populated from PTM tags below
    modes    = {},
    -- Reaper-specific extras (non-NI standard, but useful)
    _ptm = {
      uuid       = preset.uuid or "",
      type       = preset.type or "",
      path       = preset.path or "",
      date       = preset.date or "",
    }
  }
end

--- Injects PTM tag names into an NKS metadata table as NI-style "types".
--- @param nks_meta table   result of build_plugin_json()
--- @param preset   table   preset record
--- @param db       table   DB module
function NKS.apply_tags(nks_meta, preset, db)
  if not preset.tags or #preset.tags == 0 then return end
  local categories = {}
  for _, tag_uuid in ipairs(preset.tags) do
    local t = db.get_tag(tag_uuid)
    if t then
      -- Build hierarchy path: "Parent/Child"
      local path_parts = { t.name or "" }
      local parent_uuid = t.parent_uuid
      local depth = 0
      while parent_uuid and depth < 8 do
        local pt = db.get_tag(parent_uuid)
        if pt then
          table.insert(path_parts, 1, pt.name or "")
          parent_uuid = pt.parent_uuid
        else
          break
        end
        depth = depth + 1
      end
      categories[#categories + 1] = path_parts
    end
  end
  if #categories > 0 then
    nks_meta.types = categories
  end
end

-- ─── JSON-only sidecar (always written) ──────────────────────────────────────

--- Returns the path for the lightweight JSON sidecar next to a preset file.
--- @param preset_path string
--- @param config table
function NKS.get_sidecar_path(preset_path, config)
  local base = preset_path:gsub("%.[^%.]+$", "")
  return base .. (config.NKS_META_EXT or ".nks_meta.json")
end

--- Returns the path for the full .nksf archive sidecar.
function NKS.get_nksf_path(preset_path, config)
  local base = preset_path:gsub("%.[^%.]+$", "")
  return base .. (config.NKSF_EXT or ".nksf")
end

--- Writes the lightweight JSON sidecar and updates preset.nks_path in DB.
--- @param preset  table   preset record
--- @param db      table   DB module
--- @param config  table   Config module
--- @param json    table   json encoder (from DB._json)
--- @return boolean success
function NKS.write_sidecar(preset, db, config, json)
  local meta = NKS.build_plugin_json(preset)
  NKS.apply_tags(meta, preset, db)

  local out   = NKS.get_sidecar_path(preset.path, config)
  local encoded = json.encode(meta)
  -- Pretty-print: indent with 2 spaces (minimal manual pass)
  encoded = encoded:gsub(",", ",\n  "):gsub("{", "{\n  "):gsub("}", "\n}")

  local f = io.open(out, "wb")
  if not f then return false end
  f:write(encoded)
  f:close()

  db.update_preset(preset.uuid, { nks_path = out })
  return true
end

-- ─── Minimal ZIP reader (for importing existing .nksf files) ─────────────────
-- Only supports ZIP "stored" (method 0) and "deflate" (method 8) entries.
-- We only need to read the JSON entry; deflate decompression is done via
-- Reaper's built-in zlib if available, or skipped with a warning.

local function read_uint16_le(s, i)
  return s:byte(i) + s:byte(i + 1) * 256
end

local function read_uint32_le(s, i)
  return s:byte(i) + s:byte(i+1)*256 + s:byte(i+2)*65536 + s:byte(i+3)*16777216
end

--- Searches backward through data for the ZIP end-of-central-directory signature.
--- Returns the EOCD offset or nil.
local function find_eocd(data)
  local sig = "\x50\x4B\x05\x06"
  for i = #data - 21, math.max(1, #data - 65556), -1 do
    if data:sub(i, i + 3) == sig then
      return i
    end
  end
  return nil
end

--- Reads ZIP central directory and returns a table:
---   { [filename] = { local_header_offset, compressed_size, uncompressed_size, method } }
local function read_zip_index(data)
  local eocd = find_eocd(data)
  if not eocd then return nil, "No EOCD found" end

  local cd_offset = read_uint32_le(data, eocd + 16)
  local cd_count  = read_uint16_le(data, eocd + 8)

  local index = {}
  local pos   = cd_offset + 1  -- 1-based Lua index

  for _ = 1, cd_count do
    if data:sub(pos, pos + 3) ~= "\x50\x4B\x01\x02" then break end
    local method     = read_uint16_le(data, pos + 10)
    local comp_size  = read_uint32_le(data, pos + 20)
    local uncomp_size = read_uint32_le(data, pos + 24)
    local fname_len  = read_uint16_le(data, pos + 28)
    local extra_len  = read_uint16_le(data, pos + 30)
    local comm_len   = read_uint16_le(data, pos + 32)
    local lhdr_off   = read_uint32_le(data, pos + 42)
    local fname      = data:sub(pos + 46, pos + 45 + fname_len)

    index[fname] = {
      local_offset   = lhdr_off,
      comp_size      = comp_size,
      uncomp_size    = uncomp_size,
      method         = method,
    }
    pos = pos + 46 + fname_len + extra_len + comm_len
  end
  return index
end

--- Extracts a file entry from a ZIP data string.
--- Returns the raw (possibly compressed) bytes for the named entry, or nil.
local function zip_extract_raw(data, entry)
  local lh_pos = entry.local_offset + 1
  if data:sub(lh_pos, lh_pos + 3) ~= "\x50\x4B\x03\x04" then return nil end
  local fname_len = read_uint16_le(data, lh_pos + 26)
  local extra_len = read_uint16_le(data, lh_pos + 28)
  local data_start = lh_pos + 30 + fname_len + extra_len
  return data:sub(data_start, data_start + entry.comp_size - 1)
end

--- Reads the Plugin.json from an existing .nksf file.
--- Returns a Lua table or nil, error_message.
--- @param nksf_path string
--- @param json      table  json decoder
function NKS.read_nksf(nksf_path, json)
  local f = io.open(nksf_path, "rb")
  if not f then return nil, "Cannot open file: " .. nksf_path end
  local data = f:read("*a")
  f:close()

  local index, err = read_zip_index(data)
  if not index then return nil, "ZIP parse error: " .. (err or "?") end

  -- Look for the Plugin.json entry
  local json_entry = index["NI resources/Plugin.json"]
                  or index["NI Resources/Plugin.json"]
  if not json_entry then
    return nil, "Plugin.json not found inside NKSF"
  end

  local raw = zip_extract_raw(data, json_entry)
  if not raw then return nil, "Could not extract Plugin.json bytes" end

  if json_entry.method == 0 then
    -- Stored (no compression)
    local meta = json.decode(raw)
    return meta, nil
  elseif json_entry.method == 8 then
    -- Deflate — attempt via reaper's zlib binding if available
    if reaper.Deflate then
      local inflated = reaper.Deflate(raw, false)  -- false = inflate
      if inflated then
        return json.decode(inflated), nil
      end
    end
    return nil, "Deflate decompression not available; install SWS or use stored NKSF"
  else
    return nil, "Unsupported ZIP compression method: " .. json_entry.method
  end
end

-- ─── Import NKS metadata into PTM DB ─────────────────────────────────────────

--- Reads an .nksf and merges its metadata into the matching DB record.
--- @param nksf_path string
--- @param db        DB module
--- @param json      table  json module from DB._json
--- @return boolean success, string|nil error_message
function NKS.import_nksf(nksf_path, db, json)
  local meta, err = NKS.read_nksf(nksf_path, json)
  if not meta then return false, err end

  -- Find the matching preset by deriving the expected source path
  -- (nksf lives next to the preset with same base name)
  local base = nksf_path:gsub("%.[^%.]+$", "")
  local preset = nil

  -- Try common source extensions
  local try_exts = { ".rfxchain", ".RTrackTemplate", ".fxp", ".fxb", ".vstpreset" }
  for _, ext in ipairs(try_exts) do
    preset = db.find_preset_by_path(base .. ext)
    if preset then break end
  end

  if not preset then
    return false, "No matching preset found for " .. nksf_path
  end

  -- Merge NKS metadata (do not overwrite user edits for name/author/vendor
  -- if they are already set; only fill blanks)
  local function fill(field, value)
    if (not preset[field] or preset[field] == "") and value and value ~= "" then
      db.update_preset(preset.uuid, { [field] = value })
    end
  end
  fill("name",    meta.name)
  fill("vendor",  meta.vendor)
  fill("author",  meta.author)
  fill("comment", meta.comment)
  if meta.bankchain and meta.bankchain[2] then
    fill("pack", meta.bankchain[2])
  end

  db.update_preset(preset.uuid, { nks_path = nksf_path })
  return true
end

-- ─── Batch sync all presets ───────────────────────────────────────────────────

--- Writes JSON sidecars for all presets in the DB that have no nks_path yet.
--- @param db      DB module
--- @param config  Config module
--- @param json    table  json encoder
--- @param on_progress function|nil  called with (done, total, name)
--- @return number  count of sidecars written
function NKS.sync_all(db, config, json, on_progress)
  local data = db.get and db.get("") or nil
  if not data then return 0 end

  local queue = {}
  for _, p in pairs(data.presets) do
    if not p.nks_path or p.nks_path == "" then
      queue[#queue + 1] = p
    end
  end
  table.sort(queue, function(a, b) return (a.name or "") < (b.name or "") end)

  local done    = 0
  local success = 0
  for _, p in ipairs(queue) do
    done = done + 1
    if on_progress then on_progress(done, #queue, p.name or "") end
    if NKS.write_sidecar(p, db, config, json) then
      success = success + 1
    end
  end
  return success
end

return NKS
