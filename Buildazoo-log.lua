-- Allow override via getgenv() for self-hosted servers
local function _gk(k)
    local ok, v = pcall(function() return (getgenv and getgenv()[k]) end)
    return ok and v or nil
end

local API_URL   = tostring(_gk("EGG_API_URL") or "https://auth.ducky.host/egg-log")
local AUTH_TOKEN= tostring(_gk("EGG_AUTH_TOKEN") or "u8N3QBKHNfnDWUwm9")
local DEBUG_LOG = (function() local v=_gk("EGG_DEBUG"); return v==true or v==1 or tostring(v)=="true" end)()

local PERIOD_HEARTBEAT  = 30      -- วินาที/ครั้ง (อัปเดททุก 30 วินาที)
local MIN_SEND_INTERVAL = 5       -- กันยิงถี่เกินไป (ลดจาก 15 เป็น 5)
local DEBOUNCE_SEC      = 1       -- กันสแปมเวลามี event ชิดกัน (ลดจาก 2 เป็น 1)

-- ======= Services =======
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = (function() local ok,s=pcall(function() return game:GetService("TeleportService") end); return ok and s or nil end)()
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager = game:FindService("VirtualInputManager")
local LP = Players.LocalPlayer

-- ======= HTTP (exploit env) =======
local requestFn = (syn and syn.request)
    or (http and http.request)
    or rawget(getfenv(), "http_request")
    or rawget(getfenv(), "request")

-- ======= Shortcuts =======
local s_lower, s_gsub = string.lower, string.gsub
local t_concat = table.concat
local jsonEncode= function(t) return HttpService:JSONEncode(t) end
local function dlog(...)
    if not DEBUG_LOG then return end
    local args = { ... }
    local list = { "[EGGLOG]" }
    for i = 1, #args do list[#list+1] = tostring(args[i]) end
    print(table.concat(list, " "))
end
local now_clock = os.clock
local now_unix  = os.time
local rand      = math.random
local delay     = task.delay
local spawn     = task.spawn
local wait      = task.wait

-- ======= Ready =======
local function ready()
    if not game:IsLoaded() then game.Loaded:Wait() end
    LP:WaitForChild("PlayerGui")
end

-- ======= Helpers (normalize) =======
local function normTypeName(s)
    if not s then return nil end
    return s_gsub(s_lower(tostring(s)), "[%s%-%_]+", "")
end

local function normKey(s)
    if not s then return nil end
    s = s_lower(tostring(s))
    s = s_gsub(s, "[^%w%-%_]+", "")
    if s == "" then return nil end
    return s
end

local function splitKeys(str)
    local out = {}
    for part in tostring(str):gmatch("[^,%|/%s]+") do
        local k = normKey(part)
        if k then out[#out+1] = k end
    end
    return out
end

local function tclear(t) for k in pairs(t) do t[k] = nil end end

-- ======= Buff key filters (same as #1) =======
local BAD_SET = {
    uid=true, id=true, uuid=true, st=true, et=true, t=true, type=true, name=true,
    timer=true, time=true, start=true, stop=true, count=true, amount=true,
}
local function looks_like_hexid(k) return (#k>=8 and #k<=64 and k:match("^[0-9a-f]+$") ~= nil) end
local function looks_like_eggname(k) return (k:match("egg$") ~= nil) end
local function isBuffKey(k)
    return (k and not BAD_SET[k] and not looks_like_hexid(k) and not looks_like_eggname(k))
end

-- ======= Read mutations like #1 =======
local COMMON_MUT_FOLDERS   = { "Mutations", "EggMutations", "EggMutation", "Buffs", "ActiveBuffs", "EggBuffs", "Effects" }
local COMMON_STRING_FIELDS = { "Mutations", "Mutation", "M" }
local COMMON_COUNT_FIELDS  = { "Count", "Amount", "Qty", "Quantity", "Owned", "Stacks" }

local function findStringValue(obj, name)
    local v = obj and obj:FindFirstChild(name)
    return (v and v:IsA("StringValue")) and v.Value or nil
end

local function findNumberValue(obj, name)
    local v = obj and obj:FindFirstChild(name)
    if v and v:IsA("NumberValue") then return tonumber(v.Value) or 0 end
    return nil
end

local function add_keys(dst, keys)
    for _,k in ipairs(keys) do if isBuffKey(k) then dst[k] = true end end
end

local function resolveMutationsFromData(dataRoot, eggNode)
    local set = {}

    -- A) Folder under Data: StringValue keyed by egg name + true BoolValues
    for _, folderName in ipairs(COMMON_MUT_FOLDERS) do
        local f = dataRoot:FindFirstChild(folderName)
        if f and f:IsA("Folder") then
            local sv = f:FindFirstChild(eggNode.Name)
            if sv and sv:IsA("StringValue") and sv.Value ~= "" then add_keys(set, splitKeys(sv.Value)) end
            for _, ch in ipairs(f:GetChildren()) do
                if ch:IsA("BoolValue") and ch.Value == true then
                    local k = normKey(ch.Name); if k and isBuffKey(k) then set[k]=true end
                end
            end
        end
    end

    -- B) StringValue fields on Egg and on Data
    for _, fname in ipairs(COMMON_STRING_FIELDS) do
        local v = findStringValue(eggNode, fname); if v and v ~= "" then add_keys(set, splitKeys(v)) end
    end
    for _, fname in ipairs(COMMON_STRING_FIELDS) do
        local v = findStringValue(dataRoot, fname); if v and v ~= "" then add_keys(set, splitKeys(v)) end
    end

    -- C) Attributes on Egg/Data
    for _, owner in ipairs({eggNode, dataRoot}) do
        for _, aname in ipairs(COMMON_STRING_FIELDS) do
            local av = owner:GetAttribute(aname)
            if type(av)=="string" and av~="" then add_keys(set, splitKeys(av)) end
        end
    end

    local keys = {}
    for k,_ in pairs(set) do keys[#keys+1] = k end
    table.sort(keys)
    return (#keys>0) and keys or { "none" }
end

local function readTypeAndMuts(dataRoot, eggNode)
    local attrs = eggNode:GetAttributes()
    local rawType = attrs.T or attrs.Type or eggNode.Name
    local tk = normTypeName(rawType)
    return tk, rawType, resolveMutationsFromData(dataRoot, eggNode)
end

local function readCount(eggNode)
    -- 1) NumberValue child fields
    for _, fname in ipairs(COMMON_COUNT_FIELDS) do
        local nv = findNumberValue(eggNode, fname)
        if nv ~= nil then return math.max(0, math.floor(nv or 0)) end
    end
    -- 2) Attributes
    for _, fname in ipairs(COMMON_COUNT_FIELDS) do
        local av = eggNode:GetAttribute(fname)
        if type(av)=="number" then return math.max(0, math.floor(av)) end
        if type(av)=="string" then
            local n = tonumber(av)
            if n then return math.max(0, math.floor(n)) end
        end
    end
    -- 3) Default to 1 per item if nothing provided
    return 1
end

-- ======= State (like #1, + egg counts per type) =======
local PREPARED, TYPE_INDEX, MUTS, CHILD_STATE = {}, {}, {}, {}
local TYPE_EGG_COUNT = {}  -- eggs per type (true count, not sum of buffs)
local DATA_ROOT, EGG_FOLDER = nil, nil

local function ensureType(tKey, rawLabel)
    if not tKey then return nil end
    local idx = TYPE_INDEX[tKey]
    if not idx then
        idx = #PREPARED + 1
        TYPE_INDEX[tKey] = idx
        PREPARED[idx] = { label = rawLabel or tKey, tKey = tKey }
        MUTS[idx] = {}          -- buffKey -> count
        TYPE_EGG_COUNT[idx] = 0 -- number of eggs for this type
    else
        if PREPARED[idx].label == tKey and rawLabel and rawLabel ~= "" then
            PREPARED[idx].label = rawLabel
        end
    end
    return idx
end

local function applyDelta(idx, mutKeys, delta)
    if not idx or not mutKeys then return end
    local m = MUTS[idx]
    for _, k in ipairs(mutKeys) do
        m[k] = (m[k] or 0) + delta
        if m[k] == 0 then m[k] = nil end
    end
end

local function attachChild(dataRoot, child)
    local tk, rawType, mKeys = readTypeAndMuts(dataRoot, child)
    local cnt = readCount(child)
    local idx = ensureType(tk, rawType)
    CHILD_STATE[child] = { tKey=tk, idx=idx, mutKeys=mKeys, count=cnt }
    applyDelta(idx, mKeys, cnt)
    TYPE_EGG_COUNT[idx] = (TYPE_EGG_COUNT[idx] or 0) + cnt
end

local function detachChild(child)
    local st = CHILD_STATE[child]
    if st then
        applyDelta(st.idx, st.mutKeys, -st.count)
        TYPE_EGG_COUNT[st.idx] = math.max(0, (TYPE_EGG_COUNT[st.idx] or 0) - st.count)
        CHILD_STATE[child] = nil
    end
end

local function rescanAll()
    if not DATA_ROOT or not EGG_FOLDER then return end
    tclear(PREPARED); tclear(TYPE_INDEX); tclear(MUTS); tclear(TYPE_EGG_COUNT)
    for c,_ in pairs(CHILD_STATE) do CHILD_STATE[c] = nil end
    local children = EGG_FOLDER:GetChildren()
    for i = 1, #children do attachChild(DATA_ROOT, children[i]) end
end

local function looksLikeEggConfigNode(n)
    if not n or not n:IsA("Instance") then return false end
    local nm = tostring(n.Name or ""):lower()
    if nm:find("egg") then return true end
    local a = n:GetAttributes()
    if a and (a.T or a.Type) then return true end
    for _, fname in ipairs(COMMON_COUNT_FIELDS) do
        local nv = n:FindFirstChild(fname)
        if nv and nv:IsA("NumberValue") then return true end
        local av = n:GetAttribute(fname)
        if type(av)=="number" then return true end
    end
    return false
end

local function findEggFolder()
    -- prefer Data/Egg
    if DATA_ROOT then
        local d1 = DATA_ROOT:FindFirstChild("Egg") or DATA_ROOT:FindFirstChild("Eggs")
        if d1 and d1:IsA("Folder") then return d1 end
    end
    -- scan PlayerGui broadly
    local root = LP:FindFirstChild("PlayerGui")
    if not root then return nil end
    local best, bestScore = nil, 0
    for _, d in ipairs(root:GetDescendants()) do
        if d and d:IsA("Folder") then
            local cnt = 0
            for _, ch in ipairs(d:GetChildren()) do if looksLikeEggConfigNode(ch) then cnt = cnt + 1 end end
            if cnt > bestScore and cnt >= 1 then best = d; bestScore = cnt end
        end
    end
    return best
end

local function sameSet(a, b)
    if #a ~= #b then return false end
    local seen = {}
    for _, v in ipairs(a) do seen[v] = (seen[v] or 0) + 1 end
    for _, v in ipairs(b) do
        if not seen[v] then return false end
        seen[v] = seen[v] - 1
        if seen[v] < 0 then return false end
    end
    for _, n in pairs(seen) do if n ~= 0 then return false end end
    return true
end

local function maybeUpdateChild(dataRoot, child)
    local old = CHILD_STATE[child]
    local tk, rawType, mKeys = readTypeAndMuts(dataRoot, child)
    local cnt = readCount(child)
    if not old then
        local idx = ensureType(tk, rawType)
        CHILD_STATE[child] = { tKey=tk, idx=idx, mutKeys=mKeys, count=cnt }
        applyDelta(idx, mKeys, cnt)
        TYPE_EGG_COUNT[idx] = (TYPE_EGG_COUNT[idx] or 0) + cnt
        return true
    end
    local typeChanged = (old.tKey ~= tk)
    local mutsChanged = not sameSet(old.mutKeys, mKeys)
    local countChanged = (tonumber(old.count or 0) ~= tonumber(cnt or 0))
    if typeChanged or mutsChanged or countChanged then
        -- remove old
        applyDelta(old.idx, old.mutKeys, -old.count)
        TYPE_EGG_COUNT[old.idx] = math.max(0, (TYPE_EGG_COUNT[old.idx] or 0) - old.count)
        -- add new
        local idx = ensureType(tk, rawType)
        old.tKey, old.idx, old.mutKeys, old.count = tk, idx, mKeys, cnt
        applyDelta(idx, mKeys, cnt)
        TYPE_EGG_COUNT[idx] = (TYPE_EGG_COUNT[idx] or 0) + cnt
        return true
    end
    return false
end

-- ======= Build API payload =======
local function toSummaryTable()
    local out = table.create(#PREPARED)
    for i = 1, #PREPARED do
        local mutMap = MUTS[i] or {}
        -- copy buffs to plain table to avoid metatable issues
        local buffs = {}
        for k,v in pairs(mutMap) do buffs[k] = v end
        -- ensure at least none if absolutely nothing (defensive)
        if next(buffs) == nil then buffs.none = 1 end
        out[i] = {
            -- Use canonical type key as the server label to prevent
            -- duplicate/override when raw display names differ
            label = PREPARED[i].tKey,
            name  = PREPARED[i].label, -- display only (ignored by server)
            count = TYPE_EGG_COUNT[i] or 0, -- real egg count per type
            buffs = buffs
        }
    end
    return out
end

local function digestCounts()
    -- compact string to detect changes
    local parts = {}
    for i = 1, #PREPARED do
        local label = tostring(PREPARED[i].label)
        local cnt   = tostring(TYPE_EGG_COUNT[i] or 0)
        local kvs = {}
        local mutMap = MUTS[i] or {}
        local keys = {}
        for k,_ in pairs(mutMap) do keys[#keys+1] = k end
        table.sort(keys)
        for _,k in ipairs(keys) do kvs[#kvs+1] = k .. "=" .. tostring(mutMap[k]) end
        parts[#parts+1] = label .. "#" .. cnt .. ":" .. table.concat(kvs, ",")
    end
    return table.concat(parts, "|")
end

-- ======= Sender / Presence =======
local STOP_HEARTBEAT = false
local SENT_OFFLINE   = false

local function sendToApi(payloadTbl)
    if typeof(requestFn) ~= "function" then dlog("no requestFn"); return false, 0 end
    local res
    local ok = pcall(function()
        res = requestFn({
            Url = API_URL,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["X-Auth-Token"] = AUTH_TOKEN,
            },
            Body = jsonEncode(payloadTbl),
        })
    end)
    local code = tonumber((res and (res.StatusCode or res.status)) or 0) or 0
    dlog("POST", API_URL, "status=", code)
    return ok and code >=200 and code < 300, code
end

local function sendPresence(kind)
    local payload = {
        player  = { userId = LP.UserId, name = LP.Name, displayName = LP.DisplayName },
        placeId = game.PlaceId,
        jobId   = tostring(game.JobId or "N/A"),
        payload = {
            clientTime = now_unix(),
            period     = 0,
            reason     = "presence_" .. tostring(kind),
            totals     = toSummaryTable(),
            presence   = { kind = kind, heartbeat = PERIOD_HEARTBEAT }
        }
    }
    pcall(function() sendToApi(payload) end)
end

local function markDisconnected(reason)
    if SENT_OFFLINE then return end
    SENT_OFFLINE = true
    STOP_HEARTBEAT = true
    pcall(function() sendPresence("offline") end)
end

local lastDigest, lastSendAt = "", 0
local debounceFlag, scheduled = false, false

local function buildAndMaybeSend(reason)
    if STOP_HEARTBEAT and reason == "heartbeat" then return end
    local t0 = now_clock()
    local dt = t0 - lastSendAt
    
    -- ให้ money_bootstrap และ money_change ส่งทันทีโดยไม่ต้องรอ
    if reason == "money_bootstrap" or reason == "money_change" then
        print("[MoneyWatch] Force sending money update, reason:", reason)
    elseif dt < MIN_SEND_INTERVAL then
        if not scheduled then
            scheduled = true
            delay((MIN_SEND_INTERVAL - dt) + rand(), function()
                scheduled = false
                buildAndMaybeSend("rate_limit_flush")
            end)
        end
        return
    end
    
    local d = digestCounts()
    if d == lastDigest and reason ~= "heartbeat" and reason ~= "money_bootstrap" and reason ~= "money_change" then return end
    local payload = {
        player  = { userId = LP.UserId, name = LP.Name, displayName = LP.DisplayName },
        placeId = game.PlaceId,
        jobId   = tostring(game.JobId or "N/A"),
        payload = {
            clientTime = now_unix(),
            period     = (reason == "heartbeat") and PERIOD_HEARTBEAT or 0,
            reason     = reason,
            totals     = toSummaryTable(),
        }
    }
    if reason == "money_bootstrap" or reason == "money_change" then
        print("[MoneyWatch] Sending payload with reason:", reason)
        local totals = payload.payload.totals
        for i, item in ipairs(totals) do
            if item.label == "coins" then
                print("[MoneyWatch] Coins in payload:", item.count)
                break
            end
        end
    end
    local ok, code = sendToApi(payload)
    lastSendAt = t0
    if ok then lastDigest = d else dlog("send failed", code) end
end

local function requestSend(reason)
    -- ให้ money_bootstrap และ money_change ส่งทันทีโดยไม่ต้อง debounce
    if reason == "money_bootstrap" or reason == "money_change" then
        print("[MoneyWatch] Bypassing debounce for:", reason)
        buildAndMaybeSend(reason)
        return
    end
    
    if debounceFlag then return end
    debounceFlag = true
    delay(DEBOUNCE_SEC + rand(), function()
        debounceFlag = false
        buildAndMaybeSend(reason)
    end)
end

-- ======= 273 watcher / auto-leave (เหมือนเดิม) =======
local function _txt(o)
    local ok, v = pcall(function() return tostring(o.Text) end)
    return ok and (v or "") or ""
end

local function _hasErr273Context(gui)
    local cur = gui
    while cur and cur ~= CoreGui do
        if cur:IsA("TextLabel") or cur:IsA("TextBox") or cur:IsA("TextButton") then
            local t = s_lower(_txt(cur))
            if t:find("disconnected") or t:find("error code%:?%s*273")
               or t:find("same account launched experience") then
                return true
            end
        end
        cur = cur.Parent
    end
    return false
end

local function _clickButton(btn)
    if not btn or not btn:IsA("GuiButton") then return end
    markDisconnected("ui_leave")
    local ok = false
    if typeof(firesignal) == "function" then
        ok = pcall(firesignal, btn.MouseButton1Click)
    end
    if not ok then pcall(function() btn:Activate() end) end
    if VirtualInputManager and btn.AbsoluteSize.X > 0 and btn.AbsoluteSize.Y > 0 then
        pcall(function()
            local pos = btn.AbsolutePosition + btn.AbsoluteSize/2
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, true, btn, 0)
            VirtualInputManager:SendMouseButtonEvent(pos.X, pos.Y, 0, false, btn, 0)
        end)
    end
end

local function _tryFindAndLeave(root)
    for _, d in ipairs(root:GetDescendants()) do
        if d:IsA("TextButton") then
            local t = s_lower(_txt(d)):gsub("%s+", "")
            if t == "leave" and _hasErr273Context(d) then
                _clickButton(d)
                return true
            end
        end
    end
    return false
end

task.defer(function()
    pcall(function()
        _tryFindAndLeave(CoreGui)
    end)
end)

CoreGui.DescendantAdded:Connect(function(obj)
    if not obj:IsA("GuiObject") then return end
    pcall(function()
        if obj:IsA("TextLabel") or obj:IsA("TextBox") then
            local t = s_lower(_txt(obj))
            if t:find("disconnected") or t:find("error code%:?%s*273")
               or t:find("same account launched experience") then
                markDisconnected("ui_err")
            end
        end
    end)
    task.delay(0.05 + math.random()*0.05, function()
        pcall(function()
            if obj:IsA("TextButton") then
                local t = s_lower(_txt(obj)):gsub("%s+", "")
                if t == "leave" and _hasErr273Context(obj) then
                    _clickButton(obj)
                end
            else
                _tryFindAndLeave(obj)
            end
        end)
    end)
end)

-- ======= Main =======
spawn(function()
    ready()
    math.randomseed(now_clock()*1e6 % 2^31)

    local pg   = LP:WaitForChild("PlayerGui")
    local data = pg:WaitForChild("Data")
    DATA_ROOT = data

    local eggFolder = data:FindFirstChild("Egg")
    if not eggFolder or eggFolder.Parent ~= data then
        eggFolder = findEggFolder()
        if not eggFolder then
            eggFolder = Instance.new("Folder")
            eggFolder.Name = "Egg"
            eggFolder.Parent = data
        end
    end
    EGG_FOLDER = eggFolder

    -- initial scan
    tclear(PREPARED); tclear(TYPE_INDEX); tclear(MUTS); tclear(TYPE_EGG_COUNT)
    for c,_ in pairs(CHILD_STATE) do CHILD_STATE[c] = nil end

    rescanAll()

    local function hookConfig(cfg)
        cfg:GetAttributeChangedSignal("T"):Connect(function()
            if maybeUpdateChild(data, cfg) then requestSend("attr_change") end
        end)
        cfg:GetAttributeChangedSignal("Type"):Connect(function()
            if maybeUpdateChild(data, cfg) then requestSend("attr_change") end
        end)
        cfg:GetAttributeChangedSignal("M"):Connect(function()
            if maybeUpdateChild(data, cfg) then requestSend("attr_change") end
        end)
        cfg:GetAttributeChangedSignal("Mutation"):Connect(function()
            if maybeUpdateChild(data, cfg) then requestSend("attr_change") end
        end)
        -- Watch common numeric count attributes
        for _, fname in ipairs(COMMON_COUNT_FIELDS) do
            cfg:GetAttributeChangedSignal(fname):Connect(function()
                if maybeUpdateChild(data, cfg) then requestSend("count_attr_change") end
            end)
        end
        -- Watch NumberValue children like Count/Amount under each config node
        local function bindNumWatcher(nv)
            if nv and nv:IsA("NumberValue") then
                for _, nm in ipairs(COMMON_COUNT_FIELDS) do
                    if nv.Name == nm then
                        nv.Changed:Connect(function()
                            if maybeUpdateChild(data, cfg) then requestSend("count_value_change") end
                        end)
                        break
                    end
                end
            end
        end
        for _, ch in ipairs(cfg:GetChildren()) do bindNumWatcher(ch) end
        cfg.ChildAdded:Connect(bindNumWatcher)
    end
    for _, ch in ipairs(eggFolder:GetChildren()) do hookConfig(ch) end

    -- Watch direct children
    eggFolder.ChildAdded:Connect(function(c)
        attachChild(data, c); hookConfig(c); requestSend("child_added")
    end)
    eggFolder.ChildRemoved:Connect(function(c)
        detachChild(c); requestSend("child_removed")
    end)
    -- Watch nested descendants (some games nest config under folders)
    eggFolder.DescendantAdded:Connect(function(n)
        if looksLikeEggConfigNode(n) then
            -- let attributes settle a tick then update
            task.delay(0.05, function()
                pcall(function()
                    if not CHILD_STATE[n] then attachChild(data, n); hookConfig(n) end
                    if maybeUpdateChild(data, n) then requestSend("desc_added") end
                end)
            end)
        end
    end)
    eggFolder.DescendantRemoving:Connect(function(n)
        if CHILD_STATE[n] then detachChild(n); requestSend("desc_removed") end
    end)

    -- bootstrap + presence
    requestSend("bootstrap")
    sendPresence("online")

    -- heartbeat loop
    spawn(function()
        while not STOP_HEARTBEAT do
            wait(PERIOD_HEARTBEAT + rand(2, 6))
            if STOP_HEARTBEAT then break end
            -- Defensive full rescan to catch missed events
            pcall(rescanAll)
            requestSend("heartbeat")
            sendPresence("ping")
        end
    end)

    -- quick connectivity check
    spawn(function()
        if typeof(requestFn) ~= "function" then return end
        local ok, _ = pcall(function()
            local res = requestFn({ Url = API_URL .. "/whoami", Method = "GET" })
            dlog("PING", API_URL .. "/whoami", "status=", res and (res.StatusCode or res.status))
        end)
        if not ok then dlog("ping failed") end
    end)

    -- teleport/offline hooks
    if TeleportService then
        pcall(function()
            TeleportService.TeleportInit:Connect(function()
                markDisconnected("teleport")
            end)
        end)
    end
    pcall(function()
        game:BindToClose(function()
            markDisconnected("bind_to_close")
            task.wait(0.25)
        end)
    end)
end)

-- (removed recursive aliases that caused stack overflow)

-- ===== Money Watch (auto-detect 'money/cash/coins') =====
local function money_name_score(n)
  n = string.lower(tostring(n or ""))
  if n == "money" then return 100 end
  if n == "cash" then return 90 end
  if n == "coins" or n == "coin" then return 80 end
  if n == "gold" then return 70 end
  if n == "gems" or n == "diamond" or n == "diamonds" then return 60 end
  if n == "bucks" or n == "point" or n == "points" then return 50 end
  return 10
end
local MONEY_KIND_WEIGHT = { leaderstats=200, attribute=180, playerValue=160, guiValue=140, rsValue=120 }

local function is_value_object(x) return x and x:IsA("ValueBase") end
local function read_number_from_value_object(v)
  if not (v and v.Parent) then return nil end
  if v:IsA("NumberValue") or v:IsA("IntValue") or v:IsA("DoubleConstrainedValue") or v:IsA("IntConstrainedValue") or v:IsA("FloatValue") then
    return tonumber(v.Value)
  elseif v:IsA("StringValue") then
    local digits = tostring(v.Value):gsub("[^%d%.%-]","")
    return tonumber(digits)
  end
  return nil
end

local function money_gather_candidates()
  local cands = {}
  -- 1) leaderstats
  local ls = LP:FindFirstChild("leaderstats")
  if ls then
    for _, ch in ipairs(ls:GetChildren()) do
      if is_value_object(ch) then
        table.insert(cands, { kind="leaderstats", obj=ch, name=ch.Name, score=MONEY_KIND_WEIGHT.leaderstats + money_name_score(ch.Name) })
      end
    end
  end
  -- 2) attributes
  for name, value in pairs(LP:GetAttributes()) do
    if typeof(value) == "number" then
      table.insert(cands, { kind="attribute", attr=name, name=name, score=MONEY_KIND_WEIGHT.attribute + money_name_score(name) })
    end
  end
  -- 3) valueobjects under player
  for _, ch in ipairs(LP:GetChildren()) do
    if is_value_object(ch) then
      table.insert(cands, { kind="playerValue", obj=ch, name=ch.Name, score=MONEY_KIND_WEIGHT.playerValue + money_name_score(ch.Name) })
    end
  end
  -- 4) PlayerGui.Data/*
  local pg = LP:FindFirstChild("PlayerGui")
  local data = pg and pg:FindFirstChild("Data")
  if data then
    for _, ch in ipairs(data:GetChildren()) do
      if is_value_object(ch) then
        table.insert(cands, { kind="guiValue", obj=ch, name=ch.Name, score=MONEY_KIND_WEIGHT.guiValue + money_name_score(ch.Name) })
      end
    end
  end
  -- 5) ReplicatedStorage.PlayerData[LP.Name]/*
  local RS = game:GetService("ReplicatedStorage")
  local pd = RS:FindFirstChild("PlayerData")
  local my = pd and pd:FindFirstChild(LP.Name)
  if my then
    for _, ch in ipairs(my:GetChildren()) do
      if is_value_object(ch) then
        table.insert(cands, { kind="rsValue", obj=ch, name=ch.Name, score=MONEY_KIND_WEIGHT.rsValue + money_name_score(ch.Name) })
      end
    end
  end
  table.sort(cands, function(a,b) return (a.score or 0) > (b.score or 0) end)
  return cands
end

local function money_can_read(c)
  if c.kind == "attribute" then
    return typeof(LP:GetAttribute(c.attr)) == "number"
  else
    return read_number_from_value_object(c.obj) ~= nil
  end
end

local function money_read(c)
  if not c then return nil end
  if c.kind == "attribute" then
    local v = LP:GetAttribute(c.attr)
    return typeof(v) == "number" and v or nil
  else
    return read_number_from_value_object(c.obj)
  end
end

local MONEY_SOURCE, MONEY_SOURCE_ID, MONEY_LAST = nil, nil, nil
local MONEY_VAL_CONN, MONEY_ATTR_CONN, MONEY_LIFE_CONN = nil, nil, nil

local function money_clear()
  pcall(function() if MONEY_VAL_CONN then MONEY_VAL_CONN:Disconnect() end end); MONEY_VAL_CONN=nil
  pcall(function() if MONEY_ATTR_CONN then MONEY_ATTR_CONN:Disconnect() end end); MONEY_ATTR_CONN=nil
  pcall(function() if MONEY_LIFE_CONN then MONEY_LIFE_CONN:Disconnect() end end); MONEY_LIFE_CONN=nil
end

local function money_id(c)
  if not c then return nil end
  return (c.kind or "?") .. ":" .. tostring(c.name or c.attr)
end

local function money_attach(c)
  money_clear()
  MONEY_SOURCE = c
  MONEY_SOURCE_ID = money_id(c)
  MONEY_LAST = money_read(c)
  print("[MoneyWatch] Attached source:", c.kind, c.name or c.attr, "value:", MONEY_LAST)
  -- trigger a send once when attached so counts_snapshot_live is updated
  print("[MoneyWatch] Triggering send for money bootstrap...")
  pcall(function() requestSend("money_bootstrap") end)
  if c.kind == "attribute" then
    MONEY_ATTR_CONN = LP.AttributeChanged:Connect(function(attr)
      if attr ~= c.attr then return end
      local v = money_read(c)
      if v ~= MONEY_LAST then MONEY_LAST = v; pcall(function() requestSend("money_change") end) end
    end)
  else
    if c.obj and c.obj.Changed then
      MONEY_VAL_CONN = c.obj.Changed:Connect(function(prop)
        if prop ~= "Value" then return end
        local v = money_read(c)
        if v ~= MONEY_LAST then MONEY_LAST = v; pcall(function() requestSend("money_change") end) end
      end)
    end
    MONEY_LIFE_CONN = (c.obj and c.obj:GetPropertyChangedSignal("Parent")) and c.obj:GetPropertyChangedSignal("Parent"):Connect(function()
      if not (c.obj and c.obj.Parent) then
        money_clear(); MONEY_SOURCE, MONEY_SOURCE_ID, MONEY_LAST = nil, nil, nil
      end
    end)
  end
end

-- background loop (non-blocking)
spawn(function()
  print("[MoneyWatch] Starting money detection loop...")
  while true do
    if MONEY_SOURCE and MONEY_SOURCE_ID and money_can_read(MONEY_SOURCE) then
      -- อัปเดทค่าเงินปัจจุบันในทุก loop
      local current = money_read(MONEY_SOURCE)
      if current ~= MONEY_LAST then
        print("[MoneyWatch] Money changed:", MONEY_LAST, "->", current)
        MONEY_LAST = current
        pcall(function() requestSend("money_change") end)
      end
      task.wait(0.5)
    else
      local candidates = money_gather_candidates()
      print("[MoneyWatch] Found", #candidates, "candidates")
      local picked = nil
      for _, cand in ipairs(candidates) do
        if money_can_read(cand) then 
          picked = cand
          print("[MoneyWatch] Picked candidate:", cand.kind, cand.name or cand.attr, "score:", cand.score)
          break 
        end
      end
      if picked then
        if money_id(picked) ~= MONEY_SOURCE_ID then money_attach(picked) end
      else
        print("[MoneyWatch] No valid money source found, retrying...")
        task.wait(0.5)
      end
    end
  end
end)

-- helper to read current money value safely
local function get_current_money()
  local v = MONEY_LAST
  if typeof(v) == "number" then return math.floor(v) end
  return nil
end

-- integrate into payload: override toSummaryTable wrapper to include money
local _orig_toSummaryTable = toSummaryTable
function toSummaryTable()
  local t = _orig_toSummaryTable()
  local m = get_current_money()
  if m and m >= 0 then
    -- ใช้ label_id = 25 สำหรับ coins (แทนที่จะสร้างใหม่)
    t[#t+1] = { label = "coins", name = "Coins", count = m, buffs = { none = 1 }, label_id = 25 }
  end
  return t
end
