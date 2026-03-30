-- Oz PTM UI Detail.lua
-- Right-column detail panel: metadata editor, tag editor, waveform preview,
-- and action buttons for a single selected preset.

local Detail = {}

-- ─── State constructor ───────────────────────────────────────────────────────

function Detail.new_state()
  return {
    last_uuid     = nil,    -- uuid of the preset last displayed
    peaks         = nil,    -- waveform peak table (computed once per preset)
    peaks_loading = false,  -- true while computing peaks
    edit_buffers  = {},     -- { field_key = current_string }
    tag_picker_open = false,
    color_picker_tag = nil, -- tag uuid currently being re-colored
    color_picker_rgba = { 0.5, 0.5, 0.5, 1.0 },
    confirm_remove_tag = nil, -- tag uuid awaiting removal confirm
  }
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function sync_buffers(state, preset, config)
  for _, f in ipairs(config.META_FIELDS) do
    if f.editable then
      state.edit_buffers[f.key] = preset[f.key] or ""
    end
  end
end

-- ─── Main draw function ───────────────────────────────────────────────────────

--- Draw the detail panel for the selected preset.
--- @param ctx        ImGui context
--- @param preset     preset record (or nil if nothing selected)
--- @param state      table from Detail.new_state()
--- @param db         DB module
--- @param config     Config module
--- @param pal        palette
--- @param tags_mod   Tags module
--- @param widgets    Widgets module
--- @return table  state (mutated; caller checks pending_* fields)
function Detail.draw(ctx, preset, state, db, config, pal, tags_mod, widgets)
  local ImGui = reaper
  local W     = config.DETAIL_PANEL_W

  ImGui.ImGui_BeginChild(ctx, "##detail_panel", W, 0, true, 0)

  if not preset then
    ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
    ImGui.ImGui_TextWrapped(ctx, "Select a preset to view details.")
    ImGui.ImGui_PopStyleColor(ctx, 1)
    ImGui.ImGui_EndChild(ctx)
    return state
  end

  -- Sync edit buffers when selection changes
  if state.last_uuid ~= preset.uuid then
    state.last_uuid   = preset.uuid
    state.peaks       = nil
    state.peaks_loading = false
    state.tag_picker_open = false
    sync_buffers(state, preset, config)
  end

  -- ── Preset name (large) ──────────────────────────────────────────────────
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_header)
  ImGui.ImGui_TextWrapped(ctx, preset.name or "?")
  ImGui.ImGui_PopStyleColor(ctx, 1)

  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_Text(ctx, config.SUPPORTED_EXTS and "" or (preset.type or ""))
  ImGui.ImGui_PopStyleColor(ctx, 1)
  ImGui.ImGui_Separator(ctx)

  -- ── Waveform preview ────────────────────────────────────────────────────
  local preview = preset.preview_path or ""
  if preview ~= "" then
    -- Lazily compute peaks
    if not state.peaks and not state.peaks_loading then
      state.peaks_loading = true
      state.peaks = widgets.compute_peaks(preview, 200)
      state.peaks_loading = false
    end
    widgets.waveform(ctx, state.peaks, W - 16, config.WAVEFORM_H, pal)
  else
    ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
    ImGui.ImGui_Text(ctx, "No preview audio yet.")
    ImGui.ImGui_PopStyleColor(ctx, 1)
  end

  -- Playback / Render buttons
  ImGui.ImGui_Spacing(ctx)
  if preview ~= "" then
    if ImGui.ImGui_SmallButton(ctx, "▶ Play Preview") then
      state.pending_play_preview = preset.uuid
    end
    ImGui.ImGui_SameLine(ctx)
  end
  if ImGui.ImGui_SmallButton(ctx, "⟳ Render Preview") then
    state.pending_render_preview = preset.uuid
  end
  ImGui.ImGui_SameLine(ctx)
  if ImGui.ImGui_SmallButton(ctx, "NKS Sync") then
    state.pending_nks_sync = preset.uuid
  end
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_Separator(ctx)

  -- ── Metadata fields ──────────────────────────────────────────────────────
  widgets.section_header(ctx, "Metadata", pal)

  for _, f in ipairs(config.META_FIELDS) do
    ImGui.ImGui_PushID(ctx, "meta_" .. f.key)

    if f.editable then
      local buf = state.edit_buffers[f.key] or ""
      local new_val

      if f.multiline then
        new_val = widgets.labeled_multiline(ctx, f.key, f.label, buf, W - 16, 64)
      else
        new_val = widgets.labeled_input(ctx, f.key, f.label, buf, W - 80)
      end

      if new_val ~= nil then
        state.edit_buffers[f.key] = new_val
        -- Persist immediately to DB
        local upd = {}; upd[f.key] = new_val
        db.update_preset(preset.uuid, upd)
        preset[f.key] = new_val  -- keep local reference in sync
      end
    else
      -- Read-only display
      ImGui.ImGui_Text(ctx, f.label .. ":")
      ImGui.ImGui_SameLine(ctx)
      ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
      ImGui.ImGui_TextWrapped(ctx, tostring(preset[f.key] or ""))
      ImGui.ImGui_PopStyleColor(ctx, 1)
    end

    ImGui.ImGui_PopID(ctx)
  end

  -- ── Tags section ─────────────────────────────────────────────────────────
  ImGui.ImGui_Spacing(ctx)
  widgets.section_header(ctx, "Tags", pal)

  -- Draw existing tag pills
  if preset.tags and #preset.tags > 0 then
    for i, tag_uuid in ipairs(preset.tags) do
      local t = db.get_tag(tag_uuid)
      if t then
        if i > 1 then ImGui.ImGui_SameLine(ctx, 0, 4) end
        local ev = widgets.tag_pill(ctx, t, config, tags_mod)
        if ev == "right" then
          state.confirm_remove_tag = tag_uuid
        end
      end
    end
    ImGui.ImGui_NewLine(ctx)
  end

  -- Add tag button
  if ImGui.ImGui_SmallButton(ctx, "+ Add Tag") then
    state.tag_picker_open = true
  end

  -- Tag picker popup
  if state.tag_picker_open then
    if ImGui.ImGui_IsPopupOpen and not ImGui.ImGui_IsPopupOpen(ctx, "##tag_picker") then
      ImGui.ImGui_OpenPopup(ctx, "##tag_picker")
    end
    if ImGui.ImGui_BeginPopup(ctx, "##tag_picker") then
      local flat = tags_mod.flat_display_list(db)
      for _, entry in ipairs(flat) do
        -- Skip tags already assigned
        local already = false
        for _, au in ipairs(preset.tags or {}) do
          if au == entry.uuid then already = true; break end
        end
        if not already then
          if ImGui.ImGui_Selectable(ctx, entry.label .. "##pick_" .. entry.uuid, false, 0, 0, 0) then
            db.add_tag_to_preset(preset.uuid, entry.uuid)
            preset.tags = db.get_preset(preset.uuid).tags  -- refresh local ref
            state.tag_picker_open = false
          end
        end
      end
      if #flat == 0 then
        ImGui.ImGui_Text(ctx, "(no tags defined)")
      end
      ImGui.ImGui_Separator(ctx)
      if ImGui.ImGui_Selectable(ctx, "Close", false, 0, 0, 0) then
        state.tag_picker_open = false
      end
      ImGui.ImGui_EndPopup(ctx)
    else
      state.tag_picker_open = false
    end
  end

  -- Confirm remove tag popup
  if state.confirm_remove_tag then
    local tag = db.get_tag(state.confirm_remove_tag)
    local tag_name = tag and tag.name or "this tag"
    local res = widgets.confirm_modal(ctx,
      "Remove tag?",
      "Remove '" .. tag_name .. "' from this preset?",
      pal)
    if res == "yes" then
      db.remove_tag_from_preset(preset.uuid, state.confirm_remove_tag)
      preset.tags = (db.get_preset(preset.uuid) or preset).tags
      state.confirm_remove_tag = nil
    elseif res == "no" then
      state.confirm_remove_tag = nil
    end
  end

  -- ── Path display ──────────────────────────────────────────────────────────
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_Separator(ctx)
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_TextWrapped(ctx, preset.path or "")
  ImGui.ImGui_PopStyleColor(ctx, 1)

  -- Copy path button
  if ImGui.ImGui_SmallButton(ctx, "Copy path") then
    reaper.CF_SetClipboard and reaper.CF_SetClipboard(preset.path or "")
  end

  -- Load preset button (main action)
  ImGui.ImGui_Spacing(ctx)
  if ImGui.ImGui_Button(ctx, "Load Preset / Template", W - 16, 28) then
    state.pending_load = preset.uuid
  end

  ImGui.ImGui_EndChild(ctx)
  return state
end

return Detail
