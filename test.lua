-- Pet Gift Console UX (Client-only)
-- Drop as a LocalScript under StarterPlayerScripts

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local PPS     = game:GetService("ProximityPromptService")
local GuiSvc  = game:GetService("GuiService")
local LP      = Players.LocalPlayer

-- ====== config ======
local MAX_NEAR_DIST   = 18
local PROMPT_MAX_DIST = 16
local CONFIRM_TIMEOUT = 6
local ACCEPT_TEXTS    = {"send","confirm","ส่ง","ตกลง"}

-- ====== utils / logging to UI + F8 ======
local uiLogList, uiLogCanvas
local function uiLog(msg)
    local line = Instance.new("TextLabel")
    line.BackgroundTransparency = 1
    line.Size = UDim2.new(1,-10,0,16)
    line.Position = UDim2.new(0,5,0,uiLogCanvas.CanvasPosition.Y)
    line.TextXAlignment = Enum.TextXAlignment.Left
    line.Font = Enum.Font.Code
    line.TextSize = 14
    line.TextColor3 = Color3.fromRGB(220,230,255)
    line.Text = os.date("[%H:%M:%S] ")..tostring(msg)
    line.Parent = uiLogList
    uiLogCanvas.CanvasSize = UDim2.new(0,0,0,uiLogList.UIListLayout.AbsoluteContentSize.Y+8)
    print("[GIFT-UX] "..tostring(msg))
end

-- ====== player helpers ======
local function hrp(p)
    local c = p.Character or p.CharacterAdded:Wait()
    return c:FindFirstChild("HumanoidRootPart") or c:WaitForChild("HumanoidRootPart",2)
end
local function nearestPlayer(maxd)
    local me = hrp(LP); if not me then return end
    local best, bd = nil, 1e9
    for _,pl in ipairs(Players:GetPlayers()) do
        if pl ~= LP and pl.Character and pl.Character.Parent then
            local h = hrp(pl)
            if h then
                local d = (me.Position - h.Position).Magnitude
                if d < bd and d <= (maxd or MAX_NEAR_DIST) then best, bd = pl, d end
            end
        end
    end
    return best, bd
end

-- ====== prompt helpers ======
local function findGiftPromptForPlayer(target)
    if not target or not target.Character then return nil end
    local h = target.Character:FindFirstChild("HumanoidRootPart")
    if h then
        for _,d in ipairs(h:GetDescendants()) do
            if d:IsA("ProximityPrompt") and (d.ActionText=="Gift" or d.Name=="GiftPrompt_PT") then
                return d
            end
        end
    end
    for _,d in ipairs(workspace:GetDescendants()) do
        if d:IsA("ProximityPrompt") and (d.ActionText=="Gift" or d.Name=="GiftPrompt_PT") then
            local m = d:FindFirstAncestorOfClass("Model")
            if m and Players:GetPlayerFromCharacter(m) == target then return d end
        end
    end
    return nil
end
local function pressPrompt(prompt)
    if typeof(fireproximityprompt) == "function" then
        fireproximityprompt(prompt); return true
    end
    local ok = pcall(function()
        PPS:InputHoldBegin(prompt)
        task.wait(math.max(0.03, prompt.HoldDuration or 0))
        PPS:InputHoldEnd(prompt)
    end)
    return ok
end

-- ====== confirm dialog ======
local function isAcceptText(s)
    s = string.lower(s or "")
    for _,k in ipairs(ACCEPT_TEXTS) do
        if s==k or s:find(k,1,true) then return true end
    end
    return false
end
local function waitConfirmAndSend(targetDisplay, timeoutSec)
    local pg = LP:WaitForChild("PlayerGui")
    local t0 = os.clock(); timeoutSec = timeoutSec or CONFIRM_TIMEOUT
    -- quick sweep
    for _,d in ipairs(pg:GetDescendants()) do
        if d:IsA("TextButton") and isAcceptText(d.Text) then
            if targetDisplay then
                local ok=false
                for _,n in ipairs(d.Parent:GetDescendants()) do
                    if n:IsA("TextLabel") and string.lower(n.Text or ""):find(string.lower(targetDisplay),1,true) then ok=true break end
                end
                if not ok then goto cont end
            end
            d:Activate(); return true
        end
        ::cont::
    end
    -- wait
    local done=false
    local conn = pg.DescendantAdded:Connect(function(n)
        if done then return end
        if n:IsA("TextButton") and isAcceptText(n.Text) then
            if targetDisplay then
                local ok=false
                for _,ch in ipairs(n.Parent:GetDescendants()) do
                    if ch:IsA("TextLabel") and string.lower(ch.Text or ""):find(string.lower(targetDisplay),1,true) then ok=true break end
                end
                if not ok then return end
            end
            done = true; n:Activate()
        end
    end)
    while not done and os.clock()-t0 < timeoutSec do task.wait(0.05) end
    if conn then conn:Disconnect() end
    return done
end

-- ====== capture & click pet button (bind by GUI path) ======
local function pathFromTap(timeoutSec)
    timeoutSec = timeoutSec or 6
    uiLog("Tap a pet button in your bag within "..timeoutSec.."s")
    local mouse = LP:GetMouse()
    local t0 = os.clock()
    while os.clock()-t0 < timeoutSec do
        if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or UIS.TouchEnabled then
            local pos
            if UIS.TouchEnabled and #UIS:GetTouches() > 0 then
                local t = UIS:GetTouches()[1]
                pos = Vector2.new(t.Position.X, t.Position.Y)
            else
                pos = Vector2.new(mouse.X, mouse.Y)
            end
            local objs = GuiSvc:GetGuiObjectsAtPosition(pos.X, pos.Y)
            for _,o in ipairs(objs) do
                if o:IsDescendantOf(LP.PlayerGui) then
                    local seg, cur = {}, o
                    while cur and cur ~= LP.PlayerGui do
                        table.insert(seg, 1, cur.Name); cur = cur.Parent
                    end
                    local path = table.concat(seg, ".")
                    uiLog("Captured path: "..path)
                    return path
                end
            end
        end
        task.wait(0.05)
    end
    uiLog("Bind timed out"); return nil
end
local function getByPath(path)
    local node = LP:FindFirstChild("PlayerGui")
    for seg in string.gmatch(path, "[^%.]+") do
        node = node and node:FindFirstChild(seg)
    end
    return node
end
local function clickByPath(path)
    local obj = getByPath(path)
    if not obj then return false end
    if obj:IsA("TextButton") or obj:IsA("ImageButton") then obj:Activate(); return true end
    for _,d in ipairs(obj:GetDescendants()) do
        if d:IsA("TextButton") or d:IsA("ImageButton") then d:Activate(); return true end
    end
    return false
end

-- ====== run one: select -> gift -> send ======
local function runOne(boundPath, target)
    if not boundPath then uiLog("No pet button bound"); return false end
    if not target then uiLog("No target"); return false end

    local selOk = clickByPath(boundPath)
    if not selOk then uiLog("Bound path invalid"); return false end
    task.wait(0.12)

    local me, th = hrp(LP), hrp(target)
    if not (me and th) then uiLog("Missing HRP"); return false end
    local dist = (me.Position - th.Position).Magnitude
    if dist > PROMPT_MAX_DIST then uiLog("Too far ("..math.floor(dist)..")"); return false end

    local prompt = findGiftPromptForPlayer(target)
    if not prompt then uiLog("Gift prompt not found"); return false end
    if not pressPrompt(prompt) then uiLog("pressPrompt failed"); return false end
    uiLog("Gift prompt triggered")

    local sent = waitConfirmAndSend(target.DisplayName or target.Name, CONFIRM_TIMEOUT)
    if not sent then uiLog("Confirm not found"); return false end
    uiLog("Sent OK")
    return true
end

-- ====== UI (console style) ======
local root = Instance.new("ScreenGui")
root.Name = "PetGiftConsole"; root.ResetOnSpawn = false; root.Parent = LP:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 720, 0, 360)
panel.Position = UDim2.new(0, 40, 1, -380)
panel.BackgroundColor3 = Color3.fromRGB(18, 22, 40)
panel.BorderSizePixel = 0
panel.Parent = root
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.Text = "Pet Gift Console"
title.BackgroundTransparency = 1
title.Size = UDim2.new(1, -12, 0, 24)
title.Position = UDim2.new(0, 12, 0, 8)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold; title.TextSize = 18
title.TextColor3 = Color3.fromRGB(230,238,252)
title.Parent = panel

-- Left: Player list
local left = Instance.new("Frame")
left.Size = UDim2.new(0, 220, 1, -48)
left.Position = UDim2.new(0, 12, 0, 40)
left.BackgroundColor3 = Color3.fromRGB(24, 30, 58)
left.Parent = panel
Instance.new("UICorner", left).CornerRadius = UDim.new(0, 8)

local pFilter = Instance.new("TextBox")
pFilter.Size = UDim2.new(1, -12, 0, 26)
pFilter.Position = UDim2.new(0, 6, 0, 6)
pFilter.PlaceholderText = "search player"
pFilter.Text = ""
pFilter.BackgroundColor3 = Color3.fromRGB(18, 24, 48)
pFilter.TextColor3 = Color3.new(1,1,1); pFilter.Font = Enum.Font.Gotham; pFilter.TextSize = 14
pFilter.Parent = left
Instance.new("UICorner", pFilter).CornerRadius = UDim.new(0, 6)

local pList = Instance.new("ScrollingFrame")
pList.Size = UDim2.new(1, -12, 1, -44)
pList.Position = UDim2.new(0, 6, 0, 38)
pList.BackgroundTransparency = 1
pList.ScrollBarThickness = 6
pList.CanvasSize = UDim2.new()
pList.Parent = left
local plLayout = Instance.new("UIListLayout", pList); plLayout.Padding = UDim.new(0, 6)

local selectedTargetId, selectedTargetName = nil, "(none)"
local function refreshPlayers()
    pList:ClearAllChildren()
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            if pFilter.Text == "" or string.find(string.lower(p.DisplayName or p.Name), string.lower(pFilter.Text), 1, true) then
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1, 0, 0, 26)
                b.Text = (p.DisplayName or p.Name).." ("..p.UserId..")"
                b.BackgroundColor3 = Color3.fromRGB(30,40,76)
                b.TextColor3 = Color3.new(1,1,1); b.Font = Enum.Font.Gotham; b.TextSize = 12
                b.Parent = pList
                Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
                b.MouseButton1Click:Connect(function()
                    selectedTargetId = p.UserId; selectedTargetName = p.DisplayName or p.Name
                    uiLog("Target = "..selectedTargetName)
                end)
            end
        end
    end
    pList.CanvasSize = UDim2.new(0,0,0,plLayout.AbsoluteContentSize.Y+8)
end
pFilter:GetPropertyChangedSignal("Text"):Connect(refreshPlayers)
Players.PlayerAdded:Connect(refreshPlayers)
Players.PlayerRemoving:Connect(refreshPlayers)

-- Middle: Controls
local mid = Instance.new("Frame")
mid.Size = UDim2.new(0, 220, 1, -48)
mid.Position = UDim2.new(0, 244, 0, 40)
mid.BackgroundColor3 = Color3.fromRGB(24, 30, 58)
mid.Parent = panel
Instance.new("UICorner", mid).CornerRadius = UDim.new(0, 8)

local bindBtn = Instance.new("TextButton")
bindBtn.Text = "Bind Pet Button"
bindBtn.Size = UDim2.new(1, -12, 0, 32)
bindBtn.Position = UDim2.new(0, 6, 0, 8)
bindBtn.BackgroundColor3 = Color3.fromRGB(100,120,200)
bindBtn.TextColor3 = Color3.new(1,1,1); bindBtn.Font = Enum.Font.GothamBold; bindBtn.TextSize = 14
bindBtn.Parent = mid
Instance.new("UICorner", bindBtn).CornerRadius = UDim.new(0, 8)

local countBox = Instance.new("TextBox")
countBox.Text = "10"
countBox.PlaceholderText = "count"
countBox.Size = UDim2.new(1, -12, 0, 32)
countBox.Position = UDim2.new(0, 6, 0, 48)
countBox.BackgroundColor3 = Color3.fromRGB(18,24,48)
countBox.TextColor3 = Color3.new(1,1,1); countBox.Font = Enum.Font.Gotham; countBox.TextSize = 14
countBox.Parent = mid
Instance.new("UICorner", countBox).CornerRadius = UDim.new(0, 8)

local nearBtn = Instance.new("TextButton")
nearBtn.Text = "Pick Nearest"
nearBtn.Size = UDim2.new(1, -12, 0, 32)
nearBtn.Position = UDim2.new(0, 6, 0, 88)
nearBtn.BackgroundColor3 = Color3.fromRGB(60,140,100)
nearBtn.TextColor3 = Color3.new(1,1,1); nearBtn.Font = Enum.Font.GothamBold; nearBtn.TextSize = 14
nearBtn.Parent = mid
Instance.new("UICorner", nearBtn).CornerRadius = UDim.new(0, 8)

local runBtn = Instance.new("TextButton")
runBtn.Text = "RUN xN"
runBtn.Size = UDim2.new(1, -12, 0, 36)
runBtn.Position = UDim2.new(0, 6, 0, 128)
runBtn.BackgroundColor3 = Color3.fromRGB(0,160,120)
runBtn.TextColor3 = Color3.new(1,1,1); runBtn.Font = Enum.Font.GothamBold; runBtn.TextSize = 16
runBtn.Parent = mid
Instance.new("UICorner", runBtn).CornerRadius = UDim.new(0, 10)

-- Right: Console log
local right = Instance.new("Frame")
right.Size = UDim2.new(0, 220, 1, -48)
right.Position = UDim2.new(0, 476, 0, 40)
right.BackgroundColor3 = Color3.fromRGB(14, 18, 38)
right.Parent = panel
Instance.new("UICorner", right).CornerRadius = UDim.new(0, 8)

local logHeader = Instance.new("TextLabel")
logHeader.Text = "Console"
logHeader.BackgroundTransparency = 1
logHeader.Size = UDim2.new(1,-12,0,18)
logHeader.Position = UDim2.new(0,6,0,6)
logHeader.TextXAlignment = Enum.TextXAlignment.Left
logHeader.Font = Enum.Font.GothamSemibold; logHeader.TextSize = 14
logHeader.TextColor3 = Color3.fromRGB(180,196,230)
logHeader.Parent = right

local clearBtn = Instance.new("TextButton")
clearBtn.Text = "Clear"
clearBtn.Size = UDim2.new(0,60,0,22)
clearBtn.Position = UDim2.new(1,-66,0,6)
clearBtn.BackgroundColor3 = Color3.fromRGB(40,50,88)
clearBtn.TextColor3 = Color3.new(1,1,1); clearBtn.Font = Enum.Font.Gotham; clearBtn.TextSize = 12
clearBtn.Parent = right
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0,6)

uiLogCanvas = Instance.new("ScrollingFrame")
uiLogCanvas.Size = UDim2.new(1,-12,1,-36)
uiLogCanvas.Position = UDim2.new(0,6,0,30)
uiLogCanvas.BackgroundTransparency = 1
uiLogCanvas.ScrollBarThickness = 6
uiLogCanvas.CanvasSize = UDim2.new()
uiLogCanvas.Parent = right

uiLogList = Instance.new("Frame"); uiLogList.Size = UDim2.new(1,0,0,0); uiLogList.BackgroundTransparency = 1; uiLogList.Parent = uiLogCanvas
local ll = Instance.new("UIListLayout", uiLogList); ll.Padding = UDim.new(0,2)
uiLogList.UIListLayout = ll
clearBtn.MouseButton1Click:Connect(function()
    for _,c in ipairs(uiLogList:GetChildren()) do if c:IsA("TextLabel") then c:Destroy() end end
    uiLogCanvas.CanvasSize = UDim2.new()
end)

-- drag panel
do
    local dragging, offset = false, Vector2.zero
    panel.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = true
            local p = i.Position; offset = Vector2.new(p.X,p.Y) - panel.AbsolutePosition
        end
    end)
    panel.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
    end)
    UIS.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType==Enum.UserInputType.MouseMovement or i.UserInputType==Enum.UserInputType.Touch) then
            local p = i.Position; local v2 = Vector2.new(p.X,p.Y)
            panel.Position = UDim2.fromOffset(v2.X - offset.X, v2.Y - offset.Y)
        end
    end)
end

-- state
local BIND_PATH = nil

-- actions
bindBtn.MouseButton1Click:Connect(function()
    task.spawn(function()
        local path = pathFromTap(6)
        if path then BIND_PATH = path; uiLog("Bind OK") else uiLog("Bind failed") end
    end)
end)

nearBtn.MouseButton1Click:Connect(function()
    local t = select(1, nearestPlayer(MAX_NEAR_DIST))
    if t then selectedTargetId = t.UserId; selectedTargetName = t.DisplayName or t.Name; uiLog("Target = "..selectedTargetName)
    else uiLog("No nearby player") end
end)

local function runBatch()
    if not BIND_PATH then uiLog("Please bind pet button first"); return end
    if not selectedTargetId then uiLog("Pick target first"); return end
    local n = tonumber(countBox.Text) or 1
    local tgt = Players:GetPlayerByUserId(selectedTargetId)
    if not tgt then uiLog("Target left the server"); return end
    uiLog("Run x"..n.." -> "..(tgt.DisplayName or tgt.Name))
    task.spawn(function()
        for i=1,n do
            local ok = runOne(BIND_PATH, tgt)
            uiLog((ok and "OK " or "FAIL ")..i.."/"..n)
            task.wait(0.35)
        end
        uiLog("Done")
    end)
end
runBtn.MouseButton1Click:Connect(runBatch)

-- initial
refreshPlayers()
uiLog("Console ready. 1) Bind Pet Button  2) Pick Nearest or choose from list  3) RUN")
