-- Oz PTM Config.lua
-- Central constants, ext-state keys, and default path configuration.
-- All other modules require this via the loader.

local Config = {}

-- ─── Extension state section ────────────────────────────────────────────────
Config.EXT_SECTION          = "OZ_PTM"
Config.PANEL_SECTION        = "OZ_PTM_PANEL"

-- Ext-state keys
Config.KEY_DB_PATH          = "DB_PATH"
Config.KEY_SCAN_ROOTS       = "SCAN_ROOTS_JSON"
Config.KEY_WINDOW_X         = "WINDOW_X"
Config.KEY_WINDOW_Y         = "WINDOW_Y"
Config.KEY_WINDOW_W         = "WINDOW_W"
Config.KEY_WINDOW_H         = "WINDOW_H"
Config.KEY_DOCK_STATE       = "DOCK_STATE"
Config.KEY_LAST_TAB         = "LAST_TAB"
Config.KEY_CLOUD_ZOOM        = "CLOUD_ZOOM"
Config.KEY_CLOUD_PAN_X       = "CLOUD_PAN_X"
Config.KEY_CLOUD_PAN_Y       = "CLOUD_PAN_Y"
Config.KEY_SORT_FIELD        = "SORT_FIELD"
Config.KEY_SORT_DIR          = "SORT_DIR"
Config.KEY_FILTER_TYPE       = "FILTER_TYPE"
Config.KEY_SEARCH_TEXT       = "SEARCH_TEXT"

-- ─── Database ────────────────────────────────────────────────────────────────
Config.DB_VERSION            = 2
Config.DB_FILENAME           = "ptm_db.json"

-- ─── Preset / template file extensions ──────────────────────────────────────
Config.FX_PRESET_EXT         = ".reabank"          -- per-plugin presets (also VST .fxp/.fxb)
Config.FX_CHAIN_EXT          = ".rfxchain"
Config.TRACK_TEMPLATE_EXT    = ".RTrackTemplate"
Config.INSTRUMENT_BANK_EXT   = ".reabank"

-- All supported extensions (lower-cased for comparison)
Config.SUPPORTED_EXTS = {
  [".rfxchain"]        = "fx_chain",
  [".rtracktemplate"]  = "track_template",
  [".fxp"]             = "fx_preset",
  [".fxb"]             = "fx_preset",
  [".vstpreset"]       = "fx_preset",
  [".reabank"]         = "instrument_bank",
}

-- ─── Preview / render ────────────────────────────────────────────────────────
Config.PREVIEW_EXT           = ".ogg"
Config.PREVIEW_MIDI_NOTE     = 60     -- Middle C (C3 in Reaper's default numbering)
Config.PREVIEW_MIDI_VEL      = 100
Config.PREVIEW_MIDI_DUR      = 2.0    -- seconds
Config.PREVIEW_RENDER_DUR    = 4.0    -- total render length including tail
Config.PREVIEW_SAMPLE_RATE   = 44100
Config.PREVIEW_CHANNELS      = 2
Config.PREVIEW_OGG_QUALITY   = 0.7    -- 0–1; 0.7 ≈ ~128 kbps equivalent

-- ─── NKS ─────────────────────────────────────────────────────────────────────
Config.NKS_META_EXT          = ".nks_meta.json"    -- lightweight sidecar we always write
Config.NKSF_EXT              = ".nksf"             -- full NI NKS file (ZIP+JSON, optional)

-- ─── Similarity / cloud ───────────────────────────────────────────────────────
Config.SIM_VEC_DIM           = 32     -- MFCC-style feature vector length
Config.SIM_TSNE_ITERS        = 500
Config.SIM_TSNE_PERPLEXITY   = 30
Config.CLOUD_DOT_RADIUS      = 6
Config.CLOUD_DOT_HOVER_RADIUS = 9

-- ─── UI ──────────────────────────────────────────────────────────────────────
Config.WINDOW_TITLE          = "Oz Preset & Template Manager"
Config.DEFAULT_W             = 1100
Config.DEFAULT_H             = 680
Config.BROWSER_PANEL_W       = 280   -- left panel default width
Config.DETAIL_PANEL_W        = 320   -- right panel default width
Config.TAG_PILL_H            = 20
Config.TAG_PILL_RADIUS       = 4
Config.WAVEFORM_H            = 60
Config.GRID_ROW_H            = 22
Config.GRID_COL_NAME_W       = 260
Config.GRID_COL_TYPE_W       = 110
Config.GRID_COL_PACK_W       = 140
Config.GRID_COL_AUTHOR_W     = 120
Config.GRID_COL_DATE_W       = 90

-- Tab identifiers
Config.TAB_BROWSER           = 1
Config.TAB_CLOUD             = 2
Config.TAB_SETTINGS          = 3
Config.TAB_LABELS            = { "Browser", "Similarity Cloud", "Settings" }

-- ─── Metadata field definitions (for UI + NKS + DB) ──────────────────────────
Config.META_FIELDS = {
  { key = "name",    label = "Name",    editable = true  },
  { key = "author",  label = "Author",  editable = true  },
  { key = "vendor",  label = "Vendor",  editable = true  },
  { key = "pack",    label = "Pack",    editable = true  },
  { key = "date",    label = "Date",    editable = false },
  { key = "comment", label = "Comment", editable = true, multiline = true },
  { key = "type",    label = "Type",    editable = false },
  { key = "path",    label = "Path",    editable = false },
}

-- ─── Helpers ─────────────────────────────────────────────────────────────────

--- Returns the directory where OzPTM stores its database and cache files.
--- Creates it if it does not exist.
function Config.get_data_dir()
  local res = reaper.GetResourcePath()
  local dir = res .. "/OzPTM"
  -- reaper.RecursiveCreateDirectory is available in Reaper ≥ 5.965
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

--- Returns full path to the JSON database file.
function Config.get_db_path()
  local custom = reaper.GetExtState(Config.EXT_SECTION, Config.KEY_DB_PATH)
  if custom and custom ~= "" then return custom end
  return Config.get_data_dir() .. "/" .. Config.DB_FILENAME
end

--- Reads a number from ext-state, returning default if absent.
function Config.get_ext_num(key, default)
  local v = reaper.GetExtState(Config.EXT_SECTION, key)
  return (v and v ~= "") and tonumber(v) or default
end

--- Reads a string from ext-state, returning default if absent.
function Config.get_ext_str(key, default)
  local v = reaper.GetExtState(Config.EXT_SECTION, key)
  return (v and v ~= "") and v or default
end

--- Persists a value to ext-state (converts to string).
function Config.set_ext(key, value)
  reaper.SetExtState(Config.EXT_SECTION, key, tostring(value), true)
end

return Config
