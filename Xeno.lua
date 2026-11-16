--[[
    XenoHub.lua — Full (final)
    Executor: Xeno (guarded cho executor khác)
]]

--=========================================================
-- SERVICES
--=========================================================
local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local Lighting         = game:GetService("Lighting")
local CoreGui          = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    if Workspace.CurrentCamera then
        Camera = Workspace.CurrentCamera
    end
end)

--=========================================================
-- EXECUTOR COMPAT
--=========================================================
local HAS = {
    Drawing       = Drawing and Drawing.new ~= nil,
    HookMeta      = hookmetamethod ~= nil,
    RawMeta       = getrawmetatable ~= nil,
    SetReadonly   = setreadonly ~= nil,
    NewCClosure   = newcclosure ~= nil,
    Namecall      = getnamecallmethod ~= nil,
    SetFPSCap     = setfpscap ~= nil,
    GetHui        = gethui ~= nil,
}
local function warnMissing(name)
    warn("[XenoHub] Executor thiếu: " .. name .. " — tính năng tương ứng bị tắt")
end

--=========================================================
-- CONFIG
--=========================================================
local Config = {
    Aimlock = {
        Enabled = false, FOV = 150, Smooth = 0.35, SmoothCurve = 2.0,
        MaxTurnSpeed = 12, SwitchDelay = 0.25, Prediction = 0.15,
        Part = "Head", TeamCheck = true, WallCheck = true, MaxDist = 500,
        Debug = false,
    },
    FixLag = { Enabled = false, ClearTerrain = true, DisableEffects = true, CapFPS = 240 },
    SilentAim = {
        Enabled = false, FOV = 150, Part = "Head",
        TeamCheck = true, Prediction = 0.165, WallCheck = false,
    },
    Chams = {
        Enabled = false, TeamCheck = true,
        FillColor = Color3.fromRGB(255, 60, 60),
        OutlineColor = Color3.fromRGB(255, 255, 255),
        FillTransparency = 0.5, OutlineTransparency = 0,
        DepthMode = Enum.HighlightDepthMode.AlwaysOnTop,
    },
    SpeedHack = { Enabled = false, Speed = 50, JumpPower = 100, Method = "velocity", Smooth = true },
    FPSUnlocker = { Enabled = false, Cap = 240 },
    RapidFire = { Enabled = false, Multiplier = 3 },
    NoRecoil = { Enabled = false, SmoothFactor = 0.5 },
    AntiAim = { Enabled = false, YawSpeed = 15, PitchRange = 45, RollRange = 30, Jitter = true, JitterAmount = 5 },
    Hitbox = {
        Enabled = false, Size = 15, Transparency = 0.7, TeamCheck = true,
        Parts = { "Head", "HumanoidRootPart", "UpperTorso", "LowerTorso" },
    },
    Godmode = { Enabled = false, BlockKillBricks = true, BlockFallDamage = true, BlockHealthDecrease = true },
    Fullbright = {
        Enabled = false,
        Ambient = Color3.fromRGB(200, 200, 200),
        OutdoorAmbient = Color3.fromRGB(200, 200, 200),
        FogEnd = 1e6, RemoveAtmosphere = true, RemovePostEffects = false,
    },
    InfiniteJump = { Enabled = false },
    FOVChanger = { Enabled = false, Value = 120, Default = 70 },
    FOVCircle = {
        Enabled = false, Thickness = 1, Color = Color3.fromRGB(0, 200, 255),
        Sides = 64, UseAimlockFOV = true, Value = 150,
    },
    Teleport = { Enabled = false, Offset = Vector3.new(0, 0, 3), HeightOffset = 0 },
}

--=========================================================
-- HELPERS
--=========================================================
local function isAlive(plr)
    local char = plr.Character
    if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid")
    return hum and hum.Health > 0
end

local function sameTeam(plr, checkEnabled)
    if not checkEnabled then return false end
    if not plr.Team or not LocalPlayer.Team then return false end
    return plr.Team == LocalPlayer.Team
end

local function getPart(plr, partName)
    local char = plr.Character
    if not char then return nil end
    return char:FindFirstChild(partName) or char:FindFirstChild("HumanoidRootPart")
end

local function worldToViewport(pos)
    local sp, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), onScreen, sp.Z
end

local function dist(a, b) return (a - b).Magnitude end

local function hasLineOfSight(fromPart, toPart, targetChar, enabled)
    if not enabled then return true end
    local params = RaycastParams.new()
    local filter = { LocalPlayer.Character }
    if targetChar then table.insert(filter, targetChar) end
    params.FilterDescendantsInstances = filter
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = Workspace:Raycast(fromPart.Position, toPart.Position - fromPart.Position, params)
    return hit == nil
end

--=========================================================
-- AIMLOCK (BindToRenderStep Camera+1)
--=========================================================
local aimTarget, aimTargetPart = nil, nil
local switchCooldown = 0
local lastDebugPrint = 0

local function findBestTarget()
    local best, bestDist = nil, Config.Aimlock.FOV
    local center = Camera.ViewportSize / 2
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr == LocalPlayer then continue end
        if not isAlive(plr) then continue end
        if sameTeam(plr, Config.Aimlock.TeamCheck) then continue end
        local part = getPart(plr, Config.Aimlock.Part)
        if not part then continue end
        local myChar = LocalPlayer.Character
        if not myChar or not myChar:FindFirstChild("HumanoidRootPart") then continue end
        local myPos = myChar.HumanoidRootPart.Position
        local d = dist(myPos, part.Position)
        if d > Config.Aimlock.MaxDist then continue end
        if not hasLineOfSight(myChar.HumanoidRootPart, part, plr.Character, Config.Aimlock.WallCheck) then continue end
        local screen, onScreen = worldToViewport(part.Position)
        if not onScreen then continue end
        local fovDist = (screen - center).Magnitude
        if fovDist < bestDist then bestDist = fovDist best = plr end
    end
    return best
end

local function easeOut(t, p) return 1 - (1 - t) ^ p end
local function angleBetween(a, b) return math.acos(math.clamp(a:Dot(b), -1, 1)) end

local function predictPosition(plr, part, prediction)
    if prediction <= 0 then return part.Position end
    local char = plr.Character
    if not char then return part.Position end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return part.Position end
    return part.Position + hrp.AssemblyLinearVelocity * prediction
end

local function updateTarget(dt)
    switchCooldown = math.max(0, switchCooldown - dt)
    local newTarget = findBestTarget()
    if newTarget then
        if aimTarget == nil then
            aimTarget = newTarget
            aimTargetPart = getPart(newTarget, Config.Aimlock.Part)
            switchCooldown = Config.Aimlock.SwitchDelay
        elseif newTarget ~= aimTarget then
            if switchCooldown <= 0 then
                aimTarget = newTarget
                aimTargetPart = getPart(newTarget, Config.Aimlock.Part)
                switchCooldown = Config.Aimlock.SwitchDelay
            end
        else
            aimTargetPart = getPart(newTarget, Config.Aimlock.Part)
        end
    else
        aimTarget, aimTargetPart = nil, nil
    end
end

RunService:BindToRenderStep("XenoAimlock", Enum.RenderPriority.Camera.Value + 1, function(dt)
    if not Config.Aimlock.Enabled then
        aimTarget, aimTargetPart = nil, nil
        return
    end
    updateTarget(dt)

    -- FIX: throttle debug print
    if Config.Aimlock.Debug and tick() - lastDebugPrint > 0.5 then
        lastDebugPrint = tick()
        if aimTarget then
            print("[Aimlock] target:", aimTarget.Name, "part:", aimTargetPart and aimTargetPart.Name or "nil")
        else
            print("[Aimlock] no target")
        end
    end

    if not aimTarget or not aimTargetPart then return end
    local targetPos = predictPosition(aimTarget, aimTargetPart, Config.Aimlock.Prediction)
    local camPos = Camera.CFrame.Position
    local currentDir = Camera.CFrame.LookVector
    local targetDir = (targetPos - camPos).Unit
    local angle = angleBetween(currentDir, targetDir)
    if angle < 0.0001 then return end
    local baseSpeed = (1 - Config.Aimlock.Smooth)
    local adaptive = baseSpeed * (0.4 + 0.6 * math.min(angle / math.rad(45), 1))
    local maxStep = Config.Aimlock.MaxTurnSpeed * dt
    local step = math.min(adaptive * angle, maxStep)
    local progress = math.min(step / angle, 1)
    local eased = easeOut(progress, Config.Aimlock.SmoothCurve)
    local newDir = currentDir:Lerp(targetDir, eased).Unit
    Camera.CFrame = CFrame.lookAt(camPos, camPos + newDir)
end)

--=========================================================
-- CHAMS
--=========================================================
local chamsHighlights = {}
local function createChams(plr)
    if plr == LocalPlayer or chamsHighlights[plr] or not plr.Character then return end
    local hl = Instance.new("Highlight")
    hl.Name = "XenoChams"
    hl.FillColor = Config.Chams.FillColor
    hl.OutlineColor = Config.Chams.OutlineColor
    hl.FillTransparency = Config.Chams.FillTransparency
    hl.OutlineTransparency = Config.Chams.OutlineTransparency
    hl.DepthMode = Config.Chams.DepthMode
    hl.Adornee = plr.Character
    hl.Parent = plr.Character
    chamsHighlights[plr] = hl
end
local function removeChams(plr)
    local hl = chamsHighlights[plr]
    if hl then pcall(function() hl:Destroy() end) chamsHighlights[plr] = nil end
end
local function refreshChams()
    if not Config.Chams.Enabled then
        for plr, _ in pairs(chamsHighlights) do removeChams(plr) end
        return
    end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and isAlive(plr) and not sameTeam(plr, Config.Chams.TeamCheck) then
            if not chamsHighlights[plr] or chamsHighlights[plr].Adornee ~= plr.Character then
                removeChams(plr) createChams(plr)
            else
                local hl = chamsHighlights[plr]
                hl.FillColor = Config.Chams.FillColor
                hl.OutlineColor = Config.Chams.OutlineColor
                hl.DepthMode = Config.Chams.DepthMode
            end
        else
            removeChams(plr)
        end
    end
end
Players.PlayerRemoving:Connect(removeChams)
task.spawn(function()
    while true do task.wait(0.5) if Config.Chams.Enabled then refreshChams() end end
end)

--=========================================================
-- SILENT AIM (with URL failure warn)
--=========================================================
local silentAimModule = nil
pcall(function()
    local ok, result = pcall(function()
        return loadstring(game:HttpGet(
            "https://raw.githubusercontent.com/RapperDeluxe/scripts/main/silent%20aim%20module"
        ))()
    end)
    if ok and result then
        silentAimModule = result
        if silentAimModule.TeamCheck then
            pcall(function() silentAimModule.TeamCheck(Config.SilentAim.TeamCheck) end)
        end
    else
        warn("[XenoHub] Silent Aim module không load được — tính năng Silent Aim tắt")
    end
end)

if HAS.HookMeta and HAS.RawMeta and HAS.NewCClosure then
    local oldIndex
    oldIndex = hookmetamethod(game, "__index", function(t, k)
        if Config.SilentAim.Enabled and silentAimModule
           and t:IsA("Mouse") and (k == "Hit" or k == "Target")
           and silentAimModule.Check and silentAimModule.Check() then
            local part = silentAimModule.SelectedPart
            if part then
                if k == "Hit" then
                    return part.CFrame + (part.Velocity * Config.SilentAim.Prediction)
                else
                    return part
                end
            end
        end
        return oldIndex(t, k)
    end)
else
    warnMissing("hookmetamethod/getrawmetatable/newcclosure (Silent Aim)")
end

--=========================================================
-- SPEED HACK
--=========================================================
local speedConnection, bodyVel = nil, nil
local function cleanupSpeedHack()
    if speedConnection then speedConnection:Disconnect() speedConnection = nil end
    if bodyVel then pcall(function() bodyVel:Destroy() end) bodyVel = nil end
    local char = LocalPlayer.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = 16 hum.JumpPower = 50 end
    end
end
local function applySpeedHack()
    cleanupSpeedHack()
    if not Config.SpeedHack.Enabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp then return end
    hum.JumpPower = Config.SpeedHack.JumpPower
    if Config.SpeedHack.Method == "walkspeed" then
        hum.WalkSpeed = Config.SpeedHack.Speed
    else
        bodyVel = Instance.new("BodyVelocity")
        bodyVel.MaxForce = Vector3.new(math.huge, 0, math.huge)
        bodyVel.Velocity = Vector3.zero
        bodyVel.Parent = hrp
        speedConnection = RunService.Heartbeat:Connect(function()
            if not Config.SpeedHack.Enabled or not bodyVel or not bodyVel.Parent then return end
            local moveDir = hum.MoveDirection
            if moveDir.Magnitude > 0.1 then
                local targetVel = moveDir.Unit * Config.SpeedHack.Speed
                if Config.SpeedHack.Smooth then
                    bodyVel.Velocity = bodyVel.Velocity:Lerp(targetVel, 0.3)
                else
                    bodyVel.Velocity = targetVel
                end
            else
                bodyVel.Velocity = bodyVel.Velocity:Lerp(Vector3.zero, 0.5)
            end
        end)
    end
end
LocalPlayer.CharacterAdded:Connect(function() task.wait(0.5) applySpeedHack() end)

--=========================================================
-- FPS UNLOCKER
--=========================================================
local function applyFPS()
    if not HAS.SetFPSCap then warnMissing("setfpscap (FPS Unlock)") return end
    pcall(function()
        setfpscap(Config.FPSUnlocker.Enabled and Config.FPSUnlocker.Cap or 60)
    end)
end

--=========================================================
-- RAPID FIRE
--=========================================================
local rapidFireInstalled = false
local function installRapidFire()
    if rapidFireInstalled then return end
    if not (HAS.RawMeta and HAS.SetReadonly and HAS.NewCClosure and HAS.Namecall) then
        warnMissing("hook namecall (Rapid Fire)")
        return
    end
    rapidFireInstalled = true
    local mt = getrawmetatable(game)
    local oldNamecall = mt.__namecall
    setreadonly(mt, false)
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        local args = { ... }
        if Config.RapidFire.Enabled and method == "Activate" and self:IsA("Tool") then
            local result = oldNamecall(self, unpack(args))
            task.spawn(function()
                for i = 2, Config.RapidFire.Multiplier do
                    pcall(function() oldNamecall(self, unpack(args)) end)
                end
            end)
            return result
        end
        return oldNamecall(self, unpack(args))
    end)
    setreadonly(mt, true)
end
installRapidFire()

--=========================================================
-- NO RECOIL (BindToRenderStep Camera+2)
--=========================================================
local smoothedCFrame = nil
RunService:BindToRenderStep("XenoNoRecoil", Enum.RenderPriority.Camera.Value + 2, function()
    if not Config.NoRecoil.Enabled then
        smoothedCFrame = Camera.CFrame
        return
    end
    local currentCF = Camera.CFrame
    if not smoothedCFrame then smoothedCFrame = currentCF return end
    local pos = currentCF.Position
    local currRot = currentCF - pos
    local prevRot = smoothedCFrame - smoothedCFrame.Position
    local delta = currRot * prevRot:Inverse()
    local _, angle = delta:ToAxisAngle()
    if angle > math.rad(0.5) then
        local factor = math.clamp(Config.NoRecoil.SmoothFactor, 0, 1)
        local filtered = prevRot:Lerp(currRot, factor)
        Camera.CFrame = CFrame.new(pos) * filtered
        smoothedCFrame = Camera.CFrame
    else
        smoothedCFrame = currentCF
    end
end)

--=========================================================
-- ANTI-AIM (Heartbeat + pcall)
--=========================================================
local antiAimTime = 0
RunService.Heartbeat:Connect(function(dt)
    if not Config.AntiAim.Enabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    antiAimTime = antiAimTime + dt
    local yaw = antiAimTime * Config.AntiAim.YawSpeed
    local pitch = math.sin(antiAimTime * 3) * math.rad(Config.AntiAim.PitchRange)
    local roll = math.cos(antiAimTime * 2.5) * math.rad(Config.AntiAim.RollRange)
    if Config.AntiAim.Jitter then
        local j = math.rad(Config.AntiAim.JitterAmount)
        pitch = pitch + (math.random() - 0.5) * j
        roll  = roll  + (math.random() - 0.5) * j
    end
    pcall(function()
        hrp.CFrame = CFrame.new(hrp.Position) * CFrame.Angles(pitch, yaw, roll)
    end)
end)

--=========================================================
-- HITBOX EXPANDER
--=========================================================
local hitboxRestore = {}
local function applyHitboxPart(part, cfg)
    if not part then return end
    if not hitboxRestore[part] then
        hitboxRestore[part] = {
            size = part.Size, transparency = part.Transparency,
            cancollide = part.CanCollide, massless = part.Massless,
        }
    end
    part.Size = Vector3.new(cfg.Size, cfg.Size, cfg.Size)
    part.Transparency = cfg.Transparency
    part.CanCollide = false
    part.Massless = true
end
local function restoreHitboxPart(part)
    local d = hitboxRestore[part]
    if not d then return end
    if part and part.Parent then
        pcall(function()
            part.Size = d.size
            part.Transparency = d.transparency
            part.CanCollide = d.cancollide
            part.Massless = d.massless
        end)
    end
    hitboxRestore[part] = nil
end
local function applyHitbox(plr)
    if plr == LocalPlayer or not Config.Hitbox.Enabled then return end
    if sameTeam(plr, Config.Hitbox.TeamCheck) then return end
    if not isAlive(plr) then return end
    local char = plr.Character
    if not char then return end
    for _, partName in ipairs(Config.Hitbox.Parts) do
        local part = char:FindFirstChild(partName)
        if part and part:IsA("BasePart") then applyHitboxPart(part, Config.Hitbox) end
    end
end
local function restoreHitbox(plr)
    local char = plr.Character
    if not char then return end
    for _, partName in ipairs(Config.Hitbox.Parts) do
        local part = char:FindFirstChild(partName)
        if part then restoreHitboxPart(part) end
    end
end
local function refreshAllHitboxes()
    if not Config.Hitbox.Enabled then
        for _, plr in ipairs(Players:GetPlayers()) do restoreHitbox(plr) end
        for part, _ in pairs(hitboxRestore) do restoreHitboxPart(part) end
        return
    end
    for _, plr in ipairs(Players:GetPlayers()) do applyHitbox(plr) end
end
task.spawn(function() while true do task.wait(0.4) refreshAllHitboxes() end end)
Players.PlayerRemoving:Connect(restoreHitbox)

--=========================================================
-- GODMODE (rawget fix)
--=========================================================
local godmodeInstalled = false
local function installGodmode()
    if godmodeInstalled then return end
    if not (HAS.RawMeta and HAS.SetReadonly and HAS.NewCClosure and HAS.Namecall) then
        warnMissing("hook (Godmode)")
        return
    end
    godmodeInstalled = true
    local mt = getrawmetatable(game)
    local oldNewIndex = mt.__newindex
    setreadonly(mt, false)
    mt.__newindex = newcclosure(function(self, key, value)
        if Config.Godmode.Enabled and Config.Godmode.BlockHealthDecrease
           and self:IsA("Humanoid") and key == "Health" then
            local myChar = LocalPlayer.Character
            if myChar and self == myChar:FindFirstChildOfClass("Humanoid") then
                -- FIX: không dùng rawget trên userdata
                local old = self.Health
                if type(value) == "number" and type(old) == "number" and value < old then
                    return
                end
            end
        end
        return oldNewIndex(self, key, value)
    end)
    local oldNamecall = mt.__namecall
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if Config.Godmode.Enabled and Config.Godmode.BlockHealthDecrease
           and method == "TakeDamage" and self:IsA("Humanoid") then
            local myChar = LocalPlayer.Character
            if myChar and self == myChar:FindFirstChildOfClass("Humanoid") then
                return
            end
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
    if Config.Godmode.BlockFallDamage then
        RunService.Heartbeat:Connect(function()
            if not Config.Godmode.Enabled then return end
            local char = LocalPlayer.Character
            if not char then return end
            local hrp = char:FindFirstChild("HumanoidRootPart")
            if not hrp then return end
            local v = hrp.AssemblyLinearVelocity
            if v.Y < -80 then hrp.AssemblyLinearVelocity = Vector3.new(v.X, -80, v.Z) end
        end)
    end
end
installGodmode()

task.spawn(function()
    while true do
        task.wait(1)
        if Config.Godmode.Enabled then
            local char = LocalPlayer.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.MaxHealth < 1000 then
                pcall(function() hum.MaxHealth = 1000 end)
            end
        end
    end
end)

--=========================================================
-- FULLBRIGHT
--=========================================================
local fullbrightOrig = nil
local function applyFullbright()
    if Config.Fullbright.Enabled then
        if not fullbrightOrig then
            fullbrightOrig = {
                Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient,
                FogEnd = Lighting.FogEnd, FogColor = Lighting.FogColor,
                Atmosphere = {}, PostEffects = {},
            }
            for _, obj in ipairs(Lighting:GetChildren()) do
                if obj:IsA("Atmosphere") then
                    fullbrightOrig.Atmosphere[obj] = obj.Enabled
                elseif obj:IsA("PostEffect") then
                    fullbrightOrig.PostEffects[obj] = obj.Enabled
                end
            end
        end
        Lighting.Ambient = Config.Fullbright.Ambient
        Lighting.OutdoorAmbient = Config.Fullbright.OutdoorAmbient
        Lighting.FogEnd = Config.Fullbright.FogEnd
        Lighting.FogColor = Color3.new(1, 1, 1)
        if Config.Fullbright.RemoveAtmosphere then
            for _, obj in ipairs(Lighting:GetChildren()) do
                if obj:IsA("Atmosphere") then pcall(function() obj.Enabled = false end) end
            end
        end
        if Config.Fullbright.RemovePostEffects then
            for _, obj in ipairs(Lighting:GetChildren()) do
                if obj:IsA("PostEffect") then pcall(function() obj.Enabled = false end) end
            end
        end
    else
        if fullbrightOrig then
            Lighting.Ambient = fullbrightOrig.Ambient
            Lighting.OutdoorAmbient = fullbrightOrig.OutdoorAmbient
            Lighting.FogEnd = fullbrightOrig.FogEnd
            Lighting.FogColor = fullbrightOrig.FogColor
            for obj, state in pairs(fullbrightOrig.Atmosphere) do
                if obj and obj.Parent then pcall(function() obj.Enabled = state end) end
            end
            for obj, state in pairs(fullbrightOrig.PostEffects) do
                if obj and obj.Parent then pcall(function() obj.Enabled = state end) end
            end
        end
    end
end

--=========================================================
-- INFINITE JUMP
--=========================================================
UserInputService.JumpRequest:Connect(function()
    if not Config.InfiniteJump.Enabled then return end
    local char = LocalPlayer.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    hum:ChangeState(Enum.HumanoidStateType.Jumping)
end)

--=========================================================
-- FOV CHANGER
--=========================================================
local function applyFOV()
    pcall(function()
        Camera.FieldOfView = Config.FOVChanger.Enabled and Config.FOVChanger.Value or Config.FOVChanger.Default
    end)
end
Camera:GetPropertyChangedSignal("FieldOfView"):Connect(function()
    if Config.FOVChanger.Enabled and Camera.FieldOfView ~= Config.FOVChanger.Value then
        Camera.FieldOfView = Config.FOVChanger.Value
    end
end)

--=========================================================
-- FOV CIRCLE
--=========================================================
local fovCircle = nil
if HAS.Drawing then
    pcall(function()
        fovCircle = Drawing.new("Circle")
        fovCircle.Visible = false
        fovCircle.Filled = false
        fovCircle.Transparency = 1
    end)
else
    warnMissing("Drawing (FOV Circle)")
end

RunService.RenderStepped:Connect(function()
    if not fovCircle then return end
    if not Config.FOVCircle.Enabled then fovCircle.Visible = false return end
    fovCircle.Radius = Config.FOVCircle.UseAimlockFOV and Config.Aimlock.FOV or Config.FOVCircle.Value
    fovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    fovCircle.Thickness = Config.FOVCircle.Thickness
    fovCircle.Color = Config.FOVCircle.Color
    fovCircle.NumSides = Config.FOVCircle.Sides
    fovCircle.Visible = true
end)

--=========================================================
-- FIX LAG
--=========================================================
local function applyFixLag()
    if not Config.FixLag.Enabled then return end
    if Config.FixLag.ClearTerrain then pcall(function() workspace.Terrain:Clear() end) end
    pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.FogEnd = 100000
        Lighting.Brightness = 1
    end)
    if Config.FixLag.DisableEffects then
        for _, obj in ipairs(Lighting:GetChildren()) do
            if obj:IsA("PostEffect") or obj:IsA("Sky") or obj:IsA("Atmosphere") then
                pcall(function() obj.Enabled = false end)
            end
        end
        pcall(function()
            Lighting.EnvironmentDiffuseScale = 0
            Lighting.EnvironmentSpecularScale = 0
        end)
    end
    for _, v in ipairs(Workspace:GetDescendants()) do
        if v:IsA("ParticleEmitter") or v:IsA("Smoke") or v:IsA("Fire")
           or v:IsA("Sparkles") or v:IsA("Decal") or v:IsA("Texture") then
            pcall(function() v.Enabled = false end)
        end
    end
    if Config.FixLag.CapFPS and HAS.SetFPSCap then
        pcall(function() setfpscap(Config.FixLag.CapFPS) end)
    end
end

--=========================================================
-- TELEPORT
--=========================================================
local function teleportTo(plr)
    if not plr or plr == LocalPlayer then return end
    local myChar = LocalPlayer.Character
    local myHrp = myChar and myChar:FindFirstChild("HumanoidRootPart")
    local targetChar = plr.Character
    local targetHrp = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
    if not myHrp or not targetHrp then return end
    local targetPos = targetHrp.Position + Config.Teleport.Offset + Vector3.new(0, Config.Teleport.HeightOffset, 0)
    myHrp.CFrame = CFrame.new(targetPos)
end

--=========================================================
-- UI
--=========================================================
local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "XenoHubUI"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = (gethui and gethui()) or CoreGui

local PlayerListFrame = Instance.new("Frame")
PlayerListFrame.Size = UDim2.new(0, 260, 0, 300)
PlayerListFrame.Position = UDim2.new(0, 320, 0, 20)
PlayerListFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
PlayerListFrame.BorderSizePixel = 0
PlayerListFrame.Visible = false
PlayerListFrame.ClipsDescendants = true
PlayerListFrame.Parent = ScreenGui

local PLCorner = Instance.new("UICorner")
PLCorner.CornerRadius = UDim.new(0, 8)
PLCorner.Parent = PlayerListFrame

local PLTitle = Instance.new("TextLabel")
PLTitle.Size = UDim2.new(1, 0, 0, 32)
PLTitle.BackgroundColor3 = Color3.fromRGB(60, 60, 200)
PLTitle.BorderSizePixel = 0
PLTitle.Text = "PLAYER LIST — click để tele"
PLTitle.TextColor3 = Color3.fromRGB(255, 255, 255)
PLTitle.Font = Enum.Font.GothamBold
PLTitle.TextSize = 12
PLTitle.Parent = PlayerListFrame

local PLTitleCorner = Instance.new("UICorner")
PLTitleCorner.CornerRadius = UDim.new(0, 8)
PLTitleCorner.Parent = PLTitle

local PLScroll = Instance.new("ScrollingFrame")
PLScroll.Size = UDim2.new(1, 0, 1, -32)
PLScroll.Position = UDim2.new(0, 0, 0, 32)
PLScroll.BackgroundTransparency = 1
PLScroll.BorderSizePixel = 0
PLScroll.ScrollBarThickness = 4
PLScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
PLScroll.Parent = PlayerListFrame

local PLList = Instance.new("UIListLayout")
PLList.Padding = UDim.new(0, 4)
PLList.SortOrder = Enum.SortOrder.LayoutOrder
PLList.Parent = PLScroll

local plButtons = {}
local function refreshPlayerList()
    for _, btn in pairs(plButtons) do btn:Destroy() end
    plButtons = {}
    local players = Players:GetPlayers()
    table.sort(players, function(a, b)
        local aHrp = a.Character and a.Character:FindFirstChild("HumanoidRootPart")
        local bHrp = b.Character and b.Character:FindFirstChild("HumanoidRootPart")
        local myHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not myHrp then return a.Name < b.Name end
        local da = aHrp and (aHrp.Position - myHrp.Position).Magnitude or math.huge
        local db = bHrp and (bHrp.Position - myHrp.Position).Magnitude or math.huge
        return da < db
    end)
    local yPos = 0
    for _, plr in ipairs(players) do
        if plr ~= LocalPlayer then
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1, -8, 0, 30)
            btn.Position = UDim2.new(0, 4, 0, yPos)
            btn.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
            btn.BorderSizePixel = 0
            btn.TextColor3 = Color3.fromRGB(220, 220, 220)
            btn.Font = Enum.Font.Gotham
            btn.TextSize = 12
            btn.Text = plr.Name
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.Parent = PLScroll
            local btnCorner = Instance.new("UICorner")
            btnCorner.CornerRadius = UDim.new(0, 4)
            btnCorner.Parent = btn
            local label = btn
            task.spawn(function()
                while label.Parent do
                    local myHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                    local tHrp = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
                    if myHrp and tHrp then
                        local d = (myHrp.Position - tHrp.Position).Magnitude
                        label.Text = string.format("%s  [%d]", plr.Name, math.floor(d))
                    else
                        label.Text = plr.Name
                    end
                    task.wait(0.5)
                end
            end)
            btn.MouseButton1Click:Connect(function() teleportTo(plr) end)
            table.insert(plButtons, btn)
            yPos = yPos + 34
        end
    end
    PLScroll.CanvasSize = UDim2.new(0, 0, 0, yPos)
end
Players.PlayerAdded:Connect(function() task.wait(0.5) refreshPlayerList() end)
Players.PlayerRemoving:Connect(function() task.wait(0.5) refreshPlayerList() end)
refreshPlayerList()

local ToggleKey = Enum.KeyCode.RightShift

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 280, 0, 380)
Frame.Position = UDim2.new(0, 20, 0, 20)
Frame.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
Frame.BorderSizePixel = 0
Frame.Active = true
Frame.Draggable = true
Frame.ClipsDescendants = true
Frame.Parent = ScreenGui

local UICorner = Instance.new("UICorner")
UICorner.CornerRadius = UDim.new(0, 8)
UICorner.Parent = Frame

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = Frame

local TitleBarCorner = Instance.new("UICorner")
TitleBarCorner.CornerRadius = UDim.new(0, 8)
TitleBarCorner.Parent = TitleBar

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -70, 1, 0)
Title.Position = UDim2.new(0, 10, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "XENO HUB  [RShift]"
Title.TextColor3 = Color3.fromRGB(255, 255, 255)
Title.Font = Enum.Font.GothamBold
Title.TextSize = 13
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Parent = TitleBar

local MinBtn = Instance.new("TextButton")
MinBtn.Size = UDim2.new(0, 24, 0, 24)
MinBtn.Position = UDim2.new(1, -56, 0, 4)
MinBtn.BackgroundColor3 = Color3.fromRGB(200, 40, 40)
MinBtn.BorderSizePixel = 0
MinBtn.Text = "—"
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 16
MinBtn.Parent = TitleBar

local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 4)
MinCorner.Parent = MinBtn

local HideBtn = Instance.new("TextButton")
HideBtn.Size = UDim2.new(0, 24, 0, 24)
HideBtn.Position = UDim2.new(1, -28, 0, 4)
HideBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
HideBtn.BorderSizePixel = 0
HideBtn.Text = "×"
HideBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
HideBtn.Font = Enum.Font.GothamBold
HideBtn.TextSize = 16
HideBtn.Parent = TitleBar

local HideCorner = Instance.new("UICorner")
HideCorner.CornerRadius = UDim.new(0, 4)
HideCorner.Parent = HideBtn

local TabBar = Instance.new("Frame")
TabBar.Size = UDim2.new(1, 0, 0, 32)
TabBar.Position = UDim2.new(0, 0, 0, 32)
TabBar.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
TabBar.BorderSizePixel = 0
TabBar.Parent = Frame

local TabLayout = Instance.new("UIListLayout")
TabLayout.FillDirection = Enum.FillDirection.Horizontal
TabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
TabLayout.VerticalAlignment = Enum.VerticalAlignment.Center
TabLayout.Padding = UDim.new(0, 4)
TabLayout.Parent = TabBar

local Content = Instance.new("Frame")
Content.Size = UDim2.new(1, 0, 1, -64)
Content.Position = UDim2.new(0, 0, 0, 64)
Content.BackgroundTransparency = 1
Content.Parent = Frame

local OpenBtn = Instance.new("TextButton")
OpenBtn.Size = UDim2.new(0, 40, 0, 40)
OpenBtn.Position = UDim2.new(0, 20, 0, 20)
OpenBtn.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
OpenBtn.BorderSizePixel = 0
OpenBtn.Text = "X"
OpenBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
OpenBtn.Font = Enum.Font.GothamBold
OpenBtn.TextSize = 18
OpenBtn.Visible = false
OpenBtn.Active = true
OpenBtn.Draggable = true
OpenBtn.Parent = ScreenGui

local OpenCorner = Instance.new("UICorner")
OpenCorner.CornerRadius = UDim.new(1, 0)
OpenCorner.Parent = OpenBtn

local EXPANDED_SIZE  = UDim2.new(0, 280, 0, 380)
local MINIMIZED_SIZE = UDim2.new(0, 280, 0, 32)
local isMinimized = false
local function setMinimized(v)
    isMinimized = v
    if v then
        Frame.Size = MINIMIZED_SIZE
        TabBar.Visible = false
        Content.Visible = false
        MinBtn.Text = "+"
    else
        Frame.Size = EXPANDED_SIZE
        TabBar.Visible = true
        Content.Visible = true
        MinBtn.Text = "—"
    end
end
MinBtn.MouseButton1Click:Connect(function() setMinimized(not isMinimized) end)
TitleBar.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
       and not MinBtn:IsHovered() and not HideBtn:IsHovered() then
        setMinimized(not isMinimized)
    end
end)
local function setMenuVisible(v) Frame.Visible = v OpenBtn.Visible = not v end
HideBtn.MouseButton1Click:Connect(function() setMenuVisible(false) end)
OpenBtn.MouseButton1Click:Connect(function() setMenuVisible(true) end)
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == ToggleKey then setMenuVisible(not Frame.Visible) end
end)

local Tabs = {}
local function createTab(name)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 80, 0, 24)
    btn.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
    btn.BorderSizePixel = 0
    btn.Text = name
    btn.TextColor3 = Color3.fromRGB(180, 180, 180)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 12
    btn.Parent = TabBar
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 4)
    c.Parent = btn

    local page = Instance.new("ScrollingFrame")
    page.Size = UDim2.new(1, 0, 1, 0)
    page.BackgroundTransparency = 1
    page.BorderSizePixel = 0
    page.ScrollBarThickness = 4
    page.ScrollBarImageColor3 = Color3.fromRGB(255, 60, 60)
    page.CanvasSize = UDim2.new(0, 0, 0, 0)
    page.Visible = false
    page.Parent = Content

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 6)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = page

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 6)
    padding.PaddingBottom = UDim.new(0, 6)
    padding.PaddingLeft = UDim.new(0, 6)
    padding.PaddingRight = UDim.new(0, 6)
    padding.Parent = page

    local tab = { Name = name, Button = btn, Page = page, Layout = layout }
    table.insert(Tabs, tab)
    btn.MouseButton1Click:Connect(function()
        for _, t in ipairs(Tabs) do
            t.Button.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
            t.Button.TextColor3 = Color3.fromRGB(180, 180, 180)
            t.Page.Visible = false
        end
        btn.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
        btn.TextColor3 = Color3.fromRGB(255, 255, 255)
        page.Visible = true
    end)
    return tab
end

local function addToggleToTab(tab, text, getter, setter)
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -8, 0, 28)
    btn.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
    btn.BorderSizePixel = 0
    btn.TextColor3 = Color3.fromRGB(220, 220, 220)
    btn.Font = Enum.Font.Gotham
    btn.TextSize = 13
    btn.Text = text .. ": " .. (getter() and "ON" or "OFF")
    btn.Parent = tab.Page
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 4)
    c.Parent = btn
    btn.MouseButton1Click:Connect(function()
        setter(not getter())
        btn.Text = text .. ": " .. (getter() and "ON" or "OFF")
    end)
end

local CombatTab = createTab("COMBAT")
local VisualTab = createTab("VISUAL")
local MiscTab   = createTab("MISC")

-- COMBAT
addToggleToTab(CombatTab, "Aimlock", function() return Config.Aimlock.Enabled end, function(v) Config.Aimlock.Enabled = v end)
addToggleToTab(CombatTab, "Silent Aim", function() return Config.SilentAim.Enabled end, function(v) Config.SilentAim.Enabled = v end)
addToggleToTab(CombatTab, "Rapid Fire", function() return Config.RapidFire.Enabled end, function(v) Config.RapidFire.Enabled = v end)
addToggleToTab(CombatTab, "No Recoil", function() return Config.NoRecoil.Enabled end, function(v) Config.NoRecoil.Enabled = v end)
addToggleToTab(CombatTab, "Hitbox+", function() return Config.Hitbox.Enabled end, function(v) Config.Hitbox.Enabled = v; refreshAllHitboxes() end)
addToggleToTab(CombatTab, "Anti-Aim+", function() return Config.AntiAim.Enabled end, function(v) Config.AntiAim.Enabled = v end)
addToggleToTab(CombatTab, "FOV Circle", function() return Config.FOVCircle.Enabled end, function(v) Config.FOVCircle.Enabled = v end)

-- VISUAL
addToggleToTab(VisualTab, "Chams", function() return Config.Chams.Enabled end, function(v) Config.Chams.Enabled = v; refreshChams() end)
addToggleToTab(VisualTab, "Fullbright", function() return Config.Fullbright.Enabled end, function(v) Config.Fullbright.Enabled = v; applyFullbright() end)
addToggleToTab(VisualTab, "FOV Changer", function() return Config.FOVChanger.Enabled end, function(v) Config.FOVChanger.Enabled = v; applyFOV() end)
addToggleToTab(VisualTab, "Fix Lag", function() return Config.FixLag.Enabled end, function(v) Config.FixLag.Enabled = v; if v then applyFixLag() end end)

-- MISC
addToggleToTab(MiscTab, "Speed Hack", function() return Config.SpeedHack.Enabled end, function(v) Config.SpeedHack.Enabled = v; applySpeedHack() end)
addToggleToTab(MiscTab, "Infinite Jump", function() return Config.InfiniteJump.Enabled end, function(v) Config.InfiniteJump.Enabled = v end)
addToggleToTab(MiscTab, "Godmode", function() return Config.Godmode.Enabled end, function(v) Config.Godmode.Enabled = v end)
addToggleToTab(MiscTab, "FPS Unlock", function() return Config.FPSUnlocker.Enabled end, function(v) Config.FPSUnlocker.Enabled = v; applyFPS() end)
addToggleToTab(MiscTab, "Teleport UI", function() return PlayerListFrame.Visible end, function(v) PlayerListFrame.Visible = v; if v then refreshPlayerList() end end)
addToggleToTab(MiscTab, "Team Check",
    function() return Config.Aimlock.TeamCheck and Config.SilentAim.TeamCheck and Config.Hitbox.TeamCheck and Config.Chams.TeamCheck end,
    function(v)
        Config.Aimlock.TeamCheck = v
        Config.SilentAim.TeamCheck = v
        Config.Hitbox.TeamCheck = v
        Config.Chams.TeamCheck = v
        if silentAimModule and silentAimModule.TeamCheck then
            pcall(function() silentAimModule.TeamCheck(v) end)
        end
    end)
addToggleToTab(MiscTab, "Wall Check", function() return Config.Aimlock.WallCheck end, function(v) Config.Aimlock.WallCheck = v end)
addToggleToTab(MiscTab, "Aim Debug", function() return Config.Aimlock.Debug end, function(v) Config.Aimlock.Debug = v end)

-- Default tab
for _, t in ipairs(Tabs) do
    t.Button.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
    t.Button.TextColor3 = Color3.fromRGB(180, 180, 180)
    t.Page.Visible = false
end
Tabs[1].Button.BackgroundColor3 = Color3.fromRGB(255, 60, 60)
Tabs[1].Button.TextColor3 = Color3.fromRGB(255, 255, 255)
Tabs[1].Page.Visible = true

--=========================================================
-- CLEANUP
--=========================================================
LocalPlayer.OnTeleport:Connect(function()
    Config.Aimlock.Enabled = false
    Config.NoRecoil.Enabled = false
    aimTarget, aimTargetPart = nil, nil
    pcall(function() RunService:UnbindFromRenderStep("XenoAimlock") end)
    pcall(function() RunService:UnbindFromRenderStep("XenoNoRecoil") end)
    for plr, _ in pairs(chamsHighlights) do removeChams(plr) end
    if fovCircle then pcall(function() fovCircle:Remove() end) end
    pcall(function() ScreenGui:Destroy() end)
end)
