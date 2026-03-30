-- Oz PTM Tags.lua
-- Tag management: create, rename, delete, recolor, hierarchy, color inheritance.
-- This module is a thin domain layer over DB; it enforces business rules
-- (e.g. preventing circular parent chains, cascading deletes, etc.).

local Tags = {}

-- ─── Create ──────────────────────────────────────────────────────────────────

--- Creates a new top-level or child tag.
--- @param db table         DB module
--- @param name string
--- @param parent_uuid string|nil  nil = top-level tag
--- @param color table|nil  { r, g, b, a } 0-1 floats; defaults to a mild grey
--- @return table  the new tag record
function Tags.create(db, name, parent_uuid, color)
  if not name or name:match("^%s*$") then
    error("Tag name must not be empty")
  end

  -- If parent given, verify it exists
  if parent_uuid then
    local p = db.get_tag(parent_uuid)
    if not p then
      error("Parent tag not found: " .. tostring(parent_uuid))
    end
    -- Inherit parent color by default when creating a child
    if not color then
      color = { r = p.color_r, g = p.color_g, b = p.color_b, a = p.color_a }
    end
  end

  local record = db.new_tag_record(name, parent_uuid)
  if color then
    record.color_r = color.r or 0.5
    record.color_g = color.g or 0.5
    record.color_b = color.b or 0.5
    record.color_a = color.a or 1.0
  end
  db.add_tag(record)
  return record
end

-- ─── Rename ──────────────────────────────────────────────────────────────────

function Tags.rename(db, uuid, new_name)
  if not new_name or new_name:match("^%s*$") then
    error("Tag name must not be empty")
  end
  db.update_tag(uuid, { name = new_name })
end

-- ─── Recolor ─────────────────────────────────────────────────────────────────

--- Sets the color of a tag.
--- @param db table
--- @param uuid string
--- @param color table  { r, g, b, a }  0-1 floats
function Tags.recolor(db, uuid, color)
  db.update_tag(uuid, {
    color_r = color.r or 0.5,
    color_g = color.g or 0.5,
    color_b = color.b or 0.5,
    color_a = color.a or 1.0,
  })
end

--- Pushes this tag's color down to all immediate children.
--- (Can be called recursively by the caller if deeper propagation is needed.)
--- @param db table
--- @param uuid string
--- @param recursive boolean  if true, propagates to grandchildren as well
function Tags.push_color_to_children(db, uuid, recursive)
  db.inherit_color_to_children(uuid)
  if recursive then
    -- Find children and recurse
    local all_tags = db.get_all_tags()
    for _, t in ipairs(all_tags) do
      if t.parent_uuid == uuid then
        Tags.push_color_to_children(db, t.uuid, true)
      end
    end
  end
end

-- ─── Reparent ────────────────────────────────────────────────────────────────

--- Moves a tag under a new parent (or to top-level if new_parent_uuid is nil).
--- Prevents circular chains.
--- @param db table
--- @param uuid string
--- @param new_parent_uuid string|nil
function Tags.reparent(db, uuid, new_parent_uuid)
  if new_parent_uuid == uuid then
    error("A tag cannot be its own parent")
  end
  -- Detect cycle: walk up from new_parent until we hit nil or find uuid
  if new_parent_uuid then
    local cursor = new_parent_uuid
    local visited = {}
    while cursor do
      if visited[cursor] then break end  -- break cycle guard
      visited[cursor] = true
      if cursor == uuid then
        error("Circular tag hierarchy detected")
      end
      local t = db.get_tag(cursor)
      cursor = t and t.parent_uuid or nil
    end
  end
  db.update_tag(uuid, { parent_uuid = new_parent_uuid })
end

-- ─── Delete ──────────────────────────────────────────────────────────────────

--- Deletes a tag. Children are re-rooted to the deleted tag's parent (not orphaned).
--- @param db table
--- @param uuid string
function Tags.delete(db, uuid)
  local tag = db.get_tag(uuid)
  if not tag then return end

  local parent_uuid = tag.parent_uuid  -- may be nil

  -- Reparent children to grandfather
  local all_tags = db.get_all_tags()
  for _, t in ipairs(all_tags) do
    if t.parent_uuid == uuid then
      db.update_tag(t.uuid, { parent_uuid = parent_uuid })
    end
  end

  db.delete_tag(uuid)
end

-- ─── Query helpers ────────────────────────────────────────────────────────────

--- Returns all top-level tags (no parent).
function Tags.get_roots(db)
  local all = db.get_all_tags()
  local roots = {}
  for _, t in ipairs(all) do
    if not t.parent_uuid then roots[#roots + 1] = t end
  end
  return roots
end

--- Returns direct children of a tag.
--- @param db table
--- @param uuid string
function Tags.get_children(db, uuid)
  local all = db.get_all_tags()
  local kids = {}
  for _, t in ipairs(all) do
    if t.parent_uuid == uuid then kids[#kids + 1] = t end
  end
  return kids
end

--- Returns all descendant uuids of a tag (inclusive of the tag itself).
--- Useful for filtering: show presets that have any tag in this subtree.
--- @param db table
--- @param uuid string
--- @return table  list of uuid strings
function Tags.get_descendant_uuids(db, uuid)
  local result = { uuid }
  local function walk(u)
    local kids = Tags.get_children(db, u)
    for _, k in ipairs(kids) do
      result[#result + 1] = k.uuid
      walk(k.uuid)
    end
  end
  walk(uuid)
  return result
end

--- Builds a flat display list for a combo/dropdown: {uuid, label, depth}
--- where label is indented with "·· " per depth level.
--- @param db table
--- @return table
function Tags.flat_display_list(db)
  local list = {}
  local function walk(nodes, depth)
    for _, node in ipairs(nodes) do
      local indent = string.rep("  ", depth)
      list[#list + 1] = {
        uuid  = node.tag.uuid,
        label = indent .. (node.tag.name or "—"),
        depth = depth,
        tag   = node.tag,
      }
      -- Sort children by name before recursing
      local kids = node.children or {}
      table.sort(kids, function(a, b)
        return (a.tag.name or "") < (b.tag.name or "")
      end)
      walk(kids, depth + 1)
    end
  end
  walk(db.build_tag_tree(), 0)
  return list
end

-- ─── Color utilities ──────────────────────────────────────────────────────────

--- Converts a tag's color to an ImGui-compatible 32-bit RGBA integer.
--- @param tag table
--- @return number
function Tags.tag_color_u32(tag)
  local r = math.floor((tag.color_r or 0.5) * 255 + 0.5)
  local g = math.floor((tag.color_g or 0.5) * 255 + 0.5)
  local b = math.floor((tag.color_b or 0.5) * 255 + 0.5)
  local a = math.floor((tag.color_a or 1.0) * 255 + 0.5)
  -- ImGui color: 0xRRGGBBAA
  return (r << 24) | (g << 16) | (b << 8) | a
end

--- Given a color u32, derives a readable foreground (white or black).
--- @param u32 number  ImGui color integer
--- @return number  either 0xFFFFFFFF or 0x000000FF
function Tags.contrast_color(u32)
  local r = (u32 >> 24) & 0xFF
  local g = (u32 >> 16) & 0xFF
  local b = (u32 >> 8) & 0xFF
  -- Relative luminance
  local lum = (0.299 * r + 0.587 * g + 0.114 * b)
  return lum > 128 and 0x000000FF or 0xFFFFFFFF
end

return Tags
