---------------------------------------------------------------
-- DoiteGroup.lua
-- Handles grouped layout logic for DoiteAuras icons
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------

-- Use a global-named table (compatible with older loader behavior)
local DoiteGroup = _G["DoiteGroup"] or {}
_G["DoiteGroup"] = DoiteGroup

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------
local function num(v, default)
  return tonumber(v) or default or 0
end

-- Fast frame getter (avoid _G["DoiteIcon_"..key] churn in sorting/layout hot paths)
local _GetIconFrame = DoiteAuras_GetIconFrame
if not _GetIconFrame then
  local G = _G
  _GetIconFrame = function(k)
    if not k then
      return nil
    end
    return G["DoiteIcon_" .. k]
  end
end

local function isValidGroupMember(entry)
  if not entry or not entry.data then
    return false
  end
  local g = entry.data.group
  return g and g ~= "" and g ~= "no"
end

local function isKnown(entry)
  -- Abilities might be unknown in another spec; never occupy a slot then
  return not (entry and entry.data and entry.data.isUnknown)
end

-- Resolve sort mode for a group: "prio" (default) or "time"
local function GetGroupSortMode(groupName)
  if not groupName then
    return "prio"
  end

  local db = DoiteAurasDB
  if db and db.groupSort and db.groupSort[groupName] then
    local mode = db.groupSort[groupName]
    if mode == "time" then
      return "time"
    end
  end

  return "prio"
end

-- Resolve fixed layout mode for a group (false by default)
local function GetGroupFixedMode(groupName, leaderData)
  if groupName and DoiteAurasDB and DoiteAurasDB.groupFixed and DoiteAurasDB.groupFixed[groupName] then
    return true
  end
  if leaderData and leaderData.groupFixed == true then
    return true
  end
  return false
end

local function _ComputeOffset(baseX, baseY, growth, pad, steps)
  local x = baseX
  local y = baseY
  if steps and steps > 0 then
    if growth == "Horizontal Right" then
      x = x + (pad * steps)
    elseif growth == "Horizontal Left" then
      x = x - (pad * steps)
    elseif growth == "Vertical Up" then
      y = y + (pad * steps)
    elseif growth == "Vertical Down" then
      y = y - (pad * steps)
    else
      x = x + (pad * steps)
    end
  end
  return x, y
end

-- Centered expansion (keeps whole group centered around baseX/baseY)
local function _ComputeCenteredOffset(baseX, baseY, growth, pad, index, totalVisible)
  local x = baseX
  local y = baseY

  if not totalVisible or totalVisible <= 0 then
    return x, y
  end

  if growth == "Centered Horizontal" then
    local halfCount = totalVisible / 2.0
    local offset = (index - 1) - (halfCount - 0.5)
    x = baseX + (offset * pad)

  elseif growth == "Centered Vertical" then
    local halfCount = totalVisible / 2.0
    local offset = (index - 1) - (halfCount - 0.5)
    y = baseY + (offset * pad)
  end

  return x, y
end

local function _ApplyPlacement(entry, x, y, size)
  if not entry then
    return
  end

  local pos = entry._computedPos
  if not pos then
    pos = {}
    entry._computedPos = pos
  end
  pos.x = x
  pos.y = y
  pos.size = size

  local f = _GetIconFrame(entry.key)
  if f then
    f._daBlockedByGroup = false
    -- Do not re-anchor while the slider owns the frame this tick
    if not f._daSliding then
      if f._daGroupX ~= x or f._daGroupY ~= y then
        f._daGroupX = x
        f._daGroupY = y
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", x, y)
      end
    end
    if f._daGroupSize ~= size then
      f._daGroupSize = size
      f:SetWidth(size)
      f:SetHeight(size)
    end
  end
end

-- Current key being edited
local function editingKey()
  return _G["DoiteEdit_CurrentKey"]
end

---------------------------------------------------------------
-- Sort comparators (no per-sort closure allocations)
---------------------------------------------------------------
local _DG = { editKey = nil }

local function _cmpPrio(a, b)
  local editKey = _DG.editKey
  if editKey then
    if a.key == editKey and b.key ~= editKey then
      return true
    end
    if b.key == editKey and a.key ~= editKey then
      return false
    end
  end

  local da = a.data
  local db = b.data
  local oa = (da and da.order) or 999
  local ob = (db and db.order) or 999

  if oa == ob then
    return (a._dgKeyStr or "") < (b._dgKeyStr or "")
  end
  return oa < ob
end

local function _cmpTime(a, b)
  local editKey = _DG.editKey
  if editKey then
    if a.key == editKey and b.key ~= editKey then
      return true
    end
    if b.key == editKey and a.key ~= editKey then
      return false
    end
  end

  local hasA = a._dgHasRem and true or false
  local hasB = b._dgHasRem and true or false

  if hasA ~= hasB then
    return hasA
  end

  if hasA and hasB then
    local ra = a._dgRem
    local rb = b._dgRem
    if ra ~= rb then
      return ra < rb
    end
  end

  -- fallback to prio behaviour
  return _cmpPrio(a, b)
end

---------------------------------------------------------------
-- Compute layout for a single group, driven by the group's leader
---------------------------------------------------------------
local function ComputeGroupLayout(entries, groupName)
  if not entries or table.getn(entries) == 0 then
    return {}
  end

  -- 1) Find leader; bail if none (group misconfigured)
  local leader = nil
  for _, e in ipairs(entries) do
    if e.data and e.data.isLeader then
      leader = e;
      break
    end
  end
  if not leader then
    return {}
  end

  local L = leader.data
  local baseX = num(L.offsetX, 0)
  local baseY = num(L.offsetY, 0)
  local baseSize = num(L.iconSize, 36)
  local growth = L.growth or "Horizontal Right"
  local limit = num(L.numAuras, 50)
  local fixed = GetGroupFixedMode(groupName, L)
  local settings = (DoiteAurasDB and DoiteAurasDB.settings)
  local spacing = num(L.spacing, (settings and settings.spacing) or 8)
  local pad = baseSize + spacing

  local isCentered = (growth == "Centered Horizontal" or growth == "Centered Vertical")

  -- 2) Build pools: known (for fixed slots) and visible-known (for actual placement)
  local fixedKnown
  if fixed then
    fixedKnown = DoiteGroup._tmpAllKnown
    if not fixedKnown then
      fixedKnown = {}
      DoiteGroup._tmpAllKnown = fixedKnown
    else
      for i = table.getn(fixedKnown), 1, -1 do
        fixedKnown[i] = nil
      end
    end
  end

  -- Build the pool of items that are BOTH known and WANT to be shown (conditions OR sliding) - reuse & shrink table without realloc
  local visibleKnown = DoiteGroup._tmpVisibleKnown
  if not visibleKnown then
    visibleKnown = {}
    DoiteGroup._tmpVisibleKnown = visibleKnown
  else
    for i = table.getn(visibleKnown), 1, -1 do
      visibleKnown[i] = nil
    end
  end

  local editKey = editingKey()
  local vn = 0
  local an = 0
  local i, n = 1, table.getn(entries)
  while i <= n do
    local e = entries[i]
    if e and isKnown(e) then
      if fixed and fixedKnown then
        an = an + 1
        fixedKnown[an] = e
      end
      local f = _GetIconFrame(e.key)
      -- Use frame flags; fall back to 'show' from candidates.
      -- Only use IsShown() fallback if frame flags haven't been initialized yet (avoids blocking collapse).
      local wants = (f and (f._daShouldShow == true or f._daSliding == true))
          or (e.show == true)
          or (f and f._daShouldShow == nil and f._daSliding == nil and f:IsShown())

      -- While editing, always include the edited member in the layout pool
      if editKey and e.key == editKey then
        wants = true
      end

      if wants then
        vn = vn + 1
        visibleKnown[vn] = e
      end
    end
    i = i + 1
  end

  -- Nothing visible? Clear any previous assignment and exit
  if vn == 0 then
    local j, m = 1, table.getn(entries)
    while j <= m do
      local e = entries[j]
      if e then
        e._computedPos = nil
      end
      j = j + 1
    end
    return {}
  end

  -- Decide how to sort this group: "prio" (default) or "time"
  local groupSortCache = DoiteGroup._sortCache or {}
  DoiteGroup._sortCache = groupSortCache

  local sortMode = groupSortCache[groupName]
  if not sortMode then
    sortMode = GetGroupSortMode(groupName)
    groupSortCache[groupName] = sortMode
  end

  local sortList = fixed and fixedKnown or visibleKnown

  -- Precompute cheap sort keys once per entry (avoids frame lookups/tostring churn inside comparator)
  local j = 1
  local sn = fixed and an or vn
  while j <= sn do
    local e = sortList[j]
    local k = e.key
    if not e._dgKeyStr then
      if type(k) == "string" then
        e._dgKeyStr = k
      else
        e._dgKeyStr = tostring(k)
      end
    end

    if sortMode == "time" then
      local f = _GetIconFrame(k)
      local r = f and f._daSortRem or nil
      if r and r > 0 then
        e._dgRem = r
        e._dgHasRem = 1
      else
        e._dgRem = nil
        e._dgHasRem = nil
      end
    end

    j = j + 1
  end

  -- 3) Order by saved priority or remaining time, depending on sort mode
  _DG.editKey = editKey
  if sortMode == "time" then
    table.sort(sortList, _cmpTime)
  else
    table.sort(sortList, _cmpPrio)
  end

  -- 4) Assign up to numAuras slots, starting from leader’s baseXY
  local placed = DoiteGroup._tmpPlaced
  if not placed then
    placed = {}
    DoiteGroup._tmpPlaced = placed
  else
    local i = 1
    while placed[i] ~= nil do
      placed[i] = nil
      i = i + 1
    end
  end

  local actualPlaced = limit
  if vn < actualPlaced then
    actualPlaced = vn
  end

  if fixed then
    -- Assign stable slot indices based on the full known list (no map).
    local s = 1
    while s <= an do
      local e = fixedKnown[s]
      if e then
        e._daFixedSlot = s
      end
      s = s + 1
    end

    -- Place visible-known entries into their fixed slots (up to limit).
    local p = 0
    local v = 1
    while v <= vn do
      local e = visibleKnown[v]
      local slot = e and e._daFixedSlot
      if slot and slot <= limit then
        local curX, curY
        if isCentered then
          curX, curY = _ComputeCenteredOffset(baseX, baseY, growth, pad, slot, limit)
        else
          curX, curY = _ComputeOffset(baseX, baseY, growth, pad, slot - 1)
        end

        -- Inline placement so we can respect _daDragging (avoid fighting the drag owner).
        local pos = e._computedPos
        if not pos then
          pos = {}
          e._computedPos = pos
        end
        pos.x = curX
        pos.y = curY
        pos.size = baseSize

        local f = _GetIconFrame(e.key)
        if f then
          f._daBlockedByGroup = false

          -- Do not re-anchor while sliding OR dragging
          if not f._daSliding and not f._daDragging then
            if f._daGroupX ~= curX or f._daGroupY ~= curY then
              f._daGroupX = curX
              f._daGroupY = curY
              f:ClearAllPoints()
              f:SetPoint("CENTER", UIParent, "CENTER", curX, curY)
            end
          end

          if f._daGroupSize ~= baseSize then
            f._daGroupSize = baseSize
            f:SetWidth(baseSize)
            f:SetHeight(baseSize)
          end
        end

        p = p + 1
        placed[p] = e
      end
      v = v + 1
    end

    actualPlaced = p
  else
    if isCentered then
      local p = 1
      while p <= actualPlaced do
        local e = visibleKnown[p]
        local curX, curY = _ComputeCenteredOffset(baseX, baseY, growth, pad, p, actualPlaced)
        _ApplyPlacement(e, curX, curY, baseSize)
        placed[p] = e
        p = p + 1
      end
    else
      local curX, curY = baseX, baseY
      local p = 1
      while p <= actualPlaced do
        local e = visibleKnown[p]

        _ApplyPlacement(e, curX, curY, baseSize)

        placed[p] = e

        if p < actualPlaced then
          curX, curY = _ComputeOffset(baseX, baseY, growth, pad, p)
        end

        p = p + 1
      end
    end
  end

  -- 5) Everything else must not occupy a position (hide if currently shown)
  local placedSet = DoiteGroup._tmpPlacedSet
  if not placedSet then
    placedSet = {}
    DoiteGroup._tmpPlacedSet = placedSet
  else
    for k in pairs(placedSet) do
      placedSet[k] = nil
    end
  end

  local q = 1
  while q <= actualPlaced do
    local e = placed[q]
    placedSet[e.key] = true
    q = q + 1
  end

  local r, m = 1, table.getn(entries)
  while r <= m do
    local e = entries[r]
    if e and not placedSet[e.key] then
      e._computedPos = nil
      local f = _GetIconFrame(e.key)
      if f then
        if editKey and e.key == editKey then
          -- While editing: do not block or force-hide this member
          f._daBlockedByGroup = false
        else
          f._daBlockedByGroup = true
          if f:IsShown() then
            f:Hide()
          end
        end
      end
    end
    r = r + 1
  end

  return placed

end

---------------------------------------------------------------
-- Public: ApplyGroupLayout over all candidates
---------------------------------------------------------------
function DoiteGroup.ApplyGroupLayout(candidates)
  if not candidates or type(candidates) ~= "table" then
    return
  end
  if _G["DoiteGroup_LayoutInProgress"] then
    return
  end
  _G["DoiteGroup_LayoutInProgress"] = true

  -- Normalize core fields (defensive)
  for _, entry in ipairs(candidates) do
    local d = entry.data or {}
    d.offsetX = num(d.offsetX, 0)
    d.offsetY = num(d.offsetY, 0)
    d.iconSize = num(d.iconSize, 36)
    d.order = num(d.order, 999)
  end

  -- 1) Partition by group (reuse tables to avoid combat allocations)
  local groups = DoiteGroup._tmpGroups
  if not groups then
    groups = {}
    DoiteGroup._tmpGroups = groups
  end

  local seen = DoiteGroup._tmpGroupsSeen
  if not seen then
    seen = {}
    DoiteGroup._tmpGroupsSeen = seen
  else
    for k in pairs(seen) do
      seen[k] = nil
    end
  end

  local idx = DoiteGroup._tmpGroupsIdx
  if not idx then
    idx = {}
    DoiteGroup._tmpGroupsIdx = idx
  else
    for k in pairs(idx) do
      idx[k] = nil
    end
  end

  -- Mark membership for the hook (cheap skip for non-group icons)
  for _, e in ipairs(candidates) do
    local f = e and _GetIconFrame(e.key) or nil
    if f then
      if isValidGroupMember(e) then
        f._daInGroup = true
      else
        f._daInGroup = nil
      end
    end

    if isValidGroupMember(e) then
      local g = e.data.group
      local list = groups[g]
      if not list then
        list = {}
        groups[g] = list
      end

      if not seen[g] then
        -- clear list array once per group
        local i = 1
        while list[i] ~= nil do
          list[i] = nil
          i = i + 1
        end
        seen[g] = true
        idx[g] = 0
      end

      local n = (idx[g] or 0) + 1
      idx[g] = n
      list[n] = e
    end
  end

  -- remove groups not present this pass (keeps Published table clean)
  for g in pairs(groups) do
    if not seen[g] then
      groups[g] = nil
    end
  end

  _hasGroups = false
  for gName, list in pairs(groups) do
    ComputeGroupLayout(list, gName)
    _hasGroups = true
  end

  -- Build a cached list of sliding keys (used to run a tiny OnUpdate ONLY while sliding)
  local slideList = DoiteGroup._tmpSlideList
  if not slideList then
    slideList = {}
    DoiteGroup._tmpSlideList = slideList
  else
    local i = 1
    while slideList[i] ~= nil do
      slideList[i] = nil
      i = i + 1
    end
  end

  local sc = 0
  for gName, list in pairs(groups) do
    local i, n = 1, table.getn(list)
    while i <= n do
      local e = list[i]
      if e then
        local f = _GetIconFrame(e.key)
        if f and f._daSliding == true then
          sc = sc + 1
          slideList[sc] = e.key
        end
      end
      i = i + 1
    end
  end
  DoiteGroup._slidingCount = sc

  -- 3) Publish for ApplyVisuals
  _G["DoiteGroup_Computed"] = groups
  _G["DoiteGroup_LayoutInProgress"] = false

  -- If anything is sliding, keep a tiny watcher active; otherwise ensure it's off
  if sc > 0 and DoiteGroup._EnableSlideWatch then
    DoiteGroup._EnableSlideWatch()
  elseif DoiteGroup._DisableSlideWatch then
    DoiteGroup._DisableSlideWatch()
  end
end


-- Event/flag-driven reflow (no periodic scanning)
local _watch = CreateFrame("Frame", "DoiteGroupWatch")

-- Fallback candidate list/pool (only used if DoiteAuras.GetAllCandidates isn't available)
local _fallbackList = {}
local _fallbackPool = {}

local function _clearArray(t)
  local i = 1
  while t[i] ~= nil do
    t[i] = nil
    i = i + 1
  end
end

local function _collectCandidates()
  if type(DoiteAuras) == "table" and type(DoiteAuras.GetAllCandidates) == "function" then
    return DoiteAuras.GetAllCandidates()
  end

  -- Fallback: synthesize from DB (reuse tables)
  local out = _fallbackList
  local pool = _fallbackPool
  _clearArray(out)

  local src = (DoiteDB and DoiteDB.icons) or (DoiteAurasDB and DoiteAurasDB.spells) or {}
  local n = 0
  for k, d in pairs(src) do
    n = n + 1
    local e = pool[n]
    if not e then
      e = {}
      pool[n] = e
    end
    e.key = k
    e.data = d
    out[n] = e
  end
  return out
end

-- Slide-only OnUpdate: no layout work, just "are any of our cached sliding keys still sliding?"
local function _SlideTick()
  local slideList = DoiteGroup._tmpSlideList
  local sc = DoiteGroup._slidingCount or 0
  if not slideList or sc <= 0 then
    _watch:SetScript("OnUpdate", nil)
    return
  end

  local i = 1
  while i <= sc do
    local key = slideList[i]
    local f = _GetIconFrame(key)
    if f and f._daSliding == true then
      i = i + 1
    else
      -- remove from list (swap with last)
      slideList[i] = slideList[sc]
      slideList[sc] = nil
      sc = sc - 1
    end
  end

  DoiteGroup._slidingCount = sc

  -- If no sliding left and no pending reflow, stop ticking.
  if sc <= 0 and _G["DoiteGroup_NeedReflow"] ~= true then
    _watch:SetScript("OnUpdate", nil)
  end
end

-- One-shot reflow runner (scheduled by RequestReflow / hooked visuals)
local function _RunReflowOnce()
  _watch:SetScript("OnUpdate", nil)
  DoiteGroup._reflowQueued = nil

  if _G["DoiteGroup_LayoutInProgress"] then
    -- try again next frame (layout may be mid-flight)
    DoiteGroup._reflowQueued = 1
    _watch:SetScript("OnUpdate", _RunReflowOnce)
    return
  end

  if _G["DoiteGroup_NeedReflow"] ~= true then
    -- If something requested reflow after, queue it.
    if _G["DoiteGroup_NeedReflow"] == true then
      DoiteGroup.RequestReflow()
      return
    end

    -- Nothing requested; if sliding exists, keep slide tick, else off.
    if (DoiteGroup._slidingCount or 0) > 0 then
      _watch:SetScript("OnUpdate", _SlideTick)
    end
    return
  end

  _G["DoiteGroup_NeedReflow"] = nil

  local candidates = _collectCandidates()
  if candidates and table.getn(candidates) > 0 then
    DoiteGroup.ApplyGroupLayout(candidates)
  else
    -- nothing to do; ensure slide watch is off
    DoiteGroup._slidingCount = 0
    _watch:SetScript("OnUpdate", nil)
  end

  -- If something requested another reflow during this run, queue again.
  if _G["DoiteGroup_NeedReflow"] == true and not _G["DoiteGroup_LayoutInProgress"] then
    DoiteGroup.RequestReflow()
    return
  end
end

-- Public API: request a group reflow (preferred over directly setting the global flag)
function DoiteGroup.RequestReflow()
  _G["DoiteGroup_NeedReflow"] = true
  if DoiteGroup._reflowQueued then
    return
  end
  DoiteGroup._reflowQueued = 1
  _watch:SetScript("OnUpdate", _RunReflowOnce)
end

-- Public API: invalidate cached sort mode for a group (call when sort mode changes)
function DoiteGroup.InvalidateSortCache(groupName)
  if DoiteGroup._sortCache then
    if groupName then
      DoiteGroup._sortCache[groupName] = nil
    else
      -- Clear entire cache if no group specified
      for k in pairs(DoiteGroup._sortCache) do
        DoiteGroup._sortCache[k] = nil
      end
    end
  end
end

-- Internal helpers called by ApplyGroupLayout (Patch 1/2)
function DoiteGroup._EnableSlideWatch()
  if (DoiteGroup._slidingCount or 0) > 0 then
    _watch:SetScript("OnUpdate", _SlideTick)
  end
end

function DoiteGroup._DisableSlideWatch()
  if _G["DoiteGroup_NeedReflow"] ~= true then
    _watch:SetScript("OnUpdate", nil)
  end
end

---------------------------------------------------------------
-- Hook visuals to automatically request reflow when the real-name
-- flags change for any key (shouldShow / sliding)
-- (No assumptions: only hooks if the table+function exist.)
---------------------------------------------------------------
local function _IsKeyGrouped(key)
  local d
  if DoiteDB and DoiteDB.icons then
    d = DoiteDB.icons[key]
  end
  if not d and DoiteAurasDB and DoiteAurasDB.spells then
    d = DoiteAurasDB.spells[key]
  end
  local g = d and d.group
  return g and g ~= "" and g ~= "no"
end

local function _HookApplyVisualsIfPresent()
  if DoiteGroup._applyVisualsHooked then
    return
  end
  if type(DoiteConditions) ~= "table" then
    return
  end
  if type(DoiteConditions.ApplyVisuals) ~= "function" then
    return
  end

  local orig = DoiteConditions.ApplyVisuals

  DoiteConditions.ApplyVisuals = function(a, b, c, d, e)
    -- Supports both call styles:
    --   DoiteConditions:ApplyVisuals(key, show, glow, grey)
    --   DoiteConditions.ApplyVisuals(key, show, glow, grey)
    local self, key, show, glow, grey
    if type(a) == "table" then
      self = a
      key = b
      show = c
      glow = d
      grey = e
    else
      self = DoiteConditions
      key = a
      show = b
      glow = c
      grey = d
    end

    local f = _GetIconFrame(key)

    -- Fast skip: only track grouped keys (works even before first ApplyGroupLayout)
    if not _IsKeyGrouped(key) then
      return orig(self, key, show, glow, grey)
    end

    -- Normalize nil/false so first-time values don't cause "fake changes"
    local oldShould = (f and f._daShouldShow == true) and 1 or 0
    local oldSliding = (f and f._daSliding == true) and 1 or 0

    local r = orig(self, key, show, glow, grey)

    f = _GetIconFrame(key)
    if f then
      local newShould = (f._daShouldShow == true) and 1 or 0
      local newSliding = (f._daSliding == true) and 1 or 0
      if oldShould ~= newShould or oldSliding ~= newSliding then
        DoiteGroup.RequestReflow()
      end
    end

    return r
  end
  DoiteGroup.RequestReflow()
  DoiteGroup._applyVisualsHooked = true
end

-- Attempt hook now, and again on login/addon load (covers load order)
_HookApplyVisualsIfPresent()
_watch:RegisterEvent("PLAYER_LOGIN")
_watch:RegisterEvent("ADDON_LOADED")
_watch:SetScript("OnEvent", function()
  _HookApplyVisualsIfPresent()
end)

---------------------------------------------------------------
-- Edit UI helpers for dynamic Group/Category management
---------------------------------------------------------------
local function _DA_DB()
  DoiteAurasDB = DoiteAurasDB or {}
  DoiteAurasDB.spells = DoiteAurasDB.spells or {}
  DoiteAurasDB.categories = DoiteAurasDB.categories or {}
  return DoiteAurasDB
end

local function _TrimName(v)
  if not v then return "" end
  return (string.gsub(v, "^%s*(.-)%s*$", "%1"))
end

local function _BuildNames(kind)
  local db = _DA_DB()
  local out = {}
  local seen = {}

  if kind == "category" then
    local i = 1
    while i <= table.getn(db.categories) do
      local c = db.categories[i]
      if c and c ~= "" and not seen[c] then
        seen[c] = true
        table.insert(out, c)
      end
      i = i + 1
    end
  end

  for _, d in pairs(db.spells) do
    local n = (kind == "group") and d.group or d.category
    if n and n ~= "" and not seen[n] then
      seen[n] = true
      table.insert(out, n)
    end
  end

  table.sort(out, function(a, b)
    return string.upper(a) < string.upper(b)
  end)
  return out
end

local function _EnsureUniqueLeader(groupName)
  if not groupName or groupName == "" then return end
  local db = _DA_DB()
  local leaderKey = nil
  for k, d in pairs(db.spells) do
    if d.group == groupName and d.isLeader then
      leaderKey = k
      break
    end
  end
  if leaderKey then return end
  for _, d in pairs(db.spells) do
    if d.group == groupName then
      d.isLeader = true
      return
    end
  end
end

local function _CleanupCategoryIfEmpty(name)
  local db = _DA_DB()
  if not name or name == "" then return end
  for _, d in pairs(db.spells) do
    if d.category == name then return end
  end
  local i = 1
  while i <= table.getn(db.categories) do
    if db.categories[i] == name then
      table.remove(db.categories, i)
    else
      i = i + 1
    end
  end
end

local function _CleanupGroupIfEmpty(name)
  local db = _DA_DB()
  if not name or name == "" then return end
  for _, d in pairs(db.spells) do
    if d.group == name then
      _EnsureUniqueLeader(name)
      return
    end
  end
  if db.groupSort then db.groupSort[name] = nil end
  if db.groupFixed then db.groupFixed[name] = nil end
  if db.bucketCollapsed then db.bucketCollapsed[name] = nil end
  if db.bucketDisabled then db.bucketDisabled[name] = nil end
end

function DoiteGroup.AttachEditGroupUI(frame, api)
  if not frame or frame._dgEditorBuilt then return end
  frame._dgEditorBuilt = true

  local state = { step = "pick", mode = nil, rename = false, key = nil }
  local function Ensure() return api and api.Ensure and api.Ensure(state.key) end
  local function RefreshAll()
    if api and api.SafeRefresh then api.SafeRefresh() end
    if api and api.SafeEvaluate then api.SafeEvaluate() end
    if api and api.ListRefresh then pcall(api.ListRefresh) end
  end

  local line = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  line:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -68)
  line:SetWidth(318)
  line:SetJustifyH("LEFT")
  frame.dgLine = line

  local bNew = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bNew:SetWidth(70); bNew:SetHeight(20); bNew:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -6); bNew:SetText("New")
  local bExisting = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bExisting:SetWidth(70); bExisting:SetHeight(20); bExisting:SetPoint("LEFT", bNew, "RIGHT", 6, 0); bExisting:SetText("Existing")

  local bGroup = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bGroup:SetWidth(70); bGroup:SetHeight(20); bGroup:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -6); bGroup:SetText("Group")
  local bCat = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bCat:SetWidth(70); bCat:SetHeight(20); bCat:SetPoint("LEFT", bGroup, "RIGHT", 6, 0); bCat:SetText("Category")
  local bBackA = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bBackA:SetWidth(70); bBackA:SetHeight(20); bBackA:SetPoint("LEFT", bCat, "RIGHT", 6, 0); bBackA:SetText("Back")

  local nameLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  nameLbl:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -10)
  local nameIn = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  nameIn:SetWidth(120); nameIn:SetHeight(18); nameIn:SetAutoFocus(false); nameIn:SetPoint("LEFT", nameLbl, "RIGHT", 8, 0)
  local bAdd = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bAdd:SetWidth(60); bAdd:SetHeight(20); bAdd:SetPoint("LEFT", nameIn, "RIGHT", 6, 0); bAdd:SetText("Add")
  local bBackB = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bBackB:SetWidth(60); bBackB:SetHeight(20); bBackB:SetPoint("LEFT", bAdd, "RIGHT", 6, 0); bBackB:SetText("Back")

  local bRename = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bRename:SetWidth(70); bRename:SetHeight(20); bRename:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -6); bRename:SetText("Rename")
  local bLeave = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bLeave:SetWidth(70); bLeave:SetHeight(20); bLeave:SetPoint("LEFT", bRename, "RIGHT", 6, 0); bLeave:SetText("Leave")
  local leaderCB = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  leaderCB:SetWidth(20); leaderCB:SetHeight(20); leaderCB:SetPoint("LEFT", bLeave, "RIGHT", 8, 0)
  leaderCB.text = leaderCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  leaderCB.text:SetPoint("LEFT", leaderCB, "RIGHT", 2, 0)
  leaderCB.text:SetText("Group Leader")

  local bSettings = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bSettings:SetWidth(90); bSettings:SetHeight(20); bSettings:SetPoint("TOPLEFT", bRename, "BOTTOMLEFT", 0, -4); bSettings:SetText("Settings")

  local bYes = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bYes:SetWidth(70); bYes:SetHeight(20); bYes:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -6); bYes:SetText("Yes")
  local bBackC = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bBackC:SetWidth(70); bBackC:SetHeight(20); bBackC:SetPoint("LEFT", bYes, "RIGHT", 6, 0); bBackC:SetText("Back")

  local groupDD = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate")
  groupDD:SetPoint("TOPLEFT", line, "BOTTOMLEFT", -16, -4); UIDropDownMenu_SetWidth(120, groupDD)
  local catDD = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate")
  catDD:SetPoint("LEFT", groupDD, "RIGHT", 6, 0); UIDropDownMenu_SetWidth(120, catDD)
  local bBackD = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bBackD:SetWidth(60); bBackD:SetHeight(20); bBackD:SetPoint("LEFT", catDD, "RIGHT", -4, 2); bBackD:SetText("Back")

  frame.dgGrowthLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.dgGrowthLabel:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -6)
  frame.dgGrowthLabel:SetText("Group expand direction:")
  local growthDD = frame.growthDD
  if growthDD then growthDD:ClearAllPoints(); growthDD:SetPoint("LEFT", frame.dgGrowthLabel, "RIGHT", -6, -2) end
  local numLbl = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  numLbl:SetPoint("TOPLEFT", frame.dgGrowthLabel, "BOTTOMLEFT", 0, -10); numLbl:SetText("# of icons visible:")
  local numDD = frame.numAurasDD
  if numDD then numDD:ClearAllPoints(); numDD:SetPoint("LEFT", numLbl, "RIGHT", -6, -2) end
  local spaceLbl = frame.spacingLabel
  if spaceLbl then spaceLbl:ClearAllPoints(); spaceLbl:SetPoint("TOPLEFT", numLbl, "BOTTOMLEFT", 0, -12); spaceLbl:SetText("Spacing between icons:") end
  local spaceS = frame.spacingSlider
  if spaceS then spaceS:ClearAllPoints(); spaceS:SetPoint("LEFT", spaceLbl, "RIGHT", 10, 0) end
  local spaceE = frame.spacingEdit
  if spaceE then spaceE:ClearAllPoints(); spaceE:SetPoint("LEFT", spaceS, "RIGHT", 8, 0) end
  local bBackSettings = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  bBackSettings:SetWidth(60); bBackSettings:SetHeight(20); bBackSettings:SetPoint("LEFT", spaceE, "RIGHT", 8, 0); bBackSettings:SetText("Back")

  local all = { bNew,bExisting,bGroup,bCat,bBackA,nameLbl,nameIn,bAdd,bBackB,bRename,bLeave,leaderCB,bSettings,bYes,bBackC,groupDD,catDD,bBackD,frame.dgGrowthLabel,numLbl,bBackSettings }
  local function HideAll() local i=1 while i<=table.getn(all) do all[i]:Hide(); i=i+1 end if growthDD then growthDD:Hide() end if numDD then numDD:Hide() end if spaceLbl then spaceLbl:Hide() end if spaceS then spaceS:Hide() end if spaceE then spaceE:Hide() end end

  local function SetAddState()
    local txt = _TrimName(nameIn:GetText() or "")
    local list = _BuildNames(state.mode)
    local dup = false
    local i = 1
    while i <= table.getn(list) do if string.upper(list[i]) == string.upper(txt) and list[i] ~= state._renameFrom then dup = true; break end i=i+1 end
    if txt == "" or dup then bAdd:Disable() else bAdd:Enable() end
  end

  local function Join(kind, name)
    local d = Ensure(); if not d then return end
    if kind == "group" then
      d.category = nil
      d.group = name
      d.isLeader = false
      _EnsureUniqueLeader(name)
      local hasLeader = false
      for k2, s in pairs(_DA_DB().spells) do if s.group == name and s.isLeader then hasLeader = true; break end end
      if not hasLeader then d.isLeader = true end
      state.step = "ingroup"
    else
      d.group = nil
      d.isLeader = false
      d.category = name
      local db = _DA_DB()
      local found = false
      local i=1 while i<=table.getn(db.categories) do if db.categories[i]==name then found=true break end i=i+1 end
      if not found then table.insert(db.categories, name) end
      state.step = "incategory"
    end
    RefreshAll()
  end

  local function LeaveCurrent()
    local d = Ensure(); if not d then return end
    if state.mode == "category" then
      local old = d.category
      d.category = nil
      _CleanupCategoryIfEmpty(old)
      state.step = "pick"
    else
      local old = d.group
      local wasLeader = d.isLeader
      d.group = nil; d.isLeader = false
      if wasLeader and old then _EnsureUniqueLeader(old) end
      _CleanupGroupIfEmpty(old)
      state.step = "pick"
    end
    RefreshAll()
  end

  local function RenameAll(newName)
    local d = Ensure(); if not d then return end
    local from = state._renameFrom
    if not from or from == "" then return end
    if state.mode == "category" then
      for _, s in pairs(_DA_DB().spells) do if s.category == from then s.category = newName end end
      local db = _DA_DB(); local found=false; local i=1 while i<=table.getn(db.categories) do if db.categories[i]==from then db.categories[i]=newName; found=true end i=i+1 end
      if not found then table.insert(db.categories, newName) end
      _CleanupCategoryIfEmpty(from)
      d.category = newName
      state.step = "incategory"
    else
      for _, s in pairs(_DA_DB().spells) do if s.group == from then s.group = newName end end
      local db = _DA_DB()
      if db.groupSort and db.groupSort[from] ~= nil then db.groupSort[newName] = db.groupSort[from]; db.groupSort[from] = nil end
      if db.groupFixed and db.groupFixed[from] ~= nil then db.groupFixed[newName] = db.groupFixed[from]; db.groupFixed[from] = nil end
      d.group = newName
      _CleanupGroupIfEmpty(from)
      _EnsureUniqueLeader(newName)
      state.step = "ingroup"
    end
    RefreshAll()
  end

  local function Refresh()
    local d = Ensure(); if not d then return end
    HideAll()
    state.mode = nil
    if d.group and d.group ~= "" then state.mode = "group"; state.step = state.step == "settings" and "settings" or "ingroup"
    elseif d.category and d.category ~= "" then state.mode = "category"; state.step = "incategory"
    elseif state.step ~= "newkind" and state.step ~= "newname" and state.step ~= "existing" then state.step = "pick" end

    if state.step == "pick" then
      line:SetText("If you want to Group or Categorize this icon, select an option below:")
      bNew:Show(); bExisting:Show()
    elseif state.step == "newkind" then
      line:SetText("Would you like to place the icon in a new Group or Category?")
      bGroup:Show(); bCat:Show(); bBackA:Show()
    elseif state.step == "newname" then
      line:SetText("Please select a unique name below:")
      nameLbl:SetText(state.mode == "group" and "New Group name:" or "New Category name:")
      nameLbl:Show(); nameIn:Show(); bAdd:Show(); bBackB:Show(); SetAddState()
    elseif state.step == "incategory" then
      line:SetText("Included in Category: " .. tostring(d.category or ""))
      bRename:Show(); bLeave:Show()
    elseif state.step == "ingroup" then
      line:SetText("Included in Group: " .. tostring(d.group or ""))
      bRename:Show(); bLeave:Show(); leaderCB:Show(); bSettings:Show()
      leaderCB:SetChecked(d.isLeader and true or false)
      if d.isLeader then leaderCB:Disable(); bSettings:Enable() else leaderCB:Enable(); bSettings:Disable() end
    elseif state.step == "confirmleave" then
      if state.mode == "group" then line:SetText("Are you sure you want the icon to leave the group?") else line:SetText("Are you sure you want the icon to leave the category?") end
      bYes:Show(); bBackC:Show()
    elseif state.step == "existing" then
      line:SetText("Select what existing Group or Category you want to place the icon in:")
      groupDD:Show(); catDD:Show(); bBackD:Show()
      UIDropDownMenu_Initialize(groupDD, function()
        local arr = _BuildNames("group")
        local i=1 while i<=table.getn(arr) do local n=arr[i]; local info=UIDropDownMenu_CreateInfo(); info.text=n; info.value=n; info.func=function() Join("group", n) end; UIDropDownMenu_AddButton(info); i=i+1 end
      end)
      UIDropDownMenu_SetText("Group", groupDD)
      UIDropDownMenu_Initialize(catDD, function()
        local arr = _BuildNames("category")
        local i=1 while i<=table.getn(arr) do local n=arr[i]; local info=UIDropDownMenu_CreateInfo(); info.text=n; info.value=n; info.func=function() Join("category", n) end; UIDropDownMenu_AddButton(info); i=i+1 end
      end)
      UIDropDownMenu_SetText("Category", catDD)
    elseif state.step == "settings" then
      line:SetText("Group settings")
      frame.dgGrowthLabel:Show(); if growthDD then growthDD:Show() end
      numLbl:Show(); if numDD then numDD:Show() end
      if spaceLbl then spaceLbl:Show() end; if spaceS then spaceS:Show() end; if spaceE then spaceE:Show() end
      if growthDD and frame.InitGrowthDropdown then
        frame.InitGrowthDropdown(growthDD, d)
        UIDropDownMenu_SetText(d.growth or "Horizontal Right", growthDD)
      end
      if numDD and frame.InitNumAurasDropdown then
        frame.InitNumAurasDropdown(numDD, d)
        UIDropDownMenu_SetText(tostring(d.numAuras or 5), numDD)
      end
      local settings = (DoiteAurasDB and DoiteAurasDB.settings)
      local s = d.spacing
      if not s then s = (settings and settings.spacing) or 8 end
      if spaceS then spaceS:SetValue(s) end
      if spaceE then spaceE:SetText(tostring(s)) end
      bBackSettings:Show()
    end
  end

  bNew:SetScript("OnClick", function() state.step = "newkind"; Refresh() end)
  bExisting:SetScript("OnClick", function() state.step = "existing"; Refresh() end)
  bGroup:SetScript("OnClick", function() state.mode = "group"; state.step = "newname"; state.rename=false; state._renameFrom=nil; nameIn:SetText(""); Refresh() end)
  bCat:SetScript("OnClick", function() state.mode = "category"; state.step = "newname"; state.rename=false; state._renameFrom=nil; nameIn:SetText(""); Refresh() end)
  bBackA:SetScript("OnClick", function() state.step = "pick"; Refresh() end)
  bBackB:SetScript("OnClick", function() if state.rename then state.step = (state.mode == "group") and "ingroup" or "incategory" else state.step = "newkind" end; Refresh() end)
  bRename:SetScript("OnClick", function() local d=Ensure(); state.rename=true; state._renameFrom=(state.mode=="group") and d.group or d.category; nameIn:SetText(state._renameFrom or ""); state.step="newname"; Refresh() end)
  bLeave:SetScript("OnClick", function() state.step = "confirmleave"; Refresh() end)
  bYes:SetScript("OnClick", function() LeaveCurrent(); Refresh() end)
  bBackC:SetScript("OnClick", function() state.step = (state.mode == "group") and "ingroup" or "incategory"; Refresh() end)
  bBackD:SetScript("OnClick", function() state.step = "pick"; Refresh() end)
  bSettings:SetScript("OnClick", function() state.step = "settings"; Refresh() end)
  bBackSettings:SetScript("OnClick", function() state.step = "ingroup"; Refresh() end)

  leaderCB:SetScript("OnClick", function(self)
    local d = Ensure(); if not d or not d.group then self:SetChecked(false); return end
    if self:GetChecked() then
      for k, s in pairs(_DA_DB().spells) do if s.group == d.group and k ~= state.key then s.isLeader = false end end
      d.isLeader = true
      self:SetChecked(true); self:Disable()
      bSettings:Enable()
      RefreshAll()
    else
      self:SetChecked(d.isLeader and true or false)
    end
  end)

  nameIn:SetScript("OnTextChanged", function() SetAddState() end)
  bAdd:SetScript("OnClick", function()
    local picked = _TrimName(nameIn:GetText() or "")
    if picked == "" then return end
    if state.rename then RenameAll(picked) else Join(state.mode, picked) end
    nameIn:SetText("")
    Refresh()
  end)

  frame.DoiteGroupUIRefresh = function(_, key)
    state.key = key
    Refresh()
  end
  frame.DoiteGroupUIIsLeaderOrFree = function()
    local d = Ensure()
    if not d then return true end
    if not d.group or d.group == "" then return true end
    return d.isLeader == true
  end
end
