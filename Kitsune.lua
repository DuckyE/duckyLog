-- ================== CONFIG ==================
local CFG = {
  MIN_PS             = "",       -- จะอ่านจาก KitsuneConfig.ProduceSpeed หรือ .MIN_PS ถ้าว่าง
  WEBHOOK_URL        = "",       -- จะอ่านจาก KitsuneConfig.WEBHOOK_URL ถ้าว่าง
  PLAYER_USERID      = {},       -- จะอ่านจาก KitsuneConfig.PLAYER_USERID ถ้าว่าง

  EXCLUDE_BIG        = true,
  MIN_DIST           = 8,
  CHECK_UI           = true,
  CHECK_TIMEOUT      = 2.0,
  YIELD_EVERY        = 75,
  RESCAN_SEC         = 5,
  MAX_RETRY_ONE      = 3,

  SELL_UNDER_MIN     = true,
  SELL_DELAY_MIN     = 1.5,
  SELL_DELAY_MAX     = 2.0,
  SELL_EXCLUDE_BIG   = true,

  STEP_ENABLED       = true,
  STEP_LOOP_SEC      = 1.5,
  STEP_DECLINE_BURST = 1000,
  STEP_YIELD_EVERY   = 300,

  DEDUP_TTL_SEC      = 300,
  RL_TOKENS_MAX      = 5,
  RL_WINDOW_SEC      = 2.0,
  RL_FALLBACK_429    = 2.0,
}
-- ============================================

-- Players / LP
local Players = game:GetService("Players")
local LP = Players.LocalPlayer
if not LP then Players:GetPropertyChangedSignal("LocalPlayer"):Wait(); LP = Players.LocalPlayer end

-- ===== Anti-AFK (ALWAYS ON) =====
do
  local vu = game:GetService("VirtualUser")
  LP.Idled:Connect(function()
    vu:CaptureController()
    vu:ClickButton2(Vector2.new())
  end)
end
-- =================================

-- ===== Utils =====
local function num(x)
  if typeof(x) == "number" then return x end
  if typeof(x) == "string" then
    local s = x:gsub(",", ""):gsub("%s+", "")
    return tonumber(s)
  end
end

local function parseIds(v)
  local out = {}
  if type(v) == "number" then
    out[v] = true
  elseif type(v) == "table" then
    for _, id in ipairs(v) do
      if type(id) == "number" then
        out[id] = true
      elseif type(id) == "string" then
        local n = tonumber(id:match("%d+")); if n then out[n] = true end
      end
    end
  elseif type(v) == "string" then
    for s in v:gmatch("%d+") do out[tonumber(s)] = true end
  end
  return out
end
-- ==================

-- ===== Load KitsuneConfig overrides =====
local G  = getgenv and getgenv() or {}
local KX = rawget(G, "KitsuneConfig")

local ALLOW_UIDS = {}
if type(KX) == "table" and KX.PLAYER_USERID ~= nil then
  ALLOW_UIDS = parseIds(KX.PLAYER_USERID)
else
  ALLOW_UIDS = parseIds(CFG.PLAYER_USERID)
end

-- ถ้า UID ของเราไม่อยู่ในลิสต์ -> หยุด worker (AFK ยังทำงาน)
if not ALLOW_UIDS[LP.UserId] then
  warn("[Kitsune] LocalPlayer ("..tostring(LP.UserId)..") not in PLAYER_USERID; abort worker (AFK still running).")
  return
end

local CFG_MIN_PS = 0
do
  local v
  if type(KX) == "table" then
    v = num(KX.ProduceSpeed or KX.MIN_PS)
    if type(KX.WEBHOOK_URL) == "string" and KX.WEBHOOK_URL ~= "" then
      CFG.WEBHOOK_URL = KX.WEBHOOK_URL
    end
  end
  if not v then v = num(CFG.MIN_PS) end
  CFG_MIN_PS = v or 0
end
print(("[CFG] ProduceSpeed(MIN_PS) = %d"):format(CFG_MIN_PS))
-- ==========================================

-- ===== Services / Handles =====
local RS        = game:GetService("ReplicatedStorage")
if not LP.Character then LP.CharacterAdded:Wait() end
local HRP       = LP.Character:WaitForChild("HumanoidRootPart",10); if not HRP then return end
local PlayerGui = LP:WaitForChild("PlayerGui",10); if not PlayerGui then return end
local Data      = PlayerGui:WaitForChild("Data",30); if not Data then return end
local PetsUI    = Data:WaitForChild("Pets",30); if not PetsUI then return end

local Remote      = RS:WaitForChild("Remote")
local CharacterRE = Remote:WaitForChild("CharacterRE")
local GiftRE      = Remote:WaitForChild("GiftRE")
local PetRE       = Remote:WaitForChild("PetRE")
local TradeRE     = Remote:WaitForChild("TradeRE")

-- ===== Discord queue + rate-limit =====
local function getRequester()
  return (syn and syn.request) or (http and http.request) or http_request or request
end
local HttpService do
  local ok, HS = pcall(game.GetService, game, "HttpService")
  if ok and HS then HttpService = HS end
end
local function jsonEncode(tbl)
  if HttpService then
    local ok, j = pcall(HttpService.JSONEncode, HttpService, tbl)
    if ok then return j end
  end
  local function esc(s) return tostring(s):gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') end
  local parts,first={"{"},true
  for k,v in pairs(tbl) do
    parts[#parts+1] = (first and "" or ",") .. '"'..esc(k)..'":' ..
      ((type(v)=="number") and tostring(v) or '"'..esc(v)..'"')
    first=false
  end
  parts[#parts+1]="}"
  return table.concat(parts)
end

local DCQ,qh,qt = {},1,0
local function qpush(job) qt = qt + 1; DCQ[qt] = job end
local function qpop()
  if qh > qt then return nil end
  local m = DCQ[qh]; DCQ[qh] = nil; qh = qh + 1; return m
end

local tokens      = CFG.RL_TOKENS_MAX or 5
local last_refill = tick()
local per_token   = (CFG.RL_WINDOW_SEC or 2.0)/(CFG.RL_TOKENS_MAX or 5)
local function refill_tokens()
  local now = tick()
  local add = math.floor((now - last_refill) / per_token)
  if add > 0 then
    tokens = math.min(CFG.RL_TOKENS_MAX or 5, tokens + add)
    last_refill = last_refill + add * per_token
  end
end
local function wait_token()
  while tokens < 1 do
    refill_tokens()
    task.wait(per_token/2)
  end
  tokens = tokens - 1
end

local sentUID = {}
local function dc_queue_payload(payload, dedupKey)
  if CFG.WEBHOOK_URL == "" then return end
  if dedupKey and dedupKey ~= "" then
    local now = tick()
    if sentUID[dedupKey] and (now - sentUID[dedupKey]) < (CFG.DEDUP_TTL_SEC or 300) then return end
    sentUID[dedupKey] = now
  end
  qpush({payload = payload})
end

local GREEN = 0x4ADE80
local function dc_log_gift(uid, petName, mutate, ps, recipient, recipientUid)
  petName  = tostring(petName or "Unknown")
  mutate   = tostring(mutate or "None")
  ps       = tostring(ps or "?")
  recipient= tostring(recipient or "?")
  local embed = {
    author = { name = LP.Name },
    title = "🎁 Gifted!",
    description = "Successfully gifted a pet.",
    color = GREEN,
    fields = {
      { name = "🖥️ Pet UID",       value = ("`%s`"):format(uid or "?"),  inline = false },
      { name = "🐾 Pet Name",       value = ("`%s`"):format(petName),     inline = true  },
      { name = "✨ Mutate",         value = ("`%s`"):format(mutate),      inline = true  },
      { name = "⚙ Produce Speed",  value = ("`%s`"):format(ps),          inline = true  },
      { name = "🎯 Gift To",        value = ("`%s`"):format(recipient),   inline = true  },
      { name = "🆔 Target UID",     value = ("`%s`"):format(recipientUid or "?"), inline = true },
    },
    footer = { text = "Build A Zoo • "..os.date("%d/%m/%Y %H:%M") },
  }
  dc_queue_payload({ embeds = { embed } }, uid or (petName..":"..mutate))
end

task.spawn(function()
  local req = getRequester(); if not req then return end
  while true do
    refill_tokens()
    local job = qpop()
    if not job then
      task.wait(0.05)
    else
      wait_token()
      local body = jsonEncode(job.payload or {content="(empty)"})
      local ok,res = pcall(function()
        return req({
          Url=CFG.WEBHOOK_URL, Method="POST",
          Headers={["Content-Type"]="application/json",["Content-Length"]=tostring(#body)},
          Body=body
        })
      end)
      local status  = (ok and res and res.StatusCode) or 0
      local headers = (ok and res and res.Headers) or {}
      if status == 429 then
        local ra = tonumber(headers["retry-after"]) or tonumber(headers["Retry-After"])
        local rs = tonumber(headers["x-ratelimit-reset-after"]) or tonumber(headers["X-RateLimit-Reset-After"])
        task.wait(ra or rs or CFG.RL_FALLBACK_429 or 2.0)
        qpush(job)
      elseif status >= 200 and status < 300 then
        local remain = tonumber(headers["x-ratelimit-remaining"]) or tonumber(headers["X-RateLimit-Remaining"])
        local resetA = tonumber(headers["x-ratelimit-reset-after"]) or tonumber(headers["X-RateLimit-Reset-After"])
        if remain and remain <= 0 and resetA then task.wait(resetA) else task.wait(0.02) end
      else
        task.wait(0.5); qpush(job)
      end
    end
  end
end)

-- ===== computePS (from game config) =====
local computePS
do
  local g = (getgenv and getgenv()) or {}
  if g.PS and type(g.PS.computePS)=="function" then
    computePS = g.PS.computePS
  else
    local Config = RS:FindFirstChild("Config") or RS:FindFirstChild("CONFIG") or RS:FindFirstChild("config")
    if not Config then
      for _,d in ipairs(RS:GetDescendants()) do if d.Name:lower()=="config" then Config=d break end end
    end
    if not Config then return end
    local RPet = Config:FindFirstChild("ResPet") or Config:FindFirstChild("Pets") or Config:FindFirstChild("RES_PET")
    local RMut = Config:FindFirstChild("ResMutate") or Config:FindFirstChild("Mutate") or Config:FindFirstChild("RES_MUTATE")
    if not RPet or not RMut then return end
    local function map(raw)
      if raw:IsA("ModuleScript") then
        local ok,t = pcall(require,raw); if ok and type(t)=="table" then return t end
        return {}
      end
      local m={}; for _,c in ipairs(raw:GetChildren()) do m[c.Name]=c end; return m
    end
    local PetMap,MutMap = map(RPet),map(RMut)
    local function toNum(x)
      if typeof(x)=="number" then return x end
      if typeof(x)=="string" then return tonumber((x:gsub(",", ""):gsub("%s+",""))) end
    end
    local function rate(e)
      local t=typeof(e)
      if t=="number" or t=="string" then return toNum(e)
      elseif t=="Instance" then
        local a=e:GetAttribute("ProduceRate"); if a~=nil then return toNum(a) end
        local nv=e:FindFirstChild("ProduceRate"); if nv and nv:IsA("NumberValue") then return toNum(nv.Value) end
      elseif t=="table" then
        local v=e.ProduceRate or e.produce_rate or e.rate or e.Produce or e.Produce_Speed
        if v~=nil then return toNum(v) end
      end
    end
    local function norm(s) return (tostring(s or ""):lower():gsub("[%s%-%_%,%.]","")) end
    local function keyOf(m,k)
      local want=norm(k or "")
      for real,_ in pairs(m) do
        local nk=norm(real)
        if nk==want or nk:find(want,1,true) or want:find(nk,1,true) then return real end
      end
    end
    computePS=function(T,M)
      local p=PetMap[keyOf(PetMap,T)]; local pr=p and rate(p); if not pr then return nil end
      local mr=1
      if M and tostring(M)~="" and tostring(M):lower()~="none" then
        local m=MutMap[keyOf(MutMap,M)]; mr=(m and rate(m)) or 1
      end
      return pr*mr
    end
  end
end

-- ===== helpers =====
local function isBig(node) return (node:GetAttribute("BigPetType") ~= nil) or (node:GetAttribute("BigValue") ~= nil) end
local function uidOf(node) local u=node:GetAttribute("UID") or node:GetAttribute("Id") or node:GetAttribute("ID"); return (typeof(u)=="string" and u~="") and u or node.Name end

-- ===== target: pick only players NOT in ALLOW_UIDS (and not self) =====
local function resolveTarget()
  for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= LP and not ALLOW_UIDS[plr.UserId] then
      return plr
    end
  end
  return nil
end

local function ensureNear(t)
  local LPc=LP and LP.Character; if not (LPc and t and t.Character) then return false end
  local thrp=t.Character:FindFirstChild("HumanoidRootPart"); if not thrp then return false end
  local hrp=LPc:FindFirstChild("HumanoidRootPart"); if not hrp then return false end
  if (hrp.Position-thrp.Position).Magnitude>(CFG.MIN_DIST or 8) then
    pcall(function() hrp.CFrame = thrp.CFrame + Vector3.new(0,3,0) end)
  end
  return true
end
local function holdPet(id)
  pcall(function() CharacterRE:FireServer("Focus", id) end)
  pcall(function() CharacterRE:FireServer("Equip", id) end)
  pcall(function() CharacterRE:FireServer("Hold", id) end)
end
local function tryGift(t,id)
  return pcall(function() GiftRE:FireServer(t) end)
      or pcall(function() GiftRE:FireServer({player=t}) end)
      or pcall(function() GiftRE:FireServer(t,id) end)
      or pcall(function() GiftRE:FireServer({target=t,id=id}) end)
end

-- ===== gift queue =====
local GQ,gset,tries={}, {}, {}
local gh,gt=1,0
local function gpush(id,node) if gset[id] then return end gt = gt + 1; GQ[gt] = {id=id,node=node}; gset[id]=true end
local function gpop() if gh>gt then return nil end local e=GQ[gh]; GQ[gh]=nil; gh = gh + 1; return e end
local function gsize() return (gt-gh+1) end

-- ===== sell scheduler =====
local sellPlan={}
task.spawn(function()
  while true do
    task.wait(0.25)
    local now=tick()
    for uid,plan in pairs(sellPlan) do
      if now>=plan.t then
        if plan.node and plan.node.Parent==PetsUI then
          local ps = nil
          if type(passPS) == "function" then
            ps = select(1, passPS(plan.node))
          end
          local doSell = false
          if type(ps) == "number" then
            local ps_cmp = math.floor(ps + 0.5)
            if (CFG.SELL_UNDER_MIN and ps_cmp < CFG_MIN_PS) then
              doSell = true
            end
          end
          if doSell then
            pcall(function() PetRE:FireServer("Sell", uid) end)
          else
            gpush(uid, plan.node)
          end
        end
        sellPlan[uid]=nil
      end
    end
  end
end)
local function scheduleSell(node)
  if CFG.SELL_EXCLUDE_BIG and isBig(node) then return end
  local uid=uidOf(node); if not uid or sellPlan[uid] then return end
  local dmin,dmax=CFG.SELL_DELAY_MIN or 1, CFG.SELL_DELAY_MAX or 2
  local delay=math.random(math.floor(dmin*1000), math.floor(dmax*1000))/1000
  sellPlan[uid]={t=tick()+delay,node=node}
end

-- ===== decision =====
local function passPS(node)
  local T=node:GetAttribute("PetID") or node:GetAttribute("PetName") or node:GetAttribute("T") or node.Name
  local M=node:GetAttribute("MutateName") or node:GetAttribute("Mutate") or node:GetAttribute("M")
  local ps=computePS and computePS(T,M) or nil
  return ps,T,M
end
local function stillOwned(entry)
  local n=entry.node
  if not n or n.Parent~=PetsUI then return false end
  local owner=n:GetAttribute("UserId") or n:GetAttribute("OwnerUserId")
  return (owner==nil) or (owner==LP.UserId)
end

local function evalNode(node)
  if not node then return end
  if CFG.EXCLUDE_BIG and isBig(node) then return end

  local ps, T, M = passPS(node)
  if typeof(ps) ~= "number" then return end

  local ps_cmp = math.floor(ps + 0.5)
  local minps  = CFG_MIN_PS

  if CFG.SELL_UNDER_MIN and (ps_cmp < minps) then
    scheduleSell(node)
  else
    gpush(uidOf(node), node)
  end
end

-- ===== worker =====
local target=nil
local static_running=false
local function worker()
  if static_running then return end
  static_running=true

  target=resolveTarget()
  if not target then
    static_running=false
    return
  end

  ensureNear(target)
  local step=0
  while gsize()>0 do
    local t2 = resolveTarget()
    if not t2 then break end
    if t2 ~= target then target = t2 end
    ensureNear(target)

    local e=gpop(); if not e then break end
    local id,node=e.id,e.node
    gset[id]=nil
    local ps,T,M=passPS(node)
    holdPet(id)
    local ok=tryGift(target,id)
    if CFG.CHECK_UI then
      local t0=tick()
      while stillOwned(e) and (tick()-t0)<(CFG.CHECK_TIMEOUT or 2) do task.wait(0) end
    end
    if ok and not stillOwned(e) then
      tries[id]=0
      dc_log_gift(tostring(id), tostring(T or "Pet"), tostring(M or "None"), math.floor(ps or 0), target.Name, target.UserId)
    else
      local ntry=(tries[id] or 0)+1; tries[id]=ntry
      if ntry < (CFG.MAX_RETRY_ONE or 3) then gpush(id,node) end
    end
    step = step + 1
    if step%(CFG.YIELD_EVERY or 75)==0 then task.wait() end
  end
  static_running=false
end

-- ===== bootstrap + watchers =====
for _,n in ipairs(PetsUI:GetChildren()) do evalNode(n) end
if gsize()>0 then task.defer(worker) end

PetsUI.ChildAdded:Connect(function(n)
  task.wait(0.05)
  for _,a in ipairs({"PetID","PetName","T","MutateName","Mutate","M","BigPetType","BigValue","UserId","OwnerUserId"}) do
    n:GetAttributeChangedSignal(a):Connect(function()
      evalNode(n); if gsize()>0 then task.defer(worker) end
    end)
  end
  evalNode(n); if gsize()>0 then task.defer(worker) end
end)

-- รีเฟรชเป้าหมายเมื่อผู้เล่นเข้า/ออก
Players.PlayerAdded:Connect(function()
  if gsize()>0 then task.defer(worker) end
end)
Players.PlayerRemoving:Connect(function()
  if gsize()>0 then task.defer(worker) end
end)

task.spawn(function()
  while true do
    task.wait(CFG.RESCAN_SEC or 5)
    for _,n in ipairs(PetsUI:GetChildren()) do evalNode(n) end
    if gsize()>0 then task.defer(worker) end
  end
end)

-- ===== Step Runner =====
local function runStepOnce()
  if not TradeRE then return end
  local decline={{event="decline"}}
  local burst, every = CFG.STEP_DECLINE_BURST or 1000, CFG.STEP_YIELD_EVERY or 300
  for i=1,burst do
    pcall(function() TradeRE:FireServer(unpack(decline)) end)
    if i%every==0 then task.wait() end
  end
  local claim={{event="claimreward"}}
  pcall(function() TradeRE:FireServer(unpack(claim)) end)
  pcall(function() TradeRE:FireServer(unpack(claim)) end)
end
if CFG.STEP_ENABLED and TradeRE then
  task.spawn(function()
    while true do runStepOnce(); task.wait(CFG.STEP_LOOP_SEC or 3) end
  end)
end
