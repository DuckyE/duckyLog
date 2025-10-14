-- ========== Config (allow override via getgenv) ==========
local function _gk(k) local ok,v=pcall(function() return getgenv and getgenv()[k] end); return ok and v or nil end
local API_URL    = tostring(_gk("EGG_API_URL")    or "https://auth.ducky.host/egg-log")
local AUTH_TOKEN = tostring(_gk("EGG_AUTH_TOKEN") or "u8N3QBKHNfnDWUwm9")
local DEBUG_LOG  = (function() local v=_gk("EGG_DEBUG"); return v==true or v==1 or tostring(v)=="true" end)()

local PERIOD_HEARTBEAT  = 90   -- วิ/ครั้ง
local MIN_SEND_INTERVAL = 15   -- กันยิงถี่เกิน
local DEBOUNCE_SEC      = 2    -- กันสแปมเหตุการณ์ติดกัน

-- ========== Services ==========
local Players, HttpService = game:GetService("Players"), game:GetService("HttpService")
local CoreGui, LP = game:GetService("CoreGui"), Players.LocalPlayer
local TeleportService = (function() local ok,s=pcall(function() return game:GetService("TeleportService") end); return ok and s or nil end)()
local VIM = game:FindService("VirtualInputManager")

-- ========== HTTP (exploit env) ==========
local requestFn = (syn and syn.request) or (http and http.request) or rawget(getfenv(), "http_request") or rawget(getfenv(), "request")

-- ========== Utils ==========
local s_lower, s_gsub = string.lower, string.gsub
local now_clock, now_unix, rand, delay, spawn, wait = os.clock, os.time, math.random, task.delay, task.spawn, task.wait
local function dlog(...) if not DEBUG_LOG then return end local t={"[EGGLOG]"} for i=1,select("#",...) do t[#t+1]=tostring(select(i,...)) end print(table.concat(t," ")) end
local function ready() if not game:IsLoaded() then game.Loaded:Wait() end LP:WaitForChild("PlayerGui") end
local function tclear(t) for k in pairs(t) do t[k]=nil end end

-- ========== Key normalization ==========
local function normTypeName(s) if not s then return nil end return s_gsub(s_lower(tostring(s)), "[%s%-%_]+", "") end
local function normKey(s)
  if not s then return nil end
  s=s_lower(tostring(s)); s=s_gsub(s,"[^%w%-%_]+",""); if s=="" then return nil end; return s
end
local function splitKeys(str) local out={} for part in tostring(str):gmatch("[^,%|/%s]+") do local k=normKey(part) if k then out[#out+1]=k end end return out end

-- ========== Buff key filters ==========
local BAD_SET = { uid=true,id=true,uuid=true,st=true,et=true,t=true,type=true,name=true,timer=true,time=true,start=true,stop=true,count=true,amount=true }
local function looksHex(k) return (#k>=8 and #k<=64 and k:match("^[0-9a-f]+$")) end
local function looksEggName(k) return k:match("egg$") ~= nil end
local function isBuffKey(k) return (k and not BAD_SET[k] and not looksHex(k) and not looksEggName(k)) end

-- ========== Mutation sources ==========
local MUT_FOLDERS   = { "Mutations","EggMutations","EggMutation","Buffs","ActiveBuffs","EggBuffs","Effects" }
local STR_FIELDS    = { "Mutations","Mutation","M" }
local COUNT_FIELDS  = { "Count","Amount","Qty","Quantity","Owned","Stacks" }

local function findStringValue(obj, name) local v=obj and obj:FindFirstChild(name) return (v and v:IsA("StringValue")) and v.Value or nil end
local function findNumberValue(obj, name) local v=obj and obj:FindFirstChild(name) if v and v:IsA("NumberValue") then return tonumber(v.Value) or 0 end end
local function add_keys(dst, keys) for _,k in ipairs(keys) do if isBuffKey(k) then dst[k]=true end end end

local function resolveMutationsFromData(dataRoot, eggNode)
  local set = {}
  for _, folderName in ipairs(MUT_FOLDERS) do
    local f = dataRoot:FindFirstChild(folderName)
    if f and f:IsA("Folder") then
      local sv = f:FindFirstChild(eggNode.Name)
      if sv and sv:IsA("StringValue") and sv.Value~="" then add_keys(set, splitKeys(sv.Value)) end
      for _, ch in ipairs(f:GetChildren()) do
        if ch:IsA("BoolValue") and ch.Value==true then local k=normKey(ch.Name); if k and isBuffKey(k) then set[k]=true end end
      end
    end
  end
  for _, fname in ipairs(STR_FIELDS) do local v=findStringValue(eggNode,fname); if v and v~="" then add_keys(set, splitKeys(v)) end end
  for _, fname in ipairs(STR_FIELDS) do local v=findStringValue(dataRoot,fname); if v and v~="" then add_keys(set, splitKeys(v)) end end
  for _, owner in ipairs({eggNode,dataRoot}) do
    for _, aname in ipairs(STR_FIELDS) do local av=owner:GetAttribute(aname); if type(av)=="string" and av~="" then add_keys(set, splitKeys(av)) end end
  end
  local keys = {} for k in pairs(set) do keys[#keys+1]=k end table.sort(keys)
  return (#keys>0) and keys or { "none" }
end

local function readTypeAndMuts(dataRoot, eggNode)
  local attrs = eggNode:GetAttributes()
  local rawType = attrs.T or attrs.Type or eggNode.Name
  return normTypeName(rawType), rawType, resolveMutationsFromData(dataRoot, eggNode)
end

local function readCount(eggNode)
  for _, fname in ipairs(COUNT_FIELDS) do local nv=findNumberValue(eggNode,fname); if nv~=nil then return math.max(0, math.floor(nv)) end end
  for _, fname in ipairs(COUNT_FIELDS) do
    local av=eggNode:GetAttribute(fname)
    if type(av)=="number" then return math.max(0, math.floor(av)) end
    if type(av)=="string" then local n=tonumber(av); if n then return math.max(0, math.floor(n)) end end
  end
  return 1
end

-- ========== State ==========
local PREPARED, TYPE_INDEX, MUTS, CHILD_STATE = {}, {}, {}, {}
local TYPE_EGG_COUNT, DATA_ROOT, EGG_FOLDER = {}, nil, nil

local function ensureType(tKey, rawLabel)
  if not tKey then return nil end
  local idx = TYPE_INDEX[tKey]
  if not idx then
    idx = #PREPARED + 1
    TYPE_INDEX[tKey] = idx
    PREPARED[idx] = { label = rawLabel or tKey, tKey = tKey }
    MUTS[idx], TYPE_EGG_COUNT[idx] = {}, 0
  elseif PREPARED[idx].label == tKey and rawLabel and rawLabel~="" then
    PREPARED[idx].label = rawLabel
  end
  return idx
end

local function applyDelta(idx, mutKeys, delta)
  if not idx or not mutKeys then return end
  local m=MUTS[idx]
  for _,k in ipairs(mutKeys) do m[k]=(m[k] or 0)+delta; if m[k]==0 then m[k]=nil end end
end

local function attachChild(dataRoot, child)
  local tk, rawType, mKeys = readTypeAndMuts(dataRoot, child)
  local cnt = readCount(child)
  local idx = ensureType(tk, rawType)
  CHILD_STATE[child] = { tKey=tk, idx=idx, mutKeys=mKeys, count=cnt }
  applyDelta(idx, mKeys, cnt); TYPE_EGG_COUNT[idx]=(TYPE_EGG_COUNT[idx] or 0)+cnt
end

local function detachChild(child)
  local st=CHILD_STATE[child]; if not st then return end
  applyDelta(st.idx, st.mutKeys, -st.count)
  TYPE_EGG_COUNT[st.idx]=math.max(0,(TYPE_EGG_COUNT[st.idx] or 0)-st.count)
  CHILD_STATE[child]=nil
end

local function rescanAll()
  if not DATA_ROOT or not EGG_FOLDER then return end
  tclear(PREPARED); tclear(TYPE_INDEX); tclear(MUTS); tclear(TYPE_EGG_COUNT)
  for c in pairs(CHILD_STATE) do CHILD_STATE[c]=nil end
  for _,child in ipairs(EGG_FOLDER:GetChildren()) do attachChild(DATA_ROOT, child) end
end

local function looksLikeEggConfigNode(n)
  if not n or not n:IsA("Instance") then return false end
  local nm = tostring(n.Name or ""):lower()
  if nm:find("egg") then return true end
  local a = n:GetAttributes(); if a and (a.T or a.Type) then return true end
  for _, fname in ipairs(COUNT_FIELDS) do
    local nv=n:FindFirstChild(fname); if nv and nv:IsA("NumberValue") then return true end
    local av=n:GetAttribute(fname); if type(av)=="number" then return true end
  end
  return false
end

local function findEggFolder()
  if DATA_ROOT then
    local d = DATA_ROOT:FindFirstChild("Egg") or DATA_ROOT:FindFirstChild("Eggs")
    if d and d:IsA("Folder") then return d end
  end
  local root = LP:FindFirstChild("PlayerGui"); if not root then return nil end
  local best,bestScore=nil,0
  for _,d in ipairs(root:GetDescendants()) do
    if d and d:IsA("Folder") then
      local cnt=0; for _,ch in ipairs(d:GetChildren()) do if looksLikeEggConfigNode(ch) then cnt=cnt+1 end end
      if cnt>bestScore and cnt>=1 then best,bestScore=d,cnt end
    end
  end
  return best
end

local function sameSet(a,b)
  if #a~=#b then return false end
  local s={} for _,v in ipairs(a) do s[v]=(s[v] or 0)+1 end
  for _,v in ipairs(b) do if not s[v] then return false end s[v]=s[v]-1 if s[v]<0 then return false end end
  for _,n in pairs(s) do if n~=0 then return false end end
  return true
end

local function maybeUpdateChild(dataRoot, child)
  local old=CHILD_STATE[child]
  local tk, rawType, mKeys = readTypeAndMuts(dataRoot, child)
  local cnt = readCount(child)
  if not old then
    local idx=ensureType(tk, rawType)
    CHILD_STATE[child]={ tKey=tk, idx=idx, mutKeys=mKeys, count=cnt }
    applyDelta(idx, mKeys, cnt); TYPE_EGG_COUNT[idx]=(TYPE_EGG_COUNT[idx] or 0)+cnt
    return true
  end
  local typeChanged = (old.tKey~=tk)
  local mutsChanged = not sameSet(old.mutKeys, mKeys)
  local countChanged= (tonumber(old.count or 0) ~= tonumber(cnt or 0))
  if typeChanged or mutsChanged or countChanged then
    applyDelta(old.idx, old.mutKeys, -old.count)
    TYPE_EGG_COUNT[old.idx]=math.max(0,(TYPE_EGG_COUNT[old.idx] or 0)-old.count)
    local idx=ensureType(tk, rawType)
    old.tKey, old.idx, old.mutKeys, old.count = tk, idx, mKeys, cnt
    applyDelta(idx, mKeys, cnt); TYPE_EGG_COUNT[idx]=(TYPE_EGG_COUNT[idx] or 0)+cnt
    return true
  end
  return false
end

-- ========== Payload / digest ==========
local function toSummaryTable()
  local n=#PREPARED; local out=table.create(n)
  for i=1,n do
    local buffs={}; for k,v in pairs(MUTS[i] or {}) do buffs[k]=v end
    if next(buffs)==nil then buffs.none=1 end
    out[i]={ label=PREPARED[i].tKey, name=PREPARED[i].label, count=TYPE_EGG_COUNT[i] or 0, buffs=buffs }
  end
  return out
end

local function digestCounts()
  local parts={}
  for i=1,#PREPARED do
    local label=tostring(PREPARED[i].label); local cnt=tostring(TYPE_EGG_COUNT[i] or 0)
    local keys={} for k in pairs(MUTS[i] or {}) do keys[#keys+1]=k end; table.sort(keys)
    local kvs={} for _,k in ipairs(keys) do kvs[#kvs+1]=k.."="..tostring(MUTS[i][k]) end
    parts[#parts+1]=label.."#"..cnt..":"..table.concat(kvs,",")
  end
  return table.concat(parts,"|")
end

-- ========== Sender / presence ==========
local STOP_HEARTBEAT, SENT_OFFLINE = false, false
local lastDigest, lastSendAt = "", 0
local debounceFlag, scheduled = false, false

local function sendToApi(payloadTbl)
  if typeof(requestFn)~="function" then dlog("no requestFn"); return false,0 end
  local res; local ok=pcall(function()
    res = requestFn({
      Url = API_URL, Method="POST",
      Headers={ ["Content-Type"]="application/json", ["X-Auth-Token"]=AUTH_TOKEN },
      Body = HttpService:JSONEncode(payloadTbl),
    })
  end)
  local code = tonumber((res and (res.StatusCode or res.status)) or 0) or 0
  dlog("POST", API_URL, "status=", code)
  return ok and code>=200 and code<300, code
end

local function sendPresence(kind)
  local payload = {
    player={ userId=LP.UserId, name=LP.Name, displayName=LP.DisplayName },
    placeId=game.PlaceId, jobId=tostring(game.JobId or "N/A"),
    payload={ clientTime=now_unix(), period=0, reason="presence_"..tostring(kind),
              totals=toSummaryTable(), presence={ kind=kind, heartbeat=PERIOD_HEARTBEAT } }
  }
  pcall(function() sendToApi(payload) end)
end

local function markDisconnected(_reason)
  if SENT_OFFLINE then return end
  SENT_OFFLINE, STOP_HEARTBEAT = true, true
  pcall(function() sendPresence("offline") end)
end

local function buildAndMaybeSend(reason)
  if STOP_HEARTBEAT and reason=="heartbeat" then return end
  local t0 = now_clock(); local dt = t0 - lastSendAt
  if dt < MIN_SEND_INTERVAL then
    if not scheduled then
      scheduled = true
      delay((MIN_SEND_INTERVAL - dt) + rand(), function() scheduled=false; buildAndMaybeSend("rate_limit_flush") end)
    end
    return
  end
  local d = digestCounts()
  if d==lastDigest and reason~="heartbeat" then return end
  local payload = {
    player={ userId=LP.UserId, name=LP.Name, displayName=LP.DisplayName },
    placeId=game.PlaceId, jobId=tostring(game.JobId or "N/A"),
    payload={ clientTime=now_unix(), period=(reason=="heartbeat") and PERIOD_HEARTBEAT or 0,
              reason=reason, totals=toSummaryTable() }
  }
  local ok,code = sendToApi(payload)
  lastSendAt=t0; if ok then lastDigest=d else dlog("send failed",code) end
end

local function requestSend(reason)
  if debounceFlag then return end
  debounceFlag = true
  delay(DEBOUNCE_SEC + rand(), function() debounceFlag=false; buildAndMaybeSend(reason) end)
end

-- ========== 273 watcher / auto-leave ==========
local function _txt(o) local ok,v=pcall(function() return tostring(o.Text) end); return ok and (v or "") or "" end
local function _hasErr273Context(gui)
  local cur=gui
  while cur and cur~=CoreGui do
    if cur:IsA("TextLabel") or cur:IsA("TextBox") or cur:IsA("TextButton") then
      local t=s_lower(_txt(cur))
      if t:find("disconnected") or t:find("error code%:?%s*273") or t:find("same account launched experience") then return true end
    end
    cur=cur.Parent
  end
  return false
end
local function _clickButton(btn)
  if not (btn and btn:IsA("GuiButton")) then return end
  markDisconnected("ui_leave")
  local ok=false; if typeof(firesignal)=="function" then ok=pcall(firesignal, btn.MouseButton1Click) end
  if not ok then pcall(function() btn:Activate() end) end
  if VIM and btn.AbsoluteSize.X>0 and btn.AbsoluteSize.Y>0 then
    pcall(function()
      local pos=btn.AbsolutePosition + btn.AbsoluteSize/2
      VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, true, btn, 0)
      VIM:SendMouseButtonEvent(pos.X, pos.Y, 0, false, btn, 0)
    end)
  end
end
local function _tryFindAndLeave(root)
  for _,d in ipairs(root:GetDescendants()) do
    if d:IsA("TextButton") then
      local t=s_lower(_txt(d)):gsub("%s+","")
      if t=="leave" and _hasErr273Context(d) then _clickButton(d); return true end
    end
  end
  return false
end
task.defer(function() pcall(function() _tryFindAndLeave(CoreGui) end) end)
CoreGui.DescendantAdded:Connect(function(obj)
  if not obj:IsA("GuiObject") then return end
  pcall(function()
    if obj:IsA("TextLabel") or obj:IsA("TextBox") then
      local t=s_lower(_txt(obj))
      if t:find("disconnected") or t:find("error code%:?%s*273") or t:find("same account launched experience") then markDisconnected("ui_err") end
    end
  end)
  task.delay(0.05 + math.random()*0.05, function()
    pcall(function()
      if obj:IsA("TextButton") then local t=s_lower(_txt(obj)):gsub("%s+",""); if t=="leave" and _hasErr273Context(obj) then _clickButton(obj) end
      else _tryFindAndLeave(obj) end
    end)
  end)
end)

-- ========== Main ==========
spawn(function()
  ready(); math.randomseed(now_clock()*1e6 % 2^31)

  local pg   = LP:WaitForChild("PlayerGui")
  local data = pg:WaitForChild("Data"); DATA_ROOT = data

  local eggFolder = data:FindFirstChild("Egg")
  if not eggFolder or eggFolder.Parent~=data then eggFolder = findEggFolder() or Instance.new("Folder"); eggFolder.Name="Egg"; eggFolder.Parent=data end
  EGG_FOLDER = eggFolder

  -- initial scan
  tclear(PREPARED); tclear(TYPE_INDEX); tclear(MUTS); tclear(TYPE_EGG_COUNT)
  for c in pairs(CHILD_STATE) do CHILD_STATE[c]=nil end
  rescanAll()

  local function hookConfig(cfg)
    cfg:GetAttributeChangedSignal("T"):Connect(function() if maybeUpdateChild(data,cfg) then requestSend("attr_change") end end)
    cfg:GetAttributeChangedSignal("Type"):Connect(function() if maybeUpdateChild(data,cfg) then requestSend("attr_change") end end)
    cfg:GetAttributeChangedSignal("M"):Connect(function() if maybeUpdateChild(data,cfg) then requestSend("attr_change") end end)
    cfg:GetAttributeChangedSignal("Mutation"):Connect(function() if maybeUpdateChild(data,cfg) then requestSend("attr_change") end end)
    for _,fname in ipairs(COUNT_FIELDS) do
      cfg:GetAttributeChangedSignal(fname):Connect(function() if maybeUpdateChild(data,cfg) then requestSend("count_attr_change") end end)
    end
    local function bindNumWatcher(nv)
      if nv and nv:IsA("NumberValue") then
        for _,nm in ipairs(COUNT_FIELDS) do
          if nv.Name==nm then nv.Changed:Connect(function() if maybeUpdateChild(data,cfg) then requestSend("count_value_change") end end); break end
        end
      end
    end
    for _,ch in ipairs(cfg:GetChildren()) do bindNumWatcher(ch) end
    cfg.ChildAdded:Connect(bindNumWatcher)
  end

  for _,ch in ipairs(eggFolder:GetChildren()) do hookConfig(ch) end
  eggFolder.ChildAdded:Connect(function(c) attachChild(data,c); hookConfig(c); requestSend("child_added") end)
  eggFolder.ChildRemoved:Connect(function(c) detachChild(c); requestSend("child_removed") end)
  eggFolder.DescendantAdded:Connect(function(n) if looksLikeEggConfigNode(n) then task.delay(0.05,function() pcall(function() if not CHILD_STATE[n] then attachChild(data,n); hookConfig(n) end; if maybeUpdateChild(data,n) then requestSend("desc_added") end end) end) end end)
  eggFolder.DescendantRemoving:Connect(function(n) if CHILD_STATE[n] then detachChild(n); requestSend("desc_removed") end end)

  -- bootstrap + presence
  requestSend("bootstrap"); sendPresence("online")

  -- heartbeat
  spawn(function()
    while not STOP_HEARTBEAT do
      wait(PERIOD_HEARTBEAT + rand(2,6))
      if STOP_HEARTBEAT then break end
      pcall(rescanAll)      -- defensive refresh
      requestSend("heartbeat")
      sendPresence("ping")
    end
  end)

  -- teleport/offline hooks
  if TeleportService then pcall(function() TeleportService.TeleportInit:Connect(function() markDisconnected("teleport") end) end) end
  pcall(function() game:BindToClose(function() markDisconnected("bind_to_close"); task.wait(0.25) end) end)
end)
