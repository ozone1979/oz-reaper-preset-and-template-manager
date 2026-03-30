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
  local r, g, b = reaper.ColorFromNative(reaper_color)
  r = (r or 0) / 255.0
  g = (g or 0) / 255.0
  b = (b or 0) / 255.0
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, 1.0)
  end
  return (0xFF000000) | ((b * 255) << 16) | ((g * 255) << 8) | (r * 255)
end

--- Safely unpack an ImGui u32 color into r, g, b, a (all 0-1 floats).
local function unpack_u32(c)
  if reaper.ImGui_ColorConvertU32ToDouble4 then
    local r, g, b, a = reaper.ImGui_ColorConvertU32ToDouble4(c)
    return r, g, b, a
  end
  -- Fallback: parse manually (ABGR layout)
  local b2 = ((c >> 16) & 0xFF) / 255.0
  local g2 = ((c >> 8)  & 0xFF) / 255.0
  local r2 = ( c        & 0xFF) / 255.0
  local a2 = ((c >> 24) & 0xFF) / 255.0
  return r2, g2, b2, a2
end

--- Blend two u32 colors. t=0 → a, t=1 → b.
local function blend_u32(a, b, t)
  local ar, ag, ab, aa = unpack_u32(a)
  local br, bg, bb, ba = unpack_u32(b)
  local function lerp(x, y) return x + (y - x) * t end
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(
      lerp(ar, br), lerp(ag, bg), lerp(ab, bb), lerp(aa, ba)
    )
  end
  return a
end

--- Darken a u32 color by factor (0=black, 1=unchanged).
local function darken(c, factor)
  local r, g, b, a = unpack_u32(c)
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(
      math.max(0, math.min(1, r * factor)),
      math.max(0, math.min(1, g * factor)),
      math.max(0, math.min(1, b * factor)),
      a
    )
  end
  return c
end

--- Lighten a u32 color by factor (1=unchanged, 1.5=50% lighter clamped).
local function lighten(c, factor)
  local r, g, b, a = unpack_u32(c)
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(
      math.max(0, math.min(1, r * factor)),
      math.max(0, math.min(1, g * factor)),
      math.max(0, math.min(1, b * factor)),
      a
    )
  end
  return c
end

--- Determines if a color is "dark" (luminance < 0.5).
local function is_dark(c)
  local r, g, b = unpack_u32(c)
  return (0.299 * r + 0.587 * g + 0.114 * b) < 0.5
end

--- u32 with explicit alpha override.
local function with_alpha(c, a)
  local r, g, b = unpack_u32(c)
  if reaper.ImGui_ColorConvertDouble4ToU32 then
    return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
  end
  return c
end

--- Returns true if green channel dominates red and blue.
local function is_greenish(c)
  local r, g, b = unpack_u32(c)
  return (g > r * 1.05) and (g > b * 1.05)
end

-- ─── Fallback hard-coded dark palette (used when Reaper API unavailable) ─────

local FALLBACK_DARK = {
  bg             = 0xFF2A2A2E,
  bg_alt         = 0xFF232327,
  panel_bg       = 0xFF1F1F23,
  widget_bg      = 0xFF3A3A3E,
  widget_active  = 0xFF3C5A3C,
  border         = 0xFF404044,
  text           = 0xFFDDDDDD,
  text_dim       = 0xFF888888,
  text_header    = 0xFFFFFFFF,
  accent         = 0xFF22AA66,
  accent_hover   = 0xFF33CC88,
  accent_active  = 0xFF1A8A52,
  danger         = 0xFFBB4444,
  success        = 0xFF44AA88,
  waveform_fill  = 0xFF22AA66,
  waveform_bg    = 0xFF1A1A22,
  cloud_bg       = 0xFF1D2420,
  scrollbar_bg   = 0xFF2A2A2E,
  scrollbar_grab = 0xFF556655,
  tag_default    = 0xFF4B6E54,
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

    -- Prefer genuinely green theme keys; avoid inheriting cyan/blue selection accents.
    local cursor_raw = get("col_cursor")
    local cursor_col = cursor_raw and darken(cursor_raw, 0.65) or nil

    local accent_candidates = {
      cursor_col,
      get("col_marker"),
      get("col_toolbar_text_on"),
      get("toolbararmed_color"),
      get("col_selitemmarker"),
    }
    local sel = nil
    for _, c in ipairs(accent_candidates) do
      if c and is_greenish(c) then
        sel = c
        break
      end
    end

    if not sel then
      -- No greenish key available: lock to a stable green baseline.
      sel = FALLBACK_DARK.accent
    else
      -- Keep theme relation but nudge toward green so tabs/highlights don't drift cyan.
      sel = blend_u32(sel, FALLBACK_DARK.accent, 0.35)
    end

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
  local function col(name)
    local fn = reaper["ImGui_Col_" .. name]
    if type(fn) == "function" then
      return fn()
    end
    return nil
  end

  local pushed = 0
  local function push_if(name, value)
    local cid = col(name)
    if cid ~= nil then
      push(ctx, cid, value)
      pushed = pushed + 1
    end
  end

  if Theme.USE_NATIVE_REAPER_STYLE then
    -- Keep REAPER visual language, but lock panel surfaces and accents to theme-derived palette.
    push_if("WindowBg",       pal.bg)
    push_if("ChildBg",        pal.panel_bg)
    push_if("PopupBg",        pal.panel_bg)
    push_if("FrameBg",        pal.widget_bg)
    push_if("FrameBgHovered", pal.widget_hovered or pal.widget_bg)
    push_if("FrameBgActive",  pal.widget_active or pal.accent)
    push_if("TitleBg",        pal.bg_alt)
    push_if("TitleBgActive",  pal.bg_alt)
    push_if("Button",         pal.widget_bg)
    push_if("Header",         with_alpha(pal.accent, 0.30))
    push_if("HeaderHovered",  with_alpha(pal.accent, 0.55))
    push_if("HeaderActive",   with_alpha(pal.accent, 0.80))
    push_if("Tab",            with_alpha(pal.accent, 0.45))
    push_if("TabHovered",     with_alpha(pal.accent, 0.85))
    push_if("TabActive",      with_alpha(pal.accent, 1.00))
    push_if("CheckMark",      pal.accent)
    push_if("SliderGrab",     pal.accent)
    push_if("ButtonHovered",  pal.accent_hover or pal.accent)
    push_if("ButtonActive",   pal.accent_active or pal.accent)
    return pushed
  end

  push_if("WindowBg",       pal.bg)
  push_if("ChildBg",        pal.panel_bg)
  push_if("PopupBg",        pal.panel_bg)
  push_if("Border",         pal.border)
  push_if("FrameBg",        pal.widget_bg)
  push_if("FrameBgHovered", pal.widget_hovered or pal.widget_bg)
  push_if("FrameBgActive",  pal.widget_active  or pal.accent)
  push_if("TitleBg",        pal.panel_bg)
  push_if("TitleBgActive",  pal.bg_alt)
  push_if("MenuBarBg",      pal.bg_alt)
  push_if("ScrollbarBg",    pal.scrollbar_bg)
  push_if("ScrollbarGrab",  pal.scrollbar_grab)
  push_if("CheckMark",      pal.accent)
  push_if("SliderGrab",     pal.accent)
  push_if("Button",         pal.widget_bg)
  push_if("ButtonHovered",  pal.accent_hover or pal.accent)
  push_if("ButtonActive",   pal.accent_active or pal.accent)
  push_if("Header",         with_alpha(pal.accent, 0.35))
  push_if("HeaderHovered",  with_alpha(pal.accent, 0.55))
  push_if("HeaderActive",   with_alpha(pal.accent, 0.80))
  push_if("Separator",      pal.border)
  push_if("Text",           pal.text)
  push_if("TextDisabled",   pal.text_dim)
  push_if("Tab",            pal.widget_bg)
  push_if("TabHovered",     pal.accent_hover or pal.accent)
  push_if("TabActive",      pal.accent)

  return pushed
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
