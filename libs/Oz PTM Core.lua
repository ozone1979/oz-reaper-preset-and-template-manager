-- Oz PTM Core.lua
-- Central loader: requires all sub-modules and exposes the public API.
-- All action scripts dofile() this file and call the appropriate run_* function.

local PTM = {}

-- ─── Resolve library directory ───────────────────────────────────────────────

local CORE_DIR = debug.getinfo(1, "S").source:match("@?(.*[\\/])") or ""

local function req(rel)
  return dofile(CORE_DIR .. rel)
end

-- ─── Load sub-modules ────────────────────────────────────────────────────────

local Config  = req("Oz PTM Config.lua")
local DB      = req("Oz PTM DB.lua")
local Scanner = req("Oz PTM Scanner.lua")
local Tags    = req("Oz PTM Tags.lua")
local Theme   = req("Oz PTM Theme.lua")
local Preview = req("Oz PTM Preview.lua")
local NKS     = req("Oz PTM NKS.lua")
local Sim     = req("Oz PTM Similarity.lua")

local Widgets = req("UI/Oz PTM UI Widgets.lua")
local Browser = req("UI/Oz PTM UI Browser.lua")
local Detail  = req("UI/Oz PTM UI Detail.lua")
local Cloud   = req("UI/Oz PTM UI Cloud.lua")

-- Make json encode/decode available to Scanner (needs it for scan roots)
Config._json_decode = DB._json.decode

-- ─── Database initialisation ─────────────────────────────────────────────────

local db_path = Config.get_db_path()
DB.load(db_path)

-- ─── UI state (module-level, not global) ─────────────────────────────────────

local ui = {
  ctx          = nil,
  open         = true,
  palette      = nil,
  tab          = Config.TAB_BROWSER,
  browser_st   = Browser.new_state(),
  detail_st    = Detail.new_state(),
  cloud_st     = Cloud.new_state(),
  scan_running = false,
  scan_msg     = "",
  preview_play_handle = nil,
  settings_scan_root_buf = "",
  tag_new_name_buf = "",
  tag_new_parent_buf = "",
  tag_rename_buf = "",
  pending_tag_manager = false,
}

-- ─── Tag manager ─────────────────────────────────────────────────────────────

local function draw_tag_manager(ctx, pal)
  local ImGui = reaper
  if ImGui.ImGui_BeginPopup(ctx, "##tag_manager") then
    ImGui.ImGui_Text(ctx, "Tag Manager")
    ImGui.ImGui_Separator(ctx)

    -- New tag form
    ImGui.ImGui_Text(ctx, "New tag name:")
    ImGui.ImGui_SameLine(ctx)
    ImGui.ImGui_SetNextItemWidth(ctx, 140)
    local _, nb = ImGui.ImGui_InputText(ctx, "##new_tag_name", ui.tag_new_name_buf, 128)
    if nb ~= nil then ui.tag_new_name_buf = nb end
    ImGui.ImGui_SameLine(ctx)
    if ImGui.ImGui_SmallButton(ctx, "Add") and ui.tag_new_name_buf ~= "" then
      pcall(Tags.create, DB, ui.tag_new_name_buf, nil, nil)
      ui.tag_new_name_buf = ""
      ui.browser_st.tag_tree_dirty = true
      ui.cloud_st.needs_layout = true
    end

    ImGui.ImGui_Spacing(ctx)

    -- Handle pending renames from tree
    if ui.browser_st.pending_rename_tag then
      local rt = ui.browser_st.pending_rename_tag
      ImGui.ImGui_Text(ctx, "Renaming: " .. (rt.name or ""))
      ImGui.ImGui_SetNextItemWidth(ctx, 180)
      if ui.tag_rename_buf == "" then ui.tag_rename_buf = rt.name or "" end
      local _, rb = ImGui.ImGui_InputText(ctx, "##rename_tag", ui.tag_rename_buf, 128)
      if rb ~= nil then ui.tag_rename_buf = rb end
      ImGui.ImGui_SameLine(ctx)
      if ImGui.ImGui_SmallButton(ctx, "Save") then
        pcall(Tags.rename, DB, rt.uuid, ui.tag_rename_buf)
        ui.browser_st.pending_rename_tag = nil
        ui.tag_rename_buf = ""
        ui.browser_st.tag_tree_dirty = true
      end
    end

    -- Handle color push
    if ui.browser_st.pending_color_push then
      local uuid = ui.browser_st.pending_color_push
      Tags.push_color_to_children(DB, uuid, true)
      ui.browser_st.pending_color_push = nil
      ui.browser_st.tag_tree_dirty     = true
      ui.cloud_st.needs_layout         = true
    end

    -- Handle delete
    if ui.browser_st.pending_delete_tag then
      local ok = Widgets.confirm_modal(ctx, "Delete tag?",
        "Delete this tag and reparent its children?", pal)
      if ok == "yes" then
        Tags.delete(DB, ui.browser_st.pending_delete_tag)
        ui.browser_st.pending_delete_tag = nil
        ui.browser_st.tag_tree_dirty     = true
        ui.browser_st.results_dirty      = true
        ui.cloud_st.needs_layout         = true
      elseif ok == "no" then
        ui.browser_st.pending_delete_tag = nil
      end
    end

    if ImGui.ImGui_Button(ctx, "Close", 80, 0) then
      ImGui.ImGui_CloseCurrentPopup(ctx)
      ui.pending_tag_manager = false
    end

    ImGui.ImGui_EndPopup(ctx)
  end
end

-- ─── Settings tab ────────────────────────────────────────────────────────────

local function draw_settings(ctx, pal)
  local ImGui = reaper
  Widgets.section_header(ctx, "Library Scan", pal)

  ImGui.ImGui_Text(ctx, "Default Reaper preset paths are scanned automatically.")
  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_Text(ctx, "Add extra root:")
  ImGui.ImGui_SameLine(ctx)
  ImGui.ImGui_SetNextItemWidth(ctx, 300)
  local _, nb = ImGui.ImGui_InputTextWithHint(ctx, "##scan_root", "e.g. D:/MyPresets", ui.settings_scan_root_buf, 512)
  if nb ~= nil then ui.settings_scan_root_buf = nb end
  ImGui.ImGui_SameLine(ctx)
  if ImGui.ImGui_SmallButton(ctx, "Add path") and ui.settings_scan_root_buf ~= "" then
    local raw = Config.get_ext_str(Config.KEY_SCAN_ROOTS, "[]")
    local list = DB._json.decode(raw) or {}
    list[#list + 1] = ui.settings_scan_root_buf
    Config.set_ext(Config.KEY_SCAN_ROOTS, DB._json.encode(list))
    ui.settings_scan_root_buf = ""
  end

  ImGui.ImGui_Spacing(ctx)
  if ImGui.ImGui_Button(ctx, "Rebuild full library index", 240, 28) then
    ui.scan_running = true
    ui.scan_msg     = "Scanning…"
    local counted = Scanner.scan_all(Config, DB, function(i, total, p)
      ui.scan_msg = string.format("Scanning %d / %d …", i, total)
    end)
    Scanner.remove_stale(DB)
    DB.save(db_path)
    ui.scan_running = false
    ui.scan_msg     = string.format("Done: %d entries indexed.", counted)
    ui.browser_st.results_dirty = true
    ui.cloud_st.needs_layout    = true
  end

  if ui.scan_msg ~= "" then
    ImGui.ImGui_SameLine(ctx)
    ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
    ImGui.ImGui_Text(ctx, ui.scan_msg)
    ImGui.ImGui_PopStyleColor(ctx, 1)
  end

  ImGui.ImGui_Spacing(ctx)
  Widgets.section_header(ctx, "Similarity Cloud", pal)
  if ImGui.ImGui_Button(ctx, "Compute similarity (all presets with preview)", 340, 28) then
    Sim.run_full_pipeline(DB, Config, function(i, total, label)
      ui.scan_msg = label
    end)
    DB.save(db_path)
    ui.cloud_st.needs_layout = true
    ui.scan_msg = "Similarity projection done."
  end

  ImGui.ImGui_Spacing(ctx)
  Widgets.section_header(ctx, "NKS Export", pal)
  if ImGui.ImGui_Button(ctx, "Write NKS sidecars for all presets", 280, 28) then
    local n = NKS.sync_all(DB, Config, DB._json, nil)
    DB.save(db_path)
    ui.scan_msg = string.format("Wrote %d NKS sidecar files.", n)
  end

  ImGui.ImGui_Spacing(ctx)
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_Text(ctx, string.format("Database: %s  |  %d presets  |  %d tags",
    db_path, DB.count_presets(), DB.count_tags()))
  ImGui.ImGui_PopStyleColor(ctx, 1)
end

-- ─── Pending action dispatcher ────────────────────────────────────────────────

local function dispatch_pending(ctx, pal)
  -- Browser pending events
  local bst = ui.browser_st
  local dst = ui.detail_st

  -- New tag requested from browser
  if bst.pending_new_tag then
    bst.pending_new_tag  = false
    ui.pending_tag_manager = true
    reaper.ImGui_OpenPopup(ctx, "##tag_manager")
  end

  -- Open tag manager if flagged
  if ui.pending_tag_manager then
    draw_tag_manager(ctx, pal)
  end

  -- Load preset into Reaper
  if bst.pending_load then
    local p = DB.get_preset(bst.pending_load)
    bst.pending_load = nil
    if p then
      if p.type == "track_template" then
        if reaper.Main_openProject then
          reaper.Main_openProject(p.path)
        end
        -- Actually insert template:
        -- No API exists to load a track template by path silently in base Reaper.
        -- Best effort: open via file manager fallback.
        if reaper.CF_ShellExecute then
          reaper.CF_ShellExecute(p.path)
        end
      elseif p.type == "fx_chain" then
        -- Apply to selected track's first FX slot
        local sel = reaper.GetSelectedTrack(0, 0)
        if sel then
          reaper.LoadTrackFXChain(sel, p.path)
        else
          reaper.ShowMessageBox("Select a track first to apply the FX chain.", "Oz PTM", 0)
        end
      elseif p.type == "fx_preset" or p.type == "instrument_bank" then
        if reaper.CF_ShellExecute then
          reaper.CF_ShellExecute(p.path)
        end
      end
    end
  end

  -- Stop any playing preview first
  if dst.pending_play_preview then
    if ui.preview_play_handle then
      Preview.stop(ui.preview_play_handle)
      ui.preview_play_handle = nil
    end
    local p = DB.get_preset(dst.pending_play_preview)
    dst.pending_play_preview = nil
    if p and p.preview_path and p.preview_path ~= "" then
      ui.preview_play_handle = Preview.play(p.preview_path)
    end
  end

  -- Render preview
  if bst.pending_render_preview or dst.pending_render_preview then
    local uuid = bst.pending_render_preview or dst.pending_render_preview
    bst.pending_render_preview = nil
    dst.pending_render_preview = nil
    local p = DB.get_preset(uuid)
    if p then
      Preview.render(p, Config, DB, function(ok, out_path)
        ui.scan_msg = ok
          and ("Preview rendered: " .. (out_path or ""))
          or  "Preview render failed."
        DB.save(db_path)
        dst.peaks = nil  -- invalidate waveform cache
        ui.cloud_st.needs_layout = true
      end)
    end
  end

  -- NKS sync
  if bst.pending_nks_sync or dst.pending_nks_sync then
    local uuid = bst.pending_nks_sync or dst.pending_nks_sync
    bst.pending_nks_sync = nil
    dst.pending_nks_sync = nil
    local p = DB.get_preset(uuid)
    if p then
      NKS.write_sidecar(p, DB, Config, DB._json)
      DB.save(db_path)
      ui.scan_msg = "NKS sidecar written."
    end
  end

  -- Remove from library
  if bst.pending_remove then
    local uuid = bst.pending_remove
    bst.pending_remove = nil
    DB.delete_preset(uuid)
    bst.results_dirty = true
    bst.selected_uuid = nil
    DB.save(db_path)
    ui.cloud_st.needs_layout = true
  end
end

-- ─── Main window loop ─────────────────────────────────────────────────────────

local function run_frame()
  local ImGui = reaper
  if not ui.ctx then return false end

  -- Rebuild palette every frame (cheap; handles theme changes)
  ui.palette = Theme.build_palette()
  local pal  = ui.palette

  local style_count = Theme.push_style(ui.ctx, pal)

  -- Restore window pos/size from ext-state on first open
  local wx = Config.get_ext_num(Config.KEY_WINDOW_X, 100)
  local wy = Config.get_ext_num(Config.KEY_WINDOW_Y, 100)
  local ww = Config.get_ext_num(Config.KEY_WINDOW_W, Config.DEFAULT_W)
  local wh = Config.get_ext_num(Config.KEY_WINDOW_H, Config.DEFAULT_H)
  ImGui.ImGui_SetNextWindowPos(ui.ctx, wx, wy, ImGui.ImGui_Cond_FirstUseEver and ImGui.ImGui_Cond_FirstUseEver() or 2)
  ImGui.ImGui_SetNextWindowSize(ui.ctx, ww, wh, ImGui.ImGui_Cond_FirstUseEver and ImGui.ImGui_Cond_FirstUseEver() or 2)

  local visible, open = ImGui.ImGui_Begin(ui.ctx, Config.WINDOW_TITLE, true,
    ImGui.ImGui_WindowFlags_NoCollapse and ImGui.ImGui_WindowFlags_NoCollapse() or 0)

  ui.open = open

  if not open then
    ImGui.ImGui_End(ui.ctx)
    Theme.pop_style(ui.ctx, style_count)
    return false  -- window closed
  end

  if visible then
    -- Tab bar
    if ImGui.ImGui_BeginTabBar(ui.ctx, "##main_tabs") then
      for _, entry in ipairs({
        { id = Config.TAB_BROWSER,  label = "Browser"           },
        { id = Config.TAB_CLOUD,    label = "Similarity Cloud"  },
        { id = Config.TAB_SETTINGS, label = "Settings"          },
      }) do
        local flags = 0
        if ImGui.ImGui_BeginTabItem(ui.ctx, entry.label, nil, flags) then
          ui.tab = entry.id
          ImGui.ImGui_EndTabItem(ui.ctx)
        end
      end
      ImGui.ImGui_EndTabBar(ui.ctx)
    end

    ImGui.ImGui_Separator(ui.ctx)

    -- ── Browser tab ──────────────────────────────────────────────────────────
    if ui.tab == Config.TAB_BROWSER then
      Browser.draw(ui.ctx, ui.browser_st, DB, Config, pal, Tags, Widgets)

      -- Detail panel for selected preset
      local sel_uuid = ui.browser_st.selected_uuid
      local sel_preset = sel_uuid and DB.get_preset(sel_uuid) or nil
      ImGui.ImGui_SameLine(ui.ctx)
      Detail.draw(ui.ctx, sel_preset, ui.detail_st, DB, Config, pal, Tags, Widgets)

    -- ── Cloud tab ────────────────────────────────────────────────────────────
    elseif ui.tab == Config.TAB_CLOUD then
      local clicked_uuid = Cloud.draw(ui.ctx, ui.cloud_st, DB, Config, pal, Tags)
      if clicked_uuid then
        ui.browser_st.selected_uuid = clicked_uuid
        ui.browser_st.scroll_to     = clicked_uuid
        ui.tab = Config.TAB_BROWSER  -- jump back to browser with selection
      end

    -- ── Settings tab ─────────────────────────────────────────────────────────
    elseif ui.tab == Config.TAB_SETTINGS then
      draw_settings(ui.ctx, pal)
    end

    dispatch_pending(ui.ctx, pal)

    -- Auto-save DB on changes
    if DB.is_dirty() then
      DB.save(db_path)
    end
  end

  -- Save window position/size
  local cur_x, cur_y = ImGui.ImGui_GetWindowPos(ui.ctx)
  local cur_w, cur_h = ImGui.ImGui_GetWindowSize(ui.ctx)
  if cur_x and cur_y then
    Config.set_ext(Config.KEY_WINDOW_X, cur_x)
    Config.set_ext(Config.KEY_WINDOW_Y, cur_y)
    Config.set_ext(Config.KEY_WINDOW_W, cur_w)
    Config.set_ext(Config.KEY_WINDOW_H, cur_h)
  end

  ImGui.ImGui_End(ui.ctx)
  Theme.pop_style(ui.ctx, style_count)
  return true
end

-- ─── Public entry points ──────────────────────────────────────────────────────

--- Opens the main dockable browser panel.
function PTM.run_browser_panel()
  if not reaper.ImGui_CreateContext then
    reaper.ShowMessageBox(
      "This script requires the ReaImGui extension.\n" ..
      "Please install it from ReaPack (ReaTeam Extensions).",
      "Oz Preset Manager", 0)
    return
  end

  local dock = Config.get_ext_num(Config.KEY_DOCK_STATE, 0)
  ui.ctx = reaper.ImGui_CreateContext(Config.WINDOW_TITLE)
  if reaper.ImGui_SetConfigFlags then
    reaper.ImGui_SetConfigFlags(
      ui.ctx,
      reaper.ImGui_ConfigFlags_DockingEnable and reaper.ImGui_ConfigFlags_DockingEnable() or 0
    )
  end

  if dock ~= 0 then
    -- Will be docked on first frame via SetNextWindowDockID
    if reaper.ImGui_SetNextWindowDockID then
      reaper.ImGui_SetNextWindowDockID(ui.ctx, dock, 0)
    end
  end

  local function loop()
    local ok, keep_running = pcall(run_frame)
    if not ok or keep_running == false then
      if reaper.ImGui_DestroyContext then
        reaper.ImGui_DestroyContext(ui.ctx)
      end
      ui.ctx = nil
      return
    end
    reaper.defer(loop)
  end
  reaper.defer(loop)
end

--- Rebuilds the full library index (no UI, command-line style).
function PTM.run_rebuild_index()
  reaper.ShowConsoleMsg("Oz PTM: Scanning library…\n")
  local n = Scanner.scan_all(Config, DB, function(i, total, p)
    if i % 50 == 0 then
      reaper.ShowConsoleMsg(string.format("  %d / %d …\r", i, total))
    end
  end)
  Scanner.remove_stale(DB)
  DB.save(db_path)
  reaper.ShowConsoleMsg(string.format("Done: %d preset/template entries indexed.\n", n))
end

--- Renders previews for all unrendered presets.
function PTM.run_render_all_previews()
  reaper.ShowConsoleMsg("Oz PTM: Rendering all unrendered previews…\n")
  local n = Preview.render_all_unrendered(DB, Config, function(i, total, name)
    reaper.ShowConsoleMsg(string.format("  [%d/%d] %s\r", i, total, name))
  end)
  DB.save(db_path)
  reaper.ShowConsoleMsg(string.format("Done: %d previews rendered.\n", n))
end

--- Renders preview for the currently selected preset (single).
function PTM.run_render_selected_preview()
  -- Identify the selected preset: look for the last selected_uuid in panel ext-state if available
  -- Fallback: ask user to run from browser
  local uuid = reaper.GetExtState(Config.PANEL_SECTION, "SELECTED_PRESET_UUID")
  if not uuid or uuid == "" then
    reaper.ShowMessageBox("Open the browser panel and select a preset first.",
      "Oz PTM", 0)
    return
  end
  local p = DB.get_preset(uuid)
  if not p then
    reaper.ShowMessageBox("Selected preset not found in library.", "Oz PTM", 0)
    return
  end
  local ok = Preview.render(p, Config, DB, function(success, path)
    if success then
      reaper.ShowConsoleMsg("Oz PTM: Preview rendered to " .. (path or "") .. "\n")
    else
      reaper.ShowMessageBox("Preview render failed.", "Oz PTM", 0)
    end
  end)
  if ok then DB.save(db_path) end
end

--- Writes NKS sidecars for all presets.
function PTM.run_sync_nks()
  reaper.ShowConsoleMsg("Oz PTM: Writing NKS sidecars…\n")
  local n = NKS.sync_all(DB, Config, DB._json, function(i, total, name)
    reaper.ShowConsoleMsg(string.format("  [%d/%d] %s\r", i, total, name))
  end)
  DB.save(db_path)
  reaper.ShowConsoleMsg(string.format("Done: %d NKS sidecars written.\n", n))
end

return PTM
