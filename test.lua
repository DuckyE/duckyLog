-- == STEP #1: REDEEM CODES, then STEP #2: LOTTERY (headless 10→3→1) ==
if not game:IsLoaded() then game.Loaded:Wait() end

local Players   = game:GetService("Players")
local RS        = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local LP        = Players.LocalPlayer
local PlayerGui = LP:WaitForChild("PlayerGui")
local Remote    = RS:WaitForChild("Remote")
local RedemptionCodeRE = Remote:WaitForChild("RedemptionCodeRE")
local LotteryRE = Remote:WaitForChild("LotteryRE")
local CharacterRE = Remote:WaitForChild("CharacterRE")
local GiftRE      = Remote:WaitForChild("GiftRE")

-- ====== DISCORD WEBHOOK (default) ======
_G.Horst_DiscordWebhook = _G.Horst_DiscordWebhook or ""

-- ====== SILENCE CONSOLE OUTPUT ======
-- moved below after CONFIG; we only silence when logging disabled

-- ====== CONFIG (optional) ======
local RawConfig = (getgenv and getgenv().LotteryConfig) or {}
local CONFIG = {
    EnableLog = (RawConfig.EnableLog ~= false),
    discord_id = RawConfig.discord_id and tostring(RawConfig.discord_id) or "",
    PC_NAME = RawConfig.PC_NAME and tostring(RawConfig.PC_NAME) or ""
}

-- Allow overriding webhook via Config
do
    local cw = RawConfig and RawConfig.Horst_DiscordWebhook
    if cw and tostring(cw) ~= "" then
        _G.Horst_DiscordWebhook = tostring(cw)
    end
end

-- Silence console output only when disabled
do
    local function noop(...) end
    if not CONFIG.EnableLog then
        print = noop
        warn  = noop
    end
end

local function logStep(...)
    if CONFIG and CONFIG.EnableLog then
        print("[STEP]", ...)
    end
end

-- Try to load Pet utility directly (fallback when getgenv().PS is not available)
local PetUtil = nil
do
    local okS, SharedMod = pcall(function()
        return require(RS:WaitForChild("Shared"))
    end)
    if okS and type(SharedMod) == "function" then
        local okP, pu = pcall(function()
            return SharedMod("Pet")
        end)
        if okP then PetUtil = pu end
    end
end

-- ====== REDEEM CONFIG ======
local RAW_CODES = {
    "N7A68Q82H83",
    "4XW5RG4CHRY",
    "3XKK8Z2WB6G",
    "60KCCU919",
    "Halloween1018",
    "Nyaa",
    "subtoZRGZeRoGhost",
    "DelayGift",
    "ZTWPH3WW8SJ",
    "ADQZP3MBW6N",
    "DS5523YSQ3C",
    "NA5Y874BAGG",
    "N7A68Q82H83",
    "CFJXEH4M8K5",
    "60KCCU919",
    "50KCCU0912",
    "ZooFish829",
    "FIXERROR819",
    "MagicFruit",
    "WeekendEvent89",
    "UPD18DINO",
    "BugFixes",
    "U2CA518SC5",
    "X2CA821BA3",
    "55PA21N8y2",
    "BugFix829",
    "SurpriseGift",
    "SeasonOne",
    "Hallaween1018",
}
local WAIT_BETWEEN_CODES = 0.35
local CODE_RETRIES       = 1
local CODE_RETRY_WAIT    = 0.60
local WAIT_AFTER_REDEEM  = 0.75

-- ====== LOTTERY CONFIG ======
local ROLL_PAUSE   = 0.25
local READ_TIMEOUT = 8
local DONE_TIMEOUT = 10

-- PS_MIN threshold: prefer LotteryConfig.PS_MIN, fallback to KitsuneConfig.MIN_PS
local PS_MIN do
    local v = RawConfig and RawConfig.PS_MIN
    if v == nil and getgenv then
        local KX = getgenv().KitsuneConfig
        if type(KX) == "table" then v = KX.MIN_PS end
    end
    if typeof(v) == "number" then
        PS_MIN = v
    elseif typeof(v) == "string" then
        local s = v:gsub(",", ""):gsub("%s+", "")
        PS_MIN = tonumber(s) or 0
    else
        PS_MIN = 0
    end
end

-- ---------- REDEEM STEP ----------
local function trim(s) return (tostring(s or ""):gsub("^%s+",""):gsub("%s+$","")) end

local CODES, seen = {}, {}
for _, c in ipairs(RAW_CODES) do
    local t = trim(c)
    if #t > 0 and not seen[t] then
        seen[t] = true
        table.insert(CODES, t)
    end
end

local function fireRedeem(code)
    local args = { [1] = { event = "usecode", code = code } }
    RedemptionCodeRE:FireServer(unpack(args))
end

for i, code in ipairs(CODES) do
    logStep(("Redeem %d/%d: %s"):format(i, #CODES, code))
    fireRedeem(code)
    for r = 1, CODE_RETRIES do
        task.wait(CODE_RETRY_WAIT)
        fireRedeem(code)
    end
    task.wait(WAIT_BETWEEN_CODES)
end
logStep("Redeem done.")
task.wait(WAIT_AFTER_REDEEM)

-- ---------- LOTTERY STEP (headless; read from Data/Asset only) ----------
local function getAssetFolder(timeout)
    local t0 = os.clock()
    local Data = PlayerGui:FindFirstChild("Data")
    while not Data and os.clock() - t0 < (timeout or READ_TIMEOUT) do
        task.wait(0.05)
        Data = PlayerGui:FindFirstChild("Data")
    end
    if not Data then return nil, nil end

    local candidates = { "Asset", "Assets", "Inventory", "Bag", "Items", "Item", "Backpack" }
    local Asset = nil
    for _, n in ipairs(candidates) do
        Asset = Data:FindFirstChild(n)
        if Asset then break end
    end
    if not Asset then
        -- try find any descendant named Asset
        for _, d in ipairs(Data:GetDescendants()) do
            if d.Name == "Asset" then Asset = d break end
        end
    end
    return Asset, Data
end

local function toNum(v)
    if v == nil then return nil end
    if typeof(v) == "number" then return v end
    if typeof(v) == "string" then return tonumber((v:gsub(",",""))) end
    return nil
end

local function fmtInt(n)
    if typeof(n) ~= "number" then return tostring(n) end
    local s = string.format("%.0f", n)
    local k
    repeat
        s, k = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    until k == 0
    return s
end

local DONE_SENT = false
local function tryAccountDone()
    if DONE_SENT then return true end
    local ok = false
    if _G and typeof(_G.Horst_AccountChangeDone) == "function" then
        ok = pcall(function()
            _G.Horst_AccountChangeDone()
        end) and true or false
    end
    DONE_SENT = ok or DONE_SENT
    if not ok then
        -- fallback log to debug when global isn't present
        warn("[DONE] _G.Horst_AccountChangeDone unavailable or failed")
    end
    return ok
end

local DESC_PARTS = {}
local function sendDescMessage(text)
    table.insert(DESC_PARTS, text)
    local joined = table.concat(DESC_PARTS, " / ")
    local sent = false
    if _G and typeof(_G.Horst_SetDescription) == "function" then
        local ok = pcall(function()
            _G.Horst_SetDescription(joined)
        end)
        sent = ok and true or false
    end
    if not sent then
        print("[DESC]", joined)
    end
    -- Fire DONE right after updating description (only once)
    tryAccountDone()
end

local function postDiscordJson(payload)
    local url = _G and (_G.Horst_DiscordWebhook or _G.DC_WEBHOOK)
    if type(url) ~= "string" or #url == 0 then return false end
    local json = HttpService:JSONEncode(payload)

    -- executor/http-request fallback first (works even if HttpService is disabled)
    local http = rawget(getgenv and getgenv() or _G, "http_request")
        or (syn and syn.request)
        or (fluxus and fluxus.request)
        or (http and http.request)
        or rawget(_G, "request")

    if http then
        local ok, res = pcall(function()
            return http({
                Url = url,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = json,
            })
        end)
        if ok and res then
            local sc = res.StatusCode or res.Status or res.status_code or 0
            return sc >= 200 and sc < 300
        end
    end

    -- Roblox HttpService fallback (requires HttpEnabled on the game)
    local ok = pcall(function()
        HttpService:PostAsync(url, json, Enum.HttpContentType.ApplicationJson)
    end)
    return ok and true or false
end

local function sendDiscord(text)
    if CONFIG and not CONFIG.EnableLog then return end
    local delivered = false
    -- 1) custom function hook
    if _G and typeof(_G.Horst_DiscordLog) == "function" then
        local ok = pcall(function()
            _G.Horst_DiscordLog(text)
        end)
        delivered = ok and true or false
    end
    -- 2) webhook URL in globals
    if not delivered then
        local content = text
        if CONFIG and CONFIG.discord_id and #CONFIG.discord_id > 0 then
            content = string.format("<@%s> %s", CONFIG.discord_id, text)
        end
        delivered = postDiscordJson({ content = content })
    end
    if not delivered then
        print("[DC]", text)
    end
end

local function sendDiscordEmbedPet(rec, psVal)
    if CONFIG and not CONFIG.EnableLog then return end
    local url = _G and (_G.Horst_DiscordWebhook or _G.DC_WEBHOOK)
    if type(url) ~= "string" or #url == 0 then
        -- Fallback to plain text if no webhook configured
        local msg = ("%s -> ProduceSpeed=%s"):format(tostring(rec.T or "?"), fmtInt(psVal))
        sendDiscord(msg)
        return
    end
    local embed = {
        title = "Lottery!",
        description = "Successfully Lottery a pet.",
        color = 5763719, -- teal-ish
        fields = {
            { name = "💻 Pet UID", value = string.format("`%s`", tostring(rec.uid or "-")), inline = false },
            { name = "🐾 Pet Name", value = tostring(rec.T or "?"), inline = true },
            { name = "✨ Mutate", value = tostring(rec.M or "None"), inline = true },
            { name = "⚙️ Produce Speed", value = fmtInt(psVal), inline = true },
        },
        footer = (function()
            local base = string.format("Build A Zoo • %s", os.date("%d/%m/%Y %H:%M", os.time()))
            if CONFIG and CONFIG.PC_NAME and #CONFIG.PC_NAME > 0 then
                base = string.format("%s • %s", CONFIG.PC_NAME, base)
            end
            return { text = base }
        end)(),
    }
    local payload = { embeds = { embed } }
    if CONFIG and CONFIG.discord_id and #CONFIG.discord_id > 0 then
        payload.content = string.format("<@%s>", CONFIG.discord_id)
    end
    local ok = postDiscordJson(payload)
    if not ok then
        warn("[DC] webhook post failed")
        local msg = ("%s -> ProduceSpeed=%s"):format(tostring(rec.T or "?"), fmtInt(psVal))
        sendDiscord(msg)
    end
end

-- ====== GIFT HELPERS ======
local function resolveTarget()
    local tn = nil
    local G = (getgenv and getgenv()) or {}
    local KX = rawget(G, "KitsuneConfig")
    if type(KX) == "table" and type(KX.TARGET_NAME) == "string" and KX.TARGET_NAME ~= "" then
        tn = KX.TARGET_NAME
    end
    if not tn and RawConfig and type(RawConfig.TargetName) == "string" and RawConfig.TargetName ~= "" then
        tn = RawConfig.TargetName
    end
    if not tn then return nil end
    local q = tostring(tn):lower()
    for _, plr in ipairs(Players:GetPlayers()) do
        local nlc = plr.Name:lower()
        if nlc == q or nlc:sub(1, #q) == q then return plr end
    end
    return nil
end

local function holdPet(uid)
    pcall(function() CharacterRE:FireServer("Focus", uid) end)
    pcall(function() CharacterRE:FireServer("Equip", uid) end)
    pcall(function() CharacterRE:FireServer("Hold", uid) end)
end

local function tryGift(target, uid)
    return pcall(function() GiftRE:FireServer(target) end)
        or pcall(function() GiftRE:FireServer({ player = target }) end)
        or pcall(function() GiftRE:FireServer(target, uid) end)
        or pcall(function() GiftRE:FireServer({ target = target, id = uid }) end)
end

local function readTickets()
    local Asset, Data = getAssetFolder()
    if not Data then return nil end
    -- 1) direct child under Asset (fast path)
    if Asset then
        local node = Asset:FindFirstChild("LotteryTicket")
        if node and node:IsA("ValueBase") then return toNum(node.Value) end
        local a = Asset:GetAttribute("LotteryTicket")
        if a ~= nil then return toNum(a) end
    end
    -- 2) attribute on Data
    if Data:GetAttribute("LotteryTicket") ~= nil then
        return toNum(Data:GetAttribute("LotteryTicket"))
    end
    -- 3) search anywhere under Data for a ValueBase named LotteryTicket
    for _, d in ipairs(Data:GetDescendants()) do
        if d.Name == "LotteryTicket" and d:IsA("ValueBase") then
            return toNum(d.Value)
            end
        end
    -- 4) search attributes on descendants
    for _, d in ipairs(Data:GetDescendants()) do
        local ok, v = pcall(function()
            return d:GetAttribute("LotteryTicket")
        end)
        if ok and v ~= nil then return toNum(v) end
    end
    return nil
end

local function fireLottery(n)
    local args = { [1] = { event = "lottery", count = n } }
    LotteryRE:FireServer(unpack(args))
end

local function waitDecrease(prev, expectDecBy, maxWait)
    local t0 = os.clock()
    while os.clock() - t0 < (maxWait or 3) do
        task.wait(0.05)
        local now = readTickets()
        if now ~= nil and now < prev then return now end
    end
    return math.max((prev or 0) - (expectDecBy or 1), 0)
end

local function waitForTickets(timeout)
    local t0 = os.clock()
    while os.clock() - t0 < (timeout or READ_TIMEOUT) do
        local v = readTickets()
        if v ~= nil then return v end
        task.wait(0.2)
    end
    return readTickets()
end

local tickets = waitForTickets(READ_TIMEOUT * 2)
if tickets == nil then
    logStep("Tickets not found (nil). Abort.")
    return
end
if tickets <= 0 then
    logStep("tickets=0 -> send DONE and skip lottery")
    tryAccountDone()
    return
end
logStep(("Lottery start: tickets=%d"):format(tickets))

-- Track newly acquired pets during LOTTERY
local NEW_PETS = {}
local connPetsAdded = nil
do
    local _, Data = getAssetFolder()
    if Data then
        local Pets = Data:FindFirstChild("Pets") or Data:WaitForChild("Pets", READ_TIMEOUT)
        if Pets then
            connPetsAdded = Pets.ChildAdded:Connect(function(p)
                task.wait(0.1)
                local uid = tostring(p:GetAttribute("UID") or p.Name)
                local T = p:GetAttribute("PetID") or p:GetAttribute("PetName") or p:GetAttribute("T") or p.Name
                local M = p:GetAttribute("MutateName") or p:GetAttribute("Mutate") or p:GetAttribute("M")
                local V = p:GetAttribute("V")
                table.insert(NEW_PETS, { uid = uid, T = T, M = M, V = V })
            end)
        end
    end
end

while tickets > 0 do
    local use = (tickets >= 10) and 10 or ((tickets >= 3) and 3 or 1)
    fireLottery(use)
    task.wait(ROLL_PAUSE)

    local before = tickets
    local now = readTickets()
    if now ~= nil and now < before then
        tickets = now
    else
        tickets = waitDecrease(before, use, 2.0)
        if tickets >= before then tickets = math.max(before - use, 0) end
    end
    logStep(("Rolled %d -> left %d"):format(use, tickets))
end

-- After LOTTERY, log acquired pets and their ProduceSpeed
if connPetsAdded then connPetsAdded:Disconnect() end
if #NEW_PETS > 0 then
    logStep(("Lottery rewards total: %d"):format(#NEW_PETS))
    for _, r in ipairs(NEW_PETS) do
        local psVal = nil
        if getgenv and getgenv().PS then
            local PS = getgenv().PS
            if PS.computeByPetUtil then
                local okU, uv = pcall(function()
                    return PS.computeByPetUtil(r.T, r.M, r.V)
                end)
                if okU and uv ~= nil then psVal = uv end
            end
            if psVal == nil and PS.computePS then
                local okC, v1 = pcall(function()
                    local a,b,c = PS.computePS(r.T, r.M)
                    return a
                end)
                if okC and v1 ~= nil then psVal = v1 end
            end
        end
        -- Local fallback: use PetUtil directly if available
        if psVal == nil and PetUtil then
            local okL, lv = pcall(function()
                return PetUtil:GetPetProduce({ M = r.M, T = r.T, V = r.V }, 1)
            end)
            if okL and lv ~= nil then psVal = lv end
        end
        if psVal ~= nil and psVal >= PS_MIN then
            local msg = ("ProduceSpeed=%s"):format(fmtInt(psVal))
            sendDescMessage(msg)
            sendDiscordEmbedPet(r, psVal)
            local tgt = resolveTarget()
            if tgt then
                logStep(("Gift try: uid=%s T=%s M=%s PS=%s -> target=%s")
                    :format(tostring(r.uid), tostring(r.T), tostring(r.M or "None"), fmtInt(psVal), tgt.Name))
                holdPet(r.uid)
                local ok = tryGift(tgt, r.uid)
                if ok then
                    logStep("Gift sent OK")
                else
                    logStep("Gift send failed (retry may occur elsewhere)")
                end
            else
                logStep("Gift skipped: target not found (set KitsuneConfig.TARGET_NAME or LotteryConfig.TargetName)")
            end
        end
    end
else
	logStep("No new pets detected during rolls.")
end

-- Also, if LotteryTicket becomes 0 within DONE_TIMEOUT, trigger DONE
task.spawn(function()
    local t0 = os.clock()
    while os.clock() - t0 < DONE_TIMEOUT do
        local now = readTickets()
        if now ~= nil and now <= 0 then
            tryAccountDone()
            break
        end
        task.wait(0.25)
    end
end)

print("[LOTTERY] done (no UI needed).")
