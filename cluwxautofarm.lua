--[[
    MM2 AutoFarm - fuldautomatisk, til flere konti (ingen menu, intet at klikke på)

    - Farmer candy/coins automatisk hele tiden (tween + noclip, INGEN weld)
    - Anti-AFK så du ikke bliver kicket for idle
    - Fuld backpack:
        * Murderer (har kniv i inventory): scriptet STOPPER bare med at farme
        * Alle andre (intet, eller gunen): avataren dør/resetter
      Den starter selv igen i næste runde.

    - FLERE KONTI: scriptet kan køre på mange konti samtidig (fx 10). Kontiene taler
      sammen og deler candy op, så de næsten aldrig tager den samme:
        1) Fil-bus: hver konto skriver en lille fil i  workspace/MM2FarmBus/  med hvilken
           candy den har "claimet" + hvor den er. De andre læser filerne ca. 5 gange i
           sekundet og undgår claimede candies. Kræver at kontiene kører på SAMME pc
           (delt workspace-mappe) og at executoren har writefile/readfile/listfiles.
        2) Opdeling: de farmende konti sorteres efter UserId, og kortets candy sorteres
           langs kortets længste akse og skæres i lige store stykker - hver konto
           foretrækker sit eget stykke, så de spredes udover kortet.
        3) Smart valg (v3): nærmeste candy prioriteres højest. Men hver candy scores
           også på hvor mange andre spillere der når den FØR os og hvor mange der står
           omkring den. Er mange på vej mod den nærmeste, vælges en candy længere væk
           i stedet - og når mængden er væk igen, tager vi de nærmeste. Mens vi flyver
           tjekkes det løbende, og vi skifter mål hvis nogen slår os til den (og der er
           et klart bedre valg). Virker også uden fil-bussen. Justeres i SMART herunder.

    - LYD: alle lyde i spillet slås fra (nuværende og nye).
    - YDELSE/RAM: du kan stadig se spillet. Laveste texture-kvalitet, textures/decals
      fjernet, simple materialer, ingen skygger/effekter/lys, FPS-cap, avatar-tilbehør
      fjernet, garbage collection. Candyen ser stadig normal ud.
      Sort skærm (Disable3D) og skjult GUI (HideGui) er slået FRA som standard - kan
      slås til i PERF herunder for endnu mindre lag. Alt kan justeres i PERF.

    Remotes (ReplicatedStorage.Remotes.Gameplay):
        CoinsStarted  -> ny runde, nulstil
        CoinCollected -> (coinId, current, max)  fuld taske når max <= current

    Kør scriptet igen for at stoppe den gamle kopi og starte forfra.
]]

local CONFIG = {
    TweenSpeed  = 22,  -- studs/sek. Højere = hurtigere, men for højt giver "Invalid position" kick
    DwellTime   = 0.6, -- max sekunder på hver candy før den går videre
    MaxAttempts = 3,   -- forsøg pr. candy før den springes over
}

local SYNC = {
    Enabled      = true,
    Folder       = "MM2FarmBus", -- under executorens workspace-mappe
    Interval     = 0.2,          -- sekunder mellem skriv/læs
    Ttl          = 3,            -- sekunder uden opdatering før en konto regnes for væk
}

-- Smart valg af candy: nærmeste candy vinder, MEDMINDRE andre spillere også er på vej derhen.
-- Hver candy får en score i sekunder (lavest vinder):
--   score = flyvetid til candyen
--         + RivalPenalty  * antal spillere der når candyen FØR os
--         + CrowdPenalty  * antal spillere tæt på candyen
-- Er der mange på vej mod den nærmeste, bliver en candy længere væk billigere, og vi tager
-- den. Når mængden har taget deres candy og er væk, falder straffen igen, og vi tager
-- de nærmeste igen.
local SMART = {
    Enabled       = true,
    RivalPenalty  = 4,    -- sek pr. spiller der er hurtigere til candyen end os
    CrowdRadius   = 20,   -- studs: spillere inden for den afstand af candyen tæller som "mængde"
    CrowdPenalty  = 0.4,  -- sek pr. spiller i mængden
    SwitchMargin  = 0.5,  -- skift kun mål midt i flyvningen hvis det nye er så mange sek bedre
    Backoff       = 3,    -- sek en omstridt candy holdes væk fra valget efter et skift
}

local PERF = {
    MuteAllSounds = true,  -- alle lyde: volume 0 + stop (nye lyde fanges også)
    ClearSoundIds = true,  -- fjern også lydfilen så den ikke fylder i RAM
    Disable3D     = false, -- true = sort skærm, spillet kører stadig (størst gevinst, men du ser intet)
    FpsCap        = 30,    -- 0 = lad være
    LowGraphics   = true,  -- kvalitet 1 (laveste textures), ingen skygger/effekter/partikler/decals/lys,
                           -- meshes uden textures, simple materialer. Candyen røres IKKE.
    HideGui       = false, -- true = skjul spillets GUI (scripts kører stadig)
    TrimAvatars   = true,  -- fjern tilbehør og tøj på alle avatarer
    GcInterval    = 30,    -- sekunder mellem garbage collection, 0 = fra
}

-- kør kun én kopi ad gangen
local env = (getgenv and getgenv()) or _G
if env.MM2AutoStop then
    pcall(env.MM2AutoStop)
end

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local function svc(name)
    local s = game:GetService(name)
    return (cloneref and cloneref(s)) or s
end

local Players           = svc("Players")
local RunService        = svc("RunService")
local TweenService      = svc("TweenService")
local ReplicatedStorage = svc("ReplicatedStorage")
local Workspace         = svc("Workspace")
local HttpService       = svc("HttpService")
local Lighting          = svc("Lighting")
local SoundService      = svc("SoundService")
local StarterGui        = svc("StarterGui")

local plr = Players.LocalPlayer
while not plr do
    task.wait()
    plr = Players.LocalPlayer
end
local myId = plr.UserId

local running = true
local conns = {}
local active = false          -- true mens vi farmer en runde (noclip + hold stille)
local handled = false         -- true når "fuld taske" allerede er håndteret i denne runde
local currentTween = nil
local fullBags = {}           -- [coinId] = true når den taske er fuld
local attempts = setmetatable({}, { __mode = "k" })
local skipUntil = {}          -- [coinKey] = os.clock() til hvornår vi ikke vælger den
local lastMap = nil
local lastCoin = nil
local lastMsg = nil

local function track(c)
    conns[#conns + 1] = c
    return c
end

local function say(msg)
    if msg ~= lastMsg then
        lastMsg = msg
        print("[MM2 AutoFarm] " .. msg)
    end
end

----------------------------------------------------------------------
-- Anti-AFK (så du ikke kickes for idle)
----------------------------------------------------------------------
pcall(function()
    local GC = getconnections or get_signal_cons
    if GC then
        for _, v in pairs(GC(plr.Idled)) do
            if v.Disable then
                v:Disable()
            elseif v.Disconnect then
                v:Disconnect()
            end
        end
    end
    local vu = svc("VirtualUser")
    track(plr.Idled:Connect(function()
        vu:CaptureController()
        vu:ClickButton2(Vector2.new())
    end))
end)

----------------------------------------------------------------------
-- Hjælpefunktioner
----------------------------------------------------------------------
local function getRoot()
    local char = plr.Character
    if not char then
        return nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then
        return nil
    end
    return char:FindFirstChild("HumanoidRootPart") or hum.RootPart
end

-- murderer har en Tool der hedder "Knife" (attribut IsKnife) i backpack eller hånd
local function hasKnife()
    local function scan(container)
        if container then
            for _, t in ipairs(container:GetChildren()) do
                if t:IsA("Tool") and (t.Name == "Knife" or t:GetAttribute("IsKnife")) then
                    return true
                end
            end
        end
        return false
    end
    return scan(plr.Character) or scan(plr:FindFirstChildOfClass("Backpack"))
end

local function resetCharacter()
    local char = plr.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    pcall(function()
        if hum then
            hum.Health = 0
        end
    end)
    pcall(function()
        if char then
            char:BreakJoints()
        end
    end)
    pcall(function()
        if hum then
            hum:ChangeState(Enum.HumanoidStateType.Dead)
        end
    end)
end

local function getMap()
    for _, m in ipairs(Workspace:GetChildren()) do
        if m:IsA("Model") and m:GetAttribute("MapID") then
            local cc = m:FindFirstChild("CoinContainer")
            if cc then
                return m, cc
            end
        end
    end
    return nil
end

local function coinGone(coin)
    if not coin.Parent or coin:GetAttribute("Collected") then
        return true
    end
    local cv = coin:FindFirstChild("CoinVisual")
    return cv ~= nil and cv.Transparency >= 1
end

-- samme tekst på alle klienter for den samme candy (serveren replikerer positionerne)
local function coinKey(coin)
    local p = coin.Position
    return string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z)
end

----------------------------------------------------------------------
-- YDELSE / RAM / LYD
----------------------------------------------------------------------
local function muteSound(s)
    pcall(function()
        s.Volume = 0
        s:Stop()
        if PERF.ClearSoundIds then
            s.SoundId = ""
        end
    end)
end

local VISUAL_EFFECTS = { "ParticleEmitter", "Trail", "Beam", "Smoke", "Fire", "Sparkles", "Highlight",
    "PointLight", "SpotLight", "SurfaceLight" }
local VISUAL_JUNK = { "Decal", "Texture", "SurfaceAppearance" }
local AVATAR_JUNK = { "Accessory", "Shirt", "Pants", "ShirtGraphic", "CharacterMesh" }

local function isAny(inst, classes)
    for _, c in ipairs(classes) do
        if inst:IsA(c) then
            return true
        end
    end
    return false
end

-- bruges både til nuværende og nye objekter
local function optimizeInstance(d)
    if PERF.MuteAllSounds then
        if d:IsA("Sound") then
            muteSound(d)
            return
        end
        -- nyt audio-API
        if d:IsA("AudioPlayer") then
            d.Volume = 0
            d:Stop()
            return
        elseif d:IsA("AudioDeviceOutput") then
            d.Muted = true
            return
        end
    end

    if not PERF.LowGraphics and not PERF.TrimAvatars then
        return
    end

    if PERF.LowGraphics then
        if d:IsA("PostEffect") then
            d.Enabled = false
            return
        elseif d:IsA("Atmosphere") then
            d:Destroy()   -- himlen (Sky) beholdes så spillet stadig ser ud som et spil
            return
        end
    end

    -- alt herunder kun i Workspace (ikke skabeloner i ReplicatedStorage osv.)
    if not d:IsDescendantOf(Workspace) then
        return
    end

    if PERF.TrimAvatars and isAny(d, AVATAR_JUNK) then
        local m = d.Parent
        if m and m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") then
            d:Destroy()
        end
        return
    end

    if not PERF.LowGraphics then
        return
    end

    -- candyen skal se normal ud, så du kan se hvad der farmes
    if d:FindFirstAncestor("CoinContainer") then
        return
    end

    if isAny(d, VISUAL_EFFECTS) then
        d.Enabled = false
    elseif isAny(d, VISUAL_JUNK) or d:IsA("MaterialVariant") then
        d:Destroy()
    elseif d:IsA("BasePart") and not d:IsA("Terrain") then
        d.CastShadow = false
        d.Reflectance = 0
        -- simpelt materiale = ingen materiale-textures (map, normal map osv.)
        d.Material = Enum.Material.SmoothPlastic
        d.MaterialVariant = ""
        if d:IsA("MeshPart") then
            d.TextureID = ""
            d.RenderFidelity = Enum.RenderFidelity.Performance
        end
    end
end

local function applyGlobalPerf()
    if PERF.MuteAllSounds then
        pcall(function()
            SoundService.AmbientReverb = Enum.ReverbType.NoReverb
        end)
        pcall(function()
            UserSettings():GetService("UserGameSettings").MasterVolume = 0
        end)
    end

    if PERF.LowGraphics then
        pcall(function()
            settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
        end)
        pcall(function()
            settings().Rendering.MeshPartDetailLevel = Enum.MeshPartDetailLevel.Level04
        end)
        pcall(function()
            UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
        end)
        pcall(function()
            Lighting.GlobalShadows = false
            Lighting.ShadowSoftness = 0
        end)
        pcall(function()
            local t = Workspace.Terrain
            t.WaterWaveSize = 0
            t.WaterWaveSpeed = 0
            t.WaterReflectance = 0
            t.Decoration = false
        end)
    end

    if PERF.HideGui then
        pcall(function()
            StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.All, false)
        end)
        local pg = plr:FindFirstChildOfClass("PlayerGui")
        if pg then
            for _, g in ipairs(pg:GetChildren()) do
                if g:IsA("ScreenGui") then
                    pcall(function()
                        g.Enabled = false
                    end)
                end
            end
            track(pg.ChildAdded:Connect(function(g)
                if g:IsA("ScreenGui") then
                    pcall(function()
                        g.Enabled = false
                    end)
                end
            end))
        end
    end

    if PERF.FpsCap and PERF.FpsCap > 0 and setfpscap then
        pcall(setfpscap, PERF.FpsCap)
    end

    if PERF.Disable3D then
        pcall(function()
            RunService:Set3dRenderingEnabled(false)
        end)
    end
end

local function startPerf()
    applyGlobalPerf()

    if PERF.MuteAllSounds or PERF.LowGraphics or PERF.TrimAvatars then
        -- nye objekter (lyde, nyt kort hver runde, nye avatarer ...)
        track(game.DescendantAdded:Connect(function(d)
            pcall(optimizeInstance, d)
        end))

        -- alle eksisterende objekter, i bidder så spillet ikke fryser
        task.spawn(function()
            local all = game:GetDescendants()
            local n = #all
            for i = 1, n do
                if not running then
                    return
                end
                pcall(optimizeInstance, all[i])
                if i % 300 == 0 then
                    task.wait()
                end
            end
            all = nil
            say("Optimering færdig (" .. n .. " objekter)")
        end)
    end

    if PERF.GcInterval and PERF.GcInterval > 0 then
        task.spawn(function()
            while running do
                task.wait(PERF.GcInterval)
                pcall(collectgarbage, "collect")
            end
        end)
    end
end

----------------------------------------------------------------------
-- Samarbejde mellem konti (fil-bus i workspace/MM2FarmBus/)
----------------------------------------------------------------------
local Bus = {
    enabled = false,
    others = {},   -- [userId] = { claim = key|nil, pos = Vector3|nil, farm = bool }
    myClaim = nil,
    count = 0,
}

local busFile = SYNC.Folder .. "/" .. myId .. ".json"

if SYNC.Enabled
    and type(writefile) == "function" and type(readfile) == "function"
    and type(listfiles) == "function" and type(isfolder) == "function"
    and type(makefolder) == "function" then
    local ok = pcall(function()
        if not isfolder(SYNC.Folder) then
            makefolder(SYNC.Folder)
        end
    end)
    Bus.enabled = ok
end

local function busWrite()
    if not Bus.enabled then
        return
    end
    local root = getRoot()
    local p = root and root.Position
    pcall(writefile, busFile, HttpService:JSONEncode({
        id = myId,
        t = os.time(),
        claim = Bus.myClaim,
        farm = active and true or false,
        x = p and p.X, y = p and p.Y, z = p and p.Z,
    }))
end

local function busPoll()
    local ok, files = pcall(listfiles, SYNC.Folder)
    if not ok or type(files) ~= "table" then
        return
    end
    local now = os.time()
    local seen, n = {}, 0
    for _, path in ipairs(files) do
        local id = tonumber(tostring(path):match("(%d+)%.json$"))
        if id and id ~= myId then
            local okr, content = pcall(readfile, path)
            if okr and type(content) == "string" then
                local okd, d = pcall(HttpService.JSONDecode, HttpService, content)
                if okd and type(d) == "table" and type(d.t) == "number" and now - d.t <= SYNC.Ttl then
                    seen[id] = {
                        claim = d.claim,
                        farm = d.farm == true,
                        pos = (d.x and d.y and d.z) and Vector3.new(d.x, d.y, d.z) or nil,
                    }
                    n = n + 1
                end
            end
        end
    end
    Bus.others = seen
    if n ~= Bus.count then
        Bus.count = n
        say("Sync: " .. n .. " andre konti fundet")
    end
end

function Bus.claim(key)
    Bus.myClaim = key
    busWrite()
end

function Bus.release()
    if Bus.myClaim ~= nil then
        Bus.myClaim = nil
        busWrite()
    end
end

-- har en anden konto claimet den her candy?
function Bus.claimedByOther(key)
    for _, o in pairs(Bus.others) do
        if o.claim == key then
            return true
        end
    end
    return false
end

-- har en konto med LAVERE UserId claimet den samme candy? (så vinder den, vi viger)
function Bus.lost(key)
    for id, o in pairs(Bus.others) do
        if o.claim == key and id < myId then
            return true
        end
    end
    return false
end

-- sorteret liste over de konti der farmer lige nu (inkl. mig selv)
function Bus.farmers()
    local ids = { myId }
    for id, o in pairs(Bus.others) do
        if o.farm then
            ids[#ids + 1] = id
        end
    end
    table.sort(ids)
    return ids
end

if Bus.enabled then
    task.spawn(function()
        while running do
            busWrite()
            busPoll()
            task.wait(SYNC.Interval)
        end
    end)
    say("Sync aktiv (mappe: " .. SYNC.Folder .. ")")
else
    say("Sync via filer ikke tilgængelig - bruger kun afstand til andre spillere")
end

-- alle andre levende spillere i serveren (vores egne konti fra bussen tæller ikke som
-- konkurrenter, de deler jo candy med os)
local function getRivals()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= plr and not Bus.others[p.UserId] then
            local char = p.Character
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hum and hrp and hum.Health > 0 then
                local vel = hrp.AssemblyLinearVelocity
                list[#list + 1] = {
                    pos = hrp.Position,
                    vel = vel,
                    speed = math.clamp(math.max(hum.WalkSpeed, vel.Magnitude), 8, 40),
                }
            end
        end
    end
    return list
end

-- (antal spillere der når candyen før os, antal spillere tæt på candyen)
-- myTime = hvor lang tid VI skal bruge til candyen
local function contest(coinPos, myTime, rivals)
    local beat, near = 0, 0
    for _, r in ipairs(rivals) do
        local toCoin = coinPos - r.pos
        local d = toCoin.Magnitude
        if d <= SMART.CrowdRadius then
            near = near + 1
        end
        -- står stille langt væk, eller går væk fra candyen = er ikke på vej derhen
        local moving = r.vel.Magnitude > 1.5
        local ignore
        if not moving then
            ignore = d > 8
        else
            ignore = d > 0.1 and r.vel:Dot(toCoin.Unit) < 0
        end
        if not ignore and d / r.speed < myTime then
            beat = beat + 1
        end
    end
    return beat, near
end

-- score i sekunder, lavest er bedst (se SMART øverst)
local function scoreCoin(coin, origin, rivals, inMySlice)
    local myTime = (coin.Position - origin).Magnitude / math.max(CONFIG.TweenSpeed, 1)
    local s = myTime
    if SMART.Enabled then
        local beat, near = contest(coin.Position, myTime, rivals)
        s = s + beat * SMART.RivalPenalty + near * SMART.CrowdPenalty
    end
    if (attempts[coin] or 0) > 0 then
        s = s + 2        -- allerede prøvet uden held
    end
    if coin == lastCoin then
        s = s + 4        -- aldrig den samme to gange i træk
    end
    if inMySlice then
        s = s - 0.6      -- med flere konti: foretræk eget stykke af kortet
    end
    return s
end

----------------------------------------------------------------------
-- Vælg candy (smart: nærmeste, men uden om dem mange andre er på vej mod)
----------------------------------------------------------------------
-- 1) base = alle candy der ikke er taget -> sorteret langs kortets længste akse
--    (ens på alle klienter) og skåret i lige store stykker, ét pr. farmende konto.
-- 2) Hver candy scores (flyvetid + straf for spillere der er hurtigere dertil og for
--    mængde omkring den). Lavest score vinder. Returnerer (candy, score).
-- exclude = en candy der ikke må vælges (bruges når vi tjekker om der er et bedre valg)
local function pickCoin(container, origin, exclude)
    local base = {}
    for _, coin in ipairs(container:GetChildren()) do
        if coin:IsA("BasePart") and coin.Name == "Coin_Server" and not coinGone(coin) then
            base[#base + 1] = coin
        end
    end
    if #base == 0 then
        return nil
    end

    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, c in ipairs(base) do
        local p = c.Position
        minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
        minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
    end
    local alongX = (maxX - minX) >= (maxZ - minZ)
    table.sort(base, function(a, b)
        local pa, pb = a.Position, b.Position
        local ka, kb = alongX and pa.X or pa.Z, alongX and pb.X or pb.Z
        if ka ~= kb then
            return ka < kb
        end
        return coinKey(a) < coinKey(b)
    end)

    local ids = Bus.farmers()
    local myIdx = 1
    for i, id in ipairs(ids) do
        if id == myId then
            myIdx = i
        end
    end
    local size = math.max(math.ceil(#base / #ids), 1)
    local mine = {}
    for i, coin in ipairs(base) do
        if math.ceil(i / size) == myIdx then
            mine[coin] = true
        end
    end

    local rivals = SMART.Enabled and getRivals() or {}
    local now = os.clock()
    local best, bestScore

    for _, coin in ipairs(base) do
        local key = coinKey(coin)
        if coin ~= exclude
            and not fullBags[coin:GetAttribute("CoinID")]
            and (attempts[coin] or 0) < CONFIG.MaxAttempts
            and not (skipUntil[key] and skipUntil[key] > now)
            and not Bus.claimedByOther(key) then
            local s = scoreCoin(coin, origin, rivals, mine[coin])
            if not bestScore or s < bestScore then
                best, bestScore = coin, s
            end
        end
    end

    return best, bestScore
end

----------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------
task.spawn(function()
    local gameplay = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("Gameplay")

    track(gameplay:WaitForChild("CoinsStarted").OnClientEvent:Connect(function()
        fullBags = {}
        attempts = setmetatable({}, { __mode = "k" })
        skipUntil = {}
        lastCoin = nil
        handled = false
    end))

    track(gameplay:WaitForChild("CoinCollected").OnClientEvent:Connect(function(coinId, current, max)
        if type(coinId) == "string" and type(current) == "number" and type(max) == "number" and max <= current then
            fullBags[coinId] = true
        end
    end))
end)

----------------------------------------------------------------------
-- Noclip (kun mens vi farmer) + hold stille så vi ikke falder igennem kortet
----------------------------------------------------------------------
track(RunService.Stepped:Connect(function()
    if not active then
        return
    end
    local char = plr.Character
    if not char then
        return
    end
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("BasePart") and v.CanCollide then
            v.CanCollide = false
        end
    end
end))

track(RunService.Heartbeat:Connect(function()
    if active then
        local root = getRoot()
        if root then
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
        end
    end
end))

----------------------------------------------------------------------
-- Tween til en candy
-- Hastigheden er begrænset til TweenSpeed studs/sek: bevæger man sig for hurtigt
-- smider serveren en ud med "Invalid position" (fejlkode 267).
----------------------------------------------------------------------
-- Midt i flyvningen: er der kommet nogen der slår os til candyen, OG findes der en anden
-- candy der er klart bedre (SwitchMargin sekunder), så skift. Ellers fortsætter vi - at
-- skifte uden grund ville bare spilde tid.
local function betterElsewhere(coin, root, container)
    local remaining = (coin.Position - root.Position).Magnitude / math.max(CONFIG.TweenSpeed, 1)
    local beat, near = contest(coin.Position, remaining, getRivals())
    if beat == 0 then
        return false
    end
    local current = remaining + beat * SMART.RivalPenalty + near * SMART.CrowdPenalty
    local alt, altScore = pickCoin(container, root.Position, coin)
    return alt ~= nil and altScore + SMART.SwitchMargin < current
end

local function farmCoin(coin, root, container)
    local key = coinKey(coin)
    Bus.claim(key)
    attempts[coin] = (attempts[coin] or 0) + 1

    local yielded = false
    local lastCheck = 0
    local dist = (coin.Position - root.Position).Magnitude
    local travel = math.max(dist / math.max(CONFIG.TweenSpeed, 1), 0.05)
    local tw = TweenService:Create(root, TweenInfo.new(travel, Enum.EasingStyle.Linear), {
        CFrame = coin.CFrame
    })
    currentTween = tw
    tw:Play()
    local t0 = os.clock()
    while running and root.Parent and os.clock() - t0 < travel + 0.05 and not coinGone(coin) do
        if Bus.lost(key) then
            yielded = true
            break
        end
        if SMART.Enabled and os.clock() - lastCheck >= 0.12 then
            lastCheck = os.clock()
            if betterElsewhere(coin, root, container) then
                yielded = true
                break
            end
        end
        task.wait()
    end
    tw:Cancel()
    currentTween = nil

    -- bliv på candyen og vip lidt op og ned (max ~18 studs/sek) til serveren har taget den
    if not yielded and running and root.Parent and not coinGone(coin) then
        local d0 = os.clock()
        while running and root.Parent and os.clock() - d0 < CONFIG.DwellTime and not coinGone(coin) do
            if Bus.lost(key) then
                yielded = true
                break
            end
            pcall(function()
                root.CFrame = coin.CFrame * CFrame.new(0, 1.5 * math.sin((os.clock() - d0) * 12), 0)
            end)
            task.wait()
        end
    end

    if yielded then
        -- en anden tager den: den her gang tæller ikke, og vi vælger noget andet
        attempts[coin] = math.max((attempts[coin] or 1) - 1, 0)
        skipUntil[key] = os.clock() + SMART.Backoff
    else
        lastCoin = coin
    end
    Bus.release()
end

----------------------------------------------------------------------
-- Hovedloop
----------------------------------------------------------------------
task.spawn(function()
    while running do
        local root = getRoot()
        if not root then
            active = false
            say("Venter på karakter")
            task.wait(0.5)
        else
            local map, container = getMap()
            if map ~= lastMap then
                lastMap = map
                fullBags = {}
                attempts = setmetatable({}, { __mode = "k" })
                skipUntil = {}
                lastCoin = nil
                handled = false
            end

            if not map then
                active = false
                say("Venter på en runde")
                task.wait(0.5)
            elseif handled then
                active = false
                task.wait(0.5)
            else
                active = true
                local coin = pickCoin(container, root.Position)
                if coin then
                    say("Farmer " .. tostring(coin:GetAttribute("CoinID") or "candy"))
                    farmCoin(coin, root, container)
                elseif next(fullBags) then
                    -- fuld taske
                    handled = true
                    active = false
                    Bus.release()
                    if hasKnife() then
                        say("Fuld taske - du er murderer, stopper (ingen reset)")
                    else
                        say("Fuld taske - resetter avatar")
                        resetCharacter()
                    end
                else
                    say("Venter på mere candy")
                    task.wait(0.25)
                end
            end
        end
    end
end)

startPerf()

----------------------------------------------------------------------
-- Stop
----------------------------------------------------------------------
env.MM2AutoStop = function()
    running = false
    active = false
    if currentTween then
        pcall(function()
            currentTween:Cancel()
        end)
    end
    for _, c in ipairs(conns) do
        pcall(function()
            c:Disconnect()
        end)
    end
    table.clear(conns)
    if Bus.enabled and type(delfile) == "function" then
        pcall(delfile, busFile)
    end
    if PERF.Disable3D then
        pcall(function()
            RunService:Set3dRenderingEnabled(true)
        end)
    end
    env.MM2AutoStop = nil
end

say("Startet - farmer automatisk")
