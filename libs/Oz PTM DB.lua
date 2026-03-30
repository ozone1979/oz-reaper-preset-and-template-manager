-- Oz PTM DB.lua
-- Flat-file JSON database for presets, templates, and tags.
-- Handles load/save, CRUD, filtering, and search.
--
-- All UUIDs are generated as simple 128-bit hex strings (no external dependency).
-- The JSON encoder/decoder is a minimal pure-Lua implementation.

local DB = {}

-- ─── Minimal JSON encoder/decoder ────────────────────────────────────────────

local json = {}

-- Encode a Lua value to a JSON string.
function json.encode(val)
  local t = type(val)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return val and "true" or "false"
  elseif t == "number" then
    if val ~= val then return "null" end           -- NaN guard
    if val == math.huge or val == -math.huge then return "null" end
    -- Omit trailing zeros for integers stored as floats
    if math.floor(val) == val and math.abs(val) < 1e15 then
      return string.format("%.0f", val)
    end
    return string.format("%.10g", val)
  elseif t == "string" then
    -- Escape special characters
    local esc = val:gsub('[\\"/\b\f\n\r\t]', function(c)
      local map = {
        ['\\'] = '\\\\', ['"'] = '\\"', ['/'] = '\\/',
        ['\b'] = '\\b',  ['\f'] = '\\f', ['\n'] = '\\n',
        ['\r'] = '\\r',  ['\t'] = '\\t',
      }
      return map[c] or c
    end)
    -- Escape remaining control characters
    esc = esc:gsub('[\x00-\x1f]', function(c)
      return string.format('\\u%04x', c:byte())
    end)
    return '"' .. esc .. '"'
  elseif t == "table" then
    -- Detect array vs object: array has consecutive integer keys from 1
    local is_array = (#val > 0)
    if is_array then
      -- Verify no holes and only integer keys
      local n = #val
      local count = 0
      for _ in pairs(val) do count = count + 1 end
      if count ~= n then is_array = false end
    end
    if is_array then
      local parts = {}
      for i = 1, #val do
        parts[#parts + 1] = json.encode(val[i])
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      local parts = {}
      -- Sort keys for deterministic output
      local keys = {}
      for k in pairs(val) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. json.encode(val[k])
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  end
  return "null"
end

-- ── Decoder ──────────────────────────────────────────────────────────────────

local function skip_ws(s, i)
  while i <= #s and s:sub(i, i):match("%s") do i = i + 1 end
  return i
end

local decode_value  -- forward declaration

local function decode_string(s, i)
  -- i points to the opening "
  local result = {}
  i = i + 1  -- skip "
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then
      return table.concat(result), i + 1
    elseif c == '\\' then
      local e = s:sub(i + 1, i + 1)
      local esc = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
                    ['b'] = '\b', ['f'] = '\f', ['n'] = '\n',
                    ['r'] = '\r', ['t'] = '\t' }
      if esc[e] then
        result[#result + 1] = esc[e]
        i = i + 2
      elseif e == 'u' then
        local hex = s:sub(i + 2, i + 5)
        local codepoint = tonumber(hex, 16) or 0
        if codepoint < 0x80 then
          result[#result + 1] = string.char(codepoint)
        elseif codepoint < 0x800 then
          result[#result + 1] = string.char(
            0xC0 + math.floor(codepoint / 64),
            0x80 + (codepoint % 64))
        else
          result[#result + 1] = string.char(
            0xE0 + math.floor(codepoint / 4096),
            0x80 + math.floor((codepoint % 4096) / 64),
            0x80 + (codepoint % 64))
        end
        i = i + 6
      else
        result[#result + 1] = e
        i = i + 2
      end
    else
      result[#result + 1] = c
      i = i + 1
    end
  end
  error("JSON: unterminated string")
end

local function decode_array(s, i)
  local arr = {}
  i = i + 1  -- skip [
  i = skip_ws(s, i)
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local v, ni = decode_value(s, i)
    arr[#arr + 1] = v
    i = skip_ws(s, ni)
    local c = s:sub(i, i)
    if c == ']' then return arr, i + 1 end
    if c ~= ',' then error("JSON: expected ',' or ']'") end
    i = skip_ws(s, i + 1)
  end
end

local function decode_object(s, i)
  local obj = {}
  i = i + 1  -- skip {
  i = skip_ws(s, i)
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then error("JSON: expected string key") end
    local k, ni = decode_string(s, i)
    i = skip_ws(s, ni)
    if s:sub(i, i) ~= ':' then error("JSON: expected ':'") end
    i = skip_ws(s, i + 1)
    local v, nni = decode_value(s, i)
    obj[k] = v
    i = skip_ws(s, nni)
    local c = s:sub(i, i)
    if c == '}' then return obj, i + 1 end
    if c ~= ',' then error("JSON: expected ',' or '}'") end
    i = skip_ws(s, i + 1)
  end
end

decode_value = function(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == '"' then
    return decode_string(s, i)
  elseif c == '[' then
    return decode_array(s, i)
  elseif c == '{' then
    return decode_object(s, i)
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif s:sub(i, i + 3) == 'null' then
    return nil, i + 4
  else
    -- Number
    local num_str = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
    if num_str then
      return tonumber(num_str), i + #num_str
    end
    error("JSON: unexpected token at pos " .. i .. ": " .. s:sub(i, i + 10))
  end
end

function json.decode(s)
  if type(s) ~= "string" or s == "" then return nil end
  local ok, result = pcall(function()
    local val, _ = decode_value(s, 1)
    return val
  end)
  if ok then return result end
  return nil  -- silently return nil on parse error; caller handles
end

DB._json = json  -- expose for tests / other modules

-- ─── UUID generation ─────────────────────────────────────────────────────────

local uuid_counter = 0
local uuid_init_time = 0

function DB.new_uuid()
  uuid_counter = uuid_counter + 1
  -- Combine time, counter, and random bytes for uniqueness within a session
  local t = reaper.time_precise and reaper.time_precise() or os.time()
  local r1 = math.random(0, 0xFFFFFFFF)
  local r2 = math.random(0, 0xFFFFFFFF)
  return string.format("%08x-%04x-%04x-%04x-%08x%04x",
    math.floor(t * 1000) % 0x100000000,
    uuid_counter % 0x10000,
    r1 % 0x10000,
    r2 % 0x10000,
    r1,
    r2 % 0x10000)
end

-- ─── Internal state ───────────────────────────────────────────────────────────

local _db = nil       -- loaded database table
local _dirty = false  -- true when in-memory state differs from disk

-- ─── Schema helpers ──────────────────────────────────────────────────────────

local function empty_db()
  return {
    version  = 2,
    presets  = {},
    tags     = {},
  }
end

--- Returns a new preset record with all required fields.
--- @param path string   absolute file path
--- @param ptype string  e.g. "fx_chain"
function DB.new_preset_record(path, ptype)
  local now = os.date("%Y-%m-%d")
  local name = path:match("[^\\/]+$") or path
  name = name:gsub("%.[^%.]+$", "")  -- strip extension
  return {
    uuid         = DB.new_uuid(),
    type         = ptype or "fx_chain",
    path         = path,
    name         = name,
    author       = "",
    vendor       = "",
    date         = now,
    comment      = "",
    pack         = "",
    tags         = {},   -- list of tag uuids
    preview_path = "",
    nks_path     = "",
    sim_vec      = {},
    sim_x        = 0,
    sim_y        = 0,
    color        = 0,
  }
end

--- Returns a new tag record.
--- @param name string
--- @param parent_uuid string|nil
function DB.new_tag_record(name, parent_uuid)
  return {
    uuid        = DB.new_uuid(),
    name        = name,
    parent_uuid = parent_uuid or nil,
    color_r     = 0.5,
    color_g     = 0.5,
    color_b     = 0.5,
    color_a     = 1.0,
  }
end

-- ─── Load / Save ─────────────────────────────────────────────────────────────

--- Loads the database from disk. Returns the db table.
--- Creates an empty db if the file does not exist.
--- @param path string   file path (from Config.get_db_path())
function DB.load(path)
  local f = io.open(path, "rb")
  if f then
    local raw = f:read("*a")
    f:close()
    local parsed = json.decode(raw)
    if parsed and type(parsed) == "table" then
      -- Forward-migrate if needed
      _db = parsed
      if not _db.presets then _db.presets = {} end
      if not _db.tags    then _db.tags    = {} end
      _db.version = _db.version or 2
    else
      _db = empty_db()
    end
  else
    _db = empty_db()
  end
  _dirty = false
  return _db
end

--- Saves the in-memory database to disk.
--- @param path string
--- @return boolean success
function DB.save(path)
  if not _db then return false end
  local dir = path:match("(.*[/\\])")
  if dir then reaper.RecursiveCreateDirectory(dir, 0) end
  local encoded = json.encode(_db)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(encoded)
  f:close()
  _dirty = false
  return true
end

--- Returns the live database table (loads if needed).
--- @param path string
function DB.get(path)
  if not _db then DB.load(path) end
  return _db
end

function DB.is_dirty() return _dirty end

function DB.mark_dirty() _dirty = true end

-- ─── Preset CRUD ─────────────────────────────────────────────────────────────

--- Inserts or updates a preset record (matched by path).
--- @param record table   full preset record
function DB.upsert_preset(record)
  if not _db then return end
  -- Check if a record with this path already exists
  for uuid, p in pairs(_db.presets) do
    if p.path == record.path then
      -- Merge: update scanner-owned fields but preserve user edits
      p.type = record.type
      p.name = (p.name and p.name ~= "") and p.name or record.name
      _dirty = true
      return p
    end
  end
  _db.presets[record.uuid] = record
  _dirty = true
  return record
end

--- Updates specific fields of a preset by uuid.
--- @param uuid string
--- @param fields table   key/value pairs to merge
function DB.update_preset(uuid, fields)
  if not _db or not _db.presets[uuid] then return end
  local p = _db.presets[uuid]
  for k, v in pairs(fields) do
    p[k] = v
  end
  _dirty = true
end

--- Deletes a preset record.
function DB.delete_preset(uuid)
  if not _db then return end
  _db.presets[uuid] = nil
  _dirty = true
end

--- Returns the preset record for a given uuid, or nil.
function DB.get_preset(uuid)
  if not _db then return nil end
  return _db.presets[uuid]
end

--- Returns the preset record matching a file path, or nil.
function DB.find_preset_by_path(path)
  if not _db then return nil end
  for _, p in pairs(_db.presets) do
    if p.path == path then return p end
  end
  return nil
end

-- ─── Tag CRUD ─────────────────────────────────────────────────────────────────

--- Inserts a tag. Returns the record.
function DB.add_tag(record)
  if not _db then return end
  _db.tags[record.uuid] = record
  _dirty = true
  return record
end

--- Updates specific fields of a tag.
function DB.update_tag(uuid, fields)
  if not _db or not _db.tags[uuid] then return end
  local t = _db.tags[uuid]
  for k, v in pairs(fields) do t[k] = v end
  _dirty = true
end

--- Deletes a tag and removes it from all presets.
function DB.delete_tag(uuid)
  if not _db then return end
  _db.tags[uuid] = nil
  for _, p in pairs(_db.presets) do
    if p.tags then
      for i = #p.tags, 1, -1 do
        if p.tags[i] == uuid then table.remove(p.tags, i) end
      end
    end
  end
  _dirty = true
end

--- Returns a tag record or nil.
function DB.get_tag(uuid)
  if not _db then return nil end
  return _db.tags[uuid]
end

--- Returns all tags as a flat ordered list (sorted by name).
function DB.get_all_tags()
  if not _db then return {} end
  local list = {}
  for _, t in pairs(_db.tags) do list[#list + 1] = t end
  table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
  return list
end

--- Assigns child tags the same color as the given parent tag.
--- @param parent_uuid string
function DB.inherit_color_to_children(parent_uuid)
  if not _db then return end
  local parent = _db.tags[parent_uuid]
  if not parent then return end
  for _, t in pairs(_db.tags) do
    if t.parent_uuid == parent_uuid then
      t.color_r = parent.color_r
      t.color_g = parent.color_g
      t.color_b = parent.color_b
      t.color_a = parent.color_a
    end
  end
  _dirty = true
end

--- Builds a tree of tags: returns { [uuid] = { record, children = {...} } }
function DB.build_tag_tree()
  if not _db then return {} end
  local nodes = {}
  for uuid, t in pairs(_db.tags) do
    nodes[uuid] = { tag = t, children = {} }
  end
  local roots = {}
  for uuid, node in pairs(nodes) do
    local parent = node.tag.parent_uuid
    if parent and nodes[parent] then
      table.insert(nodes[parent].children, node)
    else
      roots[#roots + 1] = node
    end
  end
  table.sort(roots, function(a, b) return (a.tag.name or "") < (b.tag.name or "") end)
  return roots
end

-- ─── Query / filter ──────────────────────────────────────────────────────────

--- Returns a flat list of preset records matching the given filter.
--- @param filter table  optional { type=string, tag_uuid=string, search=string }
--- @param sort_field string  optional field name for sorting
--- @param sort_asc boolean   true = ascending
function DB.query(filter, sort_field, sort_asc)
  if not _db then return {} end
  filter = filter or {}
  local results = {}

  local search = filter.search and filter.search:lower() or nil

  for _, p in pairs(_db.presets) do
    local ok = true

    -- Type filter
    if filter.type and filter.type ~= "" and p.type ~= filter.type then
      ok = false
    end

    -- Tag filter
    if ok and filter.tag_uuid and filter.tag_uuid ~= "" then
      local has = false
      if p.tags then
        for _, tu in ipairs(p.tags) do
          if tu == filter.tag_uuid then has = true; break end
        end
      end
      if not has then ok = false end
    end

    -- Text search across name, author, vendor, pack, comment
    if ok and search and search ~= "" then
      local haystack = table.concat({
        (p.name    or ""):lower(),
        (p.author  or ""):lower(),
        (p.vendor  or ""):lower(),
        (p.pack    or ""):lower(),
        (p.comment or ""):lower(),
      }, " ")
      if not haystack:find(search, 1, true) then ok = false end
    end

    if ok then results[#results + 1] = p end
  end

  -- Sort
  sort_field = sort_field or "name"
  if sort_asc == nil then sort_asc = true end
  table.sort(results, function(a, b)
    local av = a[sort_field] or ""
    local bv = b[sort_field] or ""
    return sort_asc and (av < bv) or (av > bv)
  end)

  return results
end

--- Returns the count of all presets.
function DB.count_presets()
  if not _db then return 0 end
  local n = 0
  for _ in pairs(_db.presets) do n = n + 1 end
  return n
end

--- Returns the count of all tags.
function DB.count_tags()
  if not _db then return 0 end
  local n = 0
  for _ in pairs(_db.tags) do n = n + 1 end
  return n
end

-- ─── Preset tag assignment ────────────────────────────────────────────────────

function DB.add_tag_to_preset(preset_uuid, tag_uuid)
  local p = _db and _db.presets[preset_uuid]
  if not p then return end
  if not p.tags then p.tags = {} end
  for _, t in ipairs(p.tags) do
    if t == tag_uuid then return end  -- already assigned
  end
  p.tags[#p.tags + 1] = tag_uuid
  _dirty = true
end

function DB.remove_tag_from_preset(preset_uuid, tag_uuid)
  local p = _db and _db.presets[preset_uuid]
  if not p or not p.tags then return end
  for i = #p.tags, 1, -1 do
    if p.tags[i] == tag_uuid then table.remove(p.tags, i) end
  end
  _dirty = true
end

return DB
