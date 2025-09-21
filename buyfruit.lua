local SELECTED_FRUITS = {
    Strawberry=false, Blueberry=false, Watermelon=false, Apple=false, Orange=false,
    Corn=false, Banana=false, Grape=false, Pear=false, Pineapple=false,
    GoldMango=true, BloodstoneCycad=true, ColossalPinecone=true, VoltGinkgo=true,
    DeepseaPearlFruit=true,
}

local BUDGET_PER_TICK = 50000000
local TICK_EVERY = 1.0
local MAX_PER_FRUIT_PER_TICK = 1

local VERBOSE, START_STOP_TOAST, PURCHASE_TOAST = true, true, true
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
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local StarterGui=game:GetService("StarterGui")
local HttpService=game:GetService("HttpService")
local LocalPlayer=Players.LocalPlayer

local function parsePrice(p) if type(p)=="number" then return p end local s=type(p)=="string" and p or "0"; s=s:gsub(",",""):gsub("%s+",""); return tonumber(s) or 0 end
local function comma(n) n=tonumber(n) or 0; local s=tostring(math.floor(n)); local k repeat s,k=s:gsub("^(-?%d+)(%d%d%d)","%1,%2") until k==0; return s end
local function notify(title,text,d) pcall(function() StarterGui:SetCore("SendNotification",{Title=tostring(title),Text=tostring(text),Duration=d or 3}) end) local line=("[AutoBuyFruit] %s - %s"):format(title,text); if rconsoleprint then rconsoleprint(line.."\n") else print(line) end end
local function getNetWorth() local lp=LocalPlayer; if not lp then return 0 end local a=lp:GetAttribute("NetWorth"); if type(a)=="number" then return a end local ls=lp:FindFirstChild("leaderstats"); local v=ls and ls:FindFirstChild("NetWorth"); return (v and type(v.Value)=="number") and v.Value or 0 end

local function findStoreData()
    local cands={{"Data","FoodStore"},{"GameData","FoodStore"},{"Configs","FoodStore"},{"Shop","FoodStore"},{"FoodStore"}}
    for _,path in ipairs(cands) do
        local node=ReplicatedStorage
        local ok=true
        for _,name in ipairs(path) do node=node:FindFirstChild(name); if not node then ok=false break end end
        if ok then return node end
    end
    return nil
end
local STORE_DATA=findStoreData()

local function getFruitPrice(fruitId)
    local function n(v) if type(v)=="number" then return v end if type(v)=="string" then return parsePrice(v) end return 0 end
    if STORE_DATA then
        local a=STORE_DATA:GetAttribute("Price_"..fruitId) or STORE_DATA:GetAttribute(fruitId.."_Price"); if type(a)=="number" then return a end
        local node=STORE_DATA:FindFirstChild(fruitId)
        if node then
            local nv=node:FindFirstChild("Price"); if nv and (nv:IsA("NumberValue") or nv:IsA("IntValue")) then return n(nv.Value) end
            local pa=node:GetAttribute("Price") or node:GetAttribute("price"); if type(pa)=="number" then return pa end
            if node:IsA("ModuleScript") then local ok,t=pcall(require,node); if ok and type(t)=="table" then return n(t.Price or t.price) end end
        end
        local prices=STORE_DATA:FindFirstChild("Prices")
        if prices and prices:IsA("ModuleScript") then local ok,t=pcall(require,prices); if ok and type(t)=="table" then local v=t[fruitId]; if type(v)=="table" then v=v.Price or v.price end; return n(v) end end
    end
    local meta=FRUIT_DATA[fruitId]; return meta and n(meta.Price) or 0
end

local function getFoodStoreLST()
    local pg=LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui"); if not pg then return nil end
    local data=pg:FindFirstChild("Data"); if not data then return nil end
    local store=data:FindFirstChild("FoodStore"); if not store then return nil end
    return store:FindFirstChild("LST")
end

local function fruitInStock(fruitId)
    if STORE_DATA then
        local keys={"Stock_"..fruitId,fruitId.."_Stock","Available_"..fruitId,fruitId.."_Available",fruitId.."_Qty","Qty_"..fruitId}
        for _,k in ipairs(keys) do local a=STORE_DATA:GetAttribute(k); if type(a)=="number" and a>0 then return true end end
        local node=STORE_DATA:FindFirstChild(fruitId)
        if node then
            local sv=node:FindFirstChild("Stock") or node:FindFirstChild("Quantity"); if sv and (sv:IsA("NumberValue") or sv:IsA("IntValue")) then return (tonumber(sv.Value) or 0)>0 end
            local sa=node:GetAttribute("Stock") or node:GetAttribute("Quantity"); if type(sa)=="number" and sa>0 then return true end
        end
        local rf=ReplicatedStorage:FindFirstChild("Remote"); rf=rf and rf:FindFirstChild("FoodStoreRF")
        if rf and rf:IsA("RemoteFunction") then local ok,has=pcall(function() return rf:InvokeServer("GetStock",fruitId) end); if ok and has then return true end end
    end
    local lst=getFoodStoreLST(); if not lst then return false end
    local id=fruitId; local spaced=id:gsub("(%l)(%u)","%1 %2"):gsub("(%u)(%u%l)","%1 %2"); local under=spaced:gsub("%s+","_")
    local keys={id,id:lower(),id:upper(),under,under:lower(),spaced,spaced:lower(),spaced:gsub("%s+","")}
    for _,k in ipairs(keys) do
        local a=lst:GetAttribute(k); if type(a)=="number" and a>0 then return true end
        local lbl=lst:FindFirstChild(k); if lbl and lbl:IsA("TextLabel") then local num=tonumber((lbl.Text or ""):match("%d+")); if num and num>0 then return true end end
    end
    return false
end

local function fireBuyFruit(fruitId)
    local ok,err=pcall(function() ReplicatedStorage:WaitForChild("Remote"):WaitForChild("FoodStoreRE"):FireServer(fruitId) end)
    return ok,err
end

local function getRequestFunc() return (syn and syn.request) or request or http_request or (fluxus and fluxus.request) or (krnl and krnl.request) or (http and http.request) end
local function sendDiscord(payload) if not SEND_TO_DISCORD or WEBHOOK_URL=="" then return end local req=getRequestFunc(); if not req then return end pcall(function() req({Url=WEBHOOK_URL,Method="POST",Headers={["Content-Type"]="application/json"},Body=HttpService:JSONEncode(payload)}) end) end
local function sendPurchaseCard(id, price)
    local player=(LocalPlayer and (LocalPlayer.DisplayName~="" and LocalPlayer.DisplayName or LocalPlayer.Name)) or "Player"
    local embed={author={name=player},title="🛍️ Fruit Purchased!",color=0x2ECC71,fields={{name="👤 Player",value="`"..player.."`",inline=true},{name="🍎 Fruit",value="`"..fruitIcon(id).." "..labelOf(id).."`",inline=true},{name="🪙 Price",value="`฿"..comma(price).."`",inline=true}},footer={text="Auto Buy Fruit"}}
    sendDiscord({embeds={embed}})
end

local RUNNING=true
if START_STOP_TOAST then notify("🍎 Auto Buy Fruit","🟢 เริ่มทำงานแล้ว ✅",3) end
print("[AutoBuyFruit] started. Call _G.StopAutoBuyFruit() to stop.")

task.spawn(function()
    while RUNNING do
        local budgetLeft=BUDGET_PER_TICK
        local netWorth=getNetWorth()

        local wanted={}
        for id,on in pairs(SELECTED_FRUITS) do
            if on then table.insert(wanted,{id=id,price=getFruitPrice(id)}) end
        end
        table.sort(wanted,function(a,b) return a.price<b.price end)

        for _,item in ipairs(wanted) do
            if budgetLeft<=0 then break end
            if item.price<=0 or netWorth<item.price or not fruitInStock(item.id) then continue end
            local bought=0
            while bought<MAX_PER_FRUIT_PER_TICK and budgetLeft>=item.price and netWorth>=item.price do
                local ok,err=fireBuyFruit(item.id)
                if not ok then if VERBOSE then notify("❌ ซื้อไม่สำเร็จ",labelOf(item.id).." ("..tostring(err)..")",3) end break end
                bought=bought+1
                budgetLeft=budgetLeft-item.price
                netWorth=netWorth-item.price
                if VERBOSE and PURCHASE_TOAST then notify("✅ ซื้อสำเร็จ",labelOf(item.id).." ฿"..comma(item.price),2) end
                sendPurchaseCard(item.id, item.price)
                task.wait(0.2)
            end
        end
        task.wait(TICK_EVERY)
    end
end)

_G.StopAutoBuyFruit=function()
    if RUNNING then RUNNING=false
        if START_STOP_TOAST then notify("🍎 Auto Buy Fruit","🔴 หยุดทำงานแล้ว ⛔",3) end
    end
end
