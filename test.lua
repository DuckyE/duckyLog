-- Pet Gift UX: Player list + Pet list (scan) + Bind per type + Give
-- LocalScript only (StarterPlayerScripts). MuMu/touch friendly.

local Players = game:GetService("Players")
local UIS     = game:GetService("UserInputService")
local PPS     = game:GetService("ProximityPromptService")
local GuiSvc  = game:GetService("GuiService")
local LP      = Players.LocalPlayer

-- =================== config ===================
local MAX_NEAR_DIST   = 18
local PROMPT_MAX_DIST = 16
local CONFIRM_TIMEOUT = 6
local ACCEPT_TEXTS    = {"send","confirm","ส่ง","ตกลง"} -- texts for confirm button

-- =================== util / log ===================
local uiLogList, uiLogCanvas
local function uiLog(msg)
    if uiLogList then
        local line = Instance.new("TextLabel")
        line.BackgroundTransparency = 1
        line.Size = UDim2.new(1,-10,0,16)
        line.TextXAlignment = Enum.TextXAlignment.Left
        line.Font = Enum.Font.Code
        line.TextSize = 14
        line.TextColor3 = Color3.fromRGB(220,230,255)
        line.Text = os.date("[%H:%M:%S] ") .. tostring(msg)
        line.Parent = uiLogList
        uiLogCanvas.CanvasSize = UDim2.new(0,0,0,uiLogList.UIListLayout.AbsoluteContentSize.Y+8)
        uiLogCanvas.CanvasPosition = Vector2.new(0, math.max(0, uiLogCanvas.CanvasSize.Y.Offset- uiLogCanvas.AbsoluteWindowSize.Y + 8))
    end
    print("[GIFT-UX] "..tostring(msg))
end
local function norm(s)
    return (string.gsub(string.lower(tostring(s or "")),"[%s%-%_]+",""))
end

-- =================== player helpers ===================
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

-- =================== gift prompt ===================
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

-- =================== confirm dialog ===================
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
    -- sweep current
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
    -- wait incoming
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

-- =================== scan pets from Data ===================
local function findPetRoot()
    local pg   = LP:WaitForChild("PlayerGui")
    local data = pg:FindFirstChild("Data") or pg:WaitForChild("Data")
    return data:FindFirstChild("Pets")
        or data:FindFirstChild("Pet")
        or (data:FindFirstChild("Inventory") and data.Inventory:FindFirstChild("Pets"))
end
local function flatten(root)
    local out, st = {}, {root}
    while #st > 0 do
        local n = table.remove(st)
        for _, d in ipairs(n:GetChildren()) do
            out[#out+1] = d
            if #d:GetChildren() > 0 then st[#st+1] = d end
        end
    end
    return out
end
local PET_TYPE_FIELDS = {"PetType","Type","T","Name","PetName"}
local LOCK_FIELDS     = {"Locked","IsLocked","locked"}
local function getFirstAttr(attrs, keys)
    for _,k in ipairs(keys) do local v=attrs[k]; if v~=nil then return v end end
end
local function isLocked(attrs)
    for _,k in ipairs(LOCK_FIELDS) do
        local v=attrs[k]; if v==true or v==1 then return true end
    end
    return false
end

local Scan = { byType = {}, total=0, unlocked=0, locked=0 }
local function rescanPets()
    Scan = { byType = {}, total=0, unlocked=0, locked=0 }
    local root = findPetRoot()
    if not root then uiLog("Cannot find Data.Pets"); return Scan end
    for _, inst in ipairs(flatten(root)) do
        local a = inst:GetAttributes()
        local typ = getFirstAttr(a, PET_TYPE_FIELDS)
        if typ ~= nil then
            local tkey = norm(typ)
            Scan.byType[tkey] = (Scan.byType[tkey] or 0) + 1
            Scan.total += 1
            if isLocked(a) then Scan.locked += 1 else Scan.unlocked += 1 end
        end
    end
    return Scan
end

-- =================== binding per type ===================
getgenv().PET_BINDS = getgenv().PET_BINDS or {}   -- { [tkey] = { kind="path", path="PlayerGui...." } }
local BINDS = getgenv().PET_BINDS

local function getByPath(path)
    local node = LP:FindFirstChild("PlayerGui")
    for seg in string.gmatch(path, "[^%.]+") do node = node and node:FindFirstChild(seg) end
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
local function captureGuiPathOnce(timeoutSec)
    timeoutSec = timeoutSec or 6
    uiLog("Tap a pet button in your bag within "..timeoutSec.."s")
    local mouse = LP:GetMouse()
    local t0 = os.clock()
    while os.clock()-t0 < timeoutSec do
        if UIS:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) or UIS.TouchEnabled then
            local pos
            if UIS.TouchEnabled and #UIS:GetTouches() > 0 then
                local t = UIS:GetTouches()[1]
                pos = Vector2.new(t.Position.X,t.Position.Y)
            else
                pos = Vector2.new(mouse.X,mouse.Y)
            end
            local objs = GuiSvc:GetGuiObjectsAtPosition(pos.X,pos.Y)
            for _,o in ipairs(objs) do
                if o:IsDescendantOf(LP.PlayerGui) then
                    local seg, cur = {}, o
                    while cur and cur ~= LP.PlayerGui do table.insert(segs or seg,1,cur.Name); cur=cur.Parent end
                    local path = table.concat(seg,".")
                    uiLog("Captured path: "..path)
                    return path
                end
            end
        end
        task.wait(0.05)
    end
    uiLog("Bind timed out")
    return nil
end

local function selectPetByType(tkey)
    local b = BINDS[tkey]
    if not b then return false, "NO_BIND" end
    if b.kind == "path" then
        local ok = clickByPath(b.path)
        return ok, ok and nil or "PATH_NOT_FOUND"
    end
    return false, "UNKNOWN_BIND"
end

-- =================== one run: select -> gift -> send ===================
local function runOne(tkey, target)
    if not target then return false, "NO_TARGET" end
    local ok, why = selectPetByType(tkey)
    if not ok then return false, "SELECT_FAIL:"..tostring(why) end
    task.wait(0.12)

    local me, th = hrp(LP), hrp(target)
    if not (me and th) then return false, "NO_HRP" end
    local dist = (me.Position - th.Position).Magnitude
    if dist > PROMPT_MAX_DIST then return false, "TOO_FAR" end

    local prompt = findGiftPromptForPlayer(target)
    if not prompt then return false, "PROMPT_NOT_FOUND" end
    if not pressPrompt(prompt) then return false, "PROMPT_FAIL" end

    local sent = waitConfirmAndSend(target.DisplayName or target.Name, CONFIRM_TIMEOUT)
    if not sent then return false, "CONFIRM_FAIL" end
    return true
end

-- =================== UI ===================
local root = Instance.new("ScreenGui")
root.Name = "PetGiftUX"
root.ResetOnSpawn = false
root.Parent = LP:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0, 900, 0, 460)
panel.Position = UDim2.new(0, 40, 1, -480)
panel.BackgroundColor3 = Color3.fromRGB(18, 22, 40)
panel.BorderSizePixel = 0
panel.Parent = root
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.Text = "Pet Gift UX (Client-only)"
title.BackgroundTransparency = 1
title.Size = UDim2.new(1,-12,0,24)
title.Position = UDim2.new(0,12,0,8)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Font = Enum.Font.GothamBold; title.TextSize = 18
title.TextColor3 = Color3.fromRGB(230,238,252)
title.Parent = panel

-- Drag panel
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

-- Left column: Players
local colL = Instance.new("Frame")
colL.Size = UDim2.new(0, 220, 1, -60)
colL.Position = UDim2.new(0, 12, 0, 44)
colL.BackgroundColor3 = Color3.fromRGB(24, 30, 58)
colL.Parent = panel
Instance.new("UICorner", colL).CornerRadius = UDim.new(0, 8)

local pFilter = Instance.new("TextBox")
pFilter.Size = UDim2.new(1,-12,0,26)
pFilter.Position = UDim2.new(0,6,0,6)
pFilter.PlaceholderText = "search player"
pFilter.Text = ""
pFilter.BackgroundColor3 = Color3.fromRGB(18,24,48)
pFilter.TextColor3 = Color3.new(1,1,1); pFilter.Font = Enum.Font.Gotham; pFilter.TextSize = 14
pFilter.Parent = colL
Instance.new("UICorner", pFilter).CornerRadius = UDim.new(0, 6)

local pList = Instance.new("ScrollingFrame")
pList.Size = UDim2.new(1,-12,1,-44)
pList.Position = UDim2.new(0,6,0,38)
pList.BackgroundTransparency = 1
pList.ScrollBarThickness = 6
pList.CanvasSize = UDim2.new()
pList.Parent = colL
local plLayout = Instance.new("UIListLayout", pList); plLayout.Padding = UDim.new(0,6)

local selectedTargetId, selectedTargetName = nil, "(none)"
local function refreshPlayers()
    pList:ClearAllChildren()
    for _,p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local disp = p.DisplayName or p.Name
            if pFilter.Text == "" or string.find(string.lower(disp), string.lower(pFilter.Text), 1, true) then
                local b = Instance.new("TextButton")
                b.Size = UDim2.new(1,0,0,26)
                b.Text = disp.." ("..p.UserId..")"
                b.BackgroundColor3 = Color3.fromRGB(30,40,76)
                b.TextColor3 = Color3.new(1,1,1); b.Font = Enum.Font.Gotham; b.TextSize = 12
                b.Parent = pList
                Instance.new("UICorner", b).CornerRadius = UDim.new(0,6)
                b.MouseButton1Click:Connect(function()
                    selectedTargetId, selectedTargetName = p.UserId, disp
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

local pickNearest = Instance.new("TextButton")
pickNearest.Text = "Nearest"
pickNearest.Size = UDim2.new(0,90,0,26)
pickNearest.Position = UDim2.new(0,142,0,6)
pickNearest.BackgroundColor3 = Color3.fromRGB(60,140,100)
pickNearest.TextColor3 = Color3.new(1,1,1); pickNearest.Font = Enum.Font.GothamBold; pickNearest.TextSize = 12
pickNearest.Parent = colL
Instance.new("UICorner", pickNearest).CornerRadius = UDim.new(0,6)
pickNearest.MouseButton1Click:Connect(function()
    local t = select(1, nearestPlayer(MAX_NEAR_DIST))
    if t then selectedTargetId, selectedTargetName = t.UserId, (t.DisplayName or t.Name); uiLog("Target = "..selectedTargetName)
    else uiLog("No nearby player") end
end)

-- Middle column: PET list (from Data) with Bind/Count/Give
local colM = Instance.new("Frame")
colM.Size = UDim2.new(0, 380, 1, -60)
colM.Position = UDim2.new(0, 244, 0, 44)
colM.BackgroundColor3 = Color3.fromRGB(24, 30, 58)
colM.Parent = panel
Instance.new("UICorner", colM).CornerRadius = UDim.new(0, 8)

local petHeader = Instance.new("TextLabel")
petHeader.Text = "Pets in Data (tap type to focus; Bind path then Give)"
petHeader.BackgroundTransparency = 1
petHeader.Size = UDim2.new(1,-12,0,22)
petHeader.Position = UDim2.new(0,6,0,6)
petHeader.TextXAlignment = Enum.TextXAlignment.Left
petHeader.Font = Enum.Font.GothamSemibold; petHeader.TextSize = 14
petHeader.TextColor3 = Color3.fromRGB(180,196,230)
petHeader.Parent = colM

local petList = Instance.new("ScrollingFrame")
petList.Size = UDim2.new(1,-12,1,-36)
petList.Position = UDim2.new(0,6,0,30)
petList.BackgroundTransparency = 1
petList.ScrollBarThickness = 6
petList.CanvasSize = UDim2.new()
petList.Parent = colM
local listLayout = Instance.new("UIListLayout", petList); listLayout.Padding = UDim.new(0,6)

local countEditors = {} -- [tkey] -> TextBox (for count)
local function renderPets()
    petList:ClearAllChildren(); countEditors = {}
    local by = {}
    for k,v in pairs(Scan.byType or {}) do table.insert(by, {k,v}) end
    table.sort(by, function(a,b) return a[2] > b[2] end)

    for _,kv in ipairs(by) do
        local tkey, cnt = kv[1], kv[2]
        local row = Instance.new("Frame"); row.Size = UDim2.new(1,0,0,28); row.BackgroundColor3 = Color3.fromRGB(30,40,76); row.Parent = petList
        Instance.new("UICorner", row).CornerRadius = UDim.new(0,6)

        local nameLab = Instance.new("TextLabel")
        nameLab.BackgroundTransparency = 1
        nameLab.Size = UDim2.new(0.45, -8, 1, 0)
        nameLab.Position = UDim2.new(0,8,0,0)
        nameLab.Font = Enum.Font.Gotham; nameLab.TextSize = 13
        nameLab.TextXAlignment = Enum.TextXAlignment.Left
        nameLab.TextColor3 = Color3.new(1,1,1)
        nameLab.Text = tkey .. "  x" .. cnt
        nameLab.Parent = row

        local bindBtn = Instance.new("TextButton")
        bindBtn.Text = BINDS[tkey] and "Rebind" or "Bind"
        bindBtn.Size = UDim2.new(0,70,0,22)
        bindBtn.Position = UDim2.new(0.45, 4, 0.5, -11)
        bindBtn.BackgroundColor3 = Color3.fromRGB(100,120,200)
        bindBtn.TextColor3 = Color3.new(1,1,1); bindBtn.Font = Enum.Font.GothamBold; bindBtn.TextSize = 12
        bindBtn.Parent = row
        Instance.new("UICorner", bindBtn).CornerRadius = UDim.new(0,6)

        local cntBox = Instance.new("TextBox")
        cntBox.Size = UDim2.new(0,50,0,22)
        cntBox.Position = UDim2.new(0.45, 80, 0.5, -11)
        cntBox.Text = "1"; cntBox.PlaceholderText = "n"
        cntBox.BackgroundColor3 = Color3.fromRGB(18,24,48)
        cntBox.TextColor3 = Color3.new(1,1,1); cntBox.Font = Enum.Font.Gotham; cntBox.TextSize = 12
        cntBox.Parent = row; Instance.new("UICorner", cntBox).CornerRadius = UDim.new(0,6)
        countEditors[tkey] = cntBox

        local giveBtn = Instance.new("TextButton")
        giveBtn.Text = "Give"
        giveBtn.Size = UDim2.new(0,60,0,22)
        giveBtn.Position = UDim2.new(1, -64, 0.5, -11)
        giveBtn.BackgroundColor3 = Color3.fromRGB(0,160,120)
        giveBtn.TextColor3 = Color3.new(1,1,1); giveBtn.Font = Enum.Font.GothamBold; giveBtn.TextSize = 12
        giveBtn.Parent = row; Instance.new("UICorner", giveBtn).CornerRadius = UDim.new(0,6)

        bindBtn.MouseButton1Click:Connect(function()
            uiLog("Binding for type: "..tkey.." -> tap a pet button in your bag")
            task.spawn(function()
                local path = captureGuiPathOnce(6)
                if path then BINDS[tkey] = { kind="path", path=path }; bindBtn.Text = "Rebind"; uiLog("Bind OK: "..tkey)
                else uiLog("Bind failed: "..tkey) end
            end)
        end)

        giveBtn.MouseButton1Click:Connect(function()
            if not selectedTargetId then uiLog("Pick a target first"); return end
            if not BINDS[tkey] then uiLog("Please Bind this type first"); return end
            local n = tonumber(cntBox.Text) or 1
            local tgt = Players:GetPlayerByUserId(selectedTargetId)
            if not tgt then uiLog("Target left the server"); return end
            uiLog("Give "..tkey.." x"..n.." -> "..(tgt.DisplayName or tgt.Name))
            task.spawn(function()
                for i=1,n do
                    local ok, why = runOne(tkey, tgt)
                    uiLog((ok and "OK" or ("FAIL "..tostring(why))).."  "..i.."/"..n)
                    task.wait(0.35)
                end
                uiLog("Done "..tkey)
            end)
        end)
    end
    petList.CanvasSize = UDim2.new(0,0,0,listLayout.AbsoluteContentSize.Y+8)
end

-- Right column: Console
local colR = Instance.new("Frame")
colR.Size = UDim2.new(0, 240, 1, -60)
colR.Position = UDim2.new(0, 636, 0, 44)
colR.BackgroundColor3 = Color3.fromRGB(14, 18, 38)
colR.Parent = panel
Instance.new("UICorner", colR).CornerRadius = UDim.new(0, 8)

local logHdr = Instance.new("TextLabel")
logHdr.BackgroundTransparency = 1
logHdr.Size = UDim2.new(1,-12,0,18)
logHdr.Position = UDim2.new(0,6,0,6)
logHdr.TextXAlignment = Enum.TextXAlignment.Left
logHdr.Font = Enum.Font.GothamSemibold; logHdr.TextSize = 14
logHdr.TextColor3 = Color3.fromRGB(180,196,230)
logHdr.Text = "Console"
logHdr.Parent = colR

local clearBtn = Instance.new("TextButton")
clearBtn.Text = "Clear"
clearBtn.Size = UDim2.new(0,60,0,22)
clearBtn.Position = UDim2.new(1,-66,0,6)
clearBtn.BackgroundColor3 = Color3.fromRGB(40,50,88)
clearBtn.TextColor3 = Color3.new(1,1,1); clearBtn.Font = Enum.Font.Gotham; clearBtn.TextSize = 12
clearBtn.Parent = colR
Instance.new("UICorner", clearBtn).CornerRadius = UDim.new(0,6)

uiLogCanvas = Instance.new("ScrollingFrame")
uiLogCanvas.Size = UDim2.new(1,-12,1,-36)
uiLogCanvas.Position = UDim2.new(0,6,0,30)
uiLogCanvas.BackgroundTransparency = 1
uiLogCanvas.ScrollBarThickness = 6
uiLogCanvas.CanvasSize = UDim2.new()
uiLogCanvas.Parent = colR

uiLogList = Instance.new("Frame"); uiLogList.Size = UDim2.new(1,0,0,0); uiLogList.BackgroundTransparency = 1; uiLogList.Parent = uiLogCanvas
local ll = Instance.new("UIListLayout", uiLogList); ll.Padding = UDim.new(0,2)
uiLogList.UIListLayout = ll
clearBtn.MouseButton1Click:Connect(function()
    for _,c in ipairs(uiLogList:GetChildren()) do if c:IsA("TextLabel") then c:Destroy() end end
    uiLogCanvas.CanvasSize = UDim2.new()
end)

-- Top-right: Rescan button
local rescanBtn = Instance.new("TextButton")
rescanBtn.Text = "Rescan Pets"
rescanBtn.Size = UDim2.new(0,110,0,26)
rescanBtn.Position = UDim2.new(1,-122,0,8)
rescanBtn.BackgroundColor3 = Color3.fromRGB(45,95,200)
rescanBtn.TextColor3 = Color3.new(1,1,1); rescanBtn.Font = Enum.Font.GothamBold; rescanBtn.TextSize = 12
rescanBtn.Parent = panel
Instance.new("UICorner", rescanBtn).CornerRadius = UDim.new(0,6)
rescanBtn.MouseButton1Click:Connect(function()
    rescanPets(); renderPets()
    uiLog(("Rescanned: total=%d unlocked=%d locked=%d"):format(Scan.total, Scan.unlocked, Scan.locked))
end)

-- Init
rescanPets()
refreshPlayers()
renderPets()
uiLog("Ready. 1) เลือกผู้เล่นทางซ้าย (หรือ Nearest)  2) กด Bind ที่ชนิดที่ต้องการ  3) ใส่จำนวนแล้วกด Give")
