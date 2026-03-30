-- Oz PTM Theme.lua
-- Reads Reaper's active theme colors via reaper.GetThemeColor() and returns
-- a palette table used to style all ImGui panels, so the tool feels native
-- to whatever Reaper skin the user has loaded.
--
-- Color convention: all colors are returned as ImGui u32 integers (0xAABBGGRR)
-- unless the name ends in _f4, which returns a 4-element array {r,g,b,a} 0-1.

local Theme = {}
Theme.USE_NATIVE_REAPER_STYLE = true

-- ─── Reaper theme color key names (see reaper-theme docs) ────────────────────
-- We query a curated subset and derive the rest.

local REAPER_KEYS = {
  -- Main window background
  col_main_bg        = "col_main_bg",
  col_main_bg2       = "col_main_bg2",
  col_main_text      = "col_main_text",
  col_main_textshadow = "col_main_textshadow",
  col_main_editbk    = "col_main_editbk",
  col_main_3dhl      = "col_main_3dhl",
  col_main_3dsh      = "col_main_3dsh",
  col_main_resize2   = "col_main_resize2",
  -- Track panel
  col_trkpanel_bg    = "col_trkpanel_bg",
  col_trkpanel_text  = "col_trkpanel_text",
  -- MCP
  col_mcp_bg         = "col_mcp_bg",
  -- Transport
  col_trans_bg       = "col_trans_bg",
  -- Selection / highlight
  col_selitem        = "col_selitem",
  col_selitemmarker  = "col_selitemmarker",
  col_cursor         = "col_cursor",
  -- Markers
  col_marker         = "col_marker",
  col_region         = "col_region",
}

-- ─── Helpers ─────────────────────────────────────────────────────────────────

--- Convert Reaper native theme color to ImGui u32 ABGR with full alpha.
local function reaper_to_imgui(reaper_color)
  -- Use API conversion to avoid channel-order ambiguity across platforms/builds.
  local r, g, b = reaper.ColorFromNative(reaper_color)
  r = r or 0
  g = g or 0
  b = b or 0
  return (0xFF000000) | (b << 16) | (g << 8) | r
end

--- Blend two u32 colors. t=0 → a, t=1 → b.
local function blend_u32(a, b, t)
  local function chan(x, shift) return (x >> shift) & 0xFF end
  local function lerp(x, y) return math.floor(x + (y - x) * t + 0.5) end
  local r = lerp(chan(a, 0),  chan(b, 0))
  local g = lerp(chan(a, 8),  chan(b, 8))
  local bb = lerp(chan(a, 16), chan(b, 16))
  local aa = lerp(chan(a, 24), chan(b, 24))
  return (aa << 24) | (bb << 16) | (g << 8) | r
end

--- Darken a u32 color by factor (0=black, 1=unchanged).
local function darken(c, factor)
  local function d(x) return math.floor(x * factor + 0.5) end
  local r = d((c)       & 0xFF)
  local g = d((c >> 8)  & 0xFF)
  local b = d((c >> 16) & 0xFF)
  local a = (c >> 24) & 0xFF
  return (a << 24) | (b << 16) | (g << 8) | r
end

--- Lighten a u32 color by factor (1=unchanged, 1.5=50% lighter clamped).
local function lighten(c, factor)
  local function l(x) return math.min(255, math.floor(x * factor + 0.5)) end
  local r = l((c)       & 0xFF)
  local g = l((c >> 8)  & 0xFF)
  local b = l((c >> 16) & 0xFF)
  local a = (c >> 24) & 0xFF
  return (a << 24) | (b << 16) | (g << 8) | r
end

--- Determines if a color is "dark" (luminance < 0.5).
local function is_dark(c)
  local r = (c)       & 0xFF
  local g = (c >> 8)  & 0xFF
  local b = (c >> 16) & 0xFF
  return (0.299 * r + 0.587 * g + 0.114 * b) < 128
end

--- u32 with explicit alpha
local function with_alpha(c, a)
  return ((c) & 0x00FFFFFF) | (math.floor(a * 255 + 0.5) << 24)
end

-- ─── Fallback hard-coded dark palette (used when Reaper API unavailable) ─────

local FALLBACK_DARK = {
  bg             = 0xFF2A2A2E,
  bg_alt         = 0xFF232327,
  panel_bg       = 0xFF1F1F23,
  widget_bg      = 0xFF3A3A3E,
  widget_active  = 0xFF5050AA,
  border         = 0xFF404044,
  text           = 0xFFDDDDDD,
  text_dim       = 0xFF888888,
  text_header    = 0xFFFFFFFF,
  accent         = 0xFF22AA66,
  accent_hover   = 0xFF33CC88,
  accent_active  = 0xFF1A8A52,
  danger         = 0xFFBB4444,
  success        = 0xFF44AA88,
  waveform_fill  = 0xFF3366CC,
  waveform_bg    = 0xFF1A1A22,
  cloud_bg       = 0xFF121216,
  scrollbar_bg   = 0xFF2A2A2E,
  scrollbar_grab = 0xFF555566,
  tag_default    = 0xFF446688,
}

-- ─── Build palette from Reaper theme ─────────────────────────────────────────

--- Queries Reaper theme colors and builds the PTM palette.
--- Should be called once per frame (or on theme change).
--- @return table  palette with u32 color fields
function Theme.build_palette()
  local pal = {}

  -- Attempt to read Reaper theme colors
  local ok = pcall(function()
    local function get(key)
      -- GetThemeColor returns int, or -1 on failure
      local v = reaper.GetThemeColor(key, 0)
      return (v and v ~= -1) and reaper_to_imgui(v) or nil
    end

    local main_bg   = get("col_main_bg2")  or get("col_main_bg") or FALLBACK_DARK.bg
    local main_bg2  = get("col_main_bg")   or FALLBACK_DARK.bg_alt
    local main_text = get("col_main_text") or FALLBACK_DARK.text
    local panel_bg  = get("col_trkpanel_bg") or main_bg
    local edit_bg   = get("col_main_editbk") or FALLBACK_DARK.widget_bg
    local hi_3d     = get("col_main_3dhl") or FALLBACK_DARK.border
    local accent_theme = get("col_toolbar_text_on") or get("toolbararmed_color") or get("col_main_text2")
    local sel          = accent_theme or get("col_selitem") or FALLBACK_DARK.accent

    local dark_mode = is_dark(main_bg)

    -- Core surfaces
    pal.bg             = main_bg
    pal.bg_alt         = main_bg2 or darken(main_bg, 0.85)
    pal.panel_bg       = panel_bg or darken(main_bg, 0.92)
    pal.widget_bg      = edit_bg
    pal.border         = hi_3d or blend_u32(main_bg, main_text, 0.15)

    -- Text
    pal.text           = main_text
    pal.text_dim       = with_alpha(main_text, 0.5)
    pal.text_header    = lighten(main_text, 1.1)

    -- Accent (derived from selection color)
    pal.accent         = sel
    pal.accent_hover   = lighten(sel, 1.15)
    pal.accent_active  = darken(sel, 0.85)

    -- Widget states
    pal.widget_hovered = dark_mode and lighten(edit_bg, 1.2) or darken(edit_bg, 0.9)
    pal.widget_active  = dark_mode and lighten(edit_bg, 1.4) or darken(edit_bg, 0.8)

    -- Specific UI zones
    pal.danger         = 0xFFBB4444
    pal.success        = 0xFF44AA88
    pal.waveform_fill  = sel
    pal.waveform_bg    = darken(main_bg, 0.6)
    pal.cloud_bg       = darken(main_bg, 0.7)
    pal.scrollbar_bg   = darken(main_bg, 0.8)
    pal.scrollbar_grab = blend_u32(main_bg, main_text, 0.25)
    pal.tag_default    = blend_u32(sel, main_bg, 0.4)
  end)

  if not ok then
    -- Fall back to hard-coded dark palette
    for k, v in pairs(FALLBACK_DARK) do pal[k] = v end
  end

  return pal
end

-- ─── Apply palette to ImGui style ────────────────────────────────────────────

--- Pushes PTM palette into the ImGui style color stack.
--- Call this at the start of each Begin(), pop with pop_style().
--- @param ctx   ImGui context handle
--- @param pal   palette table from build_palette()
--- @return number  number of colors pushed (pass to PopStyleColor)
function Theme.push_style(ctx, pal)
  if not ctx or not reaper.ImGui_PushStyleColor then return 0 end

  local push = reaper.ImGui_PushStyleColor
  local function col(name, fallback)
    local fn = reaper["ImGui_Col_" .. name]
    if type(fn) == "function" then
      return fn()
    end
    return fallback
  end

  if Theme.USE_NATIVE_REAPER_STYLE then
    -- Keep native style baseline, but force panel surfaces + accent slots to REAPER-derived colors.
    push(ctx, col("WindowBg",       2), pal.bg)
    push(ctx, col("ChildBg",        3), pal.panel_bg)
    push(ctx, col("PopupBg",        4), pal.panel_bg)
    push(ctx, col("FrameBg",        7), pal.widget_bg)
    push(ctx, col("FrameBgHovered", 8), pal.widget_hovered or pal.widget_bg)
    push(ctx, col("FrameBgActive",  9), pal.widget_active or pal.accent)
    push(ctx, col("TitleBg",       10), pal.bg_alt)
    push(ctx, col("TitleBgActive", 11), pal.bg_alt)
    push(ctx, col("Header",        24), with_alpha(pal.accent, 0.30))
    push(ctx, col("HeaderHovered", 25), with_alpha(pal.accent, 0.55))
    push(ctx, col("HeaderActive",  26), with_alpha(pal.accent, 0.80))
    push(ctx, col("Tab",           33), pal.widget_bg)
    push(ctx, col("TabHovered",    34), with_alpha(pal.accent, 0.85))
    push(ctx, col("TabActive",     35), with_alpha(pal.accent, 1.00))
    push(ctx, col("CheckMark",     18), pal.accent)
    push(ctx, col("SliderGrab",    19), pal.accent)
    push(ctx, col("Button",        21), pal.widget_bg)
    push(ctx, col("ButtonHovered", 22), pal.accent_hover or pal.accent)
    push(ctx, col("ButtonActive",  23), pal.accent_active or pal.accent)
    return 16
  end

  push(ctx, col("WindowBg",       2),  pal.bg)
  push(ctx, col("ChildBg",        3),  pal.panel_bg)
  push(ctx, col("PopupBg",        4),  pal.panel_bg)
  push(ctx, col("Border",         5),  pal.border)
  push(ctx, col("FrameBg",        7),  pal.widget_bg)
  push(ctx, col("FrameBgHovered", 8),  pal.widget_hovered or pal.widget_bg)
  push(ctx, col("FrameBgActive",  9),  pal.widget_active  or pal.accent)
  push(ctx, col("TitleBg",       10),  pal.panel_bg)
  push(ctx, col("TitleBgActive", 11),  pal.bg_alt)
  push(ctx, col("MenuBarBg",     13),  pal.bg_alt)
  push(ctx, col("ScrollbarBg",   14),  pal.scrollbar_bg)
  push(ctx, col("ScrollbarGrab", 15),  pal.scrollbar_grab)
  push(ctx, col("CheckMark",     18),  pal.accent)
  push(ctx, col("SliderGrab",    19),  pal.accent)
  push(ctx, col("Button",        21),  pal.widget_bg)
  push(ctx, col("ButtonHovered", 22),  pal.accent_hover or pal.accent)
  push(ctx, col("ButtonActive",  23),  pal.accent_active or pal.accent)
  push(ctx, col("Header",        24),  with_alpha(pal.accent, 0.35))
  push(ctx, col("HeaderHovered", 25),  with_alpha(pal.accent, 0.55))
  push(ctx, col("HeaderActive",  26),  with_alpha(pal.accent, 0.80))
  push(ctx, col("Separator",     27),  pal.border)
  push(ctx, col("Text",           0),  pal.text)
  push(ctx, col("TextDisabled",   1),  pal.text_dim)
  push(ctx, col("Tab",           33),  pal.widget_bg)
  push(ctx, col("TabHovered",    34),  pal.accent_hover or pal.accent)
  push(ctx, col("TabActive",     35),  pal.accent)

  return 26  -- number of push calls
end

--- Pops previously pushed style colors.
--- @param ctx  ImGui context
--- @param count number  value returned by push_style
function Theme.pop_style(ctx, count)
  if ctx and reaper.ImGui_PopStyleColor and count and count > 0 then
    reaper.ImGui_PopStyleColor(ctx, count)
  end
end

-- ─── Expose helpers for other modules ────────────────────────────────────────

Theme.blend    = blend_u32
Theme.darken   = darken
Theme.lighten  = lighten
Theme.with_alpha = with_alpha
Theme.is_dark  = is_dark

return Theme
