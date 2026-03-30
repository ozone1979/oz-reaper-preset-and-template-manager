-- Oz PTM UI Widgets.lua
-- Shared ImGui helper widgets: tag pills, waveform thumbnail, icon buttons,
-- color swatches, and small utility drawers.
-- All functions receive the ImGui context (ctx) as first argument.

local Widgets = {}

-- ─── Tag pill ────────────────────────────────────────────────────────────────

--- Draws a colored rounded-rect label for a tag.
--- Returns true if the pill was clicked (left-click), or "right" for right-click.
--- @param ctx       ImGui context
--- @param tag       tag record { name, color_r, color_g, color_b }
--- @param config    Config module (for pill dimensions)
--- @param tags_mod  Tags module (for color helpers)
function Widgets.tag_pill(ctx, tag, config, tags_mod)
  local label = tag.name or "?"
  local bg    = tags_mod.tag_color_u32(tag)
  local fg    = tags_mod.contrast_color(bg)
  local r     = config.TAG_PILL_RADIUS

  local ImGui = reaper
  local tx, ty = ImGui.ImGui_GetCursorScreenPos(ctx)
  local tw = ImGui.ImGui_CalcTextSize(ctx, label) + 14  -- padding
  local th = config.TAG_PILL_H

  -- Invisible button for interaction
  ImGui.ImGui_InvisibleButton(ctx, "##pill_" .. tag.uuid, tw, th)
  local clicked       = ImGui.ImGui_IsItemClicked(ctx, 0)  -- left
  local right_clicked = ImGui.ImGui_IsItemClicked(ctx, 1)  -- right
  local hovered       = ImGui.ImGui_IsItemHovered(ctx)

  local draw = ImGui.ImGui_GetWindowDrawList(ctx)
  local bg_col = hovered and tags_mod.tag_color_u32({ -- slightly lighter on hover
    color_r = math.min(1, (tag.color_r or 0.5) * 1.15),
    color_g = math.min(1, (tag.color_g or 0.5) * 1.15),
    color_b = math.min(1, (tag.color_b or 0.5) * 1.15),
    color_a = tag.color_a or 1.0,
  }) or bg

  ImGui.ImGui_DrawList_AddRectFilled(draw, tx, ty, tx + tw, ty + th, bg_col, r)
  ImGui.ImGui_DrawList_AddText(draw, tx + 7, ty + (th - 13) * 0.5, fg, label)

  if clicked       then return "click" end
  if right_clicked then return "right" end
  return false
end

--- Draws a row of tag pills for a preset, with an "+" add button at the end.
--- @param ctx    ImGui context
--- @param preset_record  the preset (has .tags = list of uuids)
--- @param db     DB module
--- @param config Config module
--- @param tags   Tags module
--- @return string|false  "add" or a tag uuid if that pill was right-clicked
function Widgets.tag_row(ctx, preset_record, db, config, tags)
  local result = false
  local ImGui  = reaper
  ImGui.ImGui_PushID(ctx, "tag_row_" .. (preset_record.uuid or "?"))

  local spacing = 4
  for i, tag_uuid in ipairs(preset_record.tags or {}) do
    local t = db.get_tag(tag_uuid)
    if t then
      if i > 1 then
        ImGui.ImGui_SameLine(ctx, 0, spacing)
      end
      local ev = Widgets.tag_pill(ctx, t, config, tags)
      if ev == "right" then result = tag_uuid end
    end
  end

  -- "+" button
  ImGui.ImGui_SameLine(ctx, 0, spacing)
  if ImGui.ImGui_SmallButton(ctx, "+##addtag") then
    result = "add"
  end

  ImGui.ImGui_PopID(ctx)
  return result
end

-- ─── Waveform thumbnail ──────────────────────────────────────────────────────

--- Draws a simple waveform thumbnail from a peak table (list of 0-1 amplitudes).
--- @param ctx       ImGui context
--- @param peaks     table  list of normalized amplitude values (0-1)
--- @param w         number  width in pixels
--- @param h         number  height in pixels
--- @param pal       palette table
function Widgets.waveform(ctx, peaks, w, h, pal)
  local ImGui = reaper
  local x, y = ImGui.ImGui_GetCursorScreenPos(ctx)
  ImGui.ImGui_InvisibleButton(ctx, "##waveform", w, h)
  local hovered = ImGui.ImGui_IsItemHovered(ctx)

  local draw = ImGui.ImGui_GetWindowDrawList(ctx)
  local bg   = pal.waveform_bg or pal.panel_bg or 0xFF22262A
  local fill = pal.waveform_fill or pal.accent or 0xFF22AA66
  if hovered then fill = pal.accent_hover or fill end

  ImGui.ImGui_DrawList_AddRectFilled(draw, x, y, x + w, y + h, bg, 2)

  if not peaks or #peaks == 0 then
    ImGui.ImGui_DrawList_AddText(draw, x + 4, y + h * 0.5 - 6, pal.text_dim, "no preview")
    return
  end

  local step = w / #peaks
  local mid  = y + h * 0.5

  for i, amp in ipairs(peaks) do
    local px = x + (i - 1) * step
    local half = amp * (h * 0.5 - 2)
    ImGui.ImGui_DrawList_AddLine(draw, px + step * 0.5, mid - half, px + step * 0.5, mid + half, fill, math.max(1, step - 1))
  end

  ImGui.ImGui_DrawList_AddRect(draw, x, y, x + w, y + h, pal.border or 0xFF404044, 2)
end

--- Generates a simple peak table from an OGG file using REAPER's PCM source.
--- Returns a table of N peaks (normalized 0-1), or nil on failure.
--- @param path string   absolute path to OGG file
--- @param num_peaks number  desired resolution (e.g. 200)
function Widgets.compute_peaks(path, num_peaks)
  if not path or path == "" then return nil end
  local src = reaper.PCM_Source_CreateFromFile(path)
  if not src then return nil end

  local dur = reaper.GetMediaSourceLength(src, false)
  if not dur or dur <= 0 then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  -- Use an accessor to read samples
  local accessor = reaper.CreatePCMSourceAccessor(src)
  if not accessor then
    reaper.PCM_Source_Destroy(src)
    return nil
  end

  num_peaks = num_peaks or 200
  local peaks    = {}
  local buf_size = 512
  local sr       = 44100

  for i = 1, num_peaks do
    local t = (i - 0.5) / num_peaks * dur
    local start_spl = math.floor(t * sr)
    local buf = reaper.new_array(buf_size * 2)  -- stereo interleaved
    reaper.PCM_Source_AccessRead(accessor, buf, buf_size, start_spl, 1, false)
    local max_amp = 0
    for j = 1, buf_size * 2 do
      local s = math.abs(buf[j] or 0)
      if s > max_amp then max_amp = s end
    end
    peaks[i] = math.min(1, max_amp)
  end

  reaper.DestroyPCM_Source_AccessorResult(accessor)
  reaper.PCM_Source_Destroy(src)
  return peaks
end

-- ─── Icon button ─────────────────────────────────────────────────────────────

--- A small square button with a text glyph label (e.g. "▶", "✕", "✎").
--- Returns true if clicked.
--- @param ctx    ImGui context
--- @param id     string  unique id suffix
--- @param glyph  string  display text
--- @param size   number  button side length
--- @param pal    palette
function Widgets.icon_button(ctx, id, glyph, size, pal)
  local ImGui = reaper
  ImGui.ImGui_PushStyleColor(ctx, 21, pal and pal.widget_bg or 0xFF3A3A3E)  -- Button
  local clicked = ImGui.ImGui_Button(ctx, glyph .. "##" .. id, size, size)
  ImGui.ImGui_PopStyleColor(ctx, 1)
  return clicked
end

-- ─── Color swatch ────────────────────────────────────────────────────────────

--- Draws a small colored square. Returns true if clicked (to open color picker).
--- @param ctx   ImGui context
--- @param id    string
--- @param r g b a  0-1 floats
--- @param size  number
function Widgets.color_swatch(ctx, id, r, g, b, a, size)
  local ImGui = reaper
  size = size or 16
  local u32 = (math.floor((a or 1) * 255) << 24) |
               (math.floor((b or 0) * 255) << 16) |
               (math.floor((g or 0) * 255) << 8)  |
                math.floor((r or 0) * 255)

  local sx, sy = ImGui.ImGui_GetCursorScreenPos(ctx)
  ImGui.ImGui_InvisibleButton(ctx, "##swatch_" .. id, size, size)
  local clicked = ImGui.ImGui_IsItemClicked(ctx, 0)
  local draw    = ImGui.ImGui_GetWindowDrawList(ctx)
  ImGui.ImGui_DrawList_AddRectFilled(draw, sx, sy, sx + size, sy + size, u32, 2)
  ImGui.ImGui_DrawList_AddRect(draw, sx, sy, sx + size, sy + size, 0xFF888888, 2)
  return clicked, r, g, b, a
end

-- ─── Section header ──────────────────────────────────────────────────────────

--- Draws a styled section divider with label.
--- @param ctx  ImGui context
--- @param label string
--- @param pal  palette
function Widgets.section_header(ctx, label, pal)
  local ImGui = reaper
  ImGui.ImGui_Separator(ctx)
  ImGui.ImGui_PushStyleColor(ctx, 0, pal and pal.text_header or 0xFFFFFFFF)
  ImGui.ImGui_Text(ctx, label)
  ImGui.ImGui_PopStyleColor(ctx, 1)
  ImGui.ImGui_Separator(ctx)
end

-- ─── Editable text field (single) ────────────────────────────────────────────

--- Draws an inline text input. Returns the new string if changed, or nil.
--- @param ctx   ImGui context
--- @param id    string
--- @param label string  left-side label
--- @param value string  current value
--- @param width number  input field width
function Widgets.labeled_input(ctx, id, label, value, width)
  local ImGui = reaper
  ImGui.ImGui_Text(ctx, label)
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_SetNextItemWidth(ctx, width or 200)
  local changed, new_val = ImGui.ImGui_InputText(ctx, "##" .. id, value or "", 512)
  if changed then return new_val end
  return nil
end

--- Draws a multi-line text input. Returns the new string if changed, or nil.
function Widgets.labeled_multiline(ctx, id, label, value, width, height)
  local ImGui = reaper
  ImGui.ImGui_Text(ctx, label)
  ImGui.ImGui_SetNextItemWidth(ctx, width or 200)
  local changed, new_val = ImGui.ImGui_InputTextMultiline(ctx, "##" .. id, value or "", 2048, width or 200, height or 80)
  if changed then return new_val end
  return nil
end

-- ─── Confirmation modal ──────────────────────────────────────────────────────

--- Opens a confirmation modal. Returns "yes", "no", or nil (still open).
--- Call every frame while the modal should be open.
--- @param ctx      ImGui context
--- @param title    string
--- @param message  string
--- @param pal      palette
function Widgets.confirm_modal(ctx, title, message, pal)
  local ImGui = reaper
  local result = nil

  if not ImGui.ImGui_IsPopupOpen(ctx, title) then
    ImGui.ImGui_OpenPopup(ctx, title)
  end

  local open = true
  if ImGui.ImGui_BeginPopupModal(ctx, title, open, ImGui.ImGui_WindowFlags_AlwaysAutoResize and ImGui.ImGui_WindowFlags_AlwaysAutoResize(ctx) or 0) then
    ImGui.ImGui_Text(ctx, message)
    ImGui.ImGui_Spacing(ctx)
    if ImGui.ImGui_Button(ctx, "Yes", 80, 0) then
      result = "yes"
      ImGui.ImGui_CloseCurrentPopup(ctx)
    end
    ImGui.ImGui_SameLine(ctx)
    if ImGui.ImGui_Button(ctx, "No", 80, 0) then
      result = "no"
      ImGui.ImGui_CloseCurrentPopup(ctx)
    end
    ImGui.ImGui_EndPopup(ctx)
  end

  return result
end

return Widgets
