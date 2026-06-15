-- =========================================================================
-- ⚙️ [0] CONFIG  —  ตั้งค่าจากภายนอกผ่าน getgenv (ตั้งครั้งเดียวใช้ได้ทุกสคริปต์)
-- =========================================================================
local env = (getgenv and getgenv()) or _G

if not env.DuckyConfig then
    env.DuckyConfig = {
        ["EnableDebug"]      = false,  -- true  = print log ละเอียดใน console
        ["PC_NAME"]          = "51",     -- ชื่อเครื่อง/โน้ต ติดไปกับข้อมูล
        ["discord_id"]       = "264373023425953792",     -- discord id ของเจ้าของเครื่อง
    }
end

local CFG = env.DuckyConfig

-- debug logger (ทำงานเมื่อ EnableDebug = true), warn() ยังแสดงเสมอ
local function log(...)
    if CFG.EnableDebug then
        print("[Log]", ...)
    end
end

-- =========================================================================
-- 🔌 [1] API  —  การเชื่อมต่อ server (เหมือนกันทุกเกม)
-- =========================================================================
local API = {
    BaseUrl        = "https://auth.ducky.host/ingest/", -- จะเติม apiPath ของเกมต่อท้าย
    ApiKey         = "storm-ingest-key-change-me",        -- ต้องตรงกับ INGEST_API_KEY ใน server/.env
    UpdateInterval = 30,                                  -- ส่งทุกกี่วินาที
}

local GAMES = {
    {
        label    = "Grow a Garden 2",
        apiPath  = "Grow-a-Garden-2",
        placeIds = { 97598239454123 },
        type     = "garden",
        config   = {
            moneyStat = "Sheckles",
            seeds = {
                "Rainbow", "Gold", "Rainbow Seed", "Golden Seed", "Gold Seed",
            },
            pets = {
                "Raccoon", "Unicorn", "BlackDragon", "IceSerpent", "GoldenDragonfly",
            },
        },
    },
}

local GAME_TYPES = {}

-- ─────────────────────────────────────────────────────────────
-- 🔧 SHARED HELPERS — ใช้ได้กับทุกเกม
-- ─────────────────────────────────────────────────────────────
local function readMoney(config, ctx)
    if ctx.leaderstats and config.moneyStat and config.moneyStat ~= "" then
        local obj = ctx.leaderstats:FindFirstChild(config.moneyStat)
        if obj and type(obj.Value) == "number" then
            return obj.Value
        end
    end
    return 0
end

local function buildLookup(list)
    local t = {}
    for _, name in ipairs(list or {}) do t[name] = true end
    return t
end

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  GAME: Grow a Garden 2   (type = "garden")                    ║
-- ║  เก็บ: เงิน (Sheckles) + นับ seeds/pets จาก BackpackGui         ║
-- ╚══════════════════════════════════════════════════════════════╝

-- นับไอเทมในกระเป๋า (โครงสร้าง BackpackGui ของ Grow a Garden 2)
local function scanBackpack(seedLookup, petLookup)
    local foundSeeds, foundPets = {}, {}
    local PlayerGui = game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")
    if not PlayerGui then return foundSeeds, foundPets end

    local BackpackMain =
        PlayerGui:FindFirstChild("BackpackGui")
        and PlayerGui.BackpackGui:FindFirstChild("Backpack")
    if not BackpackMain then return foundSeeds, foundPets end

    local function scanFolder(folder)
        if not folder then return end
        local items = folder:GetChildren()
        for i, child in ipairs(items) do
            local toolNameObj = child:FindFirstChild("ToolName")
            local toolCountObj = child:FindFirstChild("ToolCount")
            if toolNameObj then
                local itemName =
                    toolNameObj:IsA("TextLabel") and toolNameObj.Text or toolNameObj.Value
                if type(itemName) == "string" and itemName ~= "" then
                    local itemCount = 1
                    if toolCountObj then
                        local countText =
                            toolCountObj:IsA("TextLabel") and toolCountObj.Text or tostring(toolCountObj.Value)
                        local numberOnly = string.match(string.gsub(countText, ",", ""), "%d+")
                        if numberOnly then itemCount = tonumber(numberOnly) or 1 end
                    end
                    if seedLookup[itemName] then
                        foundSeeds[itemName] = (foundSeeds[itemName] or 0) + itemCount
                    elseif petLookup[itemName] then
                        foundPets[itemName] = (foundPets[itemName] or 0) + itemCount
                    end
                end
            end
            if i % 200 == 0 then task.wait() end
        end
    end

    scanFolder(BackpackMain:FindFirstChild("Hotbar"))
    local Inventory = BackpackMain:FindFirstChild("Inventory")
    local UIGridFrame =
        Inventory
        and Inventory:FindFirstChild("ScrollingFrame")
        and Inventory.ScrollingFrame:FindFirstChild("UIGridFrame")
    scanFolder(UIGridFrame)

    return foundSeeds, foundPets
end

GAME_TYPES.garden = function(config, ctx)
    local money = readMoney(config, ctx)
    local foundSeeds, foundPets =
        scanBackpack(buildLookup(config.seeds), buildLookup(config.pets))

    local seedsArray = {}
    for name, count in pairs(foundSeeds) do
        table.insert(seedsArray, { name = name, count = count })
    end

    local petsArray = {}
    for name, count in pairs(foundPets) do
        table.insert(petsArray, { name = name, count = count })
    end

    return {
        money = money,
        seeds = seedsArray,
        pets = petsArray,
    }
end

-- ╔══════════════════════════════════════════════════════════════╗
-- ║  GAME: <เกมถัดไป>   (type = "<ชื่อ type>")                     ║
-- ║  วิธีเพิ่ม:                                                     ║
-- ║   1) เขียน collector ของเกมนั้นตรงนี้                           ║
-- ║        GAME_TYPES.myType = function(config, ctx)               ║
-- ║            return { money = ..., seeds = {...}, pets = {...} } ║
-- ║        end                                                     ║
-- ║   2) เพิ่ม block ใน [2] GAMES แล้วตั้ง type = "myType"          ║
-- ║   (ถ้าเกมใช้ BackpackGui เหมือนกัน เรียก scanBackpack ซ้ำได้)   ║
-- ╚══════════════════════════════════════════════════════════════╝

-- =========================================================================
-- ⚠️ DO NOT EDIT BELOW THIS LINE  (engine: ตรวจเกม + ลูปส่งข้อมูล)
-- =========================================================================

repeat task.wait() until game:IsLoaded()

-- ตรวจว่าตอนนี้อยู่เกมไหน จาก PlaceId
local activeGame
for _, cfg in ipairs(GAMES) do
    for _, pid in ipairs(cfg.placeIds) do
        if pid == game.PlaceId then
            activeGame = cfg
            break
        end
    end
    if activeGame then break end
end

if not activeGame then
    warn("[Log] PlaceId " .. tostring(game.PlaceId) .. " ไม่ได้อยู่ใน GAMES — หยุดทำงาน")
    return
end

local collector = GAME_TYPES[activeGame.type]
if not collector then
    warn("[Log] ไม่รู้จัก GAME_TYPE '" .. tostring(activeGame.type) .. "' — หยุดทำงาน")
    return
end

local apiUrl = API.BaseUrl .. activeGame.apiPath
log("Detected game: " .. activeGame.label .. " (" .. activeGame.type .. ") -> " .. apiUrl)

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui", 10)
local leaderstats = LocalPlayer:WaitForChild("leaderstats", 10)

-- Pick whichever HTTP request function the executor provides.
local httpRequest = http_request or request
    or (syn and syn.request)
    or (fluxus and fluxus.request)

local ctx = {
    LocalPlayer = LocalPlayer,
    PlayerGui = PlayerGui,
    leaderstats = leaderstats,
}

log("Script started!")

while true do
    -- เก็บข้อมูลตามประเภทเกม
    local ok, data = pcall(collector, activeGame.config, ctx)
    if not ok then
        warn("[Log] Collector error: " .. tostring(data))
        data = { money = 0, seeds = {}, pets = {} }
    end

    log("money=" .. tostring(data.money or 0)
        .. " seeds=" .. tostring(#(data.seeds or {}))
        .. " pets=" .. tostring(#(data.pets or {})))

    if httpRequest then
        local payload = HttpService:JSONEncode({
            username  = LocalPlayer.Name,
            userId    = LocalPlayer.UserId,
            money     = data.money or 0,
            seeds     = data.seeds or {},
            pets      = data.pets or {},
            pcName    = CFG.PC_NAME,
            discordId = CFG.discord_id,
        })

        local success, response = pcall(function()
            return httpRequest({
                Url = apiUrl,
                Method = "POST",
                Headers = {
                    ["Content-Type"] = "application/json",
                    ["x-api-key"] = API.ApiKey,
                },
                Body = payload,
            })
        end)

        if success then
            log("Sent to server")
        else
            warn("[Log] Send failed: " .. tostring(response))
        end
    else
        warn("[Log] No HTTP request function available in this executor")
    end

    task.wait(API.UpdateInterval)
end
