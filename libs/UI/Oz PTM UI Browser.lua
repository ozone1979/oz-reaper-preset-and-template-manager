-- Oz PTM UI Browser.lua
-- Left-column browser: type filter tree, tag filter tree, search bar,
-- and sortable grid list of preset records.
--
-- State is kept in a panel-local table (not globals) passed in by the caller.

local Browser = {}

-- ─── State constructor ───────────────────────────────────────────────────────

--- Create the initial browser panel state.
function Browser.new_state()
  return {
    search       = "",          -- current search string (live filter)
    filter_type  = "",          -- "" = all types
    filter_tag   = "",          -- "" = no tag filter; tag uuid otherwise
    sort_field   = "name",
    sort_asc     = true,
    results      = {},          -- cached query results
    selected_uuid= nil,         -- currently highlighted preset uuid
    scroll_to    = nil,         -- uuid to scroll into view on next frame
    results_dirty= true,        -- set true to re-run query next frame
    show_tree    = true,        -- expand/collapse left tag tree
    tag_tree     = nil,         -- cached flat display list
    tag_tree_dirty = true,
    ctx_menu_uuid = nil,        -- uuid of preset with context menu open
    rename_uuid  = nil,         -- preset being inline-renamed
    rename_buf   = "",
  }
end

-- ─── Type filter buttons ─────────────────────────────────────────────────────

local TYPE_FILTERS = {
  { key = "",                label = "All"              },
  { key = "fx_chain",        label = "FX Chains"        },
  { key = "track_template",  label = "Track Templates"  },
  { key = "fx_preset",       label = "FX Presets"       },
  { key = "instrument_bank", label = "Instrument Banks" },
}

local function draw_type_panel(ctx, state, pal, config)
  local ImGui = reaper
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_Text(ctx, "TYPE")
  ImGui.ImGui_PopStyleColor(ctx, 1)
  ImGui.ImGui_Spacing(ctx)

  for _, tf in ipairs(TYPE_FILTERS) do
    local selected = (state.filter_type == tf.key)
    local key_id = (tf.key ~= "" and tf.key) or "all"
    local type_label = string.format("%s##type_%s", tf.label, key_id)
    if selected then
      ImGui.ImGui_PushStyleColor(ctx, 24, pal.accent)  -- Header
      ImGui.ImGui_PushStyleColor(ctx, 25, pal.accent_hover or pal.accent)
    end
    if ImGui.ImGui_Selectable(ctx, type_label, selected, 0, 0, 0) then
      if state.filter_type ~= tf.key then
        state.filter_type  = tf.key
        state.results_dirty = true
      end
    end
    if selected then ImGui.ImGui_PopStyleColor(ctx, 2) end
  end
end

-- ─── Tag filter tree ─────────────────────────────────────────────────────────

local function draw_tag_node(ctx, node, state, pal, tags_mod)
  local ImGui    = reaper
  local tag      = node.tag
  local uuid     = tag.uuid
  local has_kids = node.children and #node.children > 0
  local bg       = tags_mod.tag_color_u32(tag)

  -- Draw colored indicator
  local sx, sy = ImGui.ImGui_GetCursorScreenPos(ctx)
  ImGui.ImGui_Dummy(ctx, 4, 14)
  local draw = ImGui.ImGui_GetWindowDrawList(ctx)
  ImGui.ImGui_DrawList_AddRectFilled(draw, sx, sy + 2, sx + 4, sy + 12, bg, 1)

  ImGui.ImGui_SameLine(ctx, 0, 4)

  local selected = (state.filter_tag == uuid)
  if selected then
    ImGui.ImGui_PushStyleColor(ctx, 24, pal.accent)
    ImGui.ImGui_PushStyleColor(ctx, 25, pal.accent_hover or pal.accent)
  end

  local flags = 0
  if not has_kids then
    flags = 1  -- ImGuiTreeNodeFlags_Leaf
  end
  flags = flags | 64  -- SpanAvailWidth

  local open = ImGui.ImGui_TreeNodeEx(ctx, "##tag_" .. uuid, flags)
  ImGui.ImGui_SameLine(ctx, 0, 4)

  local tag_display = (tag.name and tag.name ~= "") and tag.name or "(untitled tag)"
  local tag_label = string.format("%s##tagsel_%s", tag_display, tostring(uuid or "nil"))
  if ImGui.ImGui_Selectable(ctx, tag_label, selected, 0, 0, 0) then
    state.filter_tag   = selected and "" or uuid
    state.results_dirty = true
  end

  -- Right-click context on the selectable
  if ImGui.ImGui_IsItemHovered(ctx) and ImGui.ImGui_IsMouseClicked(ctx, 1) then
    ImGui.ImGui_OpenPopup(ctx, "tag_ctx_" .. uuid)
  end

  -- Context menu
  if ImGui.ImGui_BeginPopup(ctx, "tag_ctx_" .. uuid) then
    if ImGui.ImGui_MenuItem(ctx, "Push color to children") then
      -- caller must handle this event
      state.pending_color_push = uuid
    end
    if ImGui.ImGui_MenuItem(ctx, "Rename…") then
      state.pending_rename_tag = { uuid = uuid, name = tag.name or "" }
    end
    if ImGui.ImGui_MenuItem(ctx, "Delete tag") then
      state.pending_delete_tag = uuid
    end
    ImGui.ImGui_EndPopup(ctx)
  end

  if selected then ImGui.ImGui_PopStyleColor(ctx, 2) end

  if open then
    if has_kids then
      -- Sort children alphab.
      local sorted = {}
      for _, c in ipairs(node.children) do sorted[#sorted + 1] = c end
      table.sort(sorted, function(a, b) return (a.tag.name or "") < (b.tag.name or "") end)
      for _, child in ipairs(sorted) do
        draw_tag_node(ctx, child, state, pal, tags_mod)
      end
    end
    ImGui.ImGui_TreePop(ctx)
  end
end

local function draw_tag_panel(ctx, state, db, pal, tags_mod)
  local ImGui = reaper
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_Text(ctx, "TAGS")
  ImGui.ImGui_PopStyleColor(ctx, 1)

  -- "All tags" row
  local no_tag_sel = (state.filter_tag == "")
  if no_tag_sel then ImGui.ImGui_PushStyleColor(ctx, 24, pal.accent) end
  if ImGui.ImGui_Selectable(ctx, "All##tag_filter_all", no_tag_sel, 0, 0, 0) then
    state.filter_tag   = ""
    state.results_dirty = true
  end
  if no_tag_sel then ImGui.ImGui_PopStyleColor(ctx, 1) end

  if state.tag_tree_dirty then
    state.tag_tree       = db.build_tag_tree()
    state.tag_tree_dirty = false
  end

  if state.tag_tree then
    for _, node in ipairs(state.tag_tree) do
      draw_tag_node(ctx, node, state, pal, tags_mod)
    end
  end

  ImGui.ImGui_Spacing(ctx)
  if ImGui.ImGui_SmallButton(ctx, "+ New tag") then
    state.pending_new_tag = true
  end
end

-- ─── Grid list ───────────────────────────────────────────────────────────────

local SORT_COLUMNS = {
  { field = "name",   label = "Name"   },
  { field = "type",   label = "Type"   },
  { field = "pack",   label = "Pack"   },
  { field = "author", label = "Author" },
  { field = "date",   label = "Date"   },
}

local function draw_grid(ctx, state, db, config, pal, tags_mod, widgets)
  local ImGui = reaper
  local cw    = config

  -- Column headers
  for _, col in ipairs(SORT_COLUMNS) do
    local is_sort = (state.sort_field == col.field)
    local lbl     = col.label
    if is_sort then
      lbl = lbl .. (state.sort_asc and " ▲" or " ▼")
    end
    if ImGui.ImGui_SmallButton(ctx, lbl .. "##sort_" .. col.field) then
      if state.sort_field == col.field then
        state.sort_asc = not state.sort_asc
      else
        state.sort_field  = col.field
        state.sort_asc    = true
      end
      state.results_dirty = true
    end
    ImGui.ImGui_SameLine(ctx, 0, 6)
  end
  ImGui.ImGui_NewLine(ctx)
  ImGui.ImGui_Separator(ctx)

  -- Refresh query if dirty
  if state.results_dirty then
    state.results = db.query(
      { type = state.filter_type, tag_uuid = state.filter_tag, search = state.search },
      state.sort_field, state.sort_asc
    )
    state.results_dirty = false
  end

  -- List of results inside a scrollable child
  local list_h = 0  -- 0 = fill remaining
  local list_open = ImGui.ImGui_BeginChild(ctx, "##preset_list", 0, list_h, 0, 0)

  if list_open then

    for _, preset in ipairs(state.results) do
      local uuid     = preset.uuid
      local selected = (state.selected_uuid == uuid)

      ImGui.ImGui_PushID(ctx, "row_" .. uuid)

      -- Highlight selected row
      if selected then
        ImGui.ImGui_PushStyleColor(ctx, 24, pal.accent)   -- Header
        ImGui.ImGui_PushStyleColor(ctx, 25, pal.accent_hover or pal.accent)
      end

      local row_lbl = string.format("%-40s %-14s %-18s %-14s  %s",
        (preset.name   or ""):sub(1, 40),
        (preset.type   or ""):sub(1, 14),
        (preset.pack   or ""):sub(1, 18),
        (preset.author or ""):sub(1, 14),
        (preset.date   or ""):sub(1, 10))

      if ImGui.ImGui_Selectable(ctx, row_lbl, selected, 64, 0, cw.GRID_ROW_H) then -- SelectableFlags_AllowDoubleClick = 64? no, use 4
        state.selected_uuid = uuid
      end

      -- Double-click to load the preset
      if ImGui.ImGui_IsItemHovered(ctx) and ImGui.ImGui_IsMouseDoubleClicked(ctx, 0) then
        state.pending_load = uuid
      end

      -- Right-click context menu
      if ImGui.ImGui_IsItemHovered(ctx) and ImGui.ImGui_IsMouseClicked(ctx, 1) then
        state.ctx_menu_uuid = uuid
        ImGui.ImGui_OpenPopup(ctx, "preset_ctx")
      end

      if selected then ImGui.ImGui_PopStyleColor(ctx, 2) end

      -- Scroll to item if requested
      if state.scroll_to == uuid then
        ImGui.ImGui_SetScrollHereY(ctx, 0.5)
        state.scroll_to = nil
      end

      ImGui.ImGui_PopID(ctx)
    end

    -- Context menu (rendered outside the loop to avoid ID issues)
    if ImGui.ImGui_BeginPopup(ctx, "preset_ctx") then
      local p = state.ctx_menu_uuid and db.get_preset(state.ctx_menu_uuid)
      if p then
        ImGui.ImGui_Text(ctx, p.name or "?")
        ImGui.ImGui_Separator(ctx)
        if ImGui.ImGui_MenuItem(ctx, "Select") then
          state.selected_uuid = state.ctx_menu_uuid
        end
        if ImGui.ImGui_MenuItem(ctx, "Load preset / template") then
          state.pending_load = state.ctx_menu_uuid
        end
        if ImGui.ImGui_MenuItem(ctx, "Render preview audio") then
          state.pending_render_preview = state.ctx_menu_uuid
        end
        if ImGui.ImGui_MenuItem(ctx, "Sync NKS sidecar") then
          state.pending_nks_sync = state.ctx_menu_uuid
        end
        ImGui.ImGui_Separator(ctx)
        if ImGui.ImGui_MenuItem(ctx, "Remove from library") then
          state.pending_remove = state.ctx_menu_uuid
        end
      end
      ImGui.ImGui_EndPopup(ctx)
    end

    ImGui.ImGui_EndChild(ctx)
  end
end

-- ─── Main draw function ───────────────────────────────────────────────────────

--- Draw the full browser panel.
--- @param ctx    ImGui context
--- @param state  table from Browser.new_state()
--- @param db     DB module
--- @param config Config module
--- @param pal    palette from Theme.build_palette()
--- @param tags_mod Tags module
--- @param widgets  Widgets module
--- @return table state  (same table, mutated; caller checks pending_* fields)
function Browser.draw(ctx, state, db, config, pal, tags_mod, widgets)
  local ImGui = reaper
  local W     = config.BROWSER_PANEL_W

  -- ── Left sidebar ────────────────────────────────────────────────────────────
  local left_open = ImGui.ImGui_BeginChild(ctx, "##browser_left", W, 0, 1, 0)

  if left_open then

    -- Search box
    ImGui.ImGui_SetNextItemWidth(ctx, W - 16)
    local changed, new_search = ImGui.ImGui_InputTextWithHint(ctx, "##search", "Search…", state.search or "", 256)
    if changed then
      state.search        = new_search
      state.results_dirty = true
    end

    ImGui.ImGui_Spacing(ctx)
    draw_type_panel(ctx, state, pal, config)
    ImGui.ImGui_Spacing(ctx)
    draw_tag_panel(ctx, state, db, pal, tags_mod)

    ImGui.ImGui_EndChild(ctx)
  end

  -- ── Grid (right of sidebar) ─────────────────────────────────────────────────
  ImGui.ImGui_SameLine(ctx)
  local grid_open = ImGui.ImGui_BeginChild(ctx, "##browser_grid", 0, 0, 0, 0)
  if grid_open then
    draw_grid(ctx, state, db, config, pal, tags_mod, widgets)
    ImGui.ImGui_EndChild(ctx)
  end

  return state
end

return Browser
