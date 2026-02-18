---------------------------------------------------------------
-- DoiteTargetAuras.lua
-- Target aura cache + lookup helpers (buffs/debuffs, slot + stack counts)
-- Please respect license note: Ask permission
-- WoW 1.12 | Lua 5.0
---------------------------------------------------------------
local MAX_BUFF_SLOTS = 32
local MAX_DEBUFF_SLOTS = 16

local DoiteTargetAuras = {
  buffs = {}, -- slot -> { spellId, stacks }
  debuffs = {}, -- slot -> { spellId, stacks }

  spellIdToNameCache = {}, -- spellId -> spell name
  spellNameToIdCache = {}, -- spell name -> spellId
  spellNameToMaxStacks = {}, -- spell name -> max stacks

  activeBuffs = {}, -- spell name -> slot
  activeDebuffs = {}, -- spell name -> slot

  cappedBuffsExpirationTime = {}, -- spell name -> expiration time in seconds
  cappedBuffsStacks = {}, -- spell name -> stacks

  targetGuid = "",

  buffCapEventsEnabled = false,
}

for i = 1, MAX_BUFF_SLOTS do
  table.insert(DoiteTargetAuras.buffs, { spellId = nil, stacks = nil })
end
for i = 1, MAX_DEBUFF_SLOTS do
  table.insert(DoiteTargetAuras.debuffs, { spellId = nil, stacks = nil })
end

_G["DoiteTargetAuras"] = DoiteTargetAuras

local function NotifyConditionsChanged()
  local req = _G["DoiteConditions_RequestImmediateEval"]
  if req then
    req()
  end
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

local function ResetAuras()
  local i
  for i = 1, MAX_BUFF_SLOTS do
    DoiteTargetAuras.buffs[i].spellId = nil
    DoiteTargetAuras.buffs[i].stacks = nil
  end
  for i = 1, MAX_DEBUFF_SLOTS do
    DoiteTargetAuras.debuffs[i].spellId = nil
    DoiteTargetAuras.debuffs[i].stacks = nil
  end
  DoiteTargetAuras.activeBuffs = {}
  DoiteTargetAuras.activeDebuffs = {}
end

local function UpdateTargetGuid()
  local _, guid = UnitExists("target")
  if guid and guid ~= "" then
    DoiteTargetAuras.targetGuid = guid
    return true
  end
  DoiteTargetAuras.targetGuid = ""
  return false
end

local function UpdateAuras()
  if not UpdateTargetGuid() then
    ResetAuras()
    return
  end

  local auraSpellIds = GetUnitField("target", "aura")
  local auraStacks = GetUnitField("target", "auraApplications")

  if not auraSpellIds or not auraStacks then
    ResetAuras()
    return
  end

  DoiteTargetAuras.activeBuffs = {}
  DoiteTargetAuras.activeDebuffs = {}

  local i
  for i = 1, MAX_BUFF_SLOTS do
    local spellId = auraSpellIds[i]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.buffs[i].spellId = spellId
      DoiteTargetAuras.buffs[i].stacks = auraStacks[i] + 1
      MarkActive(spellId, DoiteTargetAuras.activeBuffs, i)
    else
      DoiteTargetAuras.buffs[i].spellId = nil
      DoiteTargetAuras.buffs[i].stacks = nil
    end
  end

  for i = 1, MAX_DEBUFF_SLOTS do
    local auraIndex = MAX_BUFF_SLOTS + i
    local spellId = auraSpellIds[auraIndex]
    if spellId and spellId ~= 0 then
      DoiteTargetAuras.debuffs[i].spellId = spellId
      DoiteTargetAuras.debuffs[i].stacks = auraStacks[auraIndex] + 1
      MarkActive(spellId, DoiteTargetAuras.activeDebuffs, i)
    else
      DoiteTargetAuras.debuffs[i].spellId = nil
      DoiteTargetAuras.debuffs[i].stacks = nil
    end
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
    if not DoiteTargetAuras.buffs[i].spellId then
      break
    end
    if DoiteTargetAuras.buffs[i].spellId == spellId then
      return DoiteTargetAuras.buffs[i].stacks
    end
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
    if not DoiteTargetAuras.debuffs[i].spellId then
      break
    end
    if DoiteTargetAuras.debuffs[i].spellId == spellId then
      return DoiteTargetAuras.debuffs[i].stacks
    end
  end

  return nil
end

function DoiteTargetAuras.HasBuffSpellId(spellId)
  local i
  for i = 1, MAX_BUFF_SLOTS do
    if DoiteTargetAuras.buffs[i].spellId == spellId then
      return true
    end
  end

  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if not spellName then
    spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
    end
  end
  if not spellName then
    return false
  end
  return DoiteTargetAuras.HasBuff(spellName)
end

function DoiteTargetAuras.HasDebuffSpellId(spellId)
  local i
  for i = 1, MAX_DEBUFF_SLOTS do
    if DoiteTargetAuras.debuffs[i].spellId == spellId then
      return true
    end
  end

  local spellName = DoiteTargetAuras.spellIdToNameCache[spellId]
  if not spellName then
    spellName = GetSpellRecField(spellId, "name")
    if spellName then
      DoiteTargetAuras.spellIdToNameCache[spellId] = spellName
      DoiteTargetAuras.spellNameToIdCache[spellName] = spellId
    end
  end
  if not spellName then
    return false
  end
  return DoiteTargetAuras.HasDebuff(spellName)
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

local BuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffAddedOther")
BuffAddedOtherFrame:RegisterEvent("BUFF_ADDED_OTHER")
BuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  if guid ~= DoiteTargetAuras.targetGuid then
    return
  end

  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local slot = auraSlot + 1
  DoiteTargetAuras.buffs[slot].spellId = spellId
  DoiteTargetAuras.buffs[slot].stacks = stacks
  MarkActive(spellId, DoiteTargetAuras.activeBuffs, slot)
  NotifyConditionsChanged()
end)

local BuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_BuffRemovedOther")
BuffRemovedOtherFrame:RegisterEvent("BUFF_REMOVED_OTHER")
BuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  if guid ~= DoiteTargetAuras.targetGuid then
    return
  end

  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if auraSlot < 0 or auraSlot >= MAX_BUFF_SLOTS then
    return
  end

  local slot = auraSlot + 1
  if state == 1 then
    DoiteTargetAuras.buffs[slot].spellId = nil
    DoiteTargetAuras.buffs[slot].stacks = nil
    MarkInactive(spellId, DoiteTargetAuras.activeBuffs)
  else
    DoiteTargetAuras.buffs[slot].stacks = stacks
  end
  NotifyConditionsChanged()
end)

local DebuffAddedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffAddedOther")
DebuffAddedOtherFrame:RegisterEvent("DEBUFF_ADDED_OTHER")
DebuffAddedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  if guid ~= DoiteTargetAuras.targetGuid then
    return
  end

  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6

  if auraSlot < MAX_BUFF_SLOTS or auraSlot >= (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    return
  end

  local slot = auraSlot - MAX_BUFF_SLOTS + 1
  DoiteTargetAuras.debuffs[slot].spellId = spellId
  DoiteTargetAuras.debuffs[slot].stacks = stacks
  MarkActive(spellId, DoiteTargetAuras.activeDebuffs, slot)
  NotifyConditionsChanged()
end)

local DebuffRemovedOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_DebuffRemovedOther")
DebuffRemovedOtherFrame:RegisterEvent("DEBUFF_REMOVED_OTHER")
DebuffRemovedOtherFrame:SetScript("OnEvent", function()
  local guid = arg1
  if guid ~= DoiteTargetAuras.targetGuid then
    return
  end

  local spellId = arg3
  local stacks = arg4
  local auraSlot = arg6
  local state = arg7

  if auraSlot < MAX_BUFF_SLOTS or auraSlot >= (MAX_BUFF_SLOTS + MAX_DEBUFF_SLOTS) then
    return
  end

  local slot = auraSlot - MAX_BUFF_SLOTS + 1
  if state == 1 then
    DoiteTargetAuras.debuffs[slot].spellId = nil
    DoiteTargetAuras.debuffs[slot].stacks = nil
    MarkInactive(spellId, DoiteTargetAuras.activeDebuffs)
  else
    DoiteTargetAuras.debuffs[slot].stacks = stacks
  end
  NotifyConditionsChanged()
end)

local AuraCastOtherFrame = CreateFrame("Frame", "DoiteTargetAuras_AuraCastOther")
AuraCastOtherFrame:RegisterEvent("AURA_CAST_ON_OTHER")
AuraCastOtherFrame:SetScript("OnEvent", function()
  local spellId = arg1
  local targetGuid = arg3
  local durationMs = arg8
  local auraCapStatus = arg9

  if targetGuid ~= DoiteTargetAuras.targetGuid then
    return
  end

  if not (auraCapStatus == 1 or auraCapStatus == 3) then
    return
  end

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

  local expirationTime = DoiteTargetAuras.cappedBuffsExpirationTime[spellName]
  if expirationTime and expirationTime > 0 and expirationTime <= GetTime() then
    DoiteTargetAuras.cappedBuffsStacks[spellName] = 0
  end

  DoiteTargetAuras.cappedBuffsExpirationTime[spellName] = GetTime() + durationMs / 1000.0

  local currentStacks = DoiteTargetAuras.cappedBuffsStacks[spellName] or 0
  local maxStacks = DoiteTargetAuras.spellNameToMaxStacks[spellName] or 1
  DoiteTargetAuras.cappedBuffsStacks[spellName] = math.min(currentStacks + 1, maxStacks)
  NotifyConditionsChanged()
end)
