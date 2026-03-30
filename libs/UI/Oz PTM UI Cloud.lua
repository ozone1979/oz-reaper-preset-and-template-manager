-- Oz PTM UI Cloud.lua
-- Similarity cloud / nebula canvas.
-- Renders presets as colored dots in a zoomable, pannable 2-D space,
-- positioned according to their sim_x / sim_y coordinates (output of t-SNE).
-- Only presets with a non-empty preview_path (i.e. audible preview) are shown.
-- Hovering a dot shows a tooltip; clicking selects it in the browser.

local Cloud = {}

-- ─── State constructor ───────────────────────────────────────────────────────

function Cloud.new_state()
  return {
    zoom     = 1.0,    -- scaling factor; 1.0 = fit to canvas
    pan_x    = 0.0,    -- offset in canvas pixels at zoom 1.0
    pan_y    = 0.0,
    dragging = false,
    drag_start_mx = 0,
    drag_start_my = 0,
    drag_start_pan_x = 0,
    drag_start_pan_y = 0,
    hovered_uuid    = nil,
    needs_layout    = true,   -- recompute dot positions
    dot_cache       = {},     -- list of { uuid, cx, cy, color } in canvas space
  }
end

-- ─── Layout ──────────────────────────────────────────────────────────────────

--- Rebuilds the dot cache from DB.
--- @param state  cloud state
--- @param db     DB module
--- @param tags_mod Tags module
local function rebuild_layout(state, db, tags_mod)
  state.dot_cache = {}
  local data = db.get and db.get("") or nil
  if not data then return end

  for _, p in pairs(data.presets) do
    if p.preview_path and p.preview_path ~= "" then
      -- Pick color: first tag color, else neutral
      local dot_color = 0xFF666688
      if p.tags and #p.tags > 0 then
        local t = db.get_tag(p.tags[1])
        if t then dot_color = tags_mod.tag_color_u32(t) end
      end
      state.dot_cache[#state.dot_cache + 1] = {
        uuid   = p.uuid,
        name   = p.name or "?",
        cx     = p.sim_x or 0,   -- 0-1 normalised coordinates
        cy     = p.sim_y or 0,
        color  = dot_color,
      }
    end
  end
  state.needs_layout = false
end

-- ─── Canvas → world and world → screen transforms ────────────────────────────

local function to_screen(world_x, world_y, cx, cy, cw, ch, zoom, pan_x, pan_y)
  -- world coords are 0-1; map to centered canvas with zoom+pan
  local sx = cx + (world_x - 0.5 + pan_x) * cw * zoom
  local sy = cy + (world_y - 0.5 + pan_y) * ch * zoom
  return sx, sy
end

local function to_world(sx, sy, cx, cy, cw, ch, zoom, pan_x, pan_y)
  local wx = (sx - cx) / (cw * zoom) + 0.5 - pan_x
  local wy = (sy - cy) / (ch * zoom) + 0.5 - pan_y
  return wx, wy
end

-- ─── Main draw ───────────────────────────────────────────────────────────────

--- Draw the cloud canvas. Returns the uuid of a dot that was clicked, or nil.
--- @param ctx       ImGui context
--- @param state     table from Cloud.new_state()
--- @param db        DB module
--- @param config    Config module
--- @param pal       palette
--- @param tags_mod  Tags module
--- @return string|nil  selected preset uuid (if clicked)
function Cloud.draw(ctx, state, db, config, pal, tags_mod)
  local ImGui = reaper

  if state.needs_layout then
    rebuild_layout(state, db, tags_mod)
  end

  -- Invisible button fills available space so we can capture input
  local avail_w = ImGui.ImGui_GetContentRegionAvail(ctx)
  local avail_h = select(2, ImGui.ImGui_GetContentRegionAvail(ctx))
  if avail_w < 1 then avail_w = 400 end
  if avail_h < 1 then avail_h = 300 end

  -- Draw background
  local cx, cy = ImGui.ImGui_GetCursorScreenPos(ctx)
  local draw    = ImGui.ImGui_GetWindowDrawList(ctx)
  ImGui.ImGui_DrawList_AddRectFilled(draw, cx, cy, cx + avail_w, cy + avail_h,
    pal.cloud_bg or 0xFF121216)

  ImGui.ImGui_InvisibleButton(ctx, "##cloud_canvas", avail_w, avail_h)
  local canvas_hovered = ImGui.ImGui_IsItemHovered(ctx)
  local canvas_active  = ImGui.ImGui_IsItemActive(ctx)

  -- Mouse position
  local mx = ImGui.ImGui_GetMousePos(ctx)
  local my = select(2, ImGui.ImGui_GetMousePos(ctx))

  -- Drag to pan
  if canvas_active and ImGui.ImGui_IsMouseDragging(ctx, 0, 1.0) then
    if not state.dragging then
      state.dragging          = true
      state.drag_start_pan_x  = state.pan_x
      state.drag_start_pan_y  = state.pan_y
      state.drag_start_mx     = mx
      state.drag_start_my     = my
    else
      local dx = (mx - state.drag_start_mx) / (avail_w * state.zoom)
      local dy = (my - state.drag_start_my) / (avail_h * state.zoom)
      state.pan_x = state.drag_start_pan_x + dx
      state.pan_y = state.drag_start_pan_y + dy
    end
  else
    state.dragging = false
  end

  -- Scroll wheel to zoom
  if canvas_hovered then
    local wheel = ImGui.ImGui_GetMouseWheel(ctx)
    if wheel ~= 0 then
      local factor = 1.0 + wheel * 0.1
      state.zoom = math.max(0.3, math.min(10.0, state.zoom * factor))
    end
  end

  -- Draw dots
  local hovered_uuid = nil
  local r      = config.CLOUD_DOT_RADIUS
  local r_hov  = config.CLOUD_DOT_HOVER_RADIUS
  local midx   = cx + avail_w * 0.5
  local midy   = cy + avail_h * 0.5

  for _, dot in ipairs(state.dot_cache) do
    local sx, sy = to_screen(dot.cx, dot.cy, midx, midy, avail_w, avail_h,
                              state.zoom, state.pan_x, state.pan_y)
    -- Clip to canvas
    if sx >= cx - r and sx <= cx + avail_w + r
    and sy >= cy - r and sy <= cy + avail_h + r then
      local dist = math.sqrt((mx - sx)^2 + (my - sy)^2)
      local is_hov = canvas_hovered and dist <= r_hov

      if is_hov then
        hovered_uuid = dot.uuid
        -- Draw larger glow ring
        ImGui.ImGui_DrawList_AddCircleFilled(draw, sx, sy, r_hov + 3,
          (pal.accent and (pal.accent & 0x00FFFFFF | 0x80000000)) or 0x805577FF)
        ImGui.ImGui_DrawList_AddCircleFilled(draw, sx, sy, r_hov, dot.color)
      else
        ImGui.ImGui_DrawList_AddCircleFilled(draw, sx, sy, r, dot.color)
      end
    end
  end

  state.hovered_uuid = hovered_uuid

  -- Tooltip
  if hovered_uuid then
    local p = db.get_preset(hovered_uuid)
    if p then
      ImGui.ImGui_BeginTooltip(ctx)
      ImGui.ImGui_Text(ctx, p.name or "?")
      if p.pack and p.pack ~= "" then
        ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
        ImGui.ImGui_Text(ctx, p.pack)
        ImGui.ImGui_PopStyleColor(ctx, 1)
      end
      -- Show tag names
      if p.tags and #p.tags > 0 then
        local tag_names = {}
        for _, tu in ipairs(p.tags) do
          local t = db.get_tag(tu)
          if t then tag_names[#tag_names + 1] = t.name end
        end
        ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
        ImGui.ImGui_Text(ctx, table.concat(tag_names, ", "))
        ImGui.ImGui_PopStyleColor(ctx, 1)
      end
      ImGui.ImGui_EndTooltip(ctx)
    end
  end

  -- Click to select
  local selected_uuid = nil
  if canvas_hovered and ImGui.ImGui_IsMouseClicked(ctx, 0) and hovered_uuid then
    selected_uuid = hovered_uuid
  end

  -- Controls overlay (bottom-left)
  ImGui.ImGui_SetCursorScreenPos(ctx, cx + 8, cy + avail_h - 26)
  ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
  ImGui.ImGui_Text(ctx, string.format("Zoom %.1fx | %d dots | scroll=zoom  drag=pan",
    state.zoom, #state.dot_cache))
  ImGui.ImGui_PopStyleColor(ctx, 1)

  -- Reset button
  ImGui.ImGui_SetCursorScreenPos(ctx, cx + avail_w - 70, cy + avail_h - 26)
  if ImGui.ImGui_SmallButton(ctx, "Reset view") then
    state.zoom  = 1.0
    state.pan_x = 0.0
    state.pan_y = 0.0
  end

  -- Empty state hint
  if #state.dot_cache == 0 then
    local msg = "No presets with preview audio.\nRender previews in the Browser tab first."
    local tw  = ImGui.ImGui_CalcTextSize(ctx, msg)
    ImGui.ImGui_SetCursorScreenPos(ctx, cx + (avail_w - tw) * 0.5, cy + avail_h * 0.5 - 10)
    ImGui.ImGui_PushStyleColor(ctx, 0, pal.text_dim)
    ImGui.ImGui_TextWrapped(ctx, msg)
    ImGui.ImGui_PopStyleColor(ctx, 1)
  end

  return selected_uuid
end

--- Forces a re-layout on next draw (call when DB changes).
function Cloud.invalidate(state)
  state.needs_layout = true
end

return Cloud
