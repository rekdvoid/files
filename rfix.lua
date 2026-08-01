if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait()
    LocalPlayer = Players.LocalPlayer
end

-- Resolve Safe UI Parent
local function GetUIParent()
    if gethui then
        local success, res = pcall(gethui)
        if success and res then return res end
    end
    local successCore, coreGui = pcall(function() return game:GetService("CoreGui") end)
    if successCore and coreGui then return coreGui end
    return LocalPlayer:WaitForChild("PlayerGui", 5)
end

-- Safe mousemoverel wrapper with NaN / Infinite parameter guards
local raw_mousemoverel = mousemoverel or (Input and Input.MouseMove) or (mousemove)
local function SafeMouseMoveRel(x, y)
    if not raw_mousemoverel then return end
    -- Check for NaN, nil, or Infinity
    if x ~= x or y ~= y or x == math.huge or y == math.huge or x == -math.huge or y == -math.huge then
        return
    end
    -- Prevent extreme jumps that crash C++ buffers
    if math.abs(x) > 2000 or math.abs(y) > 2000 then
        return
    end
    pcall(raw_mousemoverel, x, y)
end

local queue_on_teleport = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport) or queueonteleport

-- Configuration
local Settings = {
    Enabled = false,
    ShowFOV = true,
    FOV = 120,
    Sensitivity = 0.25,
    Prediction = true,
    PredictionAmount = 0.01,
    TeamCheck = true,
    WallCheck = true,
    TargetPart = "HumanoidRootPart",
    TargetType = "ALL",
    Keybind = Enum.KeyCode.L,
    HideKeybind = Enum.KeyCode.Insert,
    KillKeybind = Enum.KeyCode.Delete,
    UIVisible = true
}

-- Config Persistence
local ConfigFileName = "AimbotConfig.json"

local function SaveConfig()
    if writefile then
        local configData = {
            ShowFOV = Settings.ShowFOV,
            FOV = Settings.FOV,
            Sensitivity = Settings.Sensitivity,
            Prediction = Settings.Prediction,
            PredictionAmount = Settings.PredictionAmount,
            TeamCheck = Settings.TeamCheck,
            WallCheck = Settings.WallCheck,
            TargetPart = Settings.TargetPart,
            TargetType = Settings.TargetType
        }
        pcall(function()
            writefile(ConfigFileName, HttpService:JSONEncode(configData))
        end)
    end
end

local function LoadConfig()
    if readfile and isfile then
        pcall(function()
            if isfile(ConfigFileName) then
                local result = HttpService:JSONDecode(readfile(ConfigFileName))
                if type(result) == "table" then
                    if result.ShowFOV ~= nil then Settings.ShowFOV = result.ShowFOV end
                    if result.FOV ~= nil then Settings.FOV = result.FOV end
                    if result.Sensitivity ~= nil then Settings.Sensitivity = result.Sensitivity end
                    if result.Prediction ~= nil then Settings.Prediction = result.Prediction end
                    if result.PredictionAmount ~= nil then Settings.PredictionAmount = result.PredictionAmount end
                    if result.TeamCheck ~= nil then Settings.TeamCheck = result.TeamCheck end
                    if result.WallCheck ~= nil then Settings.WallCheck = result.WallCheck end
                    if result.TargetPart ~= nil then Settings.TargetPart = result.TargetPart end
                    if result.TargetType ~= nil then Settings.TargetType = result.TargetType end
                end
            end
        end)
    end
end

-- Constants
local MIN_FOV = 50
local MAX_FOV = 360
local FOV_STEP = 10

local MIN_SENS = 0.05
local MAX_SENS = 1.00
local SENS_STEP = 0.05

local function GetCamera()
    return workspace.CurrentCamera
end

local SharedRaycastParams = RaycastParams.new()
SharedRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

local GUI = {
    ScreenGui = nil,
    MainFrame = nil,
    Labels = {},
    Buttons = {}
}

local CachedTargets = {}

-- Safe Drawing Creation
local FOVCircle = nil
pcall(function()
    if Drawing then
        FOVCircle = Drawing.new("Circle")
        FOVCircle.Color = Color3.fromRGB(255, 255, 255)
        FOVCircle.Thickness = 2
        FOVCircle.Filled = false
        FOVCircle.Transparency = 0.5
        FOVCircle.Visible = false
    end
end)

local StartTime = tick()
local InputConnection = nil
local CharacterConnection = nil
local RenderConnection = nil
local RuntimeThread = nil
local TargetScanThread = nil

local function UpdateRuntimeLabel()
    local runtime = math.floor(tick() - StartTime)
    local hours = math.floor(runtime / 3600)
    local minutes = math.floor((runtime % 3600) / 60)
    local seconds = runtime % 60
    
    if GUI.Labels.Runtime then
        GUI.Labels.Runtime.Text = string.format("Runtime: %02d:%02d:%02d", hours, minutes, seconds)
    end
end

local function GetCharacterTargetPart(character)
    if not character or not character:IsDescendantOf(workspace) then return nil end
    return character:FindFirstChild(Settings.TargetPart) 
        or character:FindFirstChild("Head") 
        or character:FindFirstChild("HumanoidRootPart") 
        or character.PrimaryPart
end

local function IsCharacterValid(character)
    if not character or not character.Parent or not character:IsDescendantOf(workspace) then
        return false
    end
    
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not humanoid or humanoid.Health <= 0 then
        return false
    end
    
    return GetCharacterTargetPart(character) ~= nil
end

local function IsVisible(character, targetPart)
    if not Settings.WallCheck then
        return true
    end
    
    local Camera = GetCamera()
    if not Camera then return false end

    local origin = Camera.CFrame.Position
    local direction = targetPart.Position - origin
    
    local localChar = LocalPlayer.Character
    if localChar then
        SharedRaycastParams.FilterDescendantsInstances = { character, localChar }
    else
        SharedRaycastParams.FilterDescendantsInstances = { character }
    end
    
    local success, result = pcall(function()
        return workspace:Raycast(origin, direction, SharedRaycastParams)
    end)
    
    return success and (result == nil)
end

local function UpdateTargetCache()
    local targets = {}
    
    if Settings.TargetType == "ALL" or Settings.TargetType == "PLAYER" then
        local localTeam = LocalPlayer.Team
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then
                local char = player.Character
                if char and IsCharacterValid(char) then
                    if not (Settings.TeamCheck and localTeam and player.Team == localTeam) then
                        table.insert(targets, char)
                    end
                end
            end
        end
    end
    
    if Settings.TargetType == "ALL" or Settings.TargetType == "NPC" then
        for _, object in ipairs(workspace:GetChildren()) do
            if object:IsA("Model") and object ~= LocalPlayer.Character and not Players:GetPlayerFromCharacter(object) then
                if object:FindFirstChildOfClass("Humanoid") and IsCharacterValid(object) then
                    table.insert(targets, object)
                end
            end
        end
    end
    
    CachedTargets = targets
end

local function FindClosestHumanoid()
    local Camera = GetCamera()
    if not Camera then return nil end

    local viewportSize = Camera.ViewportSize
    if viewportSize.X <= 0 or viewportSize.Y <= 0 then return nil end

    local closestTarget = nil
    local closestDistance = Settings.FOV
    local center = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)

    for _, character in ipairs(CachedTargets) do
        if IsCharacterValid(character) then
            local targetPart = GetCharacterTargetPart(character)
            if targetPart and targetPart:IsDescendantOf(workspace) then
                local targetPos = targetPart.Position
                
                if Settings.Prediction then
                    local velocity = targetPart.AssemblyLinearVelocity or targetPart.Velocity
                    if velocity then
                        targetPos = targetPos + (velocity * Settings.PredictionAmount)
                    end
                end

                local screenPos, onScreen = Camera:WorldToViewportPoint(targetPos)
                if onScreen then
                    local distance = (Vector2.new(screenPos.X, screenPos.Y) - center).Magnitude
                    if distance < closestDistance then
                        if IsVisible(character, targetPart) then
                            closestDistance = distance
                            closestTarget = character
                        end
                    end
                end
            end
        end
    end
    
    return closestTarget
end

local function ToggleUIVisibility()
    Settings.UIVisible = not Settings.UIVisible
    if GUI.MainFrame then
        GUI.MainFrame.Visible = Settings.UIVisible
    end
end

local function UnloadScript()
    Settings.Enabled = false
    
    -- Safe Connection Disconnect Guard
if RenderConnection then
    local conn = RenderConnection
    RenderConnection = nil
    pcall(function()
        if conn.Connected then
            conn:Disconnect()
        end
    end)
end

if InputConnection then
    local conn = InputConnection
    InputConnection = nil
    pcall(function()
        if conn.Connected then
            conn:Disconnect()
        end
    end)
end

if CharacterConnection then
    local conn = CharacterConnection
    CharacterConnection = nil
    pcall(function()
        if conn.Connected then
            conn:Disconnect()
        end
    end)
end

-- Safe Thread Cancellation Guard
if RuntimeThread then
    local thread = RuntimeThread
    RuntimeThread = nil
    pcall(function()
        if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
            task.cancel(thread)
        end
    end)
end

if TargetScanThread then
    local thread = TargetScanThread
    TargetScanThread = nil
    pcall(function()
        if coroutine.status(thread) ~= "dead" and thread ~= coroutine.running() then
            task.cancel(thread)
        end
    end)
end
    
    if FOVCircle then
        pcall(function()
            FOVCircle.Visible = false
            FOVCircle:Remove()
        end)
    end
    
    if GUI.ScreenGui then
        GUI.ScreenGui:Destroy()
    end
    
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
end

local function CreateButton(text, position, callback)
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(0, 110, 0, 35)
    button.Position = UDim2.new(position.X, position.Y, position.Z, position.W)
    button.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
    button.BackgroundTransparency = 0
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Text = text
    button.Font = Enum.Font.GothamSemibold
    button.TextSize = 12
    button.Parent = GUI.MainFrame
    
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = button
    
    if callback then
        button.MouseButton1Click:Connect(callback)
    end
    
    return button
end

local function CreateLabel(text, position, color)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 25)
    label.Position = UDim2.new(position.X, position.Y, position.Z, position.W)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = color or Color3.fromRGB(180, 180, 180)
    label.Font = Enum.Font.Gotham
    label.TextSize = 13
    label.Parent = GUI.MainFrame
    
    return label
end

local function SetupGUI()
    local uiParent = GetUIParent()
    
    if uiParent:FindFirstChild("AimBotGUI") then
        uiParent.AimBotGUI:Destroy()
    end

    GUI.ScreenGui = Instance.new("ScreenGui")
    GUI.ScreenGui.Name = "AimBotGUI"
    GUI.ScreenGui.ResetOnSpawn = false
    GUI.ScreenGui.DisplayOrder = 999
    GUI.ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    GUI.ScreenGui.Parent = uiParent
    
    GUI.MainFrame = Instance.new("Frame")
    GUI.MainFrame.Size = UDim2.new(0, 280, 0, 550)
    GUI.MainFrame.Position = UDim2.new(0, 20, 0.5, -275)
    GUI.MainFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    GUI.MainFrame.BackgroundTransparency = 0
    GUI.MainFrame.Active = true
    GUI.MainFrame.Draggable = true
    GUI.MainFrame.Visible = Settings.UIVisible
    GUI.MainFrame.Parent = GUI.ScreenGui
    
    local mainCorner = Instance.new("UICorner")
    mainCorner.CornerRadius = UDim.new(0, 10)
    mainCorner.Parent = GUI.MainFrame
    
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 40)
    title.BackgroundTransparency = 1
    title.Text = "Aim System v3.5 (Stable)"
    title.TextColor3 = Color3.fromRGB(255, 255, 255)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 17
    title.Parent = GUI.MainFrame
    
    local separator = Instance.new("Frame")
    separator.Size = UDim2.new(1, -20, 0, 1)
    separator.Position = UDim2.new(0, 10, 0, 40)
    separator.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
    separator.BackgroundTransparency = 0
    separator.Parent = GUI.MainFrame
    
    GUI.Labels.Runtime = CreateLabel("Runtime: 00:00:00", {X = 0, Y = 0, Z = 0, W = 45}, Color3.fromRGB(200, 200, 200))
    
    local fovLabel = CreateLabel("FOV: " .. Settings.FOV, {X = 0, Y = 0, Z = 0, W = 70}, Color3.fromRGB(200, 200, 200))

    GUI.Buttons.Toggle = CreateButton(Settings.Enabled and "ENABLED" or "DISABLED", {X = 0.05, Y = 0, Z = 0, W = 100}, function()
        Settings.Enabled = not Settings.Enabled
        GUI.Buttons.Toggle.Text = Settings.Enabled and "ENABLED" or "DISABLED"
        GUI.Buttons.Toggle.BackgroundColor3 = Settings.Enabled and Color3.fromRGB(0, 150, 0) or Color3.fromRGB(35, 35, 35)
        if FOVCircle then FOVCircle.Visible = Settings.Enabled and Settings.ShowFOV end
    end)
    GUI.Buttons.Toggle.BackgroundColor3 = Settings.Enabled and Color3.fromRGB(0, 150, 0) or Color3.fromRGB(35, 35, 35)
    
    GUI.Buttons.FOVPlus = CreateButton("FOV +" .. FOV_STEP, {X = 0.55, Y = 0, Z = 0, W = 100}, function()
        Settings.FOV = math.min(MAX_FOV, Settings.FOV + FOV_STEP)
        fovLabel.Text = "FOV: " .. Settings.FOV
        SaveConfig()
    end)
    
    GUI.Buttons.FOVShow = CreateButton(Settings.ShowFOV and "FOV: SHOW" or "FOV: HIDE", {X = 0.05, Y = 0, Z = 0, W = 145}, function()
        Settings.ShowFOV = not Settings.ShowFOV
        GUI.Buttons.FOVShow.Text = Settings.ShowFOV and "FOV: SHOW" or "FOV: HIDE"
        if FOVCircle then FOVCircle.Visible = Settings.Enabled and Settings.ShowFOV end
        SaveConfig()
    end)

    GUI.Buttons.FOVMinus = CreateButton("FOV -" .. FOV_STEP, {X = 0.55, Y = 0, Z = 0, W = 145}, function()
        Settings.FOV = math.max(MIN_FOV, Settings.FOV - FOV_STEP)
        fovLabel.Text = "FOV: " .. Settings.FOV
        SaveConfig()
    end)

    local sensLabel = CreateLabel(string.format("SENSITIVITY: %.2f", Settings.Sensitivity), {X = 0, Y = 0, Z = 0, W = 190}, Color3.fromRGB(200, 200, 200))

    GUI.Buttons.SensPlus = CreateButton("SENS +", {X = 0.05, Y = 0, Z = 0, W = 220}, function()
        Settings.Sensitivity = math.min(MAX_SENS, Settings.Sensitivity + SENS_STEP)
        sensLabel.Text = string.format("SENSITIVITY: %.2f", Settings.Sensitivity)
        SaveConfig()
    end)

    GUI.Buttons.SensMinus = CreateButton("SENS -", {X = 0.55, Y = 0, Z = 0, W = 220}, function()
        Settings.Sensitivity = math.max(MIN_SENS, Settings.Sensitivity - SENS_STEP)
        sensLabel.Text = string.format("SENSITIVITY: %.2f", Settings.Sensitivity)
        SaveConfig()
    end)

    GUI.Buttons.Prediction = CreateButton(Settings.Prediction and "PRED: ON" or "PRED: OFF", {X = 0.05, Y = 0, Z = 0, W = 265}, function()
        Settings.Prediction = not Settings.Prediction
        GUI.Buttons.Prediction.Text = Settings.Prediction and "PRED: ON" or "PRED: OFF"
        SaveConfig()
    end)
    GUI.Buttons.Prediction.Size = UDim2.new(0, 252, 0, 35)

    GUI.Buttons.Team = CreateButton(Settings.TeamCheck and "TEAM: ON" or "TEAM: OFF", {X = 0.05, Y = 0, Z = 0, W = 310}, function()
        Settings.TeamCheck = not Settings.TeamCheck
        GUI.Buttons.Team.Text = Settings.TeamCheck and "TEAM: ON" or "TEAM: OFF"
        SaveConfig()
    end)
    
    GUI.Buttons.Wall = CreateButton(Settings.WallCheck and "WALL: ON" or "WALL: OFF", {X = 0.55, Y = 0, Z = 0, W = 310}, function()
        Settings.WallCheck = not Settings.WallCheck
        GUI.Buttons.Wall.Text = Settings.WallCheck and "WALL: ON" or "WALL: OFF"
        SaveConfig()
    end)
    
    local targetPartText = Settings.TargetPart == "HumanoidRootPart" and "TARGET: BODY" or "TARGET: HEAD"
    GUI.Buttons.Part = CreateButton(targetPartText, {X = 0.05, Y = 0, Z = 0, W = 355}, function()
        Settings.TargetPart = Settings.TargetPart == "HumanoidRootPart" and "Head" or "HumanoidRootPart"
        GUI.Buttons.Part.Text = Settings.TargetPart == "HumanoidRootPart" and "TARGET: BODY" or "TARGET: HEAD"
        SaveConfig()
    end)
    
    GUI.Buttons.Type = CreateButton("TYPE: " .. Settings.TargetType, {X = 0.55, Y = 0, Z = 0, W = 355}, function()
        if Settings.TargetType == "ALL" then
            Settings.TargetType = "PLAYER"
            GUI.Buttons.Type.Text = "TYPE: PLAYER"
        elseif Settings.TargetType == "PLAYER" then
            Settings.TargetType = "NPC"
            GUI.Buttons.Type.Text = "TYPE: NPC"
        else
            Settings.TargetType = "ALL"
            GUI.Buttons.Type.Text = "TYPE: ALL"
        end
        SaveConfig()
    end)

    GUI.Buttons.Hide = CreateButton("HIDE UI (INS)", {X = 0.05, Y = 0, Z = 0, W = 400}, function()
        ToggleUIVisibility()
    end)
    GUI.Buttons.Hide.Size = UDim2.new(0, 252, 0, 35)

    GUI.Buttons.Kill = CreateButton("KILL SCRIPT (DEL)", {X = 0.05, Y = 0, Z = 0, W = 443}, function()
        UnloadScript()
    end)
    GUI.Buttons.Kill.Size = UDim2.new(0, 252, 0, 35)
    GUI.Buttons.Kill.BackgroundColor3 = Color3.fromRGB(150, 35, 35)
end

local function SetupKeybind()
    InputConnection = UserInputService.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        
        if input.KeyCode == Settings.Keybind then
            Settings.Enabled = not Settings.Enabled
            GUI.Buttons.Toggle.Text = Settings.Enabled and "ENABLED" or "DISABLED"
            GUI.Buttons.Toggle.BackgroundColor3 = Settings.Enabled and Color3.fromRGB(0, 150, 0) or Color3.fromRGB(35, 35, 35)
            if FOVCircle then FOVCircle.Visible = Settings.Enabled and Settings.ShowFOV end
        elseif input.KeyCode == Settings.HideKeybind then
            ToggleUIVisibility()
        elseif input.KeyCode == Settings.KillKeybind then
            UnloadScript()
        end
    end)
end

local function Initialize()
    LoadConfig()
    SetupGUI()
    SetupKeybind()
    
    CharacterConnection = LocalPlayer.CharacterAdded:Connect(function()
        task.wait(1)
        if not GUI.ScreenGui or not GUI.ScreenGui.Parent then
            SetupGUI()
        end
    end)
    
    if queue_on_teleport then
        pcall(function()
            queue_on_teleport([[
                repeat task.wait() until game:IsLoaded()
                task.wait(2)
                pcall(function()
                    loadstring(game:HttpGet("https://raw.githubusercontent.com/rekdvoid/files/refs/heads/main/rfix.lua"))()
                end)
            ]])
        end)
    end
    
    RuntimeThread = task.spawn(function()
        while true do
            pcall(UpdateRuntimeLabel)
            task.wait(1)
        end
    end)

    TargetScanThread = task.spawn(function()
        while true do
            pcall(UpdateTargetCache)
            task.wait(0.2)
        end
    end)
    
    -- RenderStepped connection replacing BindToRenderStep to avoid engine pipeline crashes
    RenderConnection = RunService.RenderStepped:Connect(function()
        pcall(function()
            local Camera = GetCamera()
            if not Camera then return end

            local viewportSize = Camera.ViewportSize
            if viewportSize.X <= 0 or viewportSize.Y <= 0 then return end

            local center = Vector2.new(viewportSize.X * 0.5, viewportSize.Y * 0.5)
            
            if FOVCircle then
                FOVCircle.Position = center
                FOVCircle.Radius = Settings.FOV
                FOVCircle.Visible = Settings.Enabled and Settings.ShowFOV
            end
            
            if not Settings.Enabled then
                return
            end
            
            local character = FindClosestHumanoid()
            if character then
                local targetPart = GetCharacterTargetPart(character)
                if targetPart and targetPart:IsDescendantOf(workspace) then
                    local targetPos = targetPart.Position
                    
                    if Settings.Prediction then
                        local velocity = targetPart.AssemblyLinearVelocity or targetPart.Velocity
                        if velocity then
                            targetPos = targetPos + (velocity * Settings.PredictionAmount)
                        end
                    end

                    local screenPos, onScreen = Camera:WorldToViewportPoint(targetPos)
                    if onScreen then
                        local deltaX = screenPos.X - center.X
                        local deltaY = screenPos.Y - center.Y
                        
                        SafeMouseMoveRel(deltaX * Settings.Sensitivity, deltaY * Settings.Sensitivity)
                    end
                end
            end
        end)
    end)
end

Initialize()
