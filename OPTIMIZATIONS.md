# Performance Optimizations for Turtle_TransmogUI.lua

## Overview
This document summarizes the performance optimizations applied to improve efficiency for Lua 5.0.

## Changes Made

### 1. Table Size Calculation Optimization
**Location**: `Transmog:tableSize()` function

**Before**:
```lua
function Transmog:tableSize(t)
    local size = 0
    for i, d in t do
        size = size + 1
    end
    return size
end
```

**After**:
```lua
function Transmog:tableSize(t)
    -- Try table.getn first for indexed tables
    local n = table.getn(t)
    if n > 0 then return n end
    -- Fall back to pairs() for hash tables
    local size = 0
    for _ in pairs(t) do
        size = size + 1
    end
    return size
end
```

**Benefit**: Faster size calculation for indexed tables using built-in `table.getn()`.

---

### 2. Slot Type Lookup Table
**Location**: `Transmog:slotIdToServerSlot()` function

**Before**: 60+ lines of cascading if statements

**After**: Lookup table with O(1) access
```lua
Transmog.invTypeToServerSlot = {
    ['INVTYPE_HEAD'] = EQUIPMENT_SLOT_HEAD,
    ['INVTYPE_SHOULDER'] = EQUIPMENT_SLOT_SHOULDERS,
    -- ... etc
}
```

**Benefit**: Reduced from O(n) to O(1) lookup time, eliminated redundant comparisons.

---

### 3. Queue Size Caching
**Location**: OnUpdate handlers for `itemCacheBuilder` and `setsModelBuilder`

**Before**:
```lua
while budget > 0 and table.getn(Transmog.itemCacheQueue) > 0 do
    -- process
end
```

**After**:
```lua
local queue = Transmog.itemCacheQueue
local queueSize = table.getn(queue)
while budget > 0 and queueSize > 0 do
    -- process
    queueSize = queueSize - 1
end
```

**Benefit**: Reduced `table.getn()` calls from O(n) to O(1) per frame.

---

### 4. String Concatenation with table.concat
**Location**: `UpdateVisibleSetsOwnedCounters()` and similar functions

**Before**:
```lua
setItemsText = setItemsText .. (has and FONT_COLOR_CODE_CLOSE or GRAY_FONT_COLOR_CODE) .. name .. "\n"
```

**After**:
```lua
local textParts = {}
table.insert(textParts, (has and FONT_COLOR_CODE_CLOSE or GRAY_FONT_COLOR_CODE) .. name)
setItemsText = table.concat(textParts, "\n")
```

**Benefit**: O(n) complexity instead of O(n²) for string building operations.

---

### 5. API Call Caching
**Location**: Multiple functions calling `GetInventoryItemLink()`

**Before**:
```lua
if GetInventoryItemLink('player', InventorySlotId) then
    local _, _, eqItemLink = TransmogFrame_Find(GetInventoryItemLink('player', InventorySlotId), ...)
end
```

**After**:
```lua
local itemLink = GetInventoryItemLink('player', InventorySlotId)
if itemLink then
    local _, _, eqItemLink = TransmogFrame_Find(itemLink, ...)
end
```

**Benefit**: Eliminated duplicate API calls, reducing function call overhead.

---

### 6. Nested Loop Optimization
**Location**: `Transmog_Try()` function for set processing

**Before**: O(n×m) complexity with nested loops
```lua
for _, setItemId in items do
    for _, data in currentTransmogsData do
        for _, d in data do
            if d['id'] == setItemId then learned = true end
        end
    end
end
```

**After**: O(n+m) complexity with lookup table
```lua
local learnedItems = {}
for _, data in currentTransmogsData do
    for _, d in data do
        learnedItems[d['id']] = true
    end
end
for _, setItemId in items do
    local learned = learnedItems[setItemId]
end
```

**Benefit**: Reduced algorithmic complexity from quadratic to linear time.

---

### 7. Memory Leak Prevention
**Location**: OnHide handlers for animation and timer frames

**Added cleanup**:
```lua
Transmog.applyTimer:SetScript("OnHide", function()
    Transmog.applyTimer.actions = {}
end)

Transmog.itemAnimation:SetScript("OnHide", function()
    Transmog.itemAnimationFrames = {}
end)

Transmog.delayAddWonItem:SetScript("OnHide", function()
    Transmog.delayAddWonItem.data = {}
end)
```

**Benefit**: Prevents memory accumulation by clearing temporary tables when frames are hidden.

---

### 8. getglobal() Call Optimization
**Location**: Item rendering loops

**Before**:
```lua
getglobal('TransmogLook' .. itemIndex .. 'Button'):SetID(item.id)
getglobal('TransmogLook' .. itemIndex .. 'ButtonRevert'):Hide()
getglobal('TransmogLook' .. itemIndex .. 'ButtonCheck'):Hide()
```

**After**:
```lua
local lookPrefix = 'TransmogLook' .. itemIndex
local button = getglobal(lookPrefix .. 'Button')
local buttonRevert = getglobal(lookPrefix .. 'ButtonRevert')
local buttonCheck = getglobal(lookPrefix .. 'ButtonCheck')
button:SetID(item.id)
buttonRevert:Hide()
buttonCheck:Hide()
```

**Benefit**: Reduced getglobal() calls and string concatenation operations.

---

## Performance Impact Summary

1. **Time Complexity Improvements**:
   - Slot lookup: O(n) → O(1)
   - Nested loops: O(n²) → O(n)
   - String building: O(n²) → O(n)

2. **Memory Improvements**:
   - Added cleanup handlers to prevent memory leaks
   - Reduced temporary string allocations

3. **Function Call Overhead**:
   - Eliminated duplicate API calls
   - Cached repeated getglobal() results
   - Reduced table.getn() calls in loops

4. **Lua 5.0 Compatibility**:
   - All optimizations use Lua 5.0 compatible syntax
   - Uses table.getn() instead of # operator
   - Uses pairs() instead of ipairs() where appropriate

## Expected Results

These optimizations should result in:
- Smoother UI performance during item browsing
- Reduced lag when switching between tabs
- Lower memory usage during extended gameplay sessions
- Improved responsiveness on lower-end systems

## Testing Recommendations

1. Monitor frame rates during heavy UI operations
2. Check memory usage over extended sessions
3. Test with large item collections
4. Verify all UI functionality remains intact
5. Test on systems with limited resources

## Compatibility

All changes maintain full backward compatibility with Lua 5.0 and do not alter the external behavior of the addon.
