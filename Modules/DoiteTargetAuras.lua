---------------------------------------------------------------
-- DoiteTargetAuras.lua
-- Target aura cache + lookup helpers (buffs/debuffs, slot + stack counts)
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------
local MAX_BUFF_SLOTS = 32
local MAX_DEBUFF_SLOTS = 16
local CACHE_TTL_SECONDS = 15 * 60

local function CreateGuidCache(guid)
  return {
    guid = guid,
    buffs = {},
    debuffs = {},
    activeBuffs = {},
    activeDebuffs = {},
    cappedBuffsExpirationTime = {},
    cappedBuffsStacks = {},
    numActiveBuffs = 0,
    numActiveDebuffs = 0,
    lastSeenTime = GetTime(),
  }
end

local DoiteTargetAuras = {
  guidCaches = {}, -- guid -> cache

  buffs = {}, -- current target cache only: slot -> { spellId, stacks }
  debuffs = {}, -- current target cache only: slot -> { spellId, stacks }

  spellIdToNameCache = {}, -- spellId -> spell name
  spellNameToIdCache = {}, -- spell name -> spellId
  spellNameToMaxStacks = {}, -- spell name -> max stacks

  activeBuffs = {}, -- current target cache: spell name -> slot
  activeDebuffs = {}, -- current target cache: spell name -> slot

  cappedBuffsExpirationTime = {}, -- current target cache: spell name -> expiration time in seconds
  cappedBuffsStacks = {}, -- current target cache: spell name -> stacks

  numActiveBuffs = 0,
  numActiveDebuffs = 0,

  targetGuid = "",

  buffCapEventsEnabled = true,
}

_G["DoiteTargetAuras"] = DoiteTargetAuras

local function NotifyConditionsChanged()
  local req = _G["DoiteConditions_RequestImmediateEval"]
  if req then
    req()
  end
end

local function SetActiveCache(cache)
  DoiteTargetAuras.buffs = cache.buffs
  DoiteTargetAuras.debuffs = cache.debuffs
  DoiteTargetAuras.activeBuffs = cache.activeBuffs
  DoiteTargetAuras.activeDebuffs = cache.activeDebuffs
  DoiteTargetAuras.cappedBuffsExpirationTime = cache.cappedBuffsExpirationTime
  DoiteTargetAuras.cappedBuffsStacks = cache.cappedBuffsStacks
  DoiteTargetAuras.numActiveBuffs = cache.numActiveBuffs
  DoiteTargetAuras.numActiveDebuffs = cache.numActiveDebuffs
end

local function CopyCacheCountsFromActive(cache)
  cache.numActiveBuffs = DoiteTargetAuras.numActiveBuffs
  cache.numActiveDebuffs = DoiteTargetAuras.numActiveDebuffs
end

SetActiveCache(CreateGuidCache(""))

local function GetGuidCache(guid)
  if not guid or guid == "" then
    return nil
  end
  return DoiteTargetAuras.guidCaches[guid]
end

local function GetOrCreateGuidCache(guid)
  if not guid or guid == "" then
    return nil
  end

  local cache = DoiteTargetAuras.guidCaches[guid]
  if not cache then
    cache = CreateGuidCache(guid)
    DoiteTargetAuras.guidCaches[guid] = cache
  end
  cache.lastSeenTime = GetTime()
  return cache
end

local function MarkActive(spellId, activeTable, slot)
  if not DoiteTargetAuras.spellIdToNameCache[spellId] then
    local spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
      activeTable[spellName] = slot
    end
  else
    local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
    if spellName then
      activeTable[spellName] = slot
    end
  end
end

local function MarkInactive(spellId, activeTable)
  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if spellName then
    activeTable[spellName] = false
  end
end

local function RemoveCappedBuff(spellName)
  DoiteTargetAuras.cappedBuffsExpirationTime[spellName] = 0
  DoiteTargetAuras.cappedBuffsStacks[spellName] = 0
end

local function HasAnyActiveCappedBuffs()
  local now = GetTime()
  local _, cache
  for _, cache in pairs(DoiteTargetAuras.guidCaches) do
    local _, expiration
    for _, expiration in pairs(cache.cappedBuffsExpirationTime) do
      if expiration > now then
        return true
      end
    end
  end

  return false
end

local function CleanupGuidCaches()
  local now = GetTime()
  local guid, cache
  for guid, cache in pairs(DoiteTargetAuras.guidCaches) do
    if (now - cache.lastSeenTime) > CACHE_TTL_SECONDS then
      DoiteTargetAuras.guidCaches[guid] = nil
    end
  end
end

local function SetTargetGuid(guid)
  if not guid or guid == "" then
    DoiteTargetAuras.targetGuid = ""
    SetActiveCache(CreateGuidCache(""))
    return nil
  end

  DoiteTargetAuras.targetGuid = guid
  local cache = GetOrCreateGuidCache(guid)
  SetActiveCache(cache)
  return cache
end

local function UpdateTargetGuid()
  local _, guid = UnitExists("target")
  return SetTargetGuid(guid)
end

local function IsCurrentTargetPlayer()
  if not DoiteTargetAuras.targetGuid or DoiteTargetAuras.targetGuid == "" then
    return false
  end

  local _, playerGuid = UnitExists("player")
  return playerGuid and DoiteTargetAuras.targetGuid == playerGuid
end

local function UpdateAuras()
  CleanupGuidCaches()

  local cache = UpdateTargetGuid()
  if not cache then
    if not HasAnyActiveCappedBuffs() then
      DoiteTargetAuras.UnregisterBuffCapEvents()
    end
    return
  end

  local auraSpellIds = GetUnitField("target", "aura")
  local auraStacks = GetUnitField("target", "auraApplications")

  if not auraSpellIds or not auraStacks then
    if not HasAnyActiveCappedBuffs() then
      DoiteTargetAuras.UnregisterBuffCapEvents()
    end
    return
  end

  cache.activeBuffs = {}
  cache.activeDebuffs = {}
  cache.numActiveBuffs = 0
  cache.numActiveDebuffs = 0

  SetActiveCache(cache)

  local i
  for i = 1, MAX_BUFF_SLOTS do
    local spellId = auraSpellIds[i]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.buffs[i] = { spellId = spellId, stacks = auraStacks[i] + 1 }
      MarkActive(spellId, DoiteTargetAuras.activeBuffs, i)
      DoiteTargetAuras.numActiveBuffs = i
    else
      DoiteTargetAuras.buffs[i] = nil
    end
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    local auraIndex = MAX_BUFF_SLOTS + i
    local spellId = auraSpellIds[auraIndex]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.debuffs[i] = { spellId = spellId, stacks = auraStacks[auraIndex] + 1 }
      MarkActive(spellId, DoiteTargetAuras.activeDebuffs, i)
      DoiteTargetAuras.numActiveDebuffs = i
    else
      DoiteTargetAuras.debuffs[i] = nil
    end
  end

  CopyCacheCountsFromActive(cache)

  if DoiteTargetAuras.numActiveBuffs >= MAX_BUFF_SLOTS then
    DoiteTargetAuras.RegisterBuffCapEvents()
  elseif not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end

function DoiteTargetAuras.Refresh()
  UpdateAuras()
  NotifyConditionsChanged()
end

function DoiteTargetAuras.IsHiddenByBuffCap(spellName)
  local expirationTime = DoiteTargetAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    if expirationTime > GetTime() then
      return true
    end
    RemoveCappedBuff(spellName)
  end
  return false
end

function DoiteTargetAuras.IsActive(spellName)
  return DoiteTargetAuras.activeBuffs[spellName] or
      DoiteTargetAuras.activeDebuffs[spellName] or
      DoiteTargetAuras.IsHiddenByBuffCap(spellName)
end

function DoiteTargetAuras.HasBuff(spellName)
  return DoiteTargetAuras.activeBuffs[spellName] or
      DoiteTargetAuras.IsHiddenByBuffCap(spellName)
end

function DoiteTargetAuras.HasDebuff(spellName)
  return DoiteTargetAuras.activeDebuffs[spellName] or false
end

function DoiteTargetAuras.GetBuffStacks(spellName)
  local cachedSlot = DoiteTargetAuras.activeBuffs[spellName]
  if not cachedSlot then
    if DoiteTargetAuras.IsHiddenByBuffCap(spellName) then
      return DoiteTargetAuras.cappedBuffsStacks[spellName]
    end
    return nil
  end

  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  if DoiteTargetAuras.buffs[cachedSlot] and DoiteTargetAuras.buffs[cachedSlot].spellId == spellId then
    return DoiteTargetAuras.buffs[cachedSlot].stacks
  end

  local i
  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId then
      return aura.stacks
    end
  end

  return nil
end

function DoiteTargetAuras.GetActiveAuraSlot(spellName)
  local buffSlot = DoiteTargetAuras.activeBuffs[spellName]
  if buffSlot then
    return buffSlot - 1
  end

  local debuffSlot = DoiteTargetAuras.activeDebuffs[spellName]
  if debuffSlot then
    return MAX_BUFF_SLOTS + debuffSlot - 1
  end

  return nil
end

function DoiteTargetAuras.GetDebuffStacks(spellName)
  local cachedSlot = DoiteTargetAuras.activeDebuffs[spellName]
  if not cachedSlot then
    return nil
  end

  local spellId = DoiteTargetAuras.spellNameToIdCache[spellName]
  if not spellId then
    return nil
  end

  if DoiteTargetAuras.debuffs[cachedSlot] and DoiteTargetAuras.debuffs[cachedSlot].spellId == spellId then
    return DoiteTargetAuras.debuffs[cachedSlot].stacks
  end

  local i
  for i = 1, MAX_DEBUFF_SLOTS do
    local aura = DoiteTargetAuras.debuffs[i]
    if aura and aura.spellId == spellId then
      return aura.stacks
    end
  end

  return nil
end

function DoiteTargetAuras.HasBuffSpellId(spellId)
  local i
  for i = 1, MAX_BUFF_SLOTS do
    local aura = DoiteTargetAuras.buffs[i]
    if aura and aura.spellId == spellId then
      return true
    end
  end

  -- IMPORTANT: this API must stay spellId-exact.
  -- Falling back to HasBuff(name) turns rank/name aliases into false positives,
  -- which can classify a single aura as both "mine" and "other".
  return false
end

function DoiteTargetAuras.HasDebuffSpellId(spellId)
  local i
  for i = 1, MAX_DEBUFF_SLOTS do
    local aura = DoiteTargetAuras.debuffs[i]
    if aura and aura.spellId == spellId then
      return true
    end
  end

  -- Keep spellId checks exact for the same reason as HasBuffSpellId.
  return false
end

function DoiteTargetAuras.GetHiddenBuffRemaining(spellName)
  local expirationTime = DoiteTargetAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 then
    local remaining = expirationTime - GetTime()
    if remaining > 0 then
      return remaining
    end
    RemoveCappedBuff(spellName)
  end
  return nil
end

local TargetChangedFrame = CreateFrame("Frame", "DoiteTargetAuras_TargetChanged")
TargetChangedFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
TargetChangedFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
TargetChangedFrame:SetScript("OnEvent", function()
  UpdateAuras()
  NotifyConditionsChanged()
end)

-- Self aura NP events are required when player is the current target.
-- In that case, *_OTHER events do not fire, so refresh target cache directly.
local SelfAuraFrame = CreateFrame("Frame", "DoiteTargetAuras_SelfAura")
SelfAuraFrame:RegisterEvent("BUFF_ADDED_SELF")
SelfAuraFrame:RegisterEvent("BUFF_REMOVED_SELF")
SelfAuraFrame:RegisterEvent("DEBUFF_ADDED_SELF")
SelfAuraFrame:RegisterEvent("DEBUFF_REMOVED_SELF")
SelfAuraFrame:SetScript("OnEvent", function()
  if not IsCurrentTargetPlayer() then
    return
  end

  UpdateAuras()
  NotifyConditionsChanged()
end)

local UnitDiedFrame = CreateFrame("Frame", "DoiteTargetAuras_UnitDied")
UnitDiedFrame:RegisterEvent("UNIT_DIED")
UnitDiedFrame:SetScript("OnEvent", function()
  local guid = arg1
  if not guid or guid == "" then
    return
  end

  DoiteTargetAuras.guidCaches[guid] = nil
  if guid == DoiteTargetAuras.targetGuid then
    SetTargetGuid(nil)
    NotifyConditionsChanged()
  end

  if not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end)

local BuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffAddedOther")
BuffAddedOtherFrame:RegisterEvent("BUFF_ADDED_OTHER")
BuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot + 1
  cache.buffs[slot] = { spellId = spellId, stacks = stacks }
  MarkActive(spellId, cache.activeBuffs, slot)

  if state == 0 then
    cache.numActiveBuffs = cache.numActiveBuffs + 1
    if cache.numActiveBuffs >= MAX_BUFF_SLOTS then
      DoiteTargetAuras.RegisterBuffCapEvents()
    end
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Ownership swaps/refreshes can arrive as compact event sequences where
    -- slot-level deltas are ambiguous (especially for same-name debuffs).
    -- Rebuild from the authoritative target aura array to avoid stale
    -- activeDebuffs/activeBuffs state that can hide icons until a later reset.
    UpdateAuras()
    NotifyConditionsChanged()
  end
end)

local BuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffRemovedOther")
BuffRemovedOtherFrame:RegisterEvent("BUFF_REMOVED_OTHER")
BuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot + 1
  if state == 1 then
    cache.buffs[slot] = nil
    MarkInactive(spellId, cache.activeBuffs)
    cache.numActiveBuffs = cache.numActiveBuffs - 1
  else
    if cache.buffs[slot] then
      cache.buffs[slot].stacks = stacks
    else
      cache.buffs[slot] = { spellId = spellId, stacks = stacks }
    end
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Keep cache state authoritative during overwrite/replacement sequences.
    UpdateAuras()
    NotifyConditionsChanged()
  end

  if not HasAnyActiveCappedBuffs() then
    DoiteTargetAuras.UnregisterBuffCapEvents()
  end
end)

local DebuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffAddedOther")
DebuffAddedOtherFrame:RegisterEvent("DEBUFF_ADDED_OTHER")
DebuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6

  if not guid or guid == "" then
    return
  end

  if auraSlot < MAX_BUFF_SLOTS or auraSlot >= (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot - MAX_BUFF_SLOTS + 1
  cache.debuffs[slot] = { spellId = spellId, stacks = stacks }
  MarkActive(spellId, cache.activeDebuffs, slot)

  if arg7 == 0 then
    cache.numActiveDebuffs = cache.numActiveDebuffs + 1
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Keep cache state authoritative during overwrite/replacement sequences.
    UpdateAuras()
    NotifyConditionsChanged()
  end
end)

local DebuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffRemovedOther")
DebuffRemovedOtherFrame:RegisterEvent("DEBUFF_REMOVED_OTHER")
DebuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if not guid or guid == "" then
    return
  end

  if auraSlot < MAX_BUFF_SLOTS or auraSlot >= (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    return
  end

  local cache = GetGuidCache(guid)
  if not cache and guid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(guid)

  local slot = auraSlot - MAX_BUFF_SLOTS + 1
  if state == 1 then
    cache.debuffs[slot] = nil
    MarkInactive(spellId, cache.activeDebuffs)
    cache.numActiveDebuffs = cache.numActiveDebuffs - 1
  else
    if cache.debuffs[slot] then
      cache.debuffs[slot].stacks = stacks
    else
      cache.debuffs[slot] = { spellId = spellId, stacks = stacks }
    end
  end

  cache.lastSeenTime = GetTime()

  if guid == DoiteTargetAuras.targetGuid then
    -- Keep cache state authoritative during overwrite/replacement sequences.
    UpdateAuras()
    NotifyConditionsChanged()
  end
end)

local AuraCastOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_AuraCastOther")
AuraCastOtherFrame:RegisterEvent("AURA_CAST_ON_OTHER")
AuraCastOtherFrame:SetScript("OnEvent", function()
  local spellId = arg1
  local targetGuid = arg3
  local durationMs = arg8
  local auraCapStatus = arg9

  if not targetGuid or targetGuid == "" then
    return
  end

  if not (auraCapStatus == 1 or auraCapStatus == 3) then
    return
  end

  local cache = GetGuidCache(targetGuid)
  if not cache and targetGuid ~= DoiteTargetAuras.targetGuid then
    return
  end
  cache = cache or GetOrCreateGuidCache(targetGuid)

  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if not spellName then
    spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
    else
      return
    end
  end

  if not DoiteTargetAuras.spellNameToMaxStacks[spellName] then
    local maxStacks = GetSpellRecField(spellId, "stackAmount")
    if maxStacks == 0 then
      maxStacks = 1
    end
    DoiteTargetAuras.spellNameToMaxStacks[spellName] = maxStacks
  end

  local expirationTime = cache.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 and expirationTime <= GetTime() then
    cache.cappedBuffsStacks[spellName] = 0
  end

  cache.cappedBuffsExpirationTime[spellName] = GetTime() + durationMs / 1000.0

  local currentStacks = cache.cappedBuffsStacks[spellName] or 0
  local maxStacks = DoiteTargetAuras.spellNameToMaxStacks[spellName] or 1
  cache.cappedBuffsStacks[spellName] = math.min(currentStacks + 1, maxStacks)
  cache.lastSeenTime = GetTime()

  if targetGuid == DoiteTargetAuras.targetGuid then
    SetActiveCache(cache)
    NotifyConditionsChanged()
  end
end)

function DoiteTargetAuras.RegisterBuffCapEvents()
  DoiteTargetAuras.buffCapEventsEnabled = true
end

function DoiteTargetAuras.UnregisterBuffCapEvents()
  DoiteTargetAuras.buffCapEventsEnabled = false
end
