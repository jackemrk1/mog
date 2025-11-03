local EquipTransmogTooltip = CreateFrame("Frame", "EquipTransmogTooltip", GameTooltip)
local Transmog = CreateFrame("Frame")

Transmog.debug = false

Transmog:RegisterEvent("GOSSIP_SHOW")
Transmog:RegisterEvent("GOSSIP_CLOSED")
Transmog:RegisterEvent("UNIT_INVENTORY_CHANGED")
Transmog:RegisterEvent("CHAT_MSG_ADDON")
-- 注册进入世界事件，切换地图会触发
Transmog:RegisterEvent("PLAYER_ENTERING_WORLD")
Transmog:RegisterEvent("GET_ITEM_INFO_RECEIVED")

local TRANSMOG_CONFIG = {} --hax

local TransmogFrame_Find = string.find
local TransmogFrame_ToNumber = tonumber

local skipNextGossipShow = false

local fakeCtl = CreateFrame("Frame")
fakeCtl:RegisterEvent("CHAT_MSG_ADDON")

fakeCtl:SetScript("OnEvent", function()
    if event ~= "CHAT_MSG_ADDON" then return end

    -- arg1=prefix, arg2=message, arg3=channel(数字), arg4=sender 名字
    if arg1 == "LUSHI_FAKE_GOSSIP" and arg2 == "1" then
        skipNextGossipShow = true
    end
end)

local _, race = UnitRace('player')
local _, class = UnitClass('player')
local GAME_YELLOW = "|cffffd200"

function twferror(a)
    DEFAULT_CHAT_FRAME:AddMessage('|cff69ccf0[TWFError]:|cffffffff ' .. a .. '. Please report.')
end

function twfprint(a)
    if a == nil then
        twferror('Attempt to print a nil value.')
        return false
    end
    DEFAULT_CHAT_FRAME:AddMessage(GAME_YELLOW .. a)
end

function twfdebug(a)
    if not Transmog.debug then
        return
    end
    if type(a) == 'boolean' then
        if a then
            twfprint('|cff0070de[DEBUG]|cffffffff[true]')
        else
            twfprint('|cff0070de[DEBUG]|cffffffff[false]')
        end
        return true
    end
    twfprint('|cff0070de[DEBUG:' .. GetTime() .. ']|cffffffff[' .. a .. ']')
end

Transmog.race = string.lower(race)
Transmog.class = string.lower(class)
Transmog.faction = 'A'
if Transmog.race ~= 'human' and Transmog.race ~= 'gnome' and Transmog.race ~= 'dwarf' and Transmog.race ~= 'nightelf' and Transmog.race ~= 'bloodelf' then
    Transmog.faction = 'H'
end

Transmog.prefix = "TW_TRANSMOG"

Transmog.availableTransmogItems = {}
Transmog.ItemButtons = {}
Transmog.currentTransmogSlotName = nil
Transmog.currentTransmogSlot = nil
Transmog.page = -1
Transmog.currentPage = 1
Transmog.totalPages = 1
Transmog.ipp = 15
Transmog.numTransmogs = {}
Transmog.transmogDataFromServer = {}
Transmog.transmogStatusFromServer = {}
Transmog.transmogStatusToServer = {}
Transmog.tab = ''
Transmog.equippedItems = {}
Transmog.fashionCoins = 0
Transmog.currentOutfit = nil
Transmog.equippedTransmogs = {}
Transmog.overrideTooltip = {}
Transmog.serverToClientSlot = {
    [0]  = 1,  -- Head
    [2]  = 3,  -- Shoulder
    [4]  = 5,  -- Chest
    [5]  = 6,  -- Waist
    [6]  = 7,  -- Legs
    [7]  = 8,  -- Feet
    [8]  = 9,  -- Wrist
    [9]  = 10, -- Hands
    [14] = 15, -- Back
    [15] = 16, -- MainHand
    [16] = 17, -- OffHand
    [17] = 18, -- Ranged
}

-- [V79 fix] 去重：仅保留带 setsStatsReady 的这一组统计缓存
Transmog.setIndexByItemId = {}     -- itemId -> { setIndex1, setIndex2, ... }
Transmog.setSize = {}              -- setIndex -> 件数
Transmog.setCollectedCount = {}    -- setIndex -> 已收集件数（按页累计）
Transmog.completedSetsCache = nil  -- nil 表示未就绪；有值用于顶部进度条
Transmog.setsStatsReady = false    -- 统计是否已就绪（按页累计）

-- OwnedTransmogs（按页）相关临时缓存
Transmog.ownedTransmogsPageTemp = {}     -- 当前页：已拥有 itemId 的集合
Transmog.visibleSetsItemsMap     = nil   -- 当前页：setIndex -> itemId数组

Transmog.currentTransmogsData = {}

Transmog.availableSets = {}
Transmog.gearChanged = nil
Transmog.localCache = {}

Transmog.slotTransmogNames = Transmog.slotTransmogNames or {}

-- 隐藏专用 Tooltip + 逐帧限速物品缓存队列（性能优化，不改业务逻辑/结构）
Transmog.CacheTooltip = CreateFrame("GameTooltip", "TransmogCacheTooltip", UIParent, "GameTooltipTemplate")
Transmog.CacheTooltip:SetOwner(UIParent, "ANCHOR_NONE")
Transmog.maxItemCachePerFrame = 12
Transmog.itemCacheQueue = {}
Transmog.itemCacheSeen = {}
Transmog.itemCacheBuilder = CreateFrame("Frame")
Transmog.itemCacheBuilder:Hide()
Transmog.itemCacheBuilder:SetScript("OnUpdate", function()
    local budget = Transmog.maxItemCachePerFrame
    local queue = Transmog.itemCacheQueue
    local queueSize = table.getn(queue)
    while budget > 0 and queueSize > 0 do
        local id = table.remove(queue, 1)
        if not GetItemInfo(id) then
            Transmog.CacheTooltip:SetHyperlink("item:" .. id .. ":0:0:0")
        end
        budget = budget - 1
        queueSize = queueSize - 1
    end
    if queueSize == 0 then
        this:Hide()
    end
end)
function Transmog:QueueCacheItem(itemID)
    if not itemID or itemID == 0 then return end
    if self.itemCacheSeen[itemID] then return end
    self.itemCacheSeen[itemID] = true
    table.insert(self.itemCacheQueue, itemID)
    if not self.itemCacheBuilder:IsShown() then
        self.itemCacheBuilder:Show()
    end
end

-- [新增] 辅助函数：是否还有槽位幻化名字未就绪
function Transmog:HasPendingTransmogInfo()
    for InventorySlotId, itemID in self.transmogStatusFromServer do
        if itemID and itemID ~= 0 then
            local name = GetItemInfo(itemID)
            if not name then
                return true
            end
        end
    end
    return false
end

-- 套装模型异步渲染队列（仅性能优化，不改变逻辑/结构）
Transmog.maxSetModelsPerFrame = 1   -- 每帧最多渲染几个套装格子的模型，可按机器性能调节
Transmog.setModelQueue = {}
Transmog.setsModelBuilder = CreateFrame("Frame")
Transmog.setsModelBuilder:Hide()

-- 轻量延迟刷新（Lua 5.0 兼容）
Transmog.refreshDelay = CreateFrame("Frame")
Transmog.refreshDelay:Hide()
Transmog.refreshDelay.attempts = 0
Transmog.refreshDelay.delay = 0.2
Transmog.refreshDelay.maxAttempts = 12

Transmog.refreshDelay:SetScript("OnShow", function()
    this.startTime = GetTime()
end)

Transmog.refreshDelay:SetScript("OnUpdate", function()
    local gt = GetTime() * 1000
    local st = (this.startTime + Transmog.refreshDelay.delay) * 1000
    if gt >= st then
        Transmog.refreshDelay.attempts = Transmog.refreshDelay.attempts + 1
        Transmog:transmogStatus()
        if Transmog.refreshDelay.attempts >= (Transmog.refreshDelay.maxAttempts or 12) then
            Transmog.refreshDelay:Hide()
        else
            this.startTime = GetTime()
        end
    end
end)

function Transmog:BuildSetItemIndex()
    self.setIndexByItemId = {}
    self.setSize = {}
    for idx, setData in next, self.availableSets do
        local size = 0
        for _, itemID in next, setData.items do
            size = size + 1
            if not self.setIndexByItemId[itemID] then
                self.setIndexByItemId[itemID] = {}
            end
            table.insert(self.setIndexByItemId[itemID], idx)
        end
        self.setSize[idx] = size
    end
end

function Transmog:RecomputeSetsCounters()
    self.completedSetsCache = 0
    for sIdx, fullSize in next, self.setSize do
        local have = self.setCollectedCount[sIdx] or 0
        if have >= (fullSize or 0) then
            self.completedSetsCache = self.completedSetsCache + 1
        end
    end
end

function Transmog:OnGainTransmog(itemId)
    if not itemId or itemId == 0 then return end
    self.allOwnedTransmogs = self.allOwnedTransmogs or {}
    if not self.allOwnedTransmogs[itemId] then
        self.allOwnedTransmogs[itemId] = true
        local sets = self.setIndexByItemId and self.setIndexByItemId[itemId]
        if sets then
            for _, sIdx in next, sets do
                self.setCollectedCount[sIdx] = (self.setCollectedCount[sIdx] or 0) + 1
            end
        end
        self.setsStatsReady = true
        self:RecomputeSetsCounters()
        if TransmogFrame and TransmogFrame:IsVisible() and self.tab == 'sets' then
            Transmog_switchTab('sets')
        end
    end
end

function Transmog:DelayedRefreshTransmogStatus(delay)
    Transmog.refreshDelay.delay = delay or 0.2
    Transmog.refreshDelay.attempts = 0
    Transmog.refreshDelay:Show()
end

function Transmog:ClearSetModelQueue()
    self.setModelQueue = {}
    if self.setsModelBuilder:IsShown() then
        self.setsModelBuilder:Hide()
    end
end

function Transmog:QueueSetModel(model, items)
    table.insert(self.setModelQueue, { model = model, items = items })
    if not self.setsModelBuilder:IsShown() then
        self.setsModelBuilder:Show()
    end
end

function Transmog:ShowVisibleSetModels()
    for i = 1, (self.ipp or 15) do
        local btn = self.ItemButtons[i]
        if btn and btn:IsShown() then
            local m = getglobal('TransmogLook' .. i .. 'ItemModel')
            if m then
                m:SetAlpha(1)
                m:Show()
            end
        end
    end
end

function Transmog:PruneEquippedTransmogMap()
    local alive = {}
    for _, InventorySlotId in self.inventorySlots do
        local link = GetInventoryItemLink('player', InventorySlotId)
        if link then
            local _, _, eqItemLink = TransmogFrame_Find(link, "(item:%d+:%d+:%d+:%d+)")
            local eqItemId = self:IDFromLink(eqItemLink)
            if eqItemId then alive[eqItemId] = true end
        end
    end
    local map = self.equippedTransmogs or {}
    for id in pairs(map) do
        if not alive[id] then map[id] = nil end
    end
    self.equippedTransmogs = map
end

Transmog.setsModelBuilder:SetScript("OnUpdate", function()
    if not TransmogFrame or not TransmogFrame:IsVisible() then
        Transmog.setModelQueue = {}
        this:Hide()
        return
    end

    local budget = Transmog.maxSetModelsPerFrame or 3
    local queue = Transmog.setModelQueue
    local queueSize = table.getn(queue)
    while budget > 0 and queueSize > 0 do
        local job = table.remove(queue, 1)
        local model = job.model
        local items = job.items

        if model then
            model:Show()
            model:SetAlpha(0)
            model:Undress()
            for _, itemID in next, items do
                model:TryOn(itemID)
            end
        end

        budget = budget - 1
        queueSize = queueSize - 1
    end

    if queueSize == 0 then
        Transmog:ShowVisibleSetModels()
        this:Hide()
    end
end)

Transmog.inventorySlots = {
    ['HeadSlot'] = 1,
    ['ShoulderSlot'] = 3,
    ['ChestSlot'] = 5,
    ['WaistSlot'] = 6,
    ['LegsSlot'] = 7,
    ['FeetSlot'] = 8,
    ['WristSlot'] = 9,
    ['HandsSlot'] = 10,
    ['BackSlot'] = 15,
    ['MainHandSlot'] = 16,
    ['SecondaryHandSlot'] = 17,
    ['RangedSlot'] = 18
}

Transmog.inventorySlotNames = {
    [1] = "头部",
    [3] = "肩部",
    [5] = "胸部",
    [6] = "腰部",
    [7] = "腿部",
    [8] = "脚",
    [9] = "手腕",
    [10] = "手",
    [15] = "背部",
    [16] = "主手",
    [17] = "副手",
    [18] = "远程武器"
}

Transmog.invTypes = {
    ['INVTYPE_HEAD'] = 1,
    ['INVTYPE_SHOULDER'] = 3,
    ['INVTYPE_CLOAK'] = 16,
    --['INVTYPE_BODY'] = 4, -- shirt
    ['INVTYPE_CHEST'] = 5,
    ['INVTYPE_ROBE'] = 20,
    ['INVTYPE_WAIST'] = 6,
    ['INVTYPE_LEGS'] = 7,
    ['INVTYPE_FEET'] = 8,
    ['INVTYPE_WRIST'] = 9,
    ['INVTYPE_HAND'] = 10,

    ['INVTYPE_WEAPON'] = 13,
    ['INVTYPE_WEAPONMAINHAND'] = 21,

    ['INVTYPE_2HWEAPON'] = 17,

    ['INVTYPE_SHIELD'] = 14,
    ['INVTYPE_WEAPONOFFHAND'] = 22,
    ['INVTYPE_HOLDABLE'] = 23,

    ['INVTYPE_THROWN'] = 25,
    ['INVTYPE_RANGED'] = 15,
    ['INVTYPE_RANGEDRIGHT'] = 26,
}

Transmog.errors = {
    ['0'] = 'no error',
    ['1'] = 'no dest item',
    ['2'] = 'bad slot',
    ['3'] = 'transmog not learned',
    ['4'] = 'no source item proto',
    ['5'] = 'source not valid for destination',
    ['10'] = 'stoi failed',
    ['11'] = 'no coin'
}

-- server side
EQUIPMENT_SLOT_HEAD = 0
EQUIPMENT_SLOT_SHOULDERS = 2
EQUIPMENT_SLOT_BODY = 3 -- shirt ?
EQUIPMENT_SLOT_CHEST = 4
EQUIPMENT_SLOT_WAIST = 5
EQUIPMENT_SLOT_LEGS = 6
EQUIPMENT_SLOT_FEET = 7
EQUIPMENT_SLOT_WRISTS = 8
EQUIPMENT_SLOT_HANDS = 9
EQUIPMENT_SLOT_BACK = 14
EQUIPMENT_SLOT_MAINHAND = 15
EQUIPMENT_SLOT_OFFHAND = 16
EQUIPMENT_SLOT_RANGED = 17

C_INVTYPE_HEAD = 1;
C_INVTYPE_SHOULDERS = 3;
C_INVTYPE_BODY = 4;
C_INVTYPE_CHEST = 5;
C_INVTYPE_WAIST = 6;
C_INVTYPE_LEGS = 7;
C_INVTYPE_FEET = 8;
C_INVTYPE_WRISTS = 9;
C_INVTYPE_HANDS = 10;
C_INVTYPE_WEAPON = 13;
C_INVTYPE_SHIELD = 14;
C_INVTYPE_RANGED = 15;
C_INVTYPE_CLOAK = 16;
C_INVTYPE_2HWEAPON = 17;
C_INVTYPE_ROBE = 20;
C_INVTYPE_WEAPONMAINHAND = 21;
C_INVTYPE_WEAPONOFFHAND = 22;
C_INVTYPE_HOLDABLE = 23;
C_INVTYPE_THROWN = 25;
C_INVTYPE_RANGEDRIGHT = 26;

-- Optimized: Use lookup table instead of cascading if statements
Transmog.invTypeToServerSlot = {
    ['INVTYPE_HEAD'] = EQUIPMENT_SLOT_HEAD,
    ['INVTYPE_SHOULDER'] = EQUIPMENT_SLOT_SHOULDERS,
    ['INVTYPE_CLOAK'] = EQUIPMENT_SLOT_BACK,
    ['INVTYPE_CHEST'] = EQUIPMENT_SLOT_CHEST,
    ['INVTYPE_ROBE'] = EQUIPMENT_SLOT_CHEST,
    ['INVTYPE_WAIST'] = EQUIPMENT_SLOT_WAIST,
    ['INVTYPE_LEGS'] = EQUIPMENT_SLOT_LEGS,
    ['INVTYPE_FEET'] = EQUIPMENT_SLOT_FEET,
    ['INVTYPE_WRIST'] = EQUIPMENT_SLOT_WRISTS,
    ['INVTYPE_HAND'] = EQUIPMENT_SLOT_HANDS,
    ['INVTYPE_WEAPON'] = EQUIPMENT_SLOT_MAINHAND,
    ['INVTYPE_SHIELD'] = EQUIPMENT_SLOT_OFFHAND,
    ['INVTYPE_RANGED'] = EQUIPMENT_SLOT_RANGED,
    ['INVTYPE_2HWEAPON'] = EQUIPMENT_SLOT_MAINHAND,
    ['INVTYPE_WEAPONMAINHAND'] = EQUIPMENT_SLOT_MAINHAND,
    ['INVTYPE_WEAPONOFFHAND'] = EQUIPMENT_SLOT_OFFHAND,
    ['INVTYPE_HOLDABLE'] = EQUIPMENT_SLOT_OFFHAND,
    ['INVTYPE_THROWN'] = EQUIPMENT_SLOT_RANGED,
    ['INVTYPE_RANGEDRIGHT'] = EQUIPMENT_SLOT_RANGED,
}

function Transmog:slotIdToServerSlot(slotId)
    local itemType = 99
    if GetInventoryItemLink('player', slotId) then
        local itemName, _, _, _, _, _, _, it = GetItemInfo(self:IDFromLink(GetInventoryItemLink('player', slotId)))
        itemType = it
    end

    -- offhandslot exception
    if slotId == 17 and itemType == 'INVTYPE_WEAPON' then
        return EQUIPMENT_SLOT_OFFHAND
    end

    -- Lookup in table - much faster than cascading if statements
    local serverSlot = self.invTypeToServerSlot[itemType]
    if serverSlot then
        return serverSlot
    end

    twfdebug('99 slotIdToServerSlot err = ' .. slotId)
    return 99
end

Transmog:SetScript("OnEvent", function()

    if event then
        if event == "GOSSIP_SHOW" then
		    if skipNextGossipShow then
        skipNextGossipShow = false   -- 消费标记
        return                      -- 直接跳过幻化 UI 打开
            end
            if UnitName("Target") == "菲利希亚" or UnitName("Target") == "赫琳娜" then

                if Transmog.delayedLoad:IsVisible() then
                    twfdebug("Transmog addon loading retry in 5s.")
                else
                    GossipFrame:SetAlpha(0)
                    TransmogFrame:Show()
                end
            end
            return
        end
        if event == "GOSSIP_CLOSED" then
            GossipFrame:SetAlpha(1)
            TransmogFrame:Hide()
            return
        end
		
		if event == "PLAYER_ENTERING_WORLD" then
    Transmog:aSend("GetTransmogStatus")
    Transmog:DelayedRefreshTransmogStatus(0.2)
    return
end
if event == "UNIT_INVENTORY_CHANGED" then
    twfdebug(event)

    if Transmog:EquippedItemsChanged() then
        twfdebug("equipped items changed")

        -- 改：仅裁剪不再穿戴的条目，避免整表清空导致提示瞬间消失
        Transmog:PruneEquippedTransmogMap()
        if FashionTooltip and FashionTooltip:IsVisible() then
            FashionTooltip:Hide()
        end

        -- 立刻请求一次最新状态，降低等待窗口期
        Transmog:aSend("GetTransmogStatus")

        if TransmogFrame:IsVisible() then
            twfdebug("visible")
            Transmog.gearChangedDelay.delay = 1
        else
            twfdebug("not visible")
            Transmog.gearChangedDelay.delay = 2
        end
        Transmog:LockPlayerItems()
        Transmog.gearChangedDelay:Show()
    else
        twfdebug("equipped items not changed (maybe same-name swap) -> force refresh")

        -- 改：同理仅裁剪，避免整表清空
        Transmog:PruneEquippedTransmogMap()
        if FashionTooltip and FashionTooltip:IsVisible() then
            FashionTooltip:Hide()
        end

        -- 请求服务器返回最新 TransmogStatus
        Transmog:aSend("GetTransmogStatus")

        if TransmogFrame:IsVisible() then
            Transmog.gearChangedDelay.delay = 1
            Transmog:LockPlayerItems()
            Transmog.gearChangedDelay:Show()
        else
            Transmog:DelayedRefreshTransmogStatus(0.2)
        end
    end

    return
end
        if event == 'CHAT_MSG_ADDON' then

            twfdebug(arg1)
            twfdebug(arg2)
            twfdebug(arg3)
            twfdebug(arg4)

            if arg1 == "TW_CHAT_MSG_WHISPER" then
                local message = arg2
                local from = arg4
                if string.find(message, 'INSShowTransmogs', 1, true) then
                    SendAddonMessage("TW_CHAT_MSG_WHISPER<" .. from .. ">", "INSTransmogs:start", "GUILD")
                    for InventorySlotId, itemID in Transmog.transmogStatusFromServer do
                        if itemID ~= 0 then

                            local TransmogItemName = GetItemInfo(itemID)

                            if TransmogItemName then
                                -- Optimized: Cache GetInventoryItemLink result
                                local itemLink = GetInventoryItemLink('player', InventorySlotId)
                                if itemLink then
                                    local _, _, eqItemLink = TransmogFrame_Find(itemLink, "(item:%d+:%d+:%d+:%d+)");
                                    local eName = GetItemInfo(eqItemLink)
                                    SendAddonMessage("TW_CHAT_MSG_WHISPER<" .. from .. ">", "INSTransmogs:" .. eName .. ":" .. TransmogItemName, "GUILD")
                                end
                            end
                        end
                    end
                    SendAddonMessage("TW_CHAT_MSG_WHISPER<" .. from .. ">", "INSTransmogs:end", "GUILD")
                end
                return
            end
        end
        if event == 'CHAT_MSG_ADDON' and TransmogFrame_Find(arg1, Transmog.prefix, 1, true) then

            local message = arg2

            if TransmogFrame_Find(message, "SetsStatus:1", 1, true) then
                TransmogFrameSetsButton:Show()
            end
            if TransmogFrame_Find(message, "SetsStatus:0", 1, true) then
                TransmogFrameSetsButton:Hide()
            end

            if TransmogFrame_Find(message, "AvailableTransmogs", 1, true) then

                --AvailableTransmogs:slot:num:id1:id2:id3
                --AvailableTransmogs:slot:num:0
                --AvailableTransmogs:slot:num:end
                local ex = TransmogFrame_Explode(message, ":")

                twfdebug("ex4: [" .. ex[4] .."]")

                local InventorySlotId = TransmogFrame_ToNumber(ex[2])
                Transmog.numTransmogs[InventorySlotId] = TransmogFrame_ToNumber(ex[3])

                if TransmogFrame_Find(ex[4], "start", 1, true) then
                    Transmog.transmogDataFromServer[InventorySlotId] = {}
                elseif TransmogFrame_Find(ex[4], "end", 1, true) then
                    Transmog:availableTransmogs(InventorySlotId)
                else
                    for i, itemID in ex do
                        if i > 3 then
                            itemID = TransmogFrame_ToNumber(itemID)
                            if itemID ~= 0 then
                                Transmog:cacheItem(itemID)

                                Transmog.transmogDataFromServer[InventorySlotId][i - 3] = itemID;

                                if not Transmog.currentTransmogsData[InventorySlotId] then
                                    Transmog.currentTransmogsData[InventorySlotId] = {}
                                end
                                table.insert(Transmog.currentTransmogsData[InventorySlotId], {
                                    ['id'] = TransmogFrame_ToNumber(itemID),
                                    ['has'] = false
                                })
                            end
                        end
                    end
                end
                return
            end
            if TransmogFrame_Find(message, "TransmogStatus", 1, true) then

                local dataEx = TransmogFrame_Explode(message, "TransmogStatus:")
                if dataEx[2] then
                    local TransmogStatus = TransmogFrame_Explode(dataEx[2], ",")

                    Transmog.transmogStatusFromServer = {}
                    Transmog.transmogStatusToServer = {}

                    for _, InventorySlotId in Transmog.inventorySlots do
                        Transmog.transmogStatusFromServer[InventorySlotId] = 0
                        Transmog.transmogStatusToServer[InventorySlotId] = 0
                    end
                    for _, d in TransmogStatus do
                        local slotEx = TransmogFrame_Explode(d, ":")
                        local InventorySlotId = TransmogFrame_ToNumber(slotEx[1])
                        local itemID = TransmogFrame_ToNumber(slotEx[2])
                        Transmog.transmogStatusFromServer[InventorySlotId] = itemID
                        Transmog.transmogStatusToServer[InventorySlotId] = itemID

                        if TransmogFrame_ToNumber(itemID) ~= 0 then
                            Transmog:cacheItem(itemID)
                        end
                    end

                    Transmog:transmogStatus()
                end

                return
            end
if TransmogFrame_Find(message, "ResetResult:", 1, true) then
    local dataEx = TransmogFrame_Explode(message, ":")
    if dataEx[2] and dataEx[3] and dataEx[4] then
        local InventorySlotId = TransmogFrame_ToNumber(dataEx[3])
        local result = dataEx[4]

        if result == '0' then
            Transmog:aSend("GetTransmogStatus")
            Transmog:addTransmogAnim(InventorySlotId, 'reset')
        else
            twferror("Error: " .. result .. " (" .. Transmog.errors[result] .. ")")
            Transmog:Reset()
        end
    end
    return
end
            if TransmogFrame_Find(message, "TransmogResult:", 1, true) then
                local dataEx = TransmogFrame_Explode(message, ":")
                if dataEx[2] and dataEx[3] and dataEx[4] then
                    local InventorySlotId = TransmogFrame_ToNumber(dataEx[3])
                    local result = dataEx[4]

                    if result == '0' then
                        Transmog:addTransmogAnim(InventorySlotId)
                    else
                        twferror("Error: " .. result .. " (" .. Transmog.errors[result] .. ")")
                        Transmog:Reset()
                    end
                end
                return
            end
			if TransmogFrame_Find(message, "CacheItems:", 1, true) then
    local dataEx = TransmogFrame_Explode(message, ":")
    if dataEx[2] and dataEx[3] then
        local tmogItemId = TransmogFrame_ToNumber(dataEx[2])
        local sourceItemId = TransmogFrame_ToNumber(dataEx[3])
        
        Transmog:cacheItem(tmogItemId)
        Transmog:cacheItem(sourceItemId)
        
        if (TransmogFrame and TransmogFrame:IsVisible()) or (not Transmog.setsStatsReady) then
           Transmog:DelayedRefreshTransmogStatus()
        end
    end
    return
end

if TransmogFrame_Find(message, "RefreshSlot:", 1, true) then
    local dataEx = TransmogFrame_Explode(message, ":")
    if dataEx[2] then
        local slot = TransmogFrame_ToNumber(dataEx[2])
        -- 清除该槽位的缓存状态
        if Transmog.transmogStatusFromServer[slot] then
            Transmog.transmogStatusFromServer[slot] = 0
        end
        -- 强制刷新显示
        if TransmogFrame:IsVisible() then
            Transmog:transmogStatus()
        end
    end
    return
end

-- 已移除 AllTransmogs 处理块

-- 新增：OwnedTransmogs（按页）响应
if TransmogFrame_Find(message, "OwnedTransmogs:", 1, true) then
    local ex = TransmogFrame_Explode(message, ":")
    if ex[2] == "start" then
        Transmog.ownedTransmogsPageTemp = {}
    elseif ex[2] == "end" then
        -- 收齐当前页结果，刷新可见网格（勾选、tooltip、顶部进度条）
        Transmog:UpdateVisibleSetsOwnedCounters()
    else
        -- 载荷行：OwnedTransmogs:id:id:...
        for i = 2, table.getn(ex) do
            local id = TransmogFrame_ToNumber(ex[i])
            if id and id ~= 0 then
                Transmog.ownedTransmogsPageTemp[id] = true
            end
        end
    end
    return
end

-- 在 CHAT_MSG_ADDON 分支里，收到 "NewTransmog:" 的地方，增加“套装页按页刷新”
if TransmogFrame_Find(message, "NewTransmog", 1, true) then
    local dataEx = TransmogFrame_Explode(message, "NewTransmog:")
    if dataEx[2] and TransmogFrame_ToNumber(dataEx[2]) then
        local newId = TransmogFrame_ToNumber(dataEx[2])
        twfdebug("new transmog " .. newId)
        Transmog:addWonItem(newId)
        Transmog:OnGainTransmog(newId)
        -- 如果当前在“套装”页，刷新本页拥有情况
        if TransmogFrame and TransmogFrame:IsVisible() and Transmog.tab == 'sets' then
            Transmog:RequestOwnedForVisibleSets()
        end
    else
        twfdebug("new transmog not number :[" .. (dataEx[2] or "") .. "]")
    end
    return
end

-- [MODIFIED] 解析服务器发送的 Tooltip 覆盖消息: OverrideTooltip:serverSlot:tooltipEntry:baseEntry:sourceItemId
if TransmogFrame_Find(message, "OverrideTooltip:", 1, true) then
    local ex = TransmogFrame_Explode(message, ":")
    -- ex[1] = "OverrideTooltip"
    local serverSlot = TransmogFrame_ToNumber(ex[2]) or 0
    local tooltipEntry = TransmogFrame_ToNumber(ex[3]) or 0
    local baseEntry = TransmogFrame_ToNumber(ex[4]) or 0
    local sourceItemId = TransmogFrame_ToNumber(ex[5]) or 0 -- 新增 sourceItemId

    local clientSlot = Transmog.serverToClientSlot[serverSlot]
    if clientSlot then
        Transmog.overrideTooltip[clientSlot] = {
            tooltipEntry = tooltipEntry,
            baseEntry = baseEntry,
            sourceItemId = sourceItemId, -- 存储 sourceItemId
            -- appearance 与 base 是否不同由 Lua 动态判断
        }
        -- 预缓存需要的物品，减少后续 Tooltip 闪烁
        if tooltipEntry ~= 0 then Transmog:QueueCacheItem(tooltipEntry) end
        if baseEntry ~= 0 then Transmog:QueueCacheItem(baseEntry) end
        if sourceItemId ~= 0 then Transmog:QueueCacheItem(sourceItemId) end -- 缓存 sourceItemId
    end
    return
end

if event == "GET_ITEM_INFO_RECEIVED" then
    -- 若仍有未就绪的 transmog 物品信息，则再次刷新 UI
    if Transmog:HasPendingTransmogInfo() then
        Transmog:transmogStatus()
    end
    return
end

            return
        end
    end
end)

-- 新增：收集当前页套装的 itemId 列表（用于批量查询）
function Transmog:CollectVisibleSetItemIDs()
    local ids = {}
    local map = {}
    local startIndex = (self.currentPage - 1) * (self.ipp or 15)
    local stopIndex  = startIndex + (self.ipp or 15) - 1

    local idx = 0
    for i, set in next, self.availableSets do
        if idx >= startIndex and idx <= stopIndex then
            map[i] = {}
            for _, itemID in next, (set.items or {}) do
                table.insert(ids, itemID)
                table.insert(map[i], itemID)
            end
        end
        idx = idx + 1
        if idx > stopIndex then break end
    end
    return ids, map
end

-- 新增：请求“当前页已拥有项”
function Transmog:RequestOwnedForVisibleSets()
    local ids, map = self:CollectVisibleSetItemIDs()
    self.visibleSetsItemsMap = map
    self.ownedTransmogsPageTemp = {}

    if self:tableSize(ids) == 0 then
        self:UpdateVisibleSetsOwnedCounters()
        return
    end

    local MAX_LEN = 900
    local base = "HasTransmogs:"
    local msg  = base
    for _, id in next, ids do
        local part = tostring(id) .. ":"
        if string.len(msg) + string.len(part) > MAX_LEN then
            if string.sub(msg, -1) == ":" then
                msg = string.sub(msg, 1, string.len(msg) - 1)
            end
            self:aSend(msg)
            msg = base .. part
        else
            msg = msg .. part
        end
    end
    if msg ~= base then
        if string.sub(msg, -1) == ":" then
            msg = string.sub(msg, 1, string.len(msg) - 1)
        end
        self:aSend(msg)
    end
end

-- 新增：用当前页拥有集合刷新网格勾选、tooltip 与顶部进度条
function Transmog:UpdateVisibleSetsOwnedCounters()
    local startIndex = (self.currentPage - 1) * (self.ipp or 15)
    local stopIndex  = startIndex + (self.ipp or 15) - 1

    local idx = 0
    for i, set in next, self.availableSets do
        if idx >= startIndex and idx <= stopIndex then
            local total  = self.setSize and self.setSize[i] or self:tableSize(set.items or {})
            local founds = 0
            local setItemsText = ""

            local tileIndex = (idx - startIndex + 1)
            local tile = getglobal('TransmogLook' .. tileIndex .. 'Button')
            local tileCheck = getglobal('TransmogLook' .. tileIndex .. 'ButtonCheck')
            if tileCheck then tileCheck:Hide() end

            -- Optimized: Use table for string concatenation
            local textParts = {}
            for _, itemID in next, (self.visibleSetsItemsMap and self.visibleSetsItemsMap[i] or set.items or {}) do
                local has = self.ownedTransmogsPageTemp[itemID] == true
                if has then founds = founds + 1 end

                local name = GetItemInfo(itemID)
                if not name then
                    self:QueueCacheItem(itemID)
                else
                    set.itemsExtended = set.itemsExtended or {}
                    local ex = set.itemsExtended[itemID]
                    if not ex or not ex.name then
                        local _, link, quality, _, xt1, xt2, _, equip_slot, xtex = GetItemInfo(itemID)
                        set.itemsExtended[itemID] = { name = name, slot = equip_slot, tex = xtex, quality = quality or 0 }
                    end
                    table.insert(textParts, (has and FONT_COLOR_CODE_CLOSE or GRAY_FONT_COLOR_CODE) .. name)
                end
            end
            setItemsText = table.concat(textParts, "\n")
            if setItemsText ~= "" then
                setItemsText = setItemsText .. "\n"
            end

            if total > 0 and founds >= total and tileCheck then
                tileCheck:Show()
            end
            if tile then
                AddButtonOnEnterTextTooltip(tile, (set.name or "") .. " " .. founds .. "/" .. total, setItemsText ~= "" and setItemsText or nil)
            end

            self.setSize = self.setSize or {}
            self.setCollectedCount = self.setCollectedCount or {}
            self.setSize[i] = total
            self.setCollectedCount[i] = founds
        end
        idx = idx + 1
        if idx > stopIndex then break end
    end

    local completed = 0
    for sIdx, fullSize in next, (self.setSize or {}) do
        local have = (self.setCollectedCount and self.setCollectedCount[sIdx]) or 0
        if (fullSize or 0) > 0 and have >= fullSize then
            completed = completed + 1
        end
    end
    self.completedSetsCache = completed
    self.setsStatsReady = true

    self:setProgressBar(self.completedSetsCache or 0, self:tableSize(self.availableSets or {}))
end

-- Optimized: Cache GetInventoryItemLink result to avoid duplicate calls
function Transmog:EquippedItemsChanged()
    for _, InventorySlotId in self.inventorySlots do
        local itemLink = GetInventoryItemLink('player', InventorySlotId)
        if itemLink then
            local _, _, eqItemLink = TransmogFrame_Find(itemLink, "(item:%d+:%d+:%d+:%d+)");
            if self.equippedItems[InventorySlotId] ~= self:IDFromLink(eqItemLink) then
                return true
            end
        end
    end
    return false
end

function Transmog:CacheEquippedGear()
    for _, InventorySlotId in self.inventorySlots do
        local itemLink = GetInventoryItemLink('player', InventorySlotId)
        if itemLink then
            self:cacheItem(itemLink)
        end
    end
end

function Transmog:CacheOutfitsItems()
end

function Transmog:CacheSetItems()
    for _, setData in next, self.availableSets do
        for _, itemId in next, setData.items do
            self:QueueCacheItem(itemId)
        end
    end
end

function Transmog:CacheAvailableTransmogs()
    for _, InventorySlotId in self.inventorySlots do
        if self.currentTransmogsData[InventorySlotId] then
            for _, data in self.currentTransmogsData[InventorySlotId] do
                self:cacheItem(data.id)
            end
        end
    end
end

function Transmog_OnLoad()

    local bmLoaded, bmReason = LoadAddOn("Blizzard_BattlefieldMinimap")

    if not BattlefieldMinimapOptions.transmog then
        BattlefieldMinimapOptions.transmog = {}
    end

    TRANSMOG_CONFIG = BattlefieldMinimapOptions.transmog --hax

    Transmog:cacheItem(40062)

    TransmogFrameInstructions:SetText("你厌倦了每天穿同样的装备吗？\n选择你想要改变的物品，享受你的时尚新造型。")
    TransmogFrameNoTransmogs:SetText("你还没有发现这个物品的任何外观。 \n装备物品后，外观将解锁。")

    if not TRANSMOG_CONFIG then
        TRANSMOG_CONFIG = {}
    end

    if not TRANSMOG_CONFIG[UnitName('player')] then
        TRANSMOG_CONFIG[UnitName('player')] = {}
    end

    if not TRANSMOG_CONFIG[UnitName('player')]['Outfits'] then
        TRANSMOG_CONFIG[UnitName('player')]['Outfits'] = {}
    end


    UIDropDownMenu_Initialize(TransmogFrameOutfits, OutfitsDropDown_Initialize);
    UIDropDownMenu_SetWidth(123, TransmogFrameOutfits);
    TransmogFrameSaveOutfit:Disable()
    TransmogFrameDeleteOutfit:Disable()
    UIDropDownMenu_SetText("套装", TransmogFrameOutfits)

    -- pre cache equipped items
    Transmog:CacheEquippedGear()

    -- pre cache outfits items
    Transmog:CacheOutfitsItems()

    -- 构建可用套装并建立索引
    Transmog.availableSets = {}
    for _, setData in next, TWFSets do
        if TransmogFrame_Find(setData.classes, Transmog.class, 1, true) or setData.classes == '' then
            if setData.faction == '' or (setData.faction ~= '' and setData.faction == Transmog.faction) then
                table.insert(Transmog.availableSets, setData)
            end
        end
    end
    Transmog:BuildSetItemIndex()
    Transmog.setsStatsReady = false
    Transmog.completedSetsCache = nil

    -- 预缓存套装物品（限速队列），如需更轻可注释
    --Transmog:CacheSetItems()

    Transmog.newTransmogAlert:HideAnchor()

    Transmog.delayedLoad:Show()

    if Transmog.class == 'druid' or Transmog.class == 'paladin' or Transmog.class == 'shaman' then
        RangedSlot:Hide()
    end

    local TWFHookSetInventoryItem = GameTooltip.SetInventoryItem
    function GameTooltip.SetInventoryItem(self, unit, slot)
        GameTooltip.itemLink = GetInventoryItemLink(unit, slot)
        return TWFHookSetInventoryItem(self, unit, slot)
    end

    local TWFHookSetBagItem = GameTooltip.SetBagItem
    function GameTooltip.SetBagItem(self, container, slot)
        GameTooltip.itemLink = GetContainerItemLink(container, slot)
        _, GameTooltip.itemCount = GetContainerItemInfo(container, slot)
        return TWFHookSetBagItem(self, container, slot)
    end
end

function Transmog:LoadOnce()

    self:aSend("GetTransmogStatus")
    self:aSend("GetSetsStatus:")
end

function TransmogFrame_OnShow()

    Transmog_switchTab('items')
    SetPortraitTexture(TransmogFramePortrait, "target");

    Transmog:getFashionCoins()
    Transmog:Reset()

    TransmogFramePlayerModel:SetScript('OnMouseUp', function(self)
        TransmogFramePlayerModel:SetScript('OnUpdate', nil)
    end)

    TransmogFramePlayerModel:SetScript('OnMouseWheel', function(self, spining)
        local Z, X, Y = TransmogFramePlayerModel:GetPosition()
        Z = (arg1 > 0 and Z + 1 or Z - 1)

        TransmogFramePlayerModel:SetPosition(Z, X, Y)
    end)

    TransmogFramePlayerModel:SetScript('OnMouseDown', function()
        local StartX, StartY = GetCursorPosition()

        local EndX, EndY, Z, X, Y
        if arg1 == 'LeftButton' then
            TransmogFramePlayerModel:SetScript('OnUpdate', function(self)
                EndX, EndY = GetCursorPosition()

                TransmogFramePlayerModel.rotation = (EndX - StartX) / 34 + TransmogFramePlayerModel:GetFacing()

                TransmogFramePlayerModel:SetFacing(TransmogFramePlayerModel.rotation)

                StartX, StartY = GetCursorPosition()
            end)
        elseif arg1 == 'RightButton' then
            TransmogFramePlayerModel:SetScript('OnUpdate', function(self)
                EndX, EndY = GetCursorPosition()

                Z, X, Y = TransmogFramePlayerModel:GetPosition(Z, X, Y)
                X = (EndX - StartX) / 45 + X
                Y = (EndY - StartY) / 45 + Y

                TransmogFramePlayerModel:SetPosition(Z, X, Y)
                StartX, StartY = GetCursorPosition()
            end)
        end
    end)

    -- [V79 fix] 删除重复请求，避免与打开面板同帧撞车
    -- 原：Transmog:aSend("GetSetsStatus:")
end

function Transmog_OnHide()
    HideUIPanel(GossipFrame)
    GossipFrame:Hide()

    PlaySound("igCharacterInfoClose");
    Transmog.currentTransmogSlotName = nil
    Transmog.currentTransmogSlot = nil
    Transmog.currentOutfit = nil
    TransmogFrameSaveOutfit:Disable()
    TransmogFrameDeleteOutfit:Disable()
    UIDropDownMenu_SetText("套装", TransmogFrameOutfits)
end

function Transmog:Reset(once)

    if not once then
        self:aSend("GetTransmogStatus")
    end

    --self.equippedTransmogs = {}

    TransmogFrameRaceBackground:SetTexture("Interface\\TransmogFrame\\transmogbackground" .. self.race)
    TransmogFrameSplash:Show()
    TransmogFrameInstructions:Show()
    TransmogFrameApplyButton:Disable()

    self.currentPage = 1

    self:getFashionCoins()

    TransmogFramePlayerModel:SetUnit("player")

    Transmog_switchTab(self.tab)
    AddButtonOnEnterTextTooltip(TransmogFrameRevert, "重置")

end

function Transmog:aSend(data)
    if self.localCache[data] then
        twfdebug("|cff69ccf0 not send " .. data .. " data cached")
    else
        SendAddonMessage(self.prefix, data, "GUILD")
        twfdebug("|cff69ccf0 send -> " .. data)
    end
end

function Transmog:setProgressBar(collected, possible)
    if collected > possible then
        collected = possible
    end

    TransmogFrameCollectedCollectedStatus:SetText(collected .. "/" .. possible)

    local fillBarWidth = (collected / possible) * TransmogFrameCollected:GetWidth();
    TransmogFrameCollectedFillBar:SetPoint("TOPRIGHT", TransmogFrameCollected, "TOPLEFT", fillBarWidth, 0);
    TransmogFrameCollectedFillBar:Show();

    TransmogFrameCollected:SetStatusBarColor(0.0, 0.0, 0.0, 0.5);
    TransmogFrameCollectedBackground:SetVertexColor(0.0, 0.0, 0.0, 0.5);
    TransmogFrameCollectedFillBar:SetVertexColor(0.0, 1.0, 0.0, 0.5);

    TransmogFrameCollected:Show()
end

Transmog.availableTransmogsCacheDelay = CreateFrame("Frame")
Transmog.availableTransmogsCacheDelay:Hide()

Transmog.availableTransmogsCacheDelay.InventorySlotId = 0

Transmog.availableTransmogsCacheDelay:SetScript("OnShow", function()
    this.startTime = GetTime()
end)

Transmog.availableTransmogsCacheDelay:SetScript("OnUpdate", function()
    local plus = 0.1
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then

        twfdebug("delay cache: " .. Transmog.availableTransmogsCacheDelay.InventorySlotId)
        Transmog:availableTransmogs(Transmog.availableTransmogsCacheDelay.InventorySlotId)
        Transmog.availableTransmogsCacheDelay:Hide()
    end
end)

-- Optimized: Cache GetInventoryItemLink outside loop
function Transmog:availableTransmogs(InventorySlotId)

    self.availableTransmogItems[InventorySlotId] = {}
    
    -- Cache the item link once
    local inventoryLink = GetInventoryItemLink('player', InventorySlotId)
    local eqItemLink
    if inventoryLink then
        local _, _, link = TransmogFrame_Find(inventoryLink, "(item:%d+:%d+:%d+:%d+)")
        eqItemLink = link
    end

    for i, itemID in self.transmogDataFromServer[InventorySlotId] do
        itemID = TransmogFrame_ToNumber(itemID)

        local name, link, quality, _, xt1, xt2, _, equip_slot, xtex = GetItemInfo(itemID)

        if not name then
            self:cacheItem(itemID);
            twfdebug("caching item " .. itemID)
            Transmog.availableTransmogsCacheDelay.InventorySlotId = InventorySlotId
            Transmog.availableTransmogsCacheDelay:Show()
            return
        end

        if name then
            table.insert(self.availableTransmogItems[InventorySlotId], {
                ['id'] = itemID,
                ['reset'] = itemID == self:IDFromLink(eqItemLink),
                ['name'] = name,
                ['link'] = link,
                ['quality'] = quality,
                ['t1'] = xt1,
                ['t2'] = xt2,
                ['equip_slot'] = equip_slot,
                ['tex'] = xtex,
                ['itemLink'] = eqItemLink
            })
        end
    end

    -- Cache table size result
    local dataSize = self:tableSize(self.transmogDataFromServer[InventorySlotId])
    self:setProgressBar(dataSize, self.numTransmogs[InventorySlotId])
    if dataSize == 0 then
        TransmogFrameNoTransmogs:Show()
    end

    self:hideItems()
    self:hideItemBorders()

    local index = 0
    local row = 0
    local col = 0
    local itemIndex = 1

    for _, item in next, self.availableTransmogItems[InventorySlotId] do

        if index >= (self.currentPage - 1) * self.ipp and index < self.currentPage * self.ipp then

            if not self.ItemButtons[itemIndex] then
                self.ItemButtons[itemIndex] = CreateFrame('Frame', 'TransmogLook' .. itemIndex, TransmogFrame, 'TransmogFrameLookTemplate')
            end

            self.ItemButtons[itemIndex]:SetPoint("TOPLEFT", TransmogFrame, "TOPLEFT", 263 + col * 90, -105 - 120 * row)

            self.ItemButtons[itemIndex].name = item.name
            self.ItemButtons[itemIndex].id = item.id

            -- Optimized: Cache getglobal results
            local lookPrefix = 'TransmogLook' .. itemIndex
            local button = getglobal(lookPrefix .. 'Button')
            local buttonRevert = getglobal(lookPrefix .. 'ButtonRevert')
            local buttonCheck = getglobal(lookPrefix .. 'ButtonCheck')
            
            button:SetID(item.id)
            buttonRevert:Hide()
            buttonCheck:Hide()

            if item.id == self.transmogStatusToServer[InventorySlotId] then
                button:SetNormalTexture('Interface\\TransmogFrame\\item_bg_selected')
            else
                button:SetNormalTexture('Interface\\TransmogFrame\\item_bg_normal')
            end

            local _, _, _, color = GetItemQualityColor(item.quality)
            AddButtonOnEnterTextTooltip(button, color .. item.name)
            if item.reset then
                buttonRevert:Show()
            end

            self.ItemButtons[itemIndex]:Show()

            local model = getglobal('TransmogLook' .. itemIndex .. 'ItemModel')

            model:SetUnit("player")
            model:SetRotation(0.61);
            local Z, X, Y = model:GetPosition(Z, X, Y)

            if self.race == 'nightelf' then
                Z = Z + 3
            end
            if self.race == 'gnome' then
                Z = Z - 3
                Y = Y + 1.5
            end
            if self.race == 'dwarf' then
                Y = Y + 1
                Z = Z - 1
            end
            if self.race == 'troll' then
                Z = Z + 2
            end
            if self.race == 'goblin' then
                Z = Z - 0.5
            end

            if self.currentTransmogSlot == self.inventorySlots['HeadSlot'] then
                if self.race == 'tauren' then
                    model:SetRotation(0.3);
                    X = X - 0.2
                    Y = Y + 0.2
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                end
                if self.race == 'dwarf' then
                    Y = Y + 0.5
                end
                model:SetPosition(Z + 5.8, X, Y - 2.2)
            end

            if self.currentTransmogSlot == self.inventorySlots['ShoulderSlot'] then
                if self.race == 'dwarf' then
                    Y = Y - 0.2
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                    Z = Z - 0.5
                end
                if self.race == 'nightelf' then
                    Z = Z - 1
                end
                model:SetPosition(Z + 5.8, X + 0.5, Y - 1.7)
            end

            if self.currentTransmogSlot == self.inventorySlots['BackSlot'] then
                model:SetRotation(3.2);
                model:SetPosition(Z + 3.8, X, Y - 0.7)
            end

            if self.currentTransmogSlot == self.inventorySlots['ChestSlot'] then
                if self.race == 'tauren' then
                    model:SetRotation(0.3);
                    X = X - 0.2
                    Y = Y + 0.5
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                    Z = Z - 0.5
                end
                model:SetRotation(0.61);
                model:SetPosition(Z + 5.8, X + 0.1, Y - 1.2)
            end

            if self.currentTransmogSlot == self.inventorySlots['WristSlot'] then
                model:SetRotation(1.5);
                if self.race == 'gnome' then
                    Y = Y - 1
                end
                if self.race == 'tauren' then
                    X = X - 0.2
                end
                if self.race == 'dwarf' then
                    X = X - 0.3
                    Y = Y - 0.4
                end
                if self.race == 'troll' then
                    Y = Y + 0.6
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                    Z = Z - 0.5
                end
                model:SetPosition(Z + 5.8, X + 0.4, Y - 0.3)
            end

            if self.currentTransmogSlot == self.inventorySlots['HandsSlot'] then
                model:SetRotation(1.5);
                if self.race == 'gnome' then
                    Y = Y - 0.7
                end
                if self.race == 'tauren' then
                    X = X - 0.2
                end
                if self.race == 'dwarf' then
                    Z = Z - 0.2
                    X = X - 0.3
                    Y = Y - 0.1
                end
                if self.race == 'troll' then
                    Y = Y + 0.9
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                    Z = Z - 0.5
                end
                model:SetPosition(Z + 5.8, X + 0.4, Y - 0.3)
            end

            if self.currentTransmogSlot == self.inventorySlots['WaistSlot'] then
                model:SetRotation(0.31);
                if self.race == 'gnome' then
                    Y = Y - 0.7
                end
                if self.race == 'tauren' then
                    Z = Z + 1
                    Y = Y + 0.3
                end
                if self.race == 'goblin' then
                    Y = Y + 1.5
                    Z = Z - 0.5
                end
                model:SetPosition(Z + 5.8, X, Y - 0.4)
            end

            if self.currentTransmogSlot == self.inventorySlots['LegsSlot'] then
                model:SetRotation(0.31);
                if self.race == 'gnome' then
                    Z = Z + 2
                    Y = Y - 1.5
                end
                if self.race == 'dwarf' then
                    Y = Y - 0.9
                end
                model:SetPosition(Z + 3.8, X, Y + 0.9)
            end

            if self.currentTransmogSlot == self.inventorySlots['FeetSlot'] then
                model:SetRotation(0.61);
                if self.race == 'gnome' then
                    Z = Z + 2
                    Y = Y - 1.9
                end
                if self.race == 'dwarf' then
                    Y = Y - 0.6
                end
                model:SetPosition(Z + 4.8, X, Y + 1.5)
            end

            if self.currentTransmogSlot == self.inventorySlots['MainHandSlot'] then
                model:SetRotation(0.61);
                if self.race == 'gnome' then
                    Y = Y - 2
                end
                if self.race == 'dwarf' then
                    Y = Y - 1
                end
                model:SetPosition(Z + 3.8, X, Y + 0.4)
            end

            if self.currentTransmogSlot == self.inventorySlots['SecondaryHandSlot'] then
                model:SetRotation(-0.61);
                model:SetPosition(Z + 3.8, X, Y)
                if self.race == 'gnome' then
                    Y = Y - 1.5
                end
                if self.race == 'dwarf' then
                    Y = Y - 1
                end
            end

            if self.currentTransmogSlot == self.inventorySlots['RangedSlot'] then
                model:SetRotation(-0.61)
                if self.invTypes[item.equip_slot] == C_INVTYPE_RANGEDRIGHT then
                    model:SetRotation(0.61);
                end
                if self.race == 'troll' then
                    Y = Y + 1.5
                end
                if self.race == 'goblin' then
                    Y = Y + 1
                end
                if self.race == 'gnome' then
                    Y = Y - 1.5
                end
                model:SetPosition(Z + 3.8, X, Y)
            end

            model:Undress()

            if self.currentTransmogSlot == self.inventorySlots['SecondaryHandSlot'] then
                TransmogFramePlayerModel:TryOn(self.equippedItems[self.inventorySlots['MainHandSlot']])
            end

            model:TryOn(item.id);

            col = col + 1
            if col == 5 then
                row = row + 1
                col = 0
            end

            itemIndex = itemIndex + 1

        end
        index = index + 1
    end

    self.totalPages = self:ceil(self:tableSize(self.availableTransmogItems[InventorySlotId]) / self.ipp)

    TransmogFramePageText:SetText("页码 " .. self.currentPage .. "/" .. self.totalPages)

    if self.currentPage == 1 then
        TransmogFrameLeftArrow:Disable()
    else
        TransmogFrameLeftArrow:Enable()
    end

    if self.currentPage == self.totalPages or self:tableSize(self.availableTransmogItems[InventorySlotId]) < self.ipp then
        TransmogFrameRightArrow:Disable()
    else
        TransmogFrameRightArrow:Enable()
    end

    if self.totalPages > 1 then
        self:showPagination()
    else
        self:hidePagination()
    end

    if self.currentTransmogSlotName then
        getglobal(self.currentTransmogSlotName .. 'BorderSelected'):Show()
    end

end

-- Optimized: Cache GetInventoryItemLink to avoid duplicate calls
function Transmog:transmogStatus()
    local prev = self.equippedTransmogs or {}
    local newMap = {}
    local needRefresh = false

    for InventorySlotId, itemID in self.transmogStatusFromServer do
        if itemID ~= 0 then
            local itemLink = GetInventoryItemLink('player', InventorySlotId)
            if itemLink then
                local _, _, eqItemLink = TransmogFrame_Find(itemLink, "(item:%d+:%d+:%d+:%d+)")
                local eqItemId = self:IDFromLink(eqItemLink)
                if eqItemId then
                    local transmogName = GetItemInfo(itemID)
                    if transmogName then
                        newMap[eqItemId] = transmogName
                        Transmog.slotTransmogNames[InventorySlotId] = transmogName
                    else
                        -- 物品信息未缓存：先触发缓存，并保留旧值，随后轻量重试
                        self:cacheItem(itemID)
                        needRefresh = true
                        if prev[eqItemId] then
                            newMap[eqItemId] = prev[eqItemId]
                        end
                    end
                end
            end
        end
    end
    self.equippedTransmogs = newMap
    if needRefresh then
        self:DelayedRefreshTransmogStatus(0.2)
    end

    for slotName, InventorySlotId in self.inventorySlots do
        local frame = getglobal(slotName)
        if frame then
            local texture
            local texEx = TransmogFrame_Explode(frame:GetName(), 'Slot')
            texture = string.lower(texEx[1])

            if texture == 'wrist' then texture = texture .. 's' end
            if texture == 'back' then texture = 'chest' end

            getglobal(frame:GetName() .. 'ItemIcon'):SetTexture('Interface\\Paperdoll\\ui-paperdoll-slot-' .. texture)
            getglobal(frame:GetName() .. 'NoEquip'):Show()
            getglobal(frame:GetName() .. 'BorderHi'):Hide()

            AddButtonOnEnterTextTooltip(frame, self.inventorySlotNames[InventorySlotId], "此部位中没有装备物品", true)
        end
    end

    for slotName, InventorySlotId in self.inventorySlots do
        self.equippedItems[InventorySlotId] = 0
        if GetInventoryItemLink('player', InventorySlotId) then
            local _, _, eqItemLink = TransmogFrame_Find(GetInventoryItemLink('player', InventorySlotId), "(item:%d+:%d+:%d+:%d+)")
            local itemName, _, _, _, _, _, _, _, tex = GetItemInfo(eqItemLink)

            local eqItemId = self:IDFromLink(eqItemLink)
            self.equippedItems[InventorySlotId] = eqItemId

            local frame = getglobal(slotName)
            if frame then
                frame:Enable()
                frame:SetID(InventorySlotId)

                getglobal(frame:GetName() .. 'AutoCast'):Hide()
                getglobal(frame:GetName() .. 'AutoCast'):SetModel("Interface\\Buttons\\UI-AutoCastButton.mdx")
                getglobal(frame:GetName() .. 'AutoCast'):SetAlpha(0.3)

                getglobal(frame:GetName() .. 'NoEquip'):Hide()
                getglobal(frame:GetName() .. 'Revert'):Hide()

                if self.transmogStatusFromServer[InventorySlotId] and self.transmogStatusFromServer[InventorySlotId] ~= 0 then
                    getglobal(frame:GetName() .. 'BorderHi'):Show()
                    -- 传 eqItemId 映射到已幻化文本
                    local transmogDisplay = self.equippedTransmogs[eqItemId] or Transmog.slotTransmogNames[InventorySlotId]
                    AddButtonOnEnterTooltipFashion(frame, eqItemLink, transmogDisplay, true)

                    local _, _, _, _, _, _, _, _, TransmogTex = GetItemInfo(self.transmogStatusFromServer[InventorySlotId])

                    if TransmogTex then
                        getglobal(frame:GetName() .. 'ItemIcon'):SetTexture(TransmogTex)
                    else
                        local fallbackTex = tex or GetInventoryItemTexture('player', InventorySlotId)
                        if fallbackTex then
                            getglobal(frame:GetName() .. 'ItemIcon'):SetTexture(fallbackTex)
                        end
                        self:cacheItem(self.transmogStatusFromServer[InventorySlotId])
                        self:DelayedRefreshTransmogStatus(0.2)
                    end

                    getglobal(frame:GetName() .. 'Revert'):Show()
                else
                    getglobal(frame:GetName() .. 'BorderHi'):Hide()
                    AddButtonOnEnterTooltipFashion(frame, eqItemLink)
                    local fallbackTex = tex or GetInventoryItemTexture('player', InventorySlotId)
                    if fallbackTex then
                        getglobal(frame:GetName() .. 'ItemIcon'):SetTexture(fallbackTex)
                    end
                end
            end
        end
    end

    self:calculateCost()
end

function Apply_OnClick()

    local actionIndex = 0

    TransmogFrameApplyButton:Disable()

    Transmog.applyTimer.actions = {}

    for InventorySlotId, itemID in Transmog.transmogStatusToServer do

        if Transmog.transmogStatusFromServer[InventorySlotId] ~= itemID then

            actionIndex = actionIndex + 1

            if itemID == 0 then
                Transmog.applyTimer.actions[actionIndex] = {
                    ['type'] = 'reset',
                    ['serverSlot'] = Transmog:slotIdToServerSlot(InventorySlotId),
                    ['itemID'] = 0,
                    ['InventorySlotId'] = InventorySlotId,
                    ['sent'] = false
                }
            else
                Transmog.applyTimer.actions[actionIndex] = {
                    ['type'] = 'do',
                    ['serverSlot'] = Transmog:slotIdToServerSlot(InventorySlotId),
                    ['itemId'] = itemID,
                    ['InventorySlotId'] = InventorySlotId,
                    ['sent'] = false
                }
            end

        end
    end
    Transmog.itemAnimationFrames = {}
    Transmog.applyTimer:Show()

    PlaySoundFile("Interface\\TransmogFrame\\ui_transmogrify_apply.ogg", "Dialog");

end

function Transmog:addTransmogAnim(id, reset)
    for slotName, InventorySlotId in self.inventorySlots do
        if id == InventorySlotId then
            local frame = getglobal(slotName)
            if frame then
                self.itemAnimationFrames[self:tableSize(self.itemAnimationFrames) + 1] = {
                    ['frame'] = frame,
                    ['borderHi'] = getglobal(frame:GetName() .. "BorderHi"),
                    ['borderFull'] = getglobal(frame:GetName() .. "BorderFull"),
                    ['autocast'] = getglobal(frame:GetName() .. "AutoCast"),
                    ['reset'] = reset,
                    ['dir'] = 1
                }
                break
            end
        end
    end

    if self:tableSize(self.itemAnimationFrames) == self:tableSize(self.applyTimer.actions) then
        self.itemAnimation:Show()
    end
end

function Transmog:frameFromInvType(invType, clientSlot)

    if invType == 'INVTYPE_WEAPON' and clientSlot == 17 then
        return SecondaryHandSlot
    end

    if invType == 'INVTYPE_HEAD' then
        return HeadSlot
    end
    if invType == 'INVTYPE_SHOULDER' then
        return ShoulderSlot
    end
    if invType == 'INVTYPE_CLOAK' then
        return BackSlot
    end
    if invType == 'INVTYPE_CHEST' or invType == 'INVTYPE_ROBE' then
        return ChestSlot
    end
    if invType == 'INVTYPE_WRIST' then
        return WristSlot
    end
    if invType == 'INVTYPE_HAND' then
        return HandsSlot
    end
    if invType == 'INVTYPE_WAIST' then
        return WaistSlot
    end
    if invType == 'INVTYPE_LEGS' then
        return LegsSlot
    end
    if invType == 'INVTYPE_FEET' then
        return FeetSlot
    end

    if invType == 'INVTYPE_WEAPONMAINHAND' or
            invType == 'INVTYPE_2HWEAPON' or
            invType == 'INVTYPE_WEAPON' or
            invType == 'INVTYPE_WEAPONMAINHAND'
    then
        return MainHandSlot
    end
    if invType == 'INVTYPE_WEAPONOFFHAND' or
            invType == 'INVTYPE_HOLDABLE' or
            invType == 'INVTYPE_SHIELD'
    then
        return SecondaryHandSlot
    end
    if invType == 'INVTYPE_RANGED' or
            invType == 'INVTYPE_RANGEDRIGHT' then
        return RangedSlot
    end
    return nil
end

function Transmog_Try(itemId, slotName, newReset)

    if newReset and getglobal(slotName .. "NoEquip"):IsVisible() then
        return false
    end

    Transmog:hideItemBorders()

    -- 套装点击应用逻辑：跳过已经有幻化的槽位（不覆盖）；其余保持你的改动
if Transmog.tab == 'sets' and not newReset then
    TransmogFramePlayerModel:SetUnit("player")
    Transmog:getFashionCoins()
    Transmog:transmogStatus()

    for InventorySlotId, data in Transmog.transmogStatusFromServer do
        Transmog.transmogStatusToServer[InventorySlotId] = data
    end

    local setIndex = itemId
    -- Optimized: Build lookup table from currentTransmogsData for O(1) access
    local learnedItems = {}
    if Transmog.ownedTransmogsPageTemp then
        for id, _ in pairs(Transmog.ownedTransmogsPageTemp) do
            learnedItems[id] = true
        end
    else
        for _, data in next, Transmog.currentTransmogsData do
            for _, d in next, data do
                learnedItems[d['id']] = true
            end
        end
    end
    
    for _, setItemId in next, Transmog.availableSets[setIndex]['items'] do
        local learned = learnedItems[setItemId]
        
        if learned then
            Transmog.availableSets[setIndex]['itemsExtended'] = Transmog.availableSets[setIndex]['itemsExtended'] or {}
            local ex = Transmog.availableSets[setIndex]['itemsExtended'][setItemId]
            if not ex then
                local n, _, _, _, _, _, _, equip_slot, xtex = GetItemInfo(setItemId)
                if not equip_slot then
                    Transmog:cacheItem(setItemId)
                    n, _, _, _, _, _, _, equip_slot, xtex = GetItemInfo(setItemId)
                end
                if equip_slot then
                    ex = { ['name'] = n, ['slot'] = equip_slot, ['tex'] = xtex }
                    Transmog.availableSets[setIndex]['itemsExtended'][setItemId] = ex
                end
            end
            if ex and ex.slot then
                local slotId = Transmog.invTypes[ex.slot]
                local frame = Transmog:frameFromInvType(ex.slot)

                if slotId then
                    local itemLink = GetInventoryItemLink('player', slotId)
                    if itemLink then
                        if Transmog.transmogStatusFromServer[slotId] ~= 0 then
                            -- 已有幻化：跳过
                        else
                            local _, _, eqItemLink = TransmogFrame_Find(itemLink, "(item:%d+:%d+:%d+:%d+)")
                            local equippedName = GetItemInfo(eqItemLink)

                        if equippedName ~= ex.name then
                            TransmogFramePlayerModel:TryOn(setItemId)
                            if frame then
                                getglobal(frame:GetName() .. "ItemIcon"):SetTexture(ex.tex)
                                getglobal(frame:GetName() .. 'BorderHi'):Show()
                                getglobal(frame:GetName() .. 'AutoCast'):Show()
                            end
                            Transmog.transmogStatusToServer[slotId] = setItemId
                        end
                    end
                else
                    if frame then
                        getglobal(frame:GetName() .. 'BorderHi'):Hide()
                        getglobal(frame:GetName() .. 'AutoCast'):Hide()
                    end
                end
            end
        end
    end

    getglobal(slotName):SetNormalTexture('Interface\\TransmogFrame\\item_bg_selected')
    Transmog:calculateCost()
    Transmog:EnableOutfitSaveButton()
    return true
end

    if newReset then
        local InventorySlotId = Transmog.inventorySlots[slotName]
        itemId = Transmog:IDFromLink(GetInventoryItemLink('player', InventorySlotId))
        Transmog.transmogStatusToServer[InventorySlotId] = 0

        getglobal(slotName .. 'BorderHi'):Hide()
        getglobal(slotName .. 'AutoCast'):Hide()

        if Transmog.transmogStatusFromServer[InventorySlotId] ~= Transmog.transmogStatusToServer[InventorySlotId] then
            getglobal(slotName .. 'AutoCast'):Show()
        end

        TransmogFramePlayerModel:TryOn(itemId)

        local _, _, _, _, _, _, _, _, tex = GetItemInfo(itemId)
        getglobal(slotName .. "ItemIcon"):SetTexture(tex)

        AddButtonOnEnterTooltipFashion(getglobal(slotName), GetInventoryItemLink('player', InventorySlotId))

        local _, _, eqItemLink = TransmogFrame_Find(GetInventoryItemLink('player', InventorySlotId), "(item:%d+:%d+:%d+:%d+)")
        local eqId = Transmog:IDFromLink(eqItemLink)
        -- 用 itemID 清空“已幻化为”提示
        Transmog.equippedTransmogs[eqId] = nil

        Transmog:calculateCost()
        Transmog:EnableOutfitSaveButton()
        return true
    end

    if itemId == Transmog:IDFromLink(GetInventoryItemLink('player', Transmog.currentTransmogSlot)) then
        getglobal(Transmog.currentTransmogSlotName .. 'BorderHi'):Hide()
        Transmog.transmogStatusToServer[Transmog.currentTransmogSlot] = 0
    else
        getglobal(Transmog.currentTransmogSlotName .. 'BorderHi'):Show()
        Transmog.transmogStatusToServer[Transmog.currentTransmogSlot] = itemId
    end

    for itemIndex, data in Transmog.ItemButtons do
        getglobal('TransmogLook' .. itemIndex .. 'Button'):SetNormalTexture('Interface\\TransmogFrame\\item_bg_normal')
        if data.id == itemId then
            getglobal('TransmogLook' .. itemIndex .. 'Button'):SetNormalTexture('Interface\\TransmogFrame\\item_bg_selected')
        end
    end

    getglobal(Transmog.currentTransmogSlotName .. 'AutoCast'):Hide()

    if Transmog.transmogStatusFromServer[Transmog.currentTransmogSlot] ~= Transmog.transmogStatusToServer[Transmog.currentTransmogSlot] then
        getglobal(Transmog.currentTransmogSlotName .. 'AutoCast'):Show()
    end

    if slotName == 'SecondaryHandSlot' then
        TransmogFramePlayerModel:TryOn(Transmog.equippedItems[Transmog.inventorySlots['MainHandSlot']])
    end

    TransmogFramePlayerModel:TryOn(itemId);

    local itemName, itemLink, itemRarity, _, t1, t2, _, itemSlot, tex = GetItemInfo(itemId)

    getglobal(Transmog.currentTransmogSlotName .. "ItemIcon"):SetTexture(tex)

    Transmog:calculateCost()

    Transmog:EnableOutfitSaveButton()

end

function Transmog:IDFromLink(link)
    local itemSplit = TransmogFrame_Explode(link, ':')
    if itemSplit[2] and TransmogFrame_ToNumber(itemSplit[2]) then
        return TransmogFrame_ToNumber(itemSplit[2])
    end
    return nil
end

function Transmog:getFashionCoins()

    local name, linkString, _, _, _, _, _, _, tex = GetItemInfo(40062)
    if not name then
        return
    end
    local _, _, itemLink = TransmogFrame_Find(linkString, "(item:%d+:%d+:%d+:%d+)");

    if not name then
        twferror('fashion coin not cached')
        return
    end

    TransmogFrameCurrencyIcon:SetNormalTexture(tex)
    TransmogFrameCurrencyIcon:SetPushedTexture(tex)

    AddButtonOnEnterTooltipFashion(TransmogFrameCurrencyIcon, itemLink)

    self.fashionCoins = 0

    for bag = 0, 4 do
        for slot = 0, GetContainerNumSlots(bag) do

            local item = GetContainerItemLink(bag, slot)

            if item then
                local _, itemCount = GetContainerItemInfo(bag, slot);
                if TransmogFrame_Find(item, '时光徽章', 1, true) then
                    self.fashionCoins = self.fashionCoins + TransmogFrame_ToNumber(itemCount)
                end
            end
        end
    end
    TransmogFrameCurrencyText:SetText(self.fashionCoins)
end

function Transmog:hidePagination()
    TransmogFrameLeftArrow:Hide()
    TransmogFrameRightArrow:Hide()
    TransmogFramePageText:Hide()
end

function Transmog:showPagination()
    TransmogFrameLeftArrow:Show()
    TransmogFrameRightArrow:Show()
    TransmogFramePageText:Show()
end

function Transmog:hideItems()
    for index, _ in self.ItemButtons do
        getglobal('TransmogLook' .. index):Hide()
    end
end

function Transmog:hideItemBorders()
    for index in next, self.ItemButtons do
        getglobal('TransmogLook' .. index .. 'Button'):SetNormalTexture('Interface\\TransmogFrame\\item_bg_normal')
    end
end

function Transmog:calculateCost(to)

    self:getFashionCoins()

    local cost = 0
    local resets = 0

    for InventorySlotId, data in self.transmogStatusFromServer do
        if data ~= self.transmogStatusToServer[InventorySlotId] then
            if self.transmogStatusToServer[InventorySlotId] ~= 0 then
                cost = cost + 1
            else
                resets = resets + 1
            end
        end
    end

    if to == 0 then
        cost = 0
        resets = 0
    end

    if cost == 0 then

        if resets > 0 then
            TransmogFrameApplyButton:Enable()
            TransmogFrameApplyButton:SetText("重置幻化")
        else
            TransmogFrameApplyButton:Disable()
            TransmogFrameApplyButton:SetText("应用幻化")
        end

    else
        if self.fashionCoins >= cost then
            TransmogFrameApplyButton:Enable()
            TransmogFrameApplyButton:SetText("使用 " .. cost .. " 个时光 " .. (cost == 1 and "徽章" or "徽章"))
        else
            TransmogFrameApplyButton:Disable()
            TransmogFrameApplyButton:SetText("没有足够的时光徽章")
        end
    end
end

function Transmog:HidePlayerItemsAnimation()
    HeadSlotAutoCast:Hide()
    ShoulderSlotAutoCast:Hide()
    BackSlotAutoCast:Hide()
    ChestSlotAutoCast:Hide()
    WristSlotAutoCast:Hide()
    HandsSlotAutoCast:Hide()
    WaistSlotAutoCast:Hide()
    LegsSlotAutoCast:Hide()
    FeetSlotAutoCast:Hide()
    MainHandSlotAutoCast:Hide()
    SecondaryHandSlotAutoCast:Hide()
    RangedSlotAutoCast:Hide()
end

function Transmog:hidePlayerItemsBorders()
    HeadSlotBorderSelected:Hide()
    ShoulderSlotBorderSelected:Hide()
    BackSlotBorderSelected:Hide()
    ChestSlotBorderSelected:Hide()
    WristSlotBorderSelected:Hide()
    HandsSlotBorderSelected:Hide()
    WaistSlotBorderSelected:Hide()
    LegsSlotBorderSelected:Hide()
    FeetSlotBorderSelected:Hide()
    MainHandSlotBorderSelected:Hide()
    SecondaryHandSlotBorderSelected:Hide()
    RangedSlotBorderSelected:Hide()
end

function Transmog:LockPlayerItems()
    for slot in Transmog.inventorySlots do
        getglobal(slot):Disable()
        SetDesaturation(getglobal(slot .. 'ItemIcon'), 1);
    end
end

function Transmog:UnlockPlayerItems()

end

-- Optimized: Cache size when possible, faster iteration
function Transmog:tableSize(t)
    if type(t) ~= 'table' then
        twfdebug('t not table')
        return 0
    end
    -- For Lua 5.0, use table.getn for indexed tables when possible
    local n = table.getn(t)
    if n > 0 then
        return n
    end
    -- Fallback to manual count for hash tables
    local size = 0
    for k, v in pairs(t) do
        size = size + 1
    end
    return size
end

function Transmog:ceil(num)
    if num > math.floor(num) then
        return math.floor(num + 1)
    end
    return math.floor(num + 0.5)
end

function selectTransmogSlot(InventorySlotId, slotName)

    TransmogFrameNoTransmogs:Hide()

    if InventorySlotId == -1 then
        Transmog:hidePlayerItemsBorders()
        Transmog:HidePlayerItemsAnimation()
        Transmog:hideItems()
        Transmog:hideItemBorders()
        Transmog:hidePagination()
        TransmogFrameSplash:Show()
        TransmogFrameInstructions:Show()
		TransmogFrameCollected:Hide()
        Transmog.currentTransmogSlotName = nil
        Transmog.currentTransmogSlot = nil
        return true
    end

    if getglobal(slotName .. "NoEquip"):IsVisible() then
        return false
    end

    TransmogFrameSplash:Hide()
    TransmogFrameInstructions:Hide()

    Transmog.currentPage = 1
    Transmog.currentTransmogSlotName = slotName
    Transmog.currentTransmogSlot = InventorySlotId

    if Transmog.tab == 'sets' then
        Transmog_switchTab('items')
        return
    end

    if not GetInventoryItemLink('player', Transmog.currentTransmogSlot) then
        selectTransmogSlot(-1)
        return
    end

    local _, _, eqItemLink = TransmogFrame_Find(GetInventoryItemLink('player', Transmog.currentTransmogSlot), "(item:%d+:%d+:%d+:%d+)");
    local itemName, _, _, _, _, subClass, _, invType = GetItemInfo(eqItemLink)

    local eqItemId = Transmog:IDFromLink(eqItemLink)

    if Transmog.transmogStatusFromServer[Transmog.currentTransmogSlot] and Transmog.transmogStatusFromServer[Transmog.currentTransmogSlot] ~= 0 then
        TransmogFramePlayerModel:TryOn(Transmog.transmogStatusFromServer[Transmog.currentTransmogSlot])
    else
        TransmogFramePlayerModel:TryOn(eqItemId)
    end

    Transmog:hideItems()
    Transmog:hidePlayerItemsBorders()

    Transmog:aSend("GetAvailableTransmogsItemIDs:" .. InventorySlotId .. ":" .. Transmog.invTypes[invType] .. ":" .. eqItemId)

end

function TransmogModel_OnLoad()
    TransmogFramePlayerModel.rotation = 0.61;
    TransmogFramePlayerModel:SetRotation(TransmogFramePlayerModel.rotation);
end

function AddButtonOnEnterTextTooltip(frame, text, ext, error, anchor, x, y)
    frame:SetScript("OnEnter", function(self)
        if anchor and x and y then
            FashionTooltip:SetOwner(this, anchor, x, y)
        else
            FashionTooltip:SetOwner(this, "ANCHOR_RIGHT", -(this:GetWidth() / 4) + 15, -(this:GetHeight() / 4) + 20)
        end

        if error then
            FashionTooltip:AddLine(FONT_COLOR_CODE_CLOSE .. text)
            FashionTooltip:AddLine("|cffff2020" .. ext)
        else
            FashionTooltip:AddLine(HIGHLIGHT_FONT_COLOR_CODE .. text)
            if ext then
                FashionTooltip:AddLine(FONT_COLOR_CODE_CLOSE .. ext)
            end
        end
        FashionTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self)
        FashionTooltip:Hide()
    end)
end

function AddButtonOnEnterTooltipFashion(frame, itemLink, TransmogText, revert)

    if TransmogFrame_Find(itemLink, "|", 1, true) then
        local ex = TransmogFrame_Explode(itemLink, "|")

        if not ex[2] or not ex[3] then
            twferror('bad addButtonOnEnterTooltip itemLink syntax')
            twferror(itemLink)
            return false
        end

        frame:SetScript("OnEnter", function(self)
            FashionTooltip:SetOwner(this, "ANCHOR_RIGHT", -(this:GetWidth() / 4) + 10, -(this:GetHeight() / 4));
            FashionTooltip:SetHyperlink(string.sub(ex[3], 2, string.len(ex[3])));

            local tLabel = getglobal(FashionTooltip:GetName() .. "TextLeft2")
            if tLabel and TransmogText then
                if revert then
                    tLabel:SetText('|cfff471f5已幻化为:\n' .. TransmogText .. '\n|cffffd200点击右键恢复初始状态\n|cffffffff' .. tLabel:GetText())
                else
                    tLabel:SetText('|cfff471f5已幻化为:\n' .. TransmogText .. '\n|cffffffff' .. tLabel:GetText())
                end
            end

            FashionTooltip:AddLine("");
            FashionTooltip:Show();

        end)
    else
        frame:SetScript("OnEnter", function(self)
            FashionTooltip:SetOwner(this, "ANCHOR_RIGHT", -(this:GetWidth() / 4) + 10, -(this:GetHeight() / 4));
            FashionTooltip:SetHyperlink(itemLink);
            local tLabel = getglobal(FashionTooltip:GetName() .. "TextLeft2")
            if tLabel and TransmogText then
                if revert then
                    tLabel:SetText('|cfff471f5已幻化为:\n' .. TransmogText .. '\n|cffffd200点击右键恢复初始状态\n|cffffffff' .. tLabel:GetText())
                else
                    tLabel:SetText('|cfff471f5已幻化为:\n' .. TransmogText .. '\n|cffffffff' .. tLabel:GetText())
                end
            end
            FashionTooltip:Show();
        end)
    end
    frame:SetScript("OnLeave", function(self)
        FashionTooltip:Hide();
    end)
end

function Transmog_ChangePage(dir)
    Transmog.currentPage = Transmog.currentPage + dir

    Transmog:ClearSetModelQueue()

    if Transmog.tab == 'items' then
        Transmog:availableTransmogs(Transmog.currentTransmogSlot)
    else
        Transmog_switchTab(Transmog.tab)
        -- 套装翻页后，请求本页拥有情况
        Transmog:RequestOwnedForVisibleSets()
    end
end

function Transmog_revert()
    Transmog:Reset()
    Transmog:calculateCost(0)
end

function Transmog_switchTab(to)

    Transmog.tab = to

    if to == 'items' then
        Transmog:ClearSetModelQueue()

        TransmogFrameItemsButton:SetNormalTexture('Interface\\TransmogFrame\\tab_active')
        TransmogFrameItemsButton:SetPushedTexture('Interface\\TransmogFrame\\tab_active')
        TransmogFrameItemsButtonText:SetText(HIGHLIGHT_FONT_COLOR_CODE .. '物品')

        TransmogFrameSetsButton:SetNormalTexture('Interface\\TransmogFrame\\tab_inactive')
        TransmogFrameSetsButton:SetPushedTexture('Interface\\TransmogFrame\\tab_inactive')
        TransmogFrameSetsButtonText:SetText(FONT_COLOR_CODE_CLOSE .. '套装')

        if Transmog.currentTransmogSlot ~= nil then
            selectTransmogSlot(Transmog.currentTransmogSlot, Transmog.currentTransmogSlotName)
        else
            selectTransmogSlot(-1)
        end

        return
    end

    if to == 'sets' then
        Transmog:ClearSetModelQueue()

        selectTransmogSlot(-1)

        TransmogFrameSplash:Hide()
        TransmogFrameInstructions:Hide()

        TransmogFrameSetsButton:SetNormalTexture('Interface\\TransmogFrame\\tab_active')
        TransmogFrameSetsButton:SetPushedTexture('Interface\\TransmogFrame\\tab_active')
        TransmogFrameSetsButtonText:SetText(HIGHLIGHT_FONT_COLOR_CODE .. '套装')

        TransmogFrameItemsButton:SetNormalTexture('Interface\\TransmogFrame\\tab_inactive')
        TransmogFrameItemsButton:SetPushedTexture('Interface\\TransmogFrame\\tab_inactive')
        TransmogFrameItemsButtonText:SetText(FONT_COLOR_CODE_CLOSE .. '物品')

        Transmog:hideItems()
        Transmog:hideItemBorders()

        local index = 0
        local row = 0
        local col = 0
        local setIndex = 1

        local completedSets = 0
        if Transmog.setsStatsReady and Transmog.completedSetsCache ~= nil then
            completedSets = Transmog.completedSetsCache or 0
        end

        for i, set in next, Transmog.availableSets do
            if index >= (Transmog.currentPage - 1) * Transmog.ipp and index < Transmog.currentPage * Transmog.ipp then

                if not Transmog.ItemButtons[setIndex] then
                    Transmog.ItemButtons[setIndex] = CreateFrame('Frame', 'TransmogLook' .. setIndex, TransmogFrame, 'TransmogFrameLookTemplate')
                end

                Transmog.ItemButtons[setIndex]:SetPoint("TOPLEFT", TransmogFrame, "TOPLEFT", 263 + col * 90, -105 - 120 * row)
                Transmog.ItemButtons[setIndex].name = set.name

                -- Optimized: Cache getglobal results
                local lookPrefix = 'TransmogLook' .. setIndex
                local button = getglobal(lookPrefix .. 'Button')
                local buttonRevert = getglobal(lookPrefix .. 'ButtonRevert')
                local buttonCheck = getglobal(lookPrefix .. 'ButtonCheck')
                
                button:SetID(i)
                buttonRevert:Hide()
                buttonCheck:Hide()

                Transmog.availableSets[i]['itemsExtended'] = Transmog.availableSets[i]['itemsExtended'] or {}

                -- 每格“已收集/总数”与 tooltip（按页拥有集）
                local total = (Transmog.setSize and Transmog.setSize[i]) or Transmog:tableSize(set.items)
                local founds = 0
                local setItemsText = ''

                for _, itemID in set.items do
                    local setItemName, link, quality, _, xt1, xt2, _, equip_slot, xtex = GetItemInfo(itemID)
                    if not setItemName then
                        Transmog:QueueCacheItem(itemID)
                    else
                        local has = false
                        if Transmog.ownedTransmogsPageTemp and Transmog.ownedTransmogsPageTemp[itemID] then
                            has = true
                        else
                            -- 退化：当前会话数据
                            for _, data in next, Transmog.currentTransmogsData do
                                for _, d in next, data do
                                    if d['id'] == itemID then has = true break end
                                end
                                if has then break end
                            end
                        end
                        if has then founds = founds + 1 end

                        setItemsText = setItemsText .. (has and FONT_COLOR_CODE_CLOSE or GRAY_FONT_COLOR_CODE) .. setItemName .. "\n"

                        Transmog.availableSets[i]['itemsExtended'][itemID] = {
                            ['name'] = setItemName,
                            ['slot'] = equip_slot,
                            ['tex'] = xtex
                        }
                    end
                end

                if founds == total then
                    buttonCheck:Show()
                end

                AddButtonOnEnterTextTooltip(
                    button,
                    set.name .. " " .. founds .. "/" .. total,
                    setItemsText
                )

                Transmog.ItemButtons[setIndex]:Show()

                -- 模型：统一使用异步队列（不再依赖 setsStatsReady）
                local model = getglobal('TransmogLook' .. setIndex .. 'ItemModel')
                model:SetUnit("player")
                model:SetRotation(0.61)
                local Z, X, Y = model:GetPosition(Z, X, Y)
                model:SetPosition(Z + 1.5, X, Y)
                model:SetAlpha(0)
                model:Show()
                Transmog:QueueSetModel(model, set.items)

                col = col + 1
                if col == 5 then
                    row = row + 1
                    col = 0
                end

                setIndex = setIndex + 1
            end
            index = index + 1
        end

        Transmog.totalPages = Transmog:ceil(Transmog:tableSize(Transmog.availableSets) / Transmog.ipp)
        TransmogFramePageText:SetText("页码 " .. Transmog.currentPage .. "/" .. Transmog.totalPages)

        if Transmog.currentPage == 1 then
            TransmogFrameLeftArrow:Disable()
        else
            TransmogFrameLeftArrow:Enable()
        end

        if Transmog.currentPage == Transmog.totalPages or Transmog:tableSize(Transmog.availableSets) < Transmog.ipp then
            TransmogFrameRightArrow:Disable()
        else
            TransmogFrameRightArrow:Enable()
        end

        if Transmog.totalPages > 1 then
            Transmog:showPagination()
        else
            Transmog:hidePagination()
        end

        Transmog:setProgressBar(completedSets, Transmog:tableSize(Transmog.availableSets))

        -- 进入套装页后，请求“本页已拥有项”
        Transmog:RequestOwnedForVisibleSets()

        return
    end
end

function TransmogFrame_Explode(str, delimiter)
    local result = {}
    local from = 1
    local delim_from, delim_to = TransmogFrame_Find(str, delimiter, from, 1, true)
    while delim_from do
        table.insert(result, string.sub(str, from, delim_from - 1))
        from = delim_to + 1
        delim_from, delim_to = TransmogFrame_Find(str, delimiter, from, true)
    end
    table.insert(result, string.sub(str, from))
    return result
end

local characterPaperDollFrames = {
    CharacterHeadSlot,
    CharacterShoulderSlot,
    CharacterBackSlot,
    CharacterChestSlot,
    CharacterWristSlot,
    CharacterHandsSlot,
    CharacterWaistSlot,
    CharacterLegsSlot,
    CharacterFeetSlot,
    CharacterMainHandSlot,
    CharacterSecondaryHandSlot,
    CharacterRangedSlot,
}

-- 角色面板上悬浮提示，也用 itemID 查询映射
EquipTransmogTooltip:SetScript("OnShow", function()
    if GameTooltip.itemLink then
        if not PaperDollFrame:IsVisible() then return end

        local _, _, itemLink = TransmogFrame_Find(GameTooltip.itemLink, "(item:%d+:%d+:%d+:%d+)")
        if not itemLink then return end

        for _, frame in next, characterPaperDollFrames do
            if GameTooltip:IsOwned(frame) == 1 then
                local cSlot = frame:GetID()
                local ov = Transmog.overrideTooltip[cSlot]
                
                -- 核心逻辑：如果 override 数据存在，则用它来构建 Tooltip
                if ov and ov.tooltipEntry and ov.tooltipEntry ~= 0 then
                    -- 步骤 1: 设置 Tooltip 的主物品，并显示“原始物品”
                    local showLink = "item:" .. ov.tooltipEntry .. ":0:0:0"
                    GameTooltip:ClearLines()
                    GameTooltip:SetHyperlink(showLink)

                    -- 如果是套装件被幻化，显示“原始物品”行
                    if ov.baseEntry ~= 0 and ov.baseEntry ~= ov.tooltipEntry then
                        local baseName = GetItemInfo(ov.baseEntry)
                        if not baseName then
                            Transmog:QueueCacheItem(ov.baseEntry)
                            baseName = GetItemInfo(ov.baseEntry) -- 尝试再次获取
                        end
                        if baseName then
                            GameTooltip:AddLine("|cffffd200原始物品: " .. baseName)
                        else
                            GameTooltip:AddLine("|cffffd200原始物品: (载入中)")
                        end
                    end
                    
                    -- 步骤 2: 使用 sourceItemId 来显示“幻化为”
                    -- (sourceItemId > 0 表示这是一件幻化装备)
                    if ov.sourceItemId and ov.sourceItemId > 0 then
                        local sourceName = GetItemInfo(ov.sourceItemId)
                        if not sourceName then
                            Transmog:QueueCacheItem(ov.sourceItemId)
                            sourceName = GetItemInfo(ov.sourceItemId) -- 尝试再次获取
                        end

                        if sourceName then
                            local tLabel = getglobal(GameTooltip:GetName() .. "TextLeft2")
                            if tLabel then
                                -- 使用 sourceName 作为“幻化为”的文本
                                tLabel:SetText('|cfff471f5幻化为:\n' .. sourceName .. '\n|cffffffff' .. tLabel:GetText())
                            end
                        end
                    end
                    
                    GameTooltip:Show()
                end
                
                -- 旧的、依赖本地缓存的逻辑已被上面的代码块取代，所以这里不再需要执行
                -- local id = Transmog:IDFromLink(itemLink)
                -- local slotId = frame:GetID()
                -- local transmogTo = Transmog.equippedTransmogs[id] or Transmog.slotTransmogNames[slotId]
                -- ...
            end
        end
    end
end)

EquipTransmogTooltip:SetScript("OnHide", function()
    GameTooltip.itemLink = nil
end)

-- Apply Timer
Transmog.applyTimer = CreateFrame("Frame")
Transmog.applyTimer:Hide()

Transmog.applyTimer:SetScript("OnShow", function()
    this.startTime = GetTime()
    Transmog.applyTimer.actionIndex = 0
end)
Transmog.applyTimer:SetScript("OnHide", function()
    -- Reset actions table to prevent memory leak
    Transmog.applyTimer.actions = {}
end)

Transmog.applyTimer.actions = {}
Transmog.applyTimer.actionIndex = 0

Transmog.applyTimer:SetScript("OnUpdate", function()
    local plus = 0.1
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then

        Transmog.applyTimer.actionIndex = Transmog.applyTimer.actionIndex + 1

        local action = Transmog.applyTimer.actions[Transmog.applyTimer.actionIndex]

        if action then
            if action.type == 'do' then
                Transmog:aSend("DoTransmog:" .. action.serverSlot .. ":" .. action.itemId .. ":" .. action.InventorySlotId)
                action.sent = true
            else
                if action.type == 'reset' then
                    Transmog:aSend("ResetTransmog:" .. action.serverSlot .. ":" .. action.InventorySlotId)
                    action.sent = true
                end
            end
        end

        local allDone = true
        for _, action in Transmog.applyTimer.actions do
            if not action.sent then
                allDone = false
            end
        end
        if allDone then
            Transmog.applyTimer:Hide()
        end
        this.startTime = GetTime()
    end
end)

-- DoTransmog/ResetTransmog Animation
Transmog.itemAnimation = CreateFrame("Frame")
Transmog.itemAnimation:Hide()

Transmog.itemAnimation:SetScript("OnShow", function()
    this.startTime = GetTime()
    for _, frame in Transmog.itemAnimationFrames do
        frame.autocast:Hide()
        if frame.reset then
            frame.borderFull:Show()
            frame.borderFull:SetAlpha(.9)
            frame.borderHi:Show()
            frame.borderHi:SetWidth(48)
            frame.borderHi:SetHeight(48)
        else
            frame.borderFull:Show()
            frame.borderFull:SetAlpha(.2)
            frame.borderHi:Show()
            frame.borderHi:SetWidth(32)
            frame.borderHi:SetHeight(32)
        end
    end
end)
Transmog.itemAnimation:SetScript("OnHide", function()
    Transmog.currentTransmogSlot = nil
    Transmog_switchTab('items')

    Transmog:aSend("GetTransmogStatus")

    Transmog:calculateCost(0)
    
    -- Clear animation frames to prevent memory leak
    Transmog.itemAnimationFrames = {}
end)

Transmog.itemAnimationFrames = {}

Transmog.itemAnimation:SetScript("OnUpdate", function()
    local plus = 0.01
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then

        for index, frame in Transmog.itemAnimationFrames do
            if frame.reset then
                frame.borderFull:SetAlpha(frame.borderFull:GetAlpha() - 0.05)
                if frame.borderHi:GetWidth() > 32 then
                    frame.borderHi:SetWidth(frame.borderHi:GetWidth() - 0.5)
                    frame.borderHi:SetHeight(frame.borderHi:GetHeight() - 0.5)
                end
            else
                frame.borderFull:SetAlpha(frame.borderFull:GetAlpha() + 0.05 * frame.dir)
                if frame.borderHi:GetWidth() < 48 then
                    frame.borderHi:SetWidth(frame.borderHi:GetWidth() + 0.5)
                    frame.borderHi:SetHeight(frame.borderHi:GetHeight() + 0.5)
                end
            end
            if frame.borderFull:GetAlpha() >= 1 then
                frame.dir = -1
            end
            if frame.borderFull:GetAlpha() <= 0.1 then
                frame.borderHi:Hide()
                frame.borderHi:SetWidth(48)
                frame.borderHi:SetHeight(48)

                Transmog.itemAnimationFrames[index] = nil
            end
        end

        if Transmog:tableSize(Transmog.itemAnimationFrames) == 0 then
            Transmog.itemAnimation:Hide()
        end

        this.startTime = GetTime()

    end
end)

-- delayedLoad Timer
Transmog.delayedLoad = CreateFrame("Frame")
Transmog.delayedLoad:Hide()

Transmog.delayedLoad:SetScript("OnShow", function()
    twfdebug("delayedLoad show")
    this.startTime = GetTime()
end)
Transmog.delayedLoad:SetScript("OnHide", function()
    Transmog:LoadOnce()
    Transmog:Reset(true)
end)

Transmog.delayedLoad:SetScript("OnUpdate", function()
    local gt = GetTime() * 1000
    local st = (this.startTime + 1) * 1000
    if gt >= st then
        Transmog.delayedLoad:Hide()
    end
end)

-- win new transmog
Transmog.newTransmogAlert = CreateFrame("Frame")
Transmog.newTransmogAlert:Hide()
Transmog.newTransmogAlert.wonItems = {}

function Transmog.newTransmogAlert:HideAnchor()
    NewTransmogAlertFrame:SetBackdrop({
        bgFile = "",
        tile = true,
    })
    NewTransmogAlertFrame:EnableMouse(false)
    NewTransmogAlertFrameTitle:Hide()
    NewTransmogAlertFrameTestPlacement:Hide()
    NewTransmogAlertFrameClosePlacement:Hide()
end

Transmog.delayAddWonItem = CreateFrame("Frame")
Transmog.delayAddWonItem:Hide()
Transmog.delayAddWonItem.data = {}

Transmog.delayAddWonItem:SetScript("OnShow", function()
    this.startTime = GetTime()
end)
Transmog.delayAddWonItem:SetScript("OnHide", function()
    -- Clear data table when hidden to prevent memory leak
    Transmog.delayAddWonItem.data = {}
end)
Transmog.delayAddWonItem:SetScript("OnUpdate", function()
    local plus = 0.2
    local gt = GetTime() * 1000
    local st = (this.startTime + plus) * 1000
    if gt >= st then

        local atLeastOne = false
        for id, data in next, Transmog.delayAddWonItem.data do
            if Transmog.delayAddWonItem.data[id] then
                atLeastOne = true
                Transmog:addWonItem(id)
                Transmog.delayAddWonItem.data[id] = nil
            end
        end

        if not atLeastOne then
            Transmog.delayAddWonItem:Hide()
        end
    end
end)

Transmog.gearChangedDelay = CreateFrame("Frame")
Transmog.gearChangedDelay:Hide()
Transmog.gearChangedDelay.delay = 1

Transmog.gearChangedDelay:SetScript("OnShow", function()
    this.startTime = GetTime()
end)
Transmog.gearChangedDelay:SetScript("OnUpdate", function()
    local gt = GetTime() * 1000
    local st = (this.startTime + Transmog.gearChangedDelay.delay) * 1000
    if gt >= st then

        selectTransmogSlot(-1)
        Transmog_revert()

        Transmog:UnlockPlayerItems()
        Transmog.gearChangedDelay:Hide()
    end
end)

function Transmog:addWonItem(itemID)

    local name, linkString, quality, _, _, _, _, _, tex = GetItemInfo(itemID)

    if name then

        local _, _, itemLink = TransmogFrame_Find(linkString, "(item:%d+:%d+:%d+:%d+)");

        self:cacheItem(itemID)

        if not name or not quality then
            self.delayAddWonItem.data[itemID] = true
            self.delayAddWonItem:Show()
            return false
        end

        twfprint(GAME_YELLOW .. '[' .. name .. ']' .. HIGHLIGHT_FONT_COLOR_CODE .. ' 已添加到你的幻化收藏中.')

        local newTransmogIndex = 0
        for i = 1, self:tableSize(self.newTransmogAlert.wonItems), 1 do
            if not self.newTransmogAlert.wonItems[i].active then
                newTransmogIndex = i
                break
            end
        end

        if newTransmogIndex == 0 then
            newTransmogIndex = self:tableSize(self.newTransmogAlert.wonItems) + 1
        end

        if not self.newTransmogAlert.wonItems[newTransmogIndex] then
            self.newTransmogAlert.wonItems[newTransmogIndex] = CreateFrame("Frame", "NewTransmogAlertFrame" .. newTransmogIndex, NewTransmogAlertFrame, "TransmogWonItemTemplate")
        end

        self.newTransmogAlert.wonItems[newTransmogIndex]:SetPoint("TOP", NewTransmogAlertFrame, "BOTTOM", 0, (20 + 100 * newTransmogIndex))
        self.newTransmogAlert.wonItems[newTransmogIndex].active = true
        self.newTransmogAlert.wonItems[newTransmogIndex].frameIndex = 0
        self.newTransmogAlert.wonItems[newTransmogIndex].doAnim = true

        self.newTransmogAlert.wonItems[newTransmogIndex]:SetAlpha(0)
        self.newTransmogAlert.wonItems[newTransmogIndex]:Show()

        getglobal('NewTransmogAlertFrame' .. newTransmogIndex .. 'Icon'):SetNormalTexture(tex)
        getglobal('NewTransmogAlertFrame' .. newTransmogIndex .. 'Icon'):SetPushedTexture(tex)
        getglobal('NewTransmogAlertFrame' .. newTransmogIndex .. 'ItemName'):SetText(HIGHLIGHT_FONT_COLOR_CODE .. name)

        getglobal('NewTransmogAlertFrame' .. newTransmogIndex .. 'Icon'):SetScript("OnEnter", function(self)
            FashionTooltip:SetOwner(this, "ANCHOR_RIGHT", 0, 0);
            FashionTooltip:SetHyperlink(itemLink);
            FashionTooltip:Show();
        end)
        getglobal('NewTransmogAlertFrame' .. newTransmogIndex .. 'Icon'):SetScript("OnLeave", function(self)
            FashionTooltip:Hide();
        end)

        self:StartNewTransmogAlertAnimation()

    end
end

function Transmog_testNewTransmogAlert()
    Transmog:addWonItem(19364)
end

function Transmog:StartNewTransmogAlertAnimation()
    if self:tableSize(self.newTransmogAlert.wonItems) > 0 then
        self.newTransmogAlert.showLootWindow = true
    end
if not self.newTransmogAlert:IsVisible() then
        self.newTransmogAlert:Show()
    end
end

Transmog.newTransmogAlert.showLootWindow = false

Transmog.newTransmogAlert:SetScript("OnShow", function()
    this.startTime = GetTime()
end)
Transmog.newTransmogAlert:SetScript("OnUpdate", function()
    if Transmog.newTransmogAlert.showLootWindow then
        if GetTime() >= (this.startTime + 0.03) then

            this.startTime = GetTime()

            for i, d in next, Transmog.newTransmogAlert.wonItems do

                if Transmog.newTransmogAlert.wonItems[i].active then

                    local frame = getglobal('NewTransmogAlertFrame' .. i)

                    local image = 'loot_frame_xmog_'

                    getglobal('NewTransmogAlertFrame' .. i .. 'Icon'):SetPoint('LEFT', 160, -9)
                    getglobal('NewTransmogAlertFrame' .. i .. 'Icon'):SetWidth(36)
                    getglobal('NewTransmogAlertFrame' .. i .. 'IconNormalTexture'):SetWidth(36)
                    getglobal('NewTransmogAlertFrame' .. i .. 'Icon'):SetHeight(36)
                    getglobal('NewTransmogAlertFrame' .. i .. 'IconNormalTexture'):SetHeight(36)

                    if Transmog.newTransmogAlert.wonItems[i].frameIndex < 10 then
                        image = image .. '0' .. Transmog.newTransmogAlert.wonItems[i].frameIndex
                    else
                        image = image .. Transmog.newTransmogAlert.wonItems[i].frameIndex;
                    end

                    Transmog.newTransmogAlert.wonItems[i].frameIndex = Transmog.newTransmogAlert.wonItems[i].frameIndex + 1

                    if Transmog.newTransmogAlert.wonItems[i].doAnim then

                        local backdrop = {
                            bgFile = 'Interface\\TransmogFrame\\anim\\' .. image,
                            tile = false
                        };
                        if Transmog.newTransmogAlert.wonItems[i].frameIndex <= 30 then
                            frame:SetBackdrop(backdrop)
                        end
                        frame:SetAlpha(frame:GetAlpha() + 0.03)
                        getglobal('NewTransmogAlertFrame' .. i .. 'Icon'):SetAlpha(frame:GetAlpha() + 0.03)
                    end
                    if Transmog.newTransmogAlert.wonItems[i].frameIndex == 35 then
                        --stop and hold last frame
                        Transmog.newTransmogAlert.wonItems[i].doAnim = false
                    end

                    if Transmog.newTransmogAlert.wonItems[i].frameIndex > 119 then
                        frame:SetAlpha(frame:GetAlpha() - 0.03)
                        getglobal('NewTransmogAlertFrame' .. i .. 'Icon'):SetAlpha(frame:GetAlpha() + 0.03)
                    end
                    if Transmog.newTransmogAlert.wonItems[i].frameIndex == 150 then

                        Transmog.newTransmogAlert.wonItems[i].frameIndex = 0
                        frame:Hide()
                        Transmog.newTransmogAlert.wonItems[i].active = false

                    end
                end
            end
        end
    end
end)

function Transmog_close_placement()
    twfprint('|cAnchor window closed. Type |cfffff569/transmog |cto show the Anchor window.')
    Transmog.newTransmogAlert:HideAnchor()
end

function Transmog.newTransmogAlert:ShowAnchor()
    NewTransmogAlertFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        tile = true,
    })
    NewTransmogAlertFrame:EnableMouse(true)
    NewTransmogAlertFrameTitle:Show()
    NewTransmogAlertFrameTestPlacement:Show()
    NewTransmogAlertFrameClosePlacement:Show()
end

function OutfitsDropDown_Initialize()

    for name, data in TRANSMOG_CONFIG[UnitName('player')]['Outfits'] do
        local info = {}
        info.text = name
        info.value = 1
        info.arg1 = name
        info.checked = Transmog.currentOutfit == name
        info.func = Transmog_LoadOutfit
        info.tooltipTitle = name
        local descText = ''
        for slot, itemID in data do
            if itemID == 0 then
                --descText = descText .. FONT_COLOR_CODE_CLOSE ..  slot .. ": None \n"
            else
				Transmog:cacheItem(itemID)
                local n, link, quality, _, _, _, _, equip_slot = GetItemInfo(itemID)
				
				--dirty fix
                if quality == nil then quality = 0 end
				
				--dirty fix
                if n == nil then n = "error" end
				
                local _, _, _, color = GetItemQualityColor(quality)

                --descText = descText .. FONT_COLOR_CODE_CLOSE .. getglobal(equip_slot) .. ": " .. color .. n .. "\n"
                descText = descText .. FONT_COLOR_CODE_CLOSE .. color .. n .. "\n"
            end
        end
        info.tooltipText = descText
        UIDropDownMenu_AddButton(info)
    end

    if Transmog:tableSize(TRANSMOG_CONFIG[UnitName('player')]['Outfits']) < 20 then
        local _, _, _, color = GetItemQualityColor(2)

        local newOutfit = {}
        newOutfit.text = color .. "+ 新的套装"
        newOutfit.value = 1
        newOutfit.arg1 = 1
        newOutfit.checked = false
        newOutfit.func = Transmog_NewOutfitPopup
        UIDropDownMenu_AddButton(newOutfit)
    end

end

function Transmog_LoadOutfit(outfit)
    UIDropDownMenu_SetText(outfit, TransmogFrameOutfits)

    Transmog.currentOutfit = outfit

    Transmog:EnableOutfitSaveButton()

    TransmogFrameDeleteOutfit:Enable()

    Transmog:hideItemBorders()

    for slot, itemID in TRANSMOG_CONFIG[UnitName('player')]['Outfits'][outfit] do

        local eq_slot, tex
        local hasItemEquipped = false

        if GetInventoryItemLink('player', slot) then
            hasItemEquipped = true
        end

        if hasItemEquipped then

            if itemID == 0 then
                local _, _, eqItemLink = TransmogFrame_Find(GetInventoryItemLink('player', slot), "(item:%d+:%d+:%d+:%d+)");
                local _, _, _, _, _, _, _, equip_slot, outfitTex = GetItemInfo(eqItemLink)
                eq_slot = equip_slot
                tex = outfitTex
            else
                local _, _, _, _, _, _, _, equip_slot, outfitTex = GetItemInfo(itemID)
                eq_slot = equip_slot
                tex = outfitTex
            end

            local frame

            frame = Transmog:frameFromInvType(eq_slot)

            if hasItemEquipped then
                TransmogFramePlayerModel:TryOn(itemID)
            end

            if frame then

                getglobal(frame:GetName() .. "ItemIcon"):SetTexture(tex)

                if Transmog.transmogStatusToServer[slot] ~= itemID then
                    getglobal(frame:GetName() .. 'BorderHi'):Show()
                    getglobal(frame:GetName() .. 'AutoCast'):Show()
                end

                if itemID == 0 or not hasItemEquipped then
                    getglobal(frame:GetName() .. 'BorderHi'):Hide()
                    getglobal(frame:GetName() .. 'AutoCast'):Hide()
                end

            end

            Transmog.transmogStatusToServer[slot] = itemID

        end

    end
    Transmog:calculateCost()
end

function Transmog_SaveOutfit()
    TRANSMOG_CONFIG[UnitName('player')]['Outfits'][Transmog.currentOutfit] = {}
    for InventorySlotId, itemID in Transmog.transmogStatusFromServer do
        if itemID ~= 0 then
            TRANSMOG_CONFIG[UnitName('player')]['Outfits'][Transmog.currentOutfit][InventorySlotId] = itemID
        end
    end
    for InventorySlotId, itemID in Transmog.transmogStatusToServer do
        if itemID ~= 0 then
            TRANSMOG_CONFIG[UnitName('player')]['Outfits'][Transmog.currentOutfit][InventorySlotId] = itemID
        end
    end
    TransmogFrameSaveOutfit:Disable()
end

function Transmog:EnableOutfitSaveButton()
    if self.currentOutfit ~= nil then
        TransmogFrameSaveOutfit:Enable()
    end
end

function Transmog_deleteOutfit()
    TRANSMOG_CONFIG[UnitName('player')]['Outfits'][Transmog.currentOutfit] = nil
    TransmogFrameSaveOutfit:Disable()
    TransmogFrameDeleteOutfit:Disable()
    Transmog.currentOutfit = nil
    UIDropDownMenu_SetText("套装", TransmogFrameOutfits)
    Transmog_revert()
end

StaticPopupDialogs["TRANSMOG_NEW_OUTFIT"] = {
    text = "输入套装名称：",
    button1 = "Save",
    button2 = "Cancel",
    hasEditBox = 1,
    OnAccept = function()
        local outfitName = getglobal(this:GetParent():GetName() .. "EditBox"):GetText()
        if outfitName == '' then
            StaticPopup_Show('TRANSMOG_OUTFIT_EMPTY_NAME')
            return
        end
        if TRANSMOG_CONFIG[UnitName('player')]['Outfits'][outfitName] then
            StaticPopup_Show('TRANSMOG_OUTFIT_EXISTS')
            return
        end
        TRANSMOG_CONFIG[UnitName('player')]['Outfits'][outfitName] = {}
        UIDropDownMenu_SetText(outfitName, TransmogFrameOutfits)
        Transmog.currentOutfit = outfitName
        Transmog:EnableOutfitSaveButton()
        Transmog_SaveOutfit()
        getglobal(this:GetParent():GetName() .. "EditBox"):SetText('')
    end,
    timeout = 0,
    whileDead = 0,
    hideOnEscape = 1,
};

StaticPopupDialogs["TRANSMOG_OUTFIT_EXISTS"] = {
    text = "套装名称已存在",
    button1 = "Okay",
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
    hideOnEscape = 1
};

StaticPopupDialogs["TRANSMOG_OUTFIT_EMPTY_NAME"] = {
    text = "套装名称无效",
    button1 = "Okay",
    timeout = 0,
    exclusive = 1,
    whileDead = 1,
    hideOnEscape = 1
};

StaticPopupDialogs["CONFIRM_DELETE_OUTFIT"] = {
    text = "删除套装？",
    button1 = TEXT(YES),
    button2 = TEXT(NO),
    OnAccept = function()
        Transmog_deleteOutfit()
    end,
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
};

function Transmog_NewOutfitPopup()
    StaticPopup_Show('TRANSMOG_NEW_OUTFIT')
end

function Transmog:cacheItem(linkOrID)

    if not linkOrID then
        twfdebug("cache item call with null " .. type(linkOrID))
    end

    if not linkOrID or linkOrID == 0 then
        twfdebug("cache item call with null2 " .. type(linkOrID))
        return
    end

    local tooltip = Transmog.CacheTooltip

    if TransmogFrame_ToNumber(linkOrID) then
        if GetItemInfo(linkOrID) then
            -- item ok, break
            return true
        else
            local item = "item:" .. linkOrID .. ":0:0:0"
            local _, _, itemLink = TransmogFrame_Find(item, "(item:%d+:%d+:%d+:%d+)");
            linkOrID = itemLink
        end
    else
        if TransmogFrame_Find(linkOrID, "|", 1, true) then
            local _, _, itemLink = TransmogFrame_Find(linkOrID, "(item:%d+:%d+:%d+:%d+)");
            linkOrID = itemLink
            if GetItemInfo(self:IDFromLink(linkOrID)) then
                -- item ok, break
                return true
            end
        end
    end

    tooltip:SetHyperlink(linkOrID)

end

SLASH_TRANSMOG1 = "/transmog"
SlashCmdList["TRANSMOG"] = function(cmd)
    if cmd then
        Transmog.newTransmogAlert:ShowAnchor()
    end
end
SLASH_TRANSMOGDEBUG1 = "/transmogdebug"
SlashCmdList["TRANSMOGDEBUG"] = function(cmd)
    if cmd then
        if Transmog.debug then
            Transmog.debug = false
            twfprint("Transmog debug off")
        else
            Transmog.debug = true
            twfprint("Transmog debug on")
        end
    end
end