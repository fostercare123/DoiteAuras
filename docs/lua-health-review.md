# Lua health review: `Modules/DoiteEdit.lua` and `DoiteAuras.lua`

## Scope
- Reviewed for duplication, dead/unbound code, and general maintainability risks.

## `Modules/DoiteEdit.lua`

### Overall
- **Functional but very large/complex** (~11k lines) and contains several repeated helper blocks that increase maintenance cost.
- The file appears to be **working code with technical debt**, not a broken file.

### Findings
1. **Duplicated helper function names/blocks in multiple places** (mostly UI branch-local helpers):
   - `_Add` appears repeatedly in dropdown initializers for different sections (`ability`, `aura`, etc.).
   - `UpdateStacksVisibility` appears in both aura and VFX row-state handlers.
   - `YellowifyButton` appears in multiple row-build sections.
   - `_enableCheck` / `_disableCheck` exist in at least two branch-local blocks with identical logic.

2. **Potentially dead/shadowed local function**:
   - `VfxCond_Len` is defined twice in the same scope area; the second definition overwrites the first, so the first one is effectively dead from that point onward.

3. **Architecture smell**:
   - The file intermixes UI construction, per-type condition logic, rendering, and behavior wiring in one module; this is likely why it *feels* messy.

### Risk assessment
- **High maintenance risk, moderate bug risk**:
  - Copy-pasted helpers can drift over time and cause subtle inconsistencies.
  - Shadowed redefinitions can hide intent and make debugging harder.

### Recommended cleanup order
1. Extract repeated tiny helpers once at module scope (e.g., check-enable/disable, button-yellow styling, dropdown item adder).
2. Resolve duplicate `VfxCond_Len` by keeping one canonical implementation.
3. Split this file by concern (row builders, shared UI helpers, aura condition workflow, vfx workflow).

---

## `DoiteAuras.lua`

### Overall
- **Healthier than `DoiteEdit.lua`** despite being large (~3.9k lines).
- Structure is more modular with named helpers and clear sections.

### Findings
1. **No repeated function-name definitions detected** in this file (good sign compared to `DoiteEdit.lua`).
2. **Likely dead local helpers** (declared but not referenced later in-file):
   - `GetIconLayout`
   - `GetSpellData`
   - `DA_CleanupEmptyGroupAndCategory`
   - `FindPlayerBuff`
   - `FindPlayerDebuff`
   - `DA_BroadcastVersion` (while `DA_BroadcastVersionAll` is used)
3. The file still has broad responsibility (UI, caching, command handlers, networking/version checks), but with better helper boundaries.

### Risk assessment
- **Moderate maintenance risk, low-to-moderate bug risk**:
  - Dead helpers increase cognitive load and make readers hunt for usage that never comes.
  - Otherwise, helper decomposition and guard patterns are reasonably healthy.

### Recommended cleanup order
1. Remove or wire currently-unused local helpers.
2. Keep section boundaries but consider splitting by subsystem (UI/list, icon refresh/runtime, slash commands/version messaging).
3. Add a lightweight static check step in workflow (even a custom grep/rg-based lint script) to catch unused locals and duplicate local function names.

---

## Bottom line
- `DoiteEdit.lua`: **messy-but-salvageable**, with real duplication and at least one shadowed/dead local redefinition.
- `DoiteAuras.lua`: **mostly healthy for its size**, with a handful of likely dead helper functions to prune.
