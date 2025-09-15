
-- MuMu Touch Gift Helper (client-only)
-- UI buttons only; no keyboard needed.

local Players=game:GetService("Players")
local UIS=game:GetService("UserInputService")
local PPS=game:GetService("ProximityPromptService")
local GuiService=game:GetService("GuiService")
local LP=Players.LocalPlayer

-- config
local MAX_NEAR_DIST=18
local PROMPT_MAX_DIST=16
local CONFIRM_TIMEOUT=6
local CONFIRM_TEXTS={"send","confirm","ส่ง","ตกลง"}

-- log
local function log(m) print("["..os.date("%X").."] [GIFT] "..tostring(m)) end

-- helpers: player / parts
local function getHRP(plr)
    local c=plr.Character or plr.CharacterAdded:Wait()
    return c:FindFirstChild("HumanoidRootPart") or c:WaitForChild("HumanoidRootPart",2)
end

local function nearestPlayer(maxd)
    local my=getHRP(LP); if not my then return end
    local best,bd=nil,1e9
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LP and p.Character and p.Character.Parent then
            local h=getHRP(p)
            if h then
                local d=(my.Position-h.Position).Magnitude
                if d<bd and d<=(maxd or MAX_NEAR_DIST) then best,bd=p,d end
            end
        end
    end
    return best,bd
end

-- find Gift ProximityPrompt tied to target player
local function findGiftPromptForPlayer(target)
    if not target or not target.Character then return nil end
    local hrp=target.Character:FindFirstChild("HumanoidRootPart")
    if hrp then
        for _,d in ipairs(hrp:GetDescendants()) do
            if d:IsA("ProximityPrompt") and (d.ActionText=="Gift" or d.Name=="GiftPrompt_PT") then
                return d
            end
        end
    end
    -- fallback: scan workspace and match character model
    for _,d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and (d.ActionText=="Gift" or d.Name=="GiftPrompt_PT") then
            local m=d:FindFirstAncestorOfClass("Model")
            if m and Players:GetPlayerFromCharacter(m)==target then return d end
        end
    end
    return nil
end

-- press a ProximityPrompt without keyboard
local function pressPrompt(prompt)
    if typeof(fireproximityprompt)=="function" then
        fireproximityprompt(prompt); return true
    end
    local ok=pcall(function()
        PPS:InputHoldBegin(prompt)
        task.wait(math.max(0.03,prompt.HoldDuration or 0))
        PPS:InputHoldEnd(prompt)
    end)
    return ok
end

-- locate and press the Send/Confirm button in the confirmation dialog
local function isAcceptText(s)
    s=string.lower(s or "")
    for _,k in ipairs(CONFIRM_TEXTS) do
        if s==k or string.find(s,k,1,true) then return true end
    end
    return false
end
local function waitConfirmAndSend(targetDisplay,timeoutSec)
    local pg=LP:WaitForChild("PlayerGui")
    local t0=os.clock(); timeoutSec=timeoutSec or CONFIRM_TIMEOUT
    -- sweep now
    for _,d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextButton") and isAcceptText(d.Text) then
            if targetDisplay then
                local ok=false
                for _,n in ipairs(d.Parent:GetDescendants()) do
                    if n:IsA("TextLabel") and string.find(string.lower(n.Text or ""),string.lower(targetDisplay),1,true) then ok=true break end
                end
                if not ok then goto cont end
            end
            d:Activate(); return true
        end
        ::cont::
    end
    -- wait
    local done=false
    local conn=pg.DescendantAdded:Connect(function(n)
        if done then return end
        if n:IsA("TextButton") and isAcceptText(n.Text) then
            if targetDisplay then
                local ok=false
                for _,ch in ipairs(n.Parent:GetDescendants()) do
                    if ch:IsA("TextLabel") and string.find(string.lower(ch.Text or ""),string.lower(targetDisplay),1,true) then ok=true break end
                end
                if not ok then return end
            end
            done=true; n:Activate()
        end
    end)
    while not done and os.clock()-t0<timeoutSec do task.wait(0.05) end
    if conn then conn:Disconnect() end
    return done
end

-- binding: capture a GUI path by tapping a bag button once
local function pathFromTap(timeoutSec)
    timeoutSec=timeoutSec or 6
    log("Tap a pet button in your bag within "..timeoutSec.."s")
    local mouse=LP:GetMouse()
    local t0=os.clock()
    while os.clock()-t0<timeoutSec do
        if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or UIS.TouchEnabled then
            -- read GUI under cursor/finger
            local pos
            if UIS.TouchEnabled and #UIS:GetTouches()>0 then
                local t=UIS:GetTouches()[1]
                pos = Vector2.new(t.Position.X,t.Position.Y)
            else
                pos = Vector2.new(mouse.X,mouse.Y)
            end
            local objs=GuiService:GetGuiObjectsAtPosition(pos.X,pos.Y)
            for _,o in ipairs(objs) do
                if o:IsDescendantOf(LP.PlayerGui) then
                    local seg={}
                    local cur=o
                    while cur and cur~=LP.PlayerGui do
                        table.insert(seg,1,cur.Name)
                        cur=cur.Parent
                    end
                    local path=table.concat(seg,".")
                    log("Captured path: "..path)
                    return path
                end
            end
        end
        task.wait(0.05)
    end
    log("Bind timed out")
    return nil
end

local function getByPath(path)
    local node=LP:FindFirstChild("PlayerGui")
    for seg in string.gmatch(path,"[^%.]+") do
        node = node and node:FindFirstChild(seg)
    end
    return node
end

local function clickByPath(path)
    local obj=getByPath(path)
    if not obj then return false end
    if obj:IsA("TextButton") or obj:IsA("ImageButton") then obj:Activate(); return true end
    for _,d in ipairs(obj:GetDescendants()) do
        if d:IsA("TextButton") or d:IsA("ImageButton") then d:Activate(); return true end
    end
    return false
end

-- run one: select pet -> gift -> send
local function runOne(path, target)
    if not path then log("No bind yet"); return false end
    if not target then log("No target"); return false end
    -- click pet button in bag
    local okSel=clickByPath(path)
    if not okSel then log("Bind path invalid"); return false end
    task.wait(0.12)

    local me=getHRP(LP); local th=getHRP(target)
    if not (me and th) then log("Missing HRP"); return false end
    local dist=(me.Position-th.Position).Magnitude
    if dist>PROMPT_MAX_DIST then log("Too far"); return false end

    local prompt=findGiftPromptForPlayer(target)
    if not prompt then log("Gift prompt not found"); return false end
    if not pressPrompt(prompt) then log("pressPrompt failed"); return false end
    log("Gift prompt triggered")

    local sent=waitConfirmAndSend(target.DisplayName or target.Name,CONFIRM_TIMEOUT)
    if not sent then log("Confirm not found"); return false end
    log("Sent OK")
    return true
end

-- UI
local gui=Instance.new("ScreenGui"); gui.Name="MuMuGiftUI"; gui.ResetOnSpawn=false; gui.Parent=LP:WaitForChild("PlayerGui")
local panel=Instance.new("Frame"); panel.Size=UDim2.new(0,300,0,170); panel.Position=UDim2.new(1,-320,1,-190)
panel.BackgroundColor3=Color3.fromRGB(20,26,50); panel.BorderSizePixel=0; panel.Parent=gui
local c=Instance.new("UICorner",panel); c.CornerRadius=UDim.new(0,12)

local title=Instance.new("TextLabel"); title.Text="MuMu Gift Helper"; title.TextColor3=Color3.fromRGB(230,238,252)
title.BackgroundTransparency=1; title.Size=UDim2.new(1,-10,0,20); title.Position=UDim2.new(0,10,0,8)
title.Font=Enum.Font.GothamBold; title.TextSize=16; title.TextXAlignment=Enum.TextXAlignment.Left; title.Parent=panel

local pickBtn=Instance.new("TextButton"); pickBtn.Text="Pick Target"; pickBtn.Size=UDim2.new(0,120,0,30)
pickBtn.Position=UDim2.new(0,10,0,36); pickBtn.BackgroundColor3=Color3.fromRGB(45,95,200)
pickBtn.TextColor3=Color3.new(1,1,1); pickBtn.Font=Enum.Font.GothamBold; pickBtn.TextSize=13; pickBtn.Parent=panel
Instance.new("UICorner",pickBtn).CornerRadius=UDim.new(0,8)

local nearBtn=Instance.new("TextButton"); nearBtn.Text="Nearest"; nearBtn.Size=UDim2.new(0,90,0,30)
nearBtn.Position=UDim2.new(0,140,0,36); nearBtn.BackgroundColor3=Color3.fromRGB(60,140,100)
nearBtn.TextColor3=Color3.new(1,1,1); nearBtn.Font=Enum.Font.GothamBold; nearBtn.TextSize=13; nearBtn.Parent=panel
Instance.new("UICorner",nearBtn).CornerRadius=UDim.new(0,8)

local bindBtn=Instance.new("TextButton"); bindBtn.Text="Bind Pet Button"; bindBtn.Size=UDim2.new(0,180,0,30)
bindBtn.Position=UDim2.new(0,10,0,72); bindBtn.BackgroundColor3=Color3.fromRGB(100,120,200)
bindBtn.TextColor3=Color3.new(1,1,1); bindBtn.Font=Enum.Font.GothamBold; bindBtn.TextSize=13; bindBtn.Parent=panel
Instance.new("UICorner",bindBtn).CornerRadius=UDim.new(0,8)

local countBox=Instance.new("TextBox"); countBox.Text="10"; countBox.PlaceholderText="count"
countBox.Size=UDim2.new(0,60,0,30); countBox.Position=UDim2.new(0,200,0,72)
countBox.BackgroundColor3=Color3.fromRGB(25,35,70); countBox.TextColor3=Color3.new(1,1,1)
countBox.Font=Enum.Font.Gotham; countBox.TextSize=14; countBox.Parent=panel
Instance.new("UICorner",countBox).CornerRadius=UDim.new(0,8)

local runBtn=Instance.new("TextButton"); runBtn.Text="RUN xN"; runBtn.Size=UDim2.new(0,120,0,34)
runBtn.Position=UDim2.new(0,10,0,112); runBtn.BackgroundColor3=Color3.fromRGB(0,160,120)
runBtn.TextColor3=Color3.new(1,1,1); runBtn.Font=Enum.Font.GothamBold; runBtn.TextSize=14; runBtn.Parent=panel
Instance.new("UICorner",runBtn).CornerRadius=UDim.new(0,10)

local info=Instance.new("TextLabel"); info.Text="Ready"; info.BackgroundTransparency=1
info.TextColor3=Color3.fromRGB(156,176,216); info.Size=UDim2.new(1,-20,0,18); info.Position=UDim2.new(0,10,0,148)
info.Font=Enum.Font.Gotham; info.TextSize=12; info.TextXAlignment=Enum.TextXAlignment.Left; info.Parent=panel

-- pick target popup
local targetUserId=nil; local targetName="(none)"
local popup=Instance.new("Frame"); popup.Size=UDim2.new(0,260,0,180); popup.Position=UDim2.new(0,20,0,-190)
popup.BackgroundColor3=Color3.fromRGB(12,18,38); popup.Visible=false; popup.Parent=panel
Instance.new("UICorner",popup).CornerRadius=UDim.new(0,10)
local list=Instance.new("ScrollingFrame"); list.Size=UDim2.new(1,-10,1,-10); list.Position=UDim2.new(0,5,0,5)
list.CanvasSize=UDim2.new(); list.BackgroundTransparency=1; list.BorderSizePixel=0; list.Parent=popup

local function refreshList()
    list:ClearAllChildren(); local y=0
    for _,p in ipairs(Players:GetPlayers()) do
        if p~=LP then
            local b=Instance.new("TextButton")
            b.Text=(p.DisplayName or p.Name).." ("..p.UserId..")"
            b.Size=UDim2.new(1,-8,0,26); b.Position=UDim2.new(0,4,0,y)
            b.BackgroundColor3=Color3.fromRGB(25,35,70); b.TextColor3=Color3.new(1,1,1)
            b.Font=Enum.Font.Gotham; b.TextSize=12; b.Parent=list
            Instance.new("UICorner",b).CornerRadius=UDim.new(0,6)
            b.MouseButton1Click:Connect(function()
                targetUserId=p.UserId; targetName=p.DisplayName or p.Name
                popup.Visible=false; info.Text="Target: "..targetName
            end)
            y=y+28
        end
    end
    list.CanvasSize=UDim2.new(0,0,0,math.max(y,0))
end
pickBtn.MouseButton1Click:Connect(function() refreshList(); popup.Visible=true end)
nearBtn.MouseButton1Click:Connect(function()
    local p=select(1,nearestPlayer(MAX_NEAR_DIST))
    if p then targetUserId=p.UserId; targetName=p.DisplayName or p.Name; info.Text="Target: "..targetName else info.Text="No nearby player" end
end)

-- bind pet button
local BIND_PATH=nil
bindBtn.MouseButton1Click:Connect(function()
    info.Text="Open bag, then tap the pet button..."
    task.spawn(function()
        local path=pathFromTap(6)
        if path then BIND_PATH=path; info.Text="Bind OK"; else info.Text="Bind failed" end
    end)
end)

-- run xN
runBtn.MouseButton1Click:Connect(function()
    local cnt=tonumber(countBox.Text) or 1
    if not BIND_PATH then info.Text="Please bind pet button first"; return end
    if not targetUserId then info.Text="Pick target first"; return end
    local target=Players:GetPlayerByUserId(targetUserId)
    if not target then info.Text="Target left server"; return end
    info.Text="Running..."
    task.spawn(function()
        for i=1,cnt do
            local ok=runOne(BIND_PATH,target)
            log(ok and ("OK "..i.."/"..cnt) or ("FAIL "..i.."/"..cnt))
            task.wait(0.35)
        end
        info.Text="Done"
    end)
end)

-- drag panel
local dragging=false; local offset=Vector2.zero
panel.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then
        dragging=true; local p=i.Position; local v2=Vector2.new(p.X,p.Y); offset=v2-panel.AbsolutePosition
    end
end)
panel.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.MouseButton1 or i.UserInputType==Enum.UserInputType.Touch then dragging=false end
end)
UIS.InputChanged:Connect(function(i)
    if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
        local p=i.Position; local v2=Vector2.new(p.X,p.Y); panel.Position=UDim2.fromOffset(v2.X-offset.X,v2.Y-offset.Y)
    end
end)

log("MuMu Gift Helper loaded. 1) Bind Pet Button 2) Pick Target 3) RUN")
