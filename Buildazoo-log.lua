if not game:IsLoaded() then game.Loaded:Wait() end

-- ตรวจสอบว่า CONFIG มีอยู่หรือไม่ ถ้าไม่มีให้สร้าง default
if not getgenv().BuildazooConfig then
    getgenv().BuildazooConfig = {
        ["EnableLog"] = true,
        ["PC_NAME"] = "PC-001" -- ตั้งชื่อเครื่องนี้ (เปลี่ยนตามต้องการ)
    }
end

local CFG = getgenv().BuildazooConfig

-- Debug: ตรวจสอบค่า CONFIG ที่อ่านได้
print("🔧 BuildazooConfig loaded:")
print("  - EnableLog:", CFG.EnableLog)
print("  - PC_NAME:", CFG.PC_NAME)

-- ตรวจสอบว่า EnableLog เป็น true หรือไม่
if not CFG.EnableLog then
    return -- หยุดทำงานถ้า EnableLog เป็น false
end

-- ===================== API CONFIG =====================
local API_URL   = "http://localhost:3005/egg-log"
local AUTH_TOKEN = "u8N3QBKHNfnDWUwm9"
-- ======================================================

local Players     = game:GetService("Players")
local Workspace   = game:GetService("Workspace")
local RunService  = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LP          = Players.LocalPlayer
local PlayerGui   = LP:WaitForChild("PlayerGui")
local MY_UID      = LP.UserId

-- ===================== API FUNCTIONS =====================
local requestFn = (syn and syn.request)
    or (http and http.request)
    or rawget(getfenv(), "http_request")
    or rawget(getfenv(), "request")

local lastDigest, lastSendAt = "", 0
local STOP_HEARTBEAT = false

local function sendToApi(payloadTbl)
    if typeof(requestFn) ~= "function" then return false, 0 end
    local res
    local ok = pcall(function()
        res = requestFn({
            Url = API_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["X-Auth-Token"] = AUTH_TOKEN,
            },
            Body = HttpService:JSONEncode(payloadTbl),
        })
    end)
    
    local code = tonumber((res and (res.StatusCode or res.status)) or 0) or 0
    return ok and code >=200 and code < 300, code
end

local function buildSummaryTable()
    local summary = {}
    
    -- Add Coin data
    if lastCoin then
        table.insert(summary, { label = "coins", name = "Coins", count = lastCoin, buffs = { none = 1 } })
    end
    
    -- Add ProduceSpeed data (ใช้ระบบใหม่ที่ทำงานได้)
    local produceSpeedCount = lastTotal or 0
    table.insert(summary, { label = "producespeed", name = "ProduceSpeed", count = produceSpeedCount, buffs = { none = 1 } })
    
    -- Add Food data
    if foodKeys then
        local Data = PlayerGui:FindFirstChild("Data")
        local Asset = Data and Data:FindFirstChild("Asset")
        if Asset then
            for _, key in ipairs(foodKeys) do
                local v = Asset:GetAttribute(key)
                if typeof(v) == "number" and v > 0 then
                    table.insert(summary, { label = "food_" .. key, name = key, count = v, buffs = { none = 1 } })
                end
            end
        end
    end
    
    -- Add Egg data
    if true then
        local Data = PlayerGui:FindFirstChild("Data")
        local EGG = Data and (Data:FindFirstChild("Egg") or Data:FindFirstChild("EGG"))
        if EGG then
            local byType = {}
            for _, inst in ipairs(EGG:GetChildren()) do
                local T = inst:GetAttribute("T")
                local M = inst:GetAttribute("M") or "None"
                if T then
                    local slot = byType[T]; if not slot then slot = { __total = 0, buffs = {} }; byType[T] = slot end
                    slot.__total = slot.__total + 1
                    slot.buffs[M] = (slot.buffs[M] or 0) + 1
                end
            end
            
            for T, info in pairs(byType) do
                table.insert(summary, { label = T, name = T, count = info.__total, buffs = info.buffs })
            end
        end
    end
    
    return summary
end

local function digestCounts()
    local parts = {}
    local summary = buildSummaryTable()
    for _, item in ipairs(summary) do
        local buffParts = {}
        for k, v in pairs(item.buffs) do
            table.insert(buffParts, k .. "=" .. tostring(v))
        end
        table.sort(buffParts)
        table.insert(parts, item.label .. "#" .. tostring(item.count) .. ":" .. table.concat(buffParts, ","))
    end
    return table.concat(parts, "|")
end

local function buildAndMaybeSend(reason)
    if STOP_HEARTBEAT and reason == "heartbeat" then return end
    local t0 = os.clock()
    local dt = t0 - lastSendAt
    
    if reason == "bootstrap" or reason == "money_change" or reason == "producespeed_change" or reason == "food_change" or reason == "egg_change" then
        -- Send immediately for important events
    elseif dt < 3 then
        return
    end
    
    local d = digestCounts()
    if d == lastDigest and reason ~= "heartbeat" and reason ~= "bootstrap" then return end
    
    local payload = {
        player = { userId = LP.UserId, name = LP.Name, displayName = LP.Name },
        placeId = game.PlaceId,
        jobId = tostring(game.JobId or "N/A"),
        pcName = CFG.PC_NAME, -- เพิ่มชื่อ PC
        payload = {
            clientTime = os.time(),
            period = (reason == "heartbeat") and 3 or 0,
            reason = reason,
            totals = buildSummaryTable(),
        }
    }
    
    -- Debug: ตรวจสอบ payload ที่ส่งไป
    print("📤 Sending API request:")
    print("  - Reason:", reason)
    print("  - PC_NAME:", CFG.PC_NAME)
    print("  - Player ID:", LP.UserId)
    
    local ok, code = sendToApi(payload)
    lastSendAt = t0
    if ok then lastDigest = d end
end

local function requestSend(reason)
    if reason == "bootstrap" or reason == "money_change" or reason == "producespeed_change" or reason == "food_change" or reason == "egg_change" then
        buildAndMaybeSend(reason)
        return
    end
    
    task.defer(function()
        buildAndMaybeSend(reason)
    end)
end
-- ======================================================

-- ---------- helpers ----------
local function waitChild(p, name, timeout)
    timeout = timeout or 6
    local t0, x = time(), p:FindFirstChild(name)
    while not x and time() - t0 < timeout do p.ChildAdded:Wait(); x = p:FindFirstChild(name) end
    return x
end
local function toNum(v) return typeof(v)=="number" and v or (typeof(v)=="string" and tonumber(v) or nil) end
local function fmtNum(n)
    if typeof(n)~="number" then return tostring(n) end
    local s, k = tostring(n), 0
    repeat s,k = s:gsub("^(-?%d+)(%d%d%d)","%1,%2") until k==0
    return s
end

-- ================================================================
-- #1 COIN
-- ================================================================
    lastCoin = nil
    local coinConn
    local function attachCoin()
        if coinConn then coinConn:Disconnect(); coinConn=nil end
        local Data  = waitChild(PlayerGui,"Data",6);   if not Data  then return end
        local Asset = waitChild(Data,"Asset",6);       if not Asset then return end

        local coin = Asset:GetAttribute("Coin")
        if coin ~= nil and coin ~= lastCoin then lastCoin = coin end

        coinConn = Asset:GetAttributeChangedSignal("Coin"):Connect(function()
            local v = Asset:GetAttribute("Coin")
            if v ~= lastCoin then 
                lastCoin = v
                requestSend("money_change")
            end
        end)
        
        -- Monitor for coin removal (when coin becomes 0 or nil)
        Asset.AttributeChanged:Connect(function(attrName)
            if attrName == "Coin" then
                local v = Asset:GetAttribute("Coin")
                if v == 0 or v == nil then
                    requestSend("money_change")
                end
            end
        end)

        Asset.AncestryChanged:Connect(function(_,parent)
            if not parent then if coinConn then coinConn:Disconnect(); coinConn=nil end; task.defer(attachCoin) end
        end)
    end
    attachCoin()
    PlayerGui.ChildAdded:Connect(function(ch) if ch.Name=="Data" then task.defer(attachCoin) end end)
    LP.CharacterAdded:Connect(function() task.wait(1); task.defer(attachCoin) end)

    -- watchdog ตาม config (รีอ่าน coin เป็นระยะ)
    task.spawn(function()
        while true do
            task.wait(60) -- อัพเดททุก 60 วินาที
                local Data = PlayerGui:FindFirstChild("Data")
                local Asset = Data and Data:FindFirstChild("Asset")
                if Asset then
                    local v = Asset:GetAttribute("Coin")
                    if v ~= nil and v ~= lastCoin then 
                        lastCoin = v
                        requestSend("money_change")
                    end
                end
            end
        end)

-- ================================================================
-- #2 FOOD
-- ================================================================
    foodKeys = {}
    local conns, lastLine = {}, ""
    local function clear() for _,c in ipairs(conns) do c:Disconnect() end; conns = {} end
    local function getKeys(inst) local t={}; for k,_ in pairs(inst:GetAttributes()) do table.insert(t,k) end; table.sort(t); return t end

    local function printLine(Asset)
        local parts={}
        for _,k in ipairs(foodKeys) do
            local v = Asset:GetAttribute(k)
            if typeof(v)=="number" and v>0 then table.insert(parts, string.format("%s: %s", k, fmtNum(v))) end
        end
        table.sort(parts)
        local line = table.concat(parts," | ")
        if line ~= lastLine then 
            lastLine = line
            requestSend("food_change")
        end
    end

    local function wireFood()
        clear()
        local Data      = waitChild(PlayerGui,"Data",6);        if not Data then return end
        local Asset     = waitChild(Data,"Asset",6);            if not Asset then return end
        local FoodStore = waitChild(Data,"FoodStore",6);        if not FoodStore then return end
        local LST       = waitChild(FoodStore,"LST",6);         if not LST then return end

        foodKeys = getKeys(LST)
        printLine(Asset)

        for _,k in ipairs(foodKeys) do
            table.insert(conns, Asset:GetAttributeChangedSignal(k):Connect(function() 
                printLine(Asset)
            end))
        end
        table.insert(conns, LST.AttributeChanged:Connect(function() wireFood() end))
        table.insert(conns, Asset.AncestryChanged:Connect(function(_,p) if not p then clear(); task.defer(wireFood) end end))
        
        -- Monitor for food removal
        Asset.AttributeChanged:Connect(function(attrName)
            if attrName:match("^food_") then
                local v = Asset:GetAttribute(attrName)
                if typeof(v) == "number" and v == 0 then
                    requestSend("food_change")
                end
            end
        end)
    end
    wireFood()
    PlayerGui.ChildAdded:Connect(function(ch) if ch.Name=="Data" then task.defer(wireFood) end end)

    -- watchdog ตาม config
    task.spawn(function()
        while true do
            task.wait(60) -- อัพเดททุก 60 วินาที
                local Data      = PlayerGui:FindFirstChild("Data")
                local Asset     = Data and Data:FindFirstChild("Asset")
                local FoodStore = Data and Data:FindFirstChild("FoodStore")
                local LST       = FoodStore and FoodStore:FindFirstChild("LST")
                if Asset and LST then
                    local keys = {}; for k,_ in pairs(LST:GetAttributes()) do table.insert(keys,k) end
                    table.sort(keys)
                    local rewire = (#keys ~= #foodKeys)
                    if not rewire then for i,k in ipairs(keys) do if k ~= foodKeys[i] then rewire = true break end end end
                    if rewire then wireFood() else printLine(Asset) end
                end
            end
        end)

-- ================================================================
-- #3 PRODUCESPEED TOTAL (ใช้ระบบใหม่ที่ทำงานได้)
-- ================================================================
    lastTotal = 0
    local Pets = workspace:WaitForChild("Pets", 10) -- รอ Pets folder สูงสุด 10 วินาที
    
    if not Pets then
        return
    end
    
    -- สแกนสัตว์ทั้งหมดและคำนวณ ProduceSpeed รวม
    local function scanAllPets()
        local total, count = 0, 0
        for _, pet in ipairs(Pets:GetChildren()) do
            -- นับเฉพาะที่เป็นของเรา (UserId ตรงกับเรา)
            local ownerId = toNum(pet:GetAttribute("UserId"))
            if ownerId == MY_UID then
            local ps = toNum(pet:GetAttribute("ProduceSpeed"))
            total += ps
            count += 1
            end
        end
        
        -- อัพเดท lastTotal และส่ง API ถ้าค่าเปลี่ยน
        if total ~= lastTotal then
            lastTotal = total
            if CFG.EnableLog then
                buildAndMaybeSend("producespeed_change")
            end
        end
    end
    
    -- ติดตามการเปลี่ยนแปลงของสัตว์แต่ละตัว
    local function watchPet(pet)
        if typeof(pet) ~= "Instance" then return end
        
        -- รีสแกนเมื่อค่า ProduceSpeed หรือ UserId เปลี่ยน
        pet.AttributeChanged:Connect(function(attr)
            if attr == "ProduceSpeed" or attr == "UserId" then
                task.defer(scanAllPets)
            end
        end)
    end
    
    -- ติดตามสัตว์ที่มีอยู่แล้ว
    for _, pet in ipairs(Pets:GetChildren()) do
        watchPet(pet)
    end
    
    -- ติดตามสัตว์ใหม่ที่เพิ่มเข้ามา
    Pets.ChildAdded:Connect(function(p) 
        watchPet(p)
        task.defer(scanAllPets)
    end)
    
    -- ติดตามสัตว์ที่ถูกลบออก
    Pets.ChildRemoved:Connect(function() 
        task.defer(scanAllPets)
    end)
    
    -- สแกนครั้งแรก
    scanAllPets()

-- ================================================================
-- #4 EGG SUMMARY
-- ================================================================
    local eggConns, lastLine, isWiring, needSumm = {}, "", false, false
    local BUFF_ORDER = { None=1, Golden=2, Diamond=3, Electric=4, Fire=5, Jurassic=6, Snow=7, Halloween=8 }
    local function clear() for _,c in ipairs(eggConns) do c:Disconnect() end; eggConns={} end
    local function findEgg(Data) return Data:FindFirstChild("Egg") or Data:FindFirstChild("EGG") end

    local function scheduleSummary(EGG)
        if needSumm then return end
        needSumm = true
        task.defer(function()
            RunService.Heartbeat:Wait()
            needSumm = false

            local byType = {}
            for _,inst in ipairs(EGG:GetChildren()) do
                local T = inst:GetAttribute("T")
                local M = inst:GetAttribute("M") or "None"
                if T then
                    local slot = byType[T]; if not slot then slot={__total=0,buffs={}}; byType[T]=slot end
                    slot.__total += 1; slot.buffs[M] = (slot.buffs[M] or 0) + 1
                end
            end

            local parts = {}
            for T,info in pairs(byType) do
                local keys={}; for m,_ in pairs(info.buffs) do table.insert(keys,m) end
                table.sort(keys,function(a,b)
                    local ra,rb = BUFF_ORDER[a] or 999, BUFF_ORDER[b] or 999
                    return ra==rb and a<b or ra<rb
                end)
                local buffParts={}
                for _,m in ipairs(keys) do table.insert(buffParts, ("%s=%s"):format(m, fmtNum(info.buffs[m]))) end
                table.insert(parts, ("%s: %s%s"):format(T, fmtNum(info.__total), (#buffParts>0 and (" ["..table.concat(buffParts,", ").."]") or "")))
            end
            table.sort(parts)
            local line = table.concat(parts," | ")
            if line ~= lastLine then 
                lastLine = line; if line~="" then end
                if CFG.EnableLog then 
                    requestSend("egg_change") 
                end
            end
        end)
    end

    local function wireEgg()
        if isWiring then return end
        isWiring = true
        clear()

        local Data = PlayerGui:FindFirstChild("Data") or PlayerGui.ChildAdded:Wait()
        if Data.Name ~= "Data" then isWiring=false; return wireEgg() end

        local EGG = findEgg(Data)
        if not EGG then
            local ok=false
            local conn; conn = Data.ChildAdded:Connect(function(ch)
                if ch.Name=="Egg" or ch.Name=="EGG" then ok=true; conn:Disconnect() end
            end)
            task.wait(0.1)
            EGG = findEgg(Data)
            if not EGG then while not ok do task.wait(0.05) end; EGG = findEgg(Data) end
        end

        scheduleSummary(EGG)

        table.insert(eggConns, EGG.ChildAdded:Connect(function(inst)
            scheduleSummary(EGG)
            table.insert(eggConns, inst:GetAttributeChangedSignal("T"):Connect(function() 
                scheduleSummary(EGG)
                if CFG.EnableLog then 
                    requestSend("egg_change") 
                end
            end))
            table.insert(eggConns, inst:GetAttributeChangedSignal("M"):Connect(function() 
                scheduleSummary(EGG)
                if CFG.EnableLog then 
                    requestSend("egg_change") 
                end
            end))
        end))
        table.insert(eggConns, EGG.ChildRemoved:Connect(function()
            scheduleSummary(EGG)
            -- Send API update when egg is removed
            if CFG.EnableLog then 
                requestSend("egg_change") 
            end
        end))
        table.insert(eggConns, EGG.AncestryChanged:Connect(function(_,p)
            if not p then clear(); task.defer(function() isWiring=false; wireEgg() end) end
        end))
        table.insert(eggConns, PlayerGui.ChildAdded:Connect(function(ch)
            if ch.Name=="Data" then clear(); task.defer(function() isWiring=false; wireEgg() end) end
        end))

        isWiring = false
    end

    wireEgg()

    -- watchdog ตาม config
    task.spawn(function()
        while true do
            task.wait(1.5) -- อัพเดททุก 1.5 วินาที
                local Data = PlayerGui:FindFirstChild("Data")
                local EGG  = Data and (Data:FindFirstChild("Egg") or Data:FindFirstChild("EGG"))
                if EGG then 
                    scheduleSummary(EGG) 
                end
            end
        end)

-- ================================================================
-- #5 API HEARTBEAT & BOOTSTRAP
-- ================================================================
if CFG.EnableLog then
    -- Bootstrap after all systems are ready
    task.spawn(function()
        task.wait(8) -- Wait for all systems to initialize
        
        -- ส่งข้อมูลทุกอย่างทันที 1 รอบ
        requestSend("bootstrap")
        
    end)
    
    -- Periodic data sending based on minInterval
    task.spawn(function()
        while not STOP_HEARTBEAT do
            task.wait(3)
            if STOP_HEARTBEAT then break end
            
            -- ส่งข้อมูล Coin ทุก minInterval
            if lastCoin then
                requestSend("money_change")
            end
            
            -- ส่งข้อมูล Food ทุก minInterval
            if foodKeys then
                requestSend("food_change")
            end
            
            -- ส่งข้อมูล ProduceSpeed ทุก minInterval
            buildAndMaybeSend("producespeed_change")
            
        end
    end)
    
    -- Heartbeat loop
    task.spawn(function()
        while not STOP_HEARTBEAT do
            task.wait(3)
            if STOP_HEARTBEAT then break end
            requestSend("heartbeat")
        end
    end)
    
    -- Cleanup on game close (client-side safe)
    Players.PlayerRemoving:Connect(function(player)
        if player == LP then
            STOP_HEARTBEAT = true
        end
    end)
end
