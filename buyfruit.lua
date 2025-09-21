local SELECTED_FRUITS = {
  Strawberry=false, Blueberry=false, Watermelon=false, Apple=true, Orange=false,
  Corn=false, Banana=false, Grape=false, Pear=false, Pineapple=false,
  GoldMango=true, BloodstoneCycad=true, ColossalPinecone=true, VoltGinkgo=true,
  DeepseaPearlFruit=true,
}
local SELECTED_BY_NAME = { "Gold Mango","Bloodstone Cycad","Colossal Pinecone","Volt Ginkgo","Deepsea Pearl Fruit" }

local BUDGET_PER_TICK = 50_000_000
local MAX_PER_FRUIT_PER_TICK = 1

local VERBOSE = true
local PURCHASE_TOAST = true
local SEND_TO_DISCORD = true
local WEBHOOK_URL = "https://discord.com/api/webhooks/1419111758051672236/-UtONg5EotVTM2RusXQ5RH5drjJzvt4NwcfmKYaIp6jhKKMMNpewS00aStGiJCa_7P9D"

local FRUIT_DATA = {
  Strawberry={Price="5,000"}, Blueberry={Price="20,000"}, Watermelon={Price="80,000"},
  Apple={Price="400,000"}, Orange={Price="1,200,000"}, Corn={Price="3,500,000"},
  Banana={Price="12,000,000"}, Grape={Price="50,000,000"}, Pear={Price="200,000,000"},
  Pineapple={Price="600,000,000"}, GoldMango={Price="2,000,000,000"},
  BloodstoneCycad={Price="8,000,000,000"}, ColossalPinecone={Price="40,000,000,000"},
  VoltGinkgo={Price="80,000,000,000"}, DeepseaPearlFruit={Price="40,000,000,000"},
}

local FRUIT_EMOJI = {
  Strawberry="🍓", Blueberry="🫐", Watermelon="🍉", Apple="🍎", Orange="🍊",
  Corn="🌽", Banana="🍌", Grape="🍇", Pear="🍐", Pineapple="🍍",
  GoldMango="🥭", BloodstoneCycad="🌿", ColossalPinecone="🌲", VoltGinkgo="⚡",
  DeepseaPearlFruit="🦪"
}
local FRUIT_LABEL = { DeepseaPearlFruit="Deepsea Pearl Fruit" }
local function labelOf(id) return FRUIT_LABEL[id] or id end
local function fruitIcon(id) return FRUIT_EMOJI[id] or "" end

local Players=game:GetService("Players")
local RS=game:GetService("ReplicatedStorage")
local StarterGui=game:GetService("StarterGui")
local HttpService=game:GetService("HttpService")
local LP=Players.LocalPlayer

local function parsePrice(p) if type(p)=="number" then return p end local s=type(p)=="string" and p or "0"; s=s:gsub(",",""):gsub("%s+",""); return tonumber(s) or 0 end
local function comma(n) n=tonumber(n) or 0; local s=tostring(math.floor(n)); local k repeat s,k=s:gsub("^(-?%d+)(%d%d%d)","%1,%2") until k==0; return s end
local function toast(t,txt,d) if not VERBOSE then return end pcall(function() StarterGui:SetCore("SendNotification",{Title=t,Text=txt,Duration=d or 2}) end) end
local function getNetWorth() local a=LP:GetAttribute("NetWorth"); if type(a)=="number" then return a end local ls=LP:FindFirstChild("leaderstats"); local v=ls and ls:FindFirstChild("NetWorth"); return (v and type(v.Value)=="number") and v.Value or 0 end

local function findStoreData()
  local cands={{"Data","FoodStore"},{"GameData","FoodStore"},{"Configs","FoodStore"},{"Shop","FoodStore"},{"FoodStore"}}
  for _,path in ipairs(cands) do
    local node=RS; local ok=true
    for _,name in ipairs(path) do node=node:FindFirstChild(name); if not node then ok=false break end end
    if ok then return node end
  end
end
local function findRemotes()
  local f=RS:FindFirstChild("Remote") or RS
  return f:FindFirstChild("FoodStoreRE") or f:FindFirstChild("ShopRE") or f:FindFirstChild("BuyRE"),
         f:FindFirstChild("FoodStoreRF") or f:FindFirstChild("ShopRF") or f:FindFirstChild("StoreRF")
end
local STORE_DATA=findStoreData()
local BUY_RE,INFO_RF=findRemotes()

local NAME_TO_ID,ID_TO_NAME,PRICE_MAP,STOCK_MAP={},{},{},{}
local function harvestFromData()
  if not STORE_DATA then return end
  for _,ch in ipairs(STORE_DATA:GetChildren()) do
    local id=ch.Name
    local pretty=ch:GetAttribute("Label") or ch:GetAttribute("Name")
    if not pretty then local sv=ch:FindFirstChild("Name") or ch:FindFirstChild("Label"); if sv and sv:IsA("StringValue") then pretty=sv.Value end end
    pretty=pretty or id; ID_TO_NAME[id]=pretty; NAME_TO_ID[pretty]=id; NAME_TO_ID[pretty:lower()]=id
    local price=ch:GetAttribute("Price") or ch:GetAttribute("price"); local pv=ch:FindFirstChild("Price"); if not price and pv and (pv:IsA("NumberValue") or pv:IsA("IntValue") or pv:IsA("StringValue")) then price=pv.Value end
    if not price and ch:IsA("ModuleScript") then local ok,t=pcall(require,ch); if ok and type(t)=="table" then price=t.Price or t.price end end
    if price then PRICE_MAP[id]=parsePrice(price) end
    local stock=ch:GetAttribute("Stock") or ch:GetAttribute("Quantity"); local sv2=ch:FindFirstChild("Stock") or ch:FindFirstChild("Quantity"); if not stock and sv2 and (sv2:IsA("NumberValue") or sv2:IsA("IntValue") or sv2:IsA("StringValue")) then stock=sv2.Value end
    if stock~=nil then STOCK_MAP[id]=tonumber(stock) or 0 end
  end
  local prices=STORE_DATA:FindFirstChild("Prices"); if prices and prices:IsA("ModuleScript") then local ok,t=pcall(require,prices); if ok and type(t)=="table" then for id,v in pairs(t) do if type(v)=="table" then v=v.Price or v.price end; if PRICE_MAP[id]==nil then PRICE_MAP[id]=parsePrice(v) end end end end
end
local function harvestFromRemote()
  if not (INFO_RF and INFO_RF:IsA("RemoteFunction")) then return end
  local tries={function() return INFO_RF:InvokeServer("List") end,function() return INFO_RF:InvokeServer("GetAll") end,function() return INFO_RF:InvokeServer({action="List"}) end}
  for _,fn in ipairs(tries) do
    local ok,ret=pcall(fn)
    if ok and type(ret)=="table" then
      if #ret>0 then
        for _,row in ipairs(ret) do
          local id=row.Id or row.id or (row.Name and tostring(row.Name):gsub("%s+",""))
          if id then
            if row.Name then ID_TO_NAME[id]=tostring(row.Name); NAME_TO_ID[tostring(row.Name)]=id; NAME_TO_ID[tostring(row.Name):lower()]=id end
            if row.Price or row.price then PRICE_MAP[id]=parsePrice(row.Price or row.price) end
            if row.Stock or row.stock or row.Qty or row.qty then STOCK_MAP[id]=tonumber(row.Stock or row.stock or row.Qty or row.qty) or 0 end
          end
        end
      else
        for id,row in pairs(ret) do
          if type(row)=="table" then
            if row.Name then ID_TO_NAME[id]=tostring(row.Name); NAME_TO_ID[tostring(row.Name)]=id; NAME_TO_ID[tostring(row.Name):lower()]=id end
            if row.Price or row.price then PRICE_MAP[id]=parsePrice(row.Price or row.price) end
            if row.Stock or row.stock or row.Qty or row.qty then STOCK_MAP[id]=tonumber(row.Stock or row.stock or row.Qty or row.qty) or 0 end
          elseif type(row)=="number" then PRICE_MAP[id]=row end
        end
      end
      break
    end
  end
end
local function refreshStoreMaps() harvestFromData(); harvestFromRemote() end
local function mergeSelectionsFromPretty() for _,pretty in ipairs(SELECTED_BY_NAME) do local id=NAME_TO_ID[pretty] or NAME_TO_ID[pretty:lower()] or pretty:gsub("%s+",""); if id then SELECTED_FRUITS[id]=true end end end
local function getFruitPrice(id) if PRICE_MAP[id] then return PRICE_MAP[id] end local meta=FRUIT_DATA[id]; return meta and parsePrice(meta.Price) or 0 end

local function getStockNow(id)
  if type(STOCK_MAP[id])=="number" then return STOCK_MAP[id] end
  local f=RS:FindFirstChild("Remote") or RS; local rf=f:FindFirstChild("FoodStoreRF") or f:FindFirstChild("ShopRF") or f:FindFirstChild("StoreRF")
  if rf and rf:IsA("RemoteFunction") then
    local calls={function() return rf:InvokeServer("GetStock",id) end,function() return rf:InvokeServer({action="GetStock",id=id}) end,function() return rf:InvokeServer("StockOf",id) end}
    for _,fn in ipairs(calls) do local ok,ret=pcall(fn); if ok and tonumber(ret) then return tonumber(ret) end end
  end
  return nil
end
local function fruitInStock(id) local q=STOCK_MAP[id]; if type(q)=="number" then return q>0 end local n=getStockNow(id); if type(n)=="number" then return n>0 end return true end

local function findRE() local re,rf=findRemotes(); if re then BUY_RE=re end; if rf then INFO_RF=rf end end
local function tryFireBuy(id)
  findRE(); if not (BUY_RE and BUY_RE:IsA("RemoteEvent")) then return false,"no-remote" end
  local ok=pcall(function() BUY_RE:FireServer(id) end); if ok then return true end
  ok=pcall(function() BUY_RE:FireServer("Buy",id,1) end); if ok then return true end
  ok=pcall(function() BUY_RE:FireServer({id=id,amount=1}) end); if ok then return true end
  ok=pcall(function() BUY_RE:FireServer({Item=id,Count=1}) end); if ok then return true end
  return false,"wrong-args"
end

local AFTER_FIRE_PAUSE=0.30
local VERIFY_WINDOW=3.0
local POLL_STEP=0.12
local POST_LOG_DELAY=0.20
local BETWEEN_PURCHASE_DELAY=0.25
local BETWEEN_ITEMS_DELAY=0.15

-- ตอนยืนยันสำเร็จ ยังตรวจจาก NetWorth/Stock แต่ไม่คืนค่าจำนวนเงินอีกต่อไป
local function purchaseOnce(id, price)
  local beforeNW=getNetWorth()
  local beforeQty=getStockNow(id)
  local fired=tryFireBuy(id); if not fired then return false end
  task.wait(AFTER_FIRE_PAUSE)
  local t0=os.clock()
  repeat
    task.wait(POLL_STEP)
    local nw=getNetWorth()
    if nw < beforeNW - math.max(1, math.floor(price*0.95)) then return true end
    local q=getStockNow(id)
    if type(q)=="number" and type(beforeQty)=="number" and q < beforeQty then return true end
  until os.clock()-t0>VERIFY_WINDOW
  return false
end

local function reqFn() return (syn and syn.request) or request or http_request or (fluxus and fluxus.request) or (krnl and krnl.request) or (http and http.request) end
local function sendPurchaseCard(id, price)
  if not SEND_TO_DISCORD or WEBHOOK_URL=="" then return end
  local r=reqFn(); if not r then return end
  local who=(LP and ((LP.DisplayName~="" and LP.DisplayName) or LP.Name)) or "Player"
  local pretty=ID_TO_NAME[id] or labelOf(id)
  local embed={author={name=who},title="🛍️ Fruit Purchased!",color=0x2ECC71,fields={{name="👤 Player",value="`"..who.."`",inline=true},{name="🍎 Fruit",value="`"..fruitIcon(id).." "..pretty.."`",inline=true},{name="🪙 Price",value="`฿"..comma(price).."`",inline=true}},footer={text="Auto Buy Fruit"}}
  pcall(function() r({Url=WEBHOOK_URL,Method="POST",Headers={["Content-Type"]="application/json"},Body=HttpService:JSONEncode({embeds={embed}})}) end)
end

local REFRESH_PERIOD=300
local FAST_WINDOW=25
local NEAR_WINDOW=40
local FAST_DELAY=0.35
local MID_DELAY=1.00
local SLOW_DELAY=3.00
local function getRefreshETA()
  local f=RS:FindFirstChild("Remote") or RS; local rf=f:FindFirstChild("FoodStoreRF") or f:FindFirstChild("ShopRF") or f:FindFirstChild("StoreRF")
  if rf and rf:IsA("RemoteFunction") then
    local calls={function() return rf:InvokeServer("GetRefreshETA") end,function() return rf:InvokeServer("NextRefresh") end,function() return rf:InvokeServer({action="GetRefresh"}) end}
    for _,fn in ipairs(calls) do local ok,ret=pcall(fn); if ok and tonumber(ret) then return math.max(0, math.floor(ret)) end end
  end
  local d=STORE_DATA; if d then local a=d:GetAttribute("RefreshETA") or d:GetAttribute("NextRefresh") or d:GetAttribute("RefreshIn"); if tonumber(a) then return math.max(0, math.floor(a)) end
    local v=d:FindFirstChild("RefreshETA") or d:FindFirstChild("NextRefresh") or d:FindFirstChild("RefreshIn"); if v and (v:IsA("NumberValue") or v:IsA("IntValue") or v:IsA("StringValue")) then local n=tonumber(v.Value); if n then return math.max(0, math.floor(n)) end end end
  return nil
end
local lastRefreshT=os.clock()
local function markPossiblyRefreshed() lastRefreshT=os.clock() end
local function currentDelay()
  local eta=getRefreshETA()
  if eta then
    if eta<=NEAR_WINDOW or eta>=(REFRESH_PERIOD-FAST_WINDOW) then return FAST_DELAY
    elseif eta>120 then return SLOW_DELAY else return MID_DELAY end
  else
    local dt=os.clock()-lastRefreshT
    if dt<=FAST_WINDOW then return FAST_DELAY end
    if dt<=120 then return MID_DELAY end
    return SLOW_DELAY
  end
end

refreshStoreMaps()
mergeSelectionsFromPretty()

local RUNNING=true
task.spawn(function()
  while RUNNING do
    local oldStock={} for k,v in pairs(STOCK_MAP) do oldStock[k]=v end
    refreshStoreMaps()
    local refreshed=false
    for id,newq in pairs(STOCK_MAP) do local before=tonumber(oldStock[id] or 0) or 0; if tonumber(newq or 0) and (newq or 0)>before then refreshed=true break end end
    if refreshed then markPossiblyRefreshed() end

    local budget=BUDGET_PER_TICK
    local net=getNetWorth()

    local wanted={}
    for id,on in pairs(SELECTED_FRUITS) do if on then table.insert(wanted,{id=id,price=getFruitPrice(id)}) end end
    table.sort(wanted,function(a,b) return a.price<b.price end)

    for _,it in ipairs(wanted) do
      if budget<=0 then break end
      if it.price<=0 or net<it.price or not fruitInStock(it.id) then task.wait(BETWEEN_ITEMS_DELAY) continue end
      local bought=0
      while bought<MAX_PER_FRUIT_PER_TICK and budget>=it.price and net>=it.price do
        local ok=purchaseOnce(it.id,it.price)
        if not ok then break end
        bought=bought+1
        budget = budget - it.price   -- ใช้ “ราคาไอเท็ม” เสมอ
        net    = net    - it.price
        if PURCHASE_TOAST then toast("✅ ซื้อสำเร็จ",(ID_TO_NAME[it.id] or labelOf(it.id)).." ฿"..comma(it.price),1.8) end
        sendPurchaseCard(it.id,it.price)  -- log เป็นราคาไอเท็ม
        if type(STOCK_MAP[it.id])=="number" then STOCK_MAP[it.id]=math.max(0,(STOCK_MAP[it.id] or 1)-1) end
        refreshStoreMaps()
        task.wait(BETWEEN_PURCHASE_DELAY)
      end
      task.wait(BETWEEN_ITEMS_DELAY)
    end
    task.wait(currentDelay())
  end
end)

_G.StopAutoBuyFruit=function() RUNNING=false end
