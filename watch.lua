-- moseeri watch: recorder + scanner for any Roblox game. Own script, separate from the farm hub (owner 2026-11-19):
-- run it only while collecting data, so the farm script never carries the hook / scan code.
-- Built by build.ps1 from src/watch_head.lua + src/watch.lua + src/kit.lua + src/watch_pages.lua.
-- Lua 5.1 only. Reads only: never fires a remote, never require()s a module. Files go to Workspace/mwatch/.

local G = (getgenv and getgenv()) or _G
if G.__mwatch_stop then pcall(G.__mwatch_stop) end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
-- autoexec can run before the player exists: wait for it, or every LP use fails and the player's scripts are never dumped
local LP = Players.LocalPlayer
while not LP do task.wait(0.2) LP = Players.LocalPlayer end
local FOLDER = "mwatch"
local VERSION = "watch_3"

local F = {
    alive = true,
    conns = {},
    lastAction = "",
    cfg = { watchSkip = "", watchResume = false, autoScan = true, watchIgnore = {} },
}

local canFiles = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"
local function ensureFolder()
    if canFiles and type(isfolder) == "function" and type(makefolder) == "function" then
        pcall(function() if not isfolder(FOLDER) then makefolder(FOLDER) end end)
    end
end
local function log(msg) F.lastAction = os.date("%H:%M:%S ") .. tostring(msg) end
local function saveAll()
    if not canFiles then return end
    ensureFolder()
    pcall(function() writefile(FOLDER .. "/config.json", HttpService:JSONEncode({ cfg = F.cfg })) end)
end
pcall(function()
    if canFiles and isfile(FOLDER .. "/config.json") then
        local d = HttpService:JSONDecode(readfile(FOLDER .. "/config.json"))
        if type(d.cfg) == "table" then
            for k, v in pairs(d.cfg) do if F.cfg[k] ~= nil and type(v) == type(F.cfg[k]) then F.cfg[k] = v end end
        end
    end
end)

--------------------------------------------------------------------------------
-- Watch v2: game-agnostic recorder + scanner (no game names in this file; per-game skip words are a setting).
-- Reads only. It never fires a remote and never require()s a module.
--
-- RECORD (while the owner plays by hand) -> <FOLDER>/watch_<time>_<PlaceId>.txt
--   <-  server events            ->  my client's remote calls (needs the __namecall hook: own switch, off by default)
--   MOB  animations NPCs start   HIT  my HP drops         MY   my own animations / tools
--   POS  my path                 GUI  windows that open / close
--   ME   my values that change (attributes, leaderstats, value objects, backpack)
--   NEW  things that appear near me (telegraphs, projectiles, drops)
--   USE  proximity prompts I trigger          # MARK  owner's marks
-- SCAN (one press each) -> <FOLDER>/scan_<kind>_<PlaceId>_<time>.txt : game, map, screen, me, around, all (deep)
-- DUMP scripts -> <FOLDER>/src_<PlaceId>/ : decompiled client scripts (local read; own button, mid risk)
--------------------------------------------------------------------------------
local RS = game:GetService("ReplicatedStorage")
local W = {
    on = false,
    inOn = true, outOn = false, mobsOn = true, pathOn = true, guiOn = true, meOn = true, selfOn = true, newOn = true, useOn = true,
    log = {}, lines = 0, last = "", note = "", file = nil, fileBytes = 0, part = 1,
    conns = {}, listenReady = false, hookInstalled = false, selfReady = false, newReady = false, useReady = false,
    inLast = {}, inSkipped = {}, inGap = 2, counts = {},
    noise = { "mouse", "camera", "heartbeat", "ping", "input" },
    mobs = {}, mobScanAt = 0, animLast = {}, mobRange = 90, nearRange = 70,
    lastPos = nil, lastHp = nil, marks = 0, guiState = {}, meState = nil, newLast = {}, newBudget = 0,
    scanStatus = "-", checkResult = "-",
}
F.watch = W
local MAX_FILE = 3 * 1024 * 1024

local function stamp() return os.date("%m%d_%H%M%S") end
-- folders: <FOLDER>/<GameId>/            index.txt, known.txt (everything seen in this game, all maps)
--          <FOLDER>/<GameId>/<PlaceId>/  scans + recordings of that map
local GAME_DIR = FOLDER .. "/" .. tostring(game.GameId)
local PLACE_DIR = GAME_DIR .. "/" .. tostring(game.PlaceId)
local function ensureDirs()
    ensureFolder()
    if type(isfolder) == "function" and type(makefolder) == "function" then
        pcall(function() if not isfolder(GAME_DIR) then makefolder(GAME_DIR) end end)
        pcall(function() if not isfolder(PLACE_DIR) then makefolder(PLACE_DIR) end end)
    end
end
local function readText(path)
    local ok, s = pcall(function() return canFiles and isfile(path) and readfile(path) or "" end)
    return ok and type(s) == "string" and s or ""
end
local function wWrite(path, text)
    if not canFiles then return false end
    ensureDirs()
    return pcall(writefile, path, text)
end
local function wAppend(path, text)
    if not canFiles then return end
    ensureDirs()
    pcall(function()
        if type(appendfile) == "function" and isfile(path) then appendfile(path, text)
        else writefile(path, (isfile(path) and readfile(path) or "") .. text) end
    end)
end
-- known.txt: one line per thing ever seen in this game (NPC / prompt / remote), from every map, no repeats
local known
local function loadKnown()
    known = {}
    for line in string.gmatch(readText(GAME_DIR .. "/known.txt"), "[^\n]+") do
        local key = line:match("^(.-) || ")
        if key then known[key] = true end
    end
end
local knownNew = {}
local function addKnown(kind, name, detail, perPlace)
    if not known then loadKnown() end
    local key = kind .. " | " .. (perPlace and (tostring(game.PlaceId) .. " | ") or "") .. name
    if known[key] then return end
    known[key] = true
    knownNew[#knownNew + 1] = key .. " || " .. (detail or "")
end
local function flushKnown()
    if #knownNew == 0 then return end
    local chunk = table.concat(knownNew, "\n") .. "\n"
    knownNew = {}
    wAppend(GAME_DIR .. "/known.txt", chunk)
end
local function describe(v, depth)
    local t = typeof(v)
    if t == "string" then return string.format("%q", #v > 300 and (v:sub(1, 300) .. "...") or v) end
    if t == "number" or t == "boolean" or t == "nil" then return tostring(v) end
    if t == "Instance" then
        local ok, p = pcall(function() return v:GetFullName() end)
        return "<" .. v.ClassName .. " " .. (ok and p or "?") .. ">"
    end
    if t == "table" then
        if depth >= 3 then return "{...}" end
        local parts, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > 40 then parts[#parts + 1] = "..." break end
            local key = type(k) == "string" and k or ("[" .. describe(k, depth + 1) .. "]")
            parts[#parts + 1] = key .. "=" .. describe(val, depth + 1)
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    end
    return t .. "(" .. tostring(v) .. ")"
end
local function describeArgs(args)
    local parts = {}
    for i = 1, args.n or #args do parts[i] = describe(args[i], 0) end
    return table.concat(parts, ", ")
end
local function skipWords()
    local list = {}
    for _, w in ipairs(W.noise) do list[#list + 1] = w end
    for w in string.gmatch(string.lower(tostring(F.cfg.watchSkip or "")), "[^,%s]+") do list[#list + 1] = w end
    return list
end
local skipCache, skipSrc
local function isNoise(name)
    if skipSrc ~= F.cfg.watchSkip or not skipCache then skipSrc = F.cfg.watchSkip skipCache = skipWords() end
    local n = string.lower(name)
    for _, w in ipairs(skipCache) do if n:find(w, 1, true) then return true end end
    return false
end
local function wLine(line)
    W.log[#W.log + 1] = os.date("%H:%M:%S ") .. line
    W.lines = W.lines + 1
    W.last = line
end
local function count(kind, name) local k = kind .. " " .. name W.counts[k] = (W.counts[k] or 0) + 1 end
local function v3(p) return string.format("%.1f,%.1f,%.1f", p.X, p.Y, p.Z) end
local function myRoot()
    local c = LP.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end
local function fullName(o) local ok, p = pcall(function() return o:GetFullName() end) return ok and p or tostring(o) end
local function posOf(o)
    local ok, p = pcall(function()
        if o:IsA("BasePart") then return o.Position end
        if o:IsA("Model") then return o:GetPivot().Position end
        if o:IsA("Attachment") then return o.WorldPosition end
        return nil
    end)
    return ok and p or nil
end
local function attrText(o)
    local ok, a = pcall(function() return o:GetAttributes() end)
    if not ok or type(a) ~= "table" or next(a) == nil then return "" end
    return " attrs" .. describe(a, 1)
end

----------------------------------------------------------------- record: out (hook)
local onLive -- set by the Remotes part below: (remote, method, args, callerScript)
local function onOutgoing(remote, method, args, caller)
    pcall(function()
        if isNoise(remote.Name) or (F.cfg.watchIgnore and F.cfg.watchIgnore[remote.Name]) then return end
        if onLive then pcall(onLive, remote, method, args, caller) end
        if not W.on then return end
        count("->", remote.Name)
        wLine(string.format("-> %s %s(%s)%s", fullName(remote), method, describeArgs(args), caller and ("  | from " .. fullName(caller)) or ""))
    end)
end
local function installHook()
    if W.hookInstalled then return true end
    if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then return false end
    local wrap = type(newcclosure) == "function" and newcclosure or function(f) return f end
    local old
    old = hookmetamethod(game, "__namecall", wrap(function(self, ...)
        if W.outOn and F.alive then
            local method = getnamecallmethod()
            if (method == "FireServer" or method == "InvokeServer")
                and not (type(checkcaller) == "function" and checkcaller()) then
                local caller
                if type(getcallingscript) == "function" then
                    local okC, cs = pcall(getcallingscript)
                    if okC then caller = cs end
                end
                task.spawn(onOutgoing, self, method, table.pack(...), caller)
                if type(setnamecallmethod) == "function" then setnamecallmethod(method) end
                if method == "InvokeServer" then
                    local res = table.pack(old(self, ...))
                    task.spawn(function()
                        pcall(function()
                            if not W.on or isNoise(self.Name) then return end
                            wLine(string.format("<= %s answer(%s)", self.Name, describeArgs(res)))
                        end)
                    end)
                    return unpack(res, 1, res.n)
                end
            end
        end
        return old(self, ...)
    end))
    W.hookInstalled = true
    return true
end

----------------------------------------------------------------- record: in
local function listenTo(remote)
    if not remote:IsA("RemoteEvent") then return end
    W.conns[#W.conns + 1] = remote.OnClientEvent:Connect(function(...)
        if not (W.on and W.inOn) then return end
        local args = table.pack(...)
        pcall(function()
            if isNoise(remote.Name) then return end
            local key = remote.Name
            if args.n >= 1 and type(args[1]) ~= "table" then key = key .. "|" .. tostring(args[1]) end
            local now = os.clock()
            local last = W.inLast[key]
            if last and now - last < W.inGap then
                W.inSkipped[key] = (W.inSkipped[key] or 0) + 1
                return
            end
            W.inLast[key] = now
            local skipped = W.inSkipped[key] or 0
            W.inSkipped[key] = 0
            count("<-", remote.Name)
            wLine(string.format("<- %s(%s)%s", fullName(remote), describeArgs(args),
                skipped > 0 and ("  (+" .. skipped .. " skipped)") or ""))
        end)
    end)
end
local function startListening()
    if W.listenReady then return end
    W.listenReady = true
    for _, d in ipairs(RS:GetDescendants()) do listenTo(d) end
    W.conns[#W.conns + 1] = RS.DescendantAdded:Connect(listenTo)
    local function hookChar(char)
        if not char then return end
        for _, d in ipairs(char:GetDescendants()) do listenTo(d) end
        W.conns[#W.conns + 1] = char.DescendantAdded:Connect(listenTo)
    end
    hookChar(LP.Character)
    W.conns[#W.conns + 1] = LP.CharacterAdded:Connect(hookChar)
end

----------------------------------------------------------------- record: mobs + my HP
local function scanMobs()
    local list = {}
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do if p.Character then playerChars[p.Character] = true end end
    for _, d in ipairs(workspace:GetDescendants()) do
        if d:IsA("Humanoid") and d.Parent and not playerChars[d.Parent] then
            local root = d.Parent:FindFirstChild("HumanoidRootPart") or d.Parent.PrimaryPart
            if root then list[#list + 1] = { hum = d, root = root, name = d.Parent.Name } end
        end
    end
    W.mobs = list
end
local function mobTick()
    local me = myRoot()
    if not me then return end
    local now = os.clock()
    if now - W.mobScanAt > 5 then
        W.mobScanAt = now
        pcall(scanMobs)
        -- NPCs that spawned after the map scan still reach known.txt
        for _, m in ipairs(W.mobs) do
            pcall(addKnown, "NPC", m.name, string.format("maxhp %.0f at %s | %s", m.hum.MaxHealth, v3(m.root.Position), fullName(m.hum.Parent)), true)
        end
        pcall(flushKnown)
    end
    for _, m in ipairs(W.mobs) do
        if m.root.Parent and m.hum.Health > 0 then
            local dist = (m.root.Position - me.Position).Magnitude
            if dist <= W.mobRange then
                local animator = m.hum:FindFirstChildOfClass("Animator")
                local tracks = animator and animator:GetPlayingAnimationTracks() or {}
                for _, tr in ipairs(tracks) do
                    local id = tr.Animation and tr.Animation.AnimationId or "?"
                    local key = fullName(m.hum) .. id
                    if tr.TimePosition < 0.3 and (not W.animLast[key] or now - W.animLast[key] > 1) then
                        W.animLast[key] = now
                        wLine(string.format("MOB %s anim %s (%s) len %.2f dist %.0f hp %.0f/%.0f at %s",
                            m.name, id, tr.Name, tr.Length, dist, m.hum.Health, m.hum.MaxHealth, v3(m.root.Position)))
                    end
                end
            end
        end
    end
    local c = LP.Character
    local hum = c and c:FindFirstChildOfClass("Humanoid")
    if hum then
        if W.lastHp and hum.Health < W.lastHp - 0.5 then
            wLine(string.format("HIT me -%.0f hp %.0f/%.0f", W.lastHp - hum.Health, hum.Health, hum.MaxHealth))
        end
        W.lastHp = hum.Health
    end
end
local function pathTick()
    local me = myRoot()
    if not me then return end
    if not W.lastPos or (me.Position - W.lastPos).Magnitude > 4 then
        W.lastPos = me.Position
        wLine("POS " .. v3(me.Position))
    end
end

----------------------------------------------------------------- record: my own animations / tools
local function startSelf()
    if W.selfReady then return end
    W.selfReady = true
    local function hookChar(char)
        if not char then return end
        task.spawn(function()
            local hum = char:WaitForChild("Humanoid", 10)
            local animator = hum and hum:WaitForChild("Animator", 10)
            if animator then
                W.conns[#W.conns + 1] = animator.AnimationPlayed:Connect(function(tr)
                    if not (W.on and W.selfOn) then return end
                    pcall(function()
                        local id = tr.Animation and tr.Animation.AnimationId or "?"
                        local now = os.clock()
                        if W.animLast["me" .. id] and now - W.animLast["me" .. id] < 0.5 then return end
                        W.animLast["me" .. id] = now
                        wLine(string.format("MY anim %s (%s) len %.2f", id, tr.Name, tr.Length))
                    end)
                end)
            end
            W.conns[#W.conns + 1] = char.ChildAdded:Connect(function(ch)
                if W.on and W.selfOn and ch:IsA("Tool") then wLine("MY equip " .. ch.Name) end
            end)
            W.conns[#W.conns + 1] = char.ChildRemoved:Connect(function(ch)
                if W.on and W.selfOn and ch:IsA("Tool") then wLine("MY unequip " .. ch.Name) end
            end)
        end)
    end
    hookChar(LP.Character)
    W.conns[#W.conns + 1] = LP.CharacterAdded:Connect(hookChar)
end

----------------------------------------------------------------- record: GUI open / close, my values
local function guiTick()
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return end
    local seen = {}
    for _, sg in ipairs(pg:GetChildren()) do
        if sg:IsA("ScreenGui") then
            local items = { sg }
            for _, ch in ipairs(sg:GetChildren()) do if ch:IsA("GuiObject") then items[#items + 1] = ch end end
            for _, o in ipairs(items) do
                local shown
                if o:IsA("ScreenGui") then shown = o.Enabled else shown = sg.Enabled and o.Visible end
                local key = sg.Name .. (o == sg and "" or ("." .. o.Name))
                seen[key] = true
                if W.guiState[key] ~= nil and W.guiState[key] ~= shown then
                    wLine("GUI " .. (shown and "open " or "close ") .. key)
                end
                W.guiState[key] = shown
            end
        end
    end
end
local function readMe()
    local out, n = {}, 0
    local function put(k, v) if n < 400 then n = n + 1 out[k] = tostring(v) end end
    local function attrs(prefix, o)
        local ok, a = pcall(function() return o:GetAttributes() end)
        if ok and type(a) == "table" then for k, v in pairs(a) do put(prefix .. "@" .. k, describe(v, 2)) end end
    end
    local function values(prefix, o, depth)
        if depth > 4 then return end
        for _, ch in ipairs(o:GetChildren()) do
            if ch:IsA("ValueBase") then
                local ok, v = pcall(function() return ch.Value end)
                put(prefix .. "/" .. ch.Name, ok and describe(v, 2) or "?")
            end
            if ch:IsA("Folder") or ch:IsA("Configuration") or ch:IsA("ValueBase") then
                attrs(prefix .. "/" .. ch.Name, ch)
                values(prefix .. "/" .. ch.Name, ch, depth + 1)
            end
        end
    end
    attrs("player", LP)
    values("player", LP, 1)
    local c = LP.Character
    if c then attrs("char", c) values("char", c, 3) end
    local bp = LP:FindFirstChildOfClass("Backpack")
    if bp then
        local names = {}
        for _, t in ipairs(bp:GetChildren()) do names[#names + 1] = t.Name end
        table.sort(names)
        put("backpack", table.concat(names, ","))
    end
    return out
end
local function meTick()
    local now = readMe()
    if W.meState then
        local shown = 0
        for k, v in pairs(now) do
            if W.meState[k] ~= v and shown < 25 then shown = shown + 1 wLine("ME " .. k .. " " .. tostring(W.meState[k]) .. " -> " .. v) end
        end
        for k, v in pairs(W.meState) do
            if now[k] == nil and shown < 25 then shown = shown + 1 wLine("ME " .. k .. " " .. v .. " -> gone") end
        end
    end
    W.meState = now
end

----------------------------------------------------------------- record: new things near me, prompts I use
local function startNew()
    if W.newReady then return end
    W.newReady = true
    W.conns[#W.conns + 1] = workspace.DescendantAdded:Connect(function(o)
        if not (W.on and W.newOn) then return end
        if W.newBudget <= 0 then return end
        if not (o:IsA("BasePart") or o:IsA("Model")) then return end
        task.defer(function()
            pcall(function()
                local me = myRoot()
                if not me or not o.Parent then return end
                if LP.Character and o:IsDescendantOf(LP.Character) then return end
                local p = posOf(o)
                if not p or (p - me.Position).Magnitude > W.nearRange then return end
                local now = os.clock()
                local key = o.ClassName .. o.Name
                if W.newLast[key] and now - W.newLast[key] < 2 then return end
                W.newLast[key] = now
                W.newBudget = W.newBudget - 1
                local size = o:IsA("BasePart") and (" size " .. v3(o.Size)) or ""
                wLine(string.format("NEW %s %s%s dist %.0f at %s%s", o.ClassName, fullName(o), size, (p - me.Position).Magnitude, v3(p), attrText(o)))
            end)
        end)
    end)
end
local function startUse()
    if W.useReady then return end
    W.useReady = true
    pcall(function()
        local PPS = game:GetService("ProximityPromptService")
        W.conns[#W.conns + 1] = PPS.PromptTriggered:Connect(function(prompt, who)
            if not (W.on and W.useOn) or who ~= LP then return end
            pcall(function()
                local p = prompt.Parent and posOf(prompt.Parent)
                wLine(string.format("USE prompt %s action %q object %q hold %.1f at %s", fullName(prompt), prompt.ActionText,
                    prompt.ObjectText, prompt.HoldDuration, p and v3(p) or "?"))
            end)
        end)
    end)
end

----------------------------------------------------------------- record: loop, files, start / stop
local function newFile()
    W.file = PLACE_DIR .. "/watch_" .. stamp() .. ".txt"
    W.fileBytes = 0
end
local function header(why)
    local hum = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
    wLine(string.format("# %s | %s | PlaceId %s | GameId %s | Job %s | player %s | hub %s | maxhp %s | in=%s out=%s mobs=%s path=%s gui=%s me=%s self=%s new=%s use=%s",
        why, os.date("%Y-%m-%d"), tostring(game.PlaceId), tostring(game.GameId), tostring(game.JobId):sub(1, 8), LP.Name, VERSION,
        hum and tostring(hum.MaxHealth) or "?", tostring(W.inOn), tostring(W.outOn), tostring(W.mobsOn), tostring(W.pathOn),
        tostring(W.guiOn), tostring(W.meOn), tostring(W.selfOn), tostring(W.newOn), tostring(W.useOn)))
end
local function flush()
    if #W.log == 0 then return end
    if not W.file then newFile() end
    local chunk = table.concat(W.log, "\n") .. "\n"
    W.log = {}
    if W.fileBytes + #chunk > MAX_FILE then
        W.part = W.part + 1
        newFile()
        chunk = os.date("%H:%M:%S ") .. "# part " .. W.part .. " (file size cap)\n" .. chunk
    end
    W.fileBytes = W.fileBytes + #chunk
    wAppend(W.file, chunk)
end
task.spawn(function()
    local n = 0
    while F.alive do
        task.wait(0.25)
        n = n + 1
        if W.on then
            W.newBudget = 5
            if W.mobsOn then pcall(mobTick) end
            if n % 4 == 0 then
                if W.pathOn then pcall(pathTick) end
                if W.guiOn then pcall(guiTick) end
            end
            if W.meOn and n % 8 == 0 then pcall(meTick) end
        end
        if n % 12 == 0 then pcall(flush) end
    end
end)
local function summary()
    local keys = {}
    for k in pairs(W.counts) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return W.counts[a] > W.counts[b] end)
    wLine("# summary: " .. #keys .. " remotes seen")
    for i = 1, math.min(#keys, 60) do wLine("#   " .. W.counts[keys[i]] .. " x " .. keys[i]) end
end
local function startParts()
    if W.inOn then pcall(startListening) end
    if W.selfOn then pcall(startSelf) end
    if W.newOn then pcall(startNew) end
    if W.useOn then pcall(startUse) end
    if W.outOn and not installHook() then W.outOn = false wLine("# no hookmetamethod: my calls cannot be recorded") end
end
local function setWatch(v, why)
    W.on = v
    F.cfg.watchResume = v
    saveAll()
    if v then
        newFile()
        W.counts = {}
        W.meState, W.guiState, W.lastPos, W.lastHp = nil, {}, nil, nil
        header(why or "watch on")
        startParts()
    else
        pcall(summary)
        wLine("# watch off")
        pcall(flush)
    end
end
local function setPart(key, v)
    W[key] = v
    if key == "outOn" and v and not installHook() then W.outOn = false W.scanStatus = "no hookmetamethod in this executor" end
    if W.on then startParts() end
end
local function mark()
    W.marks = W.marks + 1
    local me = myRoot()
    wLine(string.format("# MARK %d %s | at %s", W.marks, W.note ~= "" and W.note or "-", me and v3(me.Position) or "?"))
end

----------------------------------------------------------------- scans (one press each)
local function scanFile(kind) return PLACE_DIR .. "/scan_" .. kind .. "_" .. stamp() .. ".txt" end
local function placeVersion() local ok, v = pcall(function() return game.PlaceVersion end) return ok and tostring(v) or "?" end
local function indexAdd(kind, lines)
    wAppend(GAME_DIR .. "/index.txt", string.format("%s | place %s | version %s | %s | %d lines | %s\n", os.date("%Y-%m-%d %H:%M:%S"),
        tostring(game.PlaceId), placeVersion(), kind, lines, LP.Name))
end
local function alreadyScanned(kind)
    local needle = "| place " .. tostring(game.PlaceId) .. " | version " .. placeVersion() .. " | " .. kind .. " |"
    return readText(GAME_DIR .. "/index.txt"):find(needle, 1, true) ~= nil
end
local function scanHead(kind)
    return { string.format("# scan %s | %s | PlaceId %s | GameId %s | player %s | hub %s", kind, os.date("%Y-%m-%d %H:%M:%S"),
        tostring(game.PlaceId), tostring(game.GameId), LP.Name, VERSION) }
end
local function valueText(o)
    if o:IsA("ValueBase") then
        local ok, v = pcall(function() return o.Value end)
        return " = " .. (ok and describe(v, 2) or "?")
    end
    return ""
end
-- instance tree: class, name, value, attributes; yields so the game does not freeze
local function tree(root, maxDepth, out, cap)
    local n = 0
    local function walk(o, depth)
        if #out >= cap then return end
        n = n + 1
        if n % 400 == 0 then task.wait() end
        local extra = ""
        if o:IsA("Animation") then extra = " id " .. tostring(o.AnimationId) end
        if o:IsA("Sound") then extra = " id " .. tostring(o.SoundId) end
        out[#out + 1] = string.rep("  ", depth) .. o.ClassName .. " " .. o.Name .. valueText(o) .. extra .. attrText(o)
        if depth >= maxDepth then
            local kids = #o:GetChildren()
            if kids > 0 then out[#out + 1] = string.rep("  ", depth + 1) .. "(" .. kids .. " children not shown)" end
            return
        end
        for _, ch in ipairs(o:GetChildren()) do walk(ch, depth + 1) end
    end
    pcall(walk, root, 0)
    if #out >= cap then out[#out + 1] = "(cut at " .. cap .. " lines)" end
end
local function finish(kind, out)
    local path = scanFile(kind)
    wWrite(path, table.concat(out, "\n"))
    W.scanStatus = kind .. ": " .. #out .. " lines"
    pcall(indexAdd, kind, #out)
    pcall(flushKnown)
    wLine("# scan " .. kind .. " -> " .. path .. " (" .. #out .. " lines)")
    return path
end

local function scanGame()
    local out = scanHead("game")
    out[#out + 1] = "\n## remotes (everywhere)"
    local roots = { RS, workspace, LP, game:GetService("ReplicatedFirst"), game:GetService("Lighting"), game:GetService("StarterGui"), game:GetService("StarterPack"), game:GetService("StarterPlayer") }
    local n = 0
    for _, r in ipairs(roots) do
        pcall(function()
            for _, d in ipairs(r:GetDescendants()) do
                n = n + 1
                if n % 2000 == 0 then task.wait() end
                if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") or d:IsA("BindableEvent") or d:IsA("BindableFunction") or d.ClassName == "UnreliableRemoteEvent" then
                    out[#out + 1] = d.ClassName .. " " .. fullName(d)
                    if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then addKnown("REMOTE", fullName(d), d.ClassName) end
                end
            end
        end)
    end
    out[#out + 1] = "\n## scripts (names only)"
    for _, r in ipairs(roots) do
        pcall(function()
            for _, d in ipairs(r:GetDescendants()) do
                if d:IsA("LocalScript") or d:IsA("ModuleScript") then out[#out + 1] = d.ClassName .. " " .. fullName(d) end
            end
        end)
    end
    out[#out + 1] = "\n## ReplicatedStorage tree"
    tree(RS, 7, out, 9000)
    out[#out + 1] = "\n## ReplicatedFirst tree"
    tree(game:GetService("ReplicatedFirst"), 5, out, 9500)
    out[#out + 1] = "\n## StarterPack / StarterPlayer tree"
    tree(game:GetService("StarterPack"), 4, out, 10000)
    tree(game:GetService("StarterPlayer"), 5, out, 10500)
    out[#out + 1] = "\n## teams / lighting"
    pcall(function() tree(game:GetService("Teams"), 2, out, 10700) end)
    return finish("game", out)
end

local function scanMap()
    local out = scanHead("map")
    local me = myRoot()
    local mePos = me and me.Position
    out[#out + 1] = "me at " .. (mePos and v3(mePos) or "?")
    local function dist(p) return (mePos and p) and string.format("%.0f", (p - mePos).Magnitude) or "?" end
    local npcs, prompts, clicks, touch, seats, tools, spawns = {}, {}, {}, {}, {}, {}, {}
    local playerChars = {}
    for _, p in ipairs(Players:GetPlayers()) do if p.Character then playerChars[p.Character] = true end end
    local n = 0
    for _, d in ipairs(workspace:GetDescendants()) do
        n = n + 1
        if n % 2000 == 0 then task.wait() end
        pcall(function()
            if d:IsA("Humanoid") and d.Parent and not playerChars[d.Parent] then
                local p = posOf(d.Parent)
                npcs[#npcs + 1] = string.format("NPC %s | hp %.0f/%.0f speed %.0f | dist %s at %s | %s%s", d.Parent.Name, d.Health, d.MaxHealth,
                    d.WalkSpeed, dist(p), p and v3(p) or "?", fullName(d.Parent), attrText(d.Parent))
                addKnown("NPC", d.Parent.Name, string.format("maxhp %.0f at %s | %s", d.MaxHealth, p and v3(p) or "?", fullName(d.Parent)), true)
            elseif d:IsA("ProximityPrompt") then
                local p = d.Parent and posOf(d.Parent)
                addKnown("PROMPT", fullName(d), string.format("%q / %q at %s", d.ActionText, d.ObjectText, p and v3(p) or "?"), true)
                prompts[#prompts + 1] = string.format("PROMPT %q / %q | enabled %s hold %.1f range %.0f | dist %s at %s | %s", d.ActionText, d.ObjectText,
                    tostring(d.Enabled), d.HoldDuration, d.MaxActivationDistance, dist(p), p and v3(p) or "?", fullName(d))
            elseif d:IsA("ClickDetector") then
                local p = d.Parent and posOf(d.Parent)
                clicks[#clicks + 1] = string.format("CLICK range %.0f | dist %s at %s | %s", d.MaxActivationDistance, dist(p), p and v3(p) or "?", fullName(d))
            elseif d:IsA("TouchTransmitter") then
                local p = d.Parent and posOf(d.Parent)
                if #touch < 600 then touch[#touch + 1] = string.format("TOUCH dist %s at %s | %s", dist(p), p and v3(p) or "?", fullName(d.Parent)) end
            elseif d:IsA("Seat") or d:IsA("VehicleSeat") then
                seats[#seats + 1] = string.format("SEAT %s at %s | %s", d.ClassName, v3(d.Position), fullName(d))
            elseif d:IsA("Tool") then
                local p = posOf(d:FindFirstChild("Handle") or d)
                tools[#tools + 1] = string.format("TOOL %s at %s | %s", d.Name, p and v3(p) or "?", fullName(d))
            elseif d:IsA("SpawnLocation") then
                spawns[#spawns + 1] = string.format("SPAWN at %s | %s", v3(d.Position), fullName(d))
            end
        end)
    end
    local function section(title, list)
        out[#out + 1] = "\n## " .. title .. " (" .. #list .. ")"
        for _, l in ipairs(list) do out[#out + 1] = l end
    end
    section("NPCs", npcs) section("proximity prompts", prompts) section("click detectors", clicks)
    section("touch parts", touch) section("seats", seats) section("tools on the ground", tools) section("spawns", spawns)
    out[#out + 1] = "\n## workspace top levels"
    tree(workspace, 2, out, #out + 2500)
    out[#out + 1] = "\n## other players (" .. (#Players:GetPlayers() - 1) .. ")"
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LP then
            local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
            out[#out + 1] = "PLAYER " .. p.Name .. " dist " .. dist(r and r.Position) .. attrText(p)
        end
    end
    return finish("map", out)
end

local function scanScreen()
    local out = scanHead("screen")
    local pg = LP:FindFirstChildOfClass("PlayerGui")
    if not pg then return finish("screen", out) end
    local function visible(o)
        local cur = o
        while cur and cur ~= pg do
            if cur:IsA("GuiObject") and not cur.Visible then return false end
            if cur:IsA("ScreenGui") and not cur.Enabled then return false end
            cur = cur.Parent
        end
        return true
    end
    out[#out + 1] = "## screen guis"
    for _, sg in ipairs(pg:GetChildren()) do
        if sg:IsA("ScreenGui") then out[#out + 1] = "GUI " .. sg.Name .. " enabled " .. tostring(sg.Enabled) .. " children " .. #sg:GetChildren() end
    end
    out[#out + 1] = "\n## visible text and buttons"
    local n = 0
    for _, d in ipairs(pg:GetDescendants()) do
        n = n + 1
        if n % 1500 == 0 then task.wait() end
        if #out > 4000 then out[#out + 1] = "(cut)" break end
        pcall(function()
            if (d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") or d:IsA("ImageButton")) and visible(d) then
                local text = (d:IsA("ImageButton") and "" or d.Text) or ""
                if d:IsA("GuiButton") or text ~= "" then
                    local ap, as = d.AbsolutePosition, d.AbsoluteSize
                    out[#out + 1] = string.format("%s %q | at %.0f,%.0f size %.0fx%.0f | %s", d.ClassName, text, ap.X, ap.Y, as.X, as.Y, fullName(d))
                end
            end
        end)
    end
    out[#out + 1] = "\n## whole PlayerGui tree (also hidden)"
    tree(pg, 6, out, #out + 5000)
    return finish("screen", out)
end

local function scanMe()
    local out = scanHead("me")
    out[#out + 1] = "## player values"
    local now = readMe()
    local keys = {}
    for k in pairs(now) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do out[#out + 1] = k .. " = " .. now[k] end
    out[#out + 1] = "\n## player tree"
    tree(LP, 6, out, #out + 4000)
    local c = LP.Character
    if c then
        out[#out + 1] = "\n## character tree"
        tree(c, 5, out, #out + 2500)
        local hum = c:FindFirstChildOfClass("Humanoid")
        if hum then
            out[#out + 1] = string.format("\n## humanoid: hp %.0f/%.0f walkspeed %.1f jump %.1f state %s", hum.Health, hum.MaxHealth, hum.WalkSpeed,
                hum.UseJumpPower and hum.JumpPower or hum.JumpHeight, tostring(hum:GetState()))
            local animator = hum:FindFirstChildOfClass("Animator")
            if animator then
                for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do
                    out[#out + 1] = "playing " .. tostring(tr.Animation and tr.Animation.AnimationId) .. " (" .. tr.Name .. ") len " .. string.format("%.2f", tr.Length)
                end
            end
        end
    end
    return finish("me", out)
end

local function scanAround()
    local out = scanHead("around")
    local me = myRoot()
    if not me then out[#out + 1] = "no character" return finish("around", out) end
    out[#out + 1] = "me at " .. v3(me.Position) .. " | range " .. W.nearRange
    local groups, order = {}, {}
    local params = OverlapParams.new()
    local ok, parts = pcall(function() return workspace:GetPartBoundsInRadius(me.Position, W.nearRange, params) end)
    if not ok then out[#out + 1] = "GetPartBoundsInRadius failed" return finish("around", out) end
    for _, p in ipairs(parts) do
        if not (LP.Character and p:IsDescendantOf(LP.Character)) then
            -- group by the highest Model under workspace's first two levels
            local top = p
            local cur = p.Parent
            while cur and cur ~= workspace do
                if cur:IsA("Model") then top = cur end
                cur = cur.Parent
            end
            local g = groups[top]
            if not g then g = { n = 0, near = math.huge } groups[top] = g order[#order + 1] = top end
            g.n = g.n + 1
            local d = (p.Position - me.Position).Magnitude
            if d < g.near then g.near = d end
        end
    end
    table.sort(order, function(a, b) return groups[a].near < groups[b].near end)
    for i, top in ipairs(order) do
        if i > 600 then out[#out + 1] = "(cut)" break end
        local g = groups[top]
        local p = posOf(top)
        local extra = ""
        if top:IsA("BasePart") then extra = string.format(" size %s collide %s anchored %s transp %.1f", v3(top.Size), tostring(top.CanCollide), tostring(top.Anchored), top.Transparency) end
        out[#out + 1] = string.format("%.0f | %s %s | parts %d | at %s%s%s", g.near, top.ClassName, fullName(top), g.n, p and v3(p) or "?", extra, attrText(top))
    end
    out[#out + 1] = "\n## nearest 25 in detail"
    for i = 1, math.min(25, #order) do
        out[#out + 1] = "--- " .. fullName(order[i])
        tree(order[i], 3, out, #out + 120)
    end
    return finish("around", out)
end

local scanning = false
local function runScan(fn, name)
    if scanning then W.scanStatus = "busy" return end
    scanning = true
    W.scanStatus = name .. ": working..."
    local ok, err = pcall(fn)
    if not ok then W.scanStatus = name .. " failed: " .. tostring(err):sub(1, 60) wLine("# scan " .. name .. " failed: " .. tostring(err)) end
    scanning = false
end
local function scanAll()
    local done = {}
    for _, s in ipairs({ { scanMe, "me" }, { scanScreen, "screen" }, { scanAround, "around" }, { scanMap, "map" }, { scanGame, "game" } }) do
        local ok = pcall(s[1])
        done[#done + 1] = s[2] .. (ok and "" or "(fail)")
        task.wait(0.2)
    end
    W.scanStatus = "all done: " .. table.concat(done, " ")
end

-- dump client scripts with the executor's decompiler. Local read of bytecode: nothing runs, nothing is sent.
-- Slow (one script per frame or slower). Own button because it is the heaviest thing here.
local function dumpScripts()
    if type(decompile) ~= "function" then W.scanStatus = "no decompile in this executor" return end
    local dir = FOLDER .. "/src_" .. tostring(game.PlaceId)
    pcall(function() if not isfolder(dir) then makefolder(dir) end end)
    local list, seen = {}, {}
    local function add(d)
        if typeof(d) == "Instance" and not seen[d] and (d:IsA("LocalScript") or d:IsA("ModuleScript")) then
            seen[d] = true
            list[#list + 1] = d
        end
    end
    local roots = { RS, game:GetService("ReplicatedFirst"), LP, workspace, game:GetService("StarterPlayer"), game:GetService("StarterGui"), game:GetService("StarterPack") }
    for _, r in ipairs(roots) do
        pcall(function() for _, d in ipairs(r:GetDescendants()) do add(d) end end)
    end
    -- scripts the game hid (parented to nil) or loaded from elsewhere: read-only lists from the executor
    for _, fname in ipairs({ "getscripts", "getloadedmodules", "getrunningscripts", "getnilinstances" }) do
        local fn = G[fname] or getfenv(0)[fname]
        if type(fn) == "function" then
            pcall(function() for _, d in ipairs(fn()) do add(d) end end)
        end
    end
    local index, okN = { "# " .. #list .. " scripts | PlaceId " .. tostring(game.PlaceId) .. " | " .. os.date("%Y-%m-%d %H:%M:%S") }, 0
    for i, s in ipairs(list) do
        if not F.alive then break end
        local ok, src = pcall(decompile, s)
        local file = string.format("%04d_%s.lua", i, (s.Name:gsub("[^%w_%-]", "_")):sub(1, 40))
        if ok and type(src) == "string" and #src > 0 then
            okN = okN + 1
            wWrite(dir .. "/" .. file, "-- " .. fullName(s) .. "\n" .. src)
        end
        index[#index + 1] = file .. " | " .. (ok and type(src) == "string" and (#src .. " bytes") or "FAILED") .. " | " .. s.ClassName .. " " .. fullName(s)
        W.scanStatus = "scripts: " .. i .. " / " .. #list
        task.wait(0.05)
    end
    wWrite(dir .. "/_index.txt", table.concat(index, "\n"))
    W.scanStatus = "scripts done: " .. okN .. " of " .. #list
    wLine("# dump scripts -> " .. dir .. " (" .. okN .. " of " .. #list .. ")")
end

-- does the server let my client move nearby NPCs? (isnetworkowner only asks; nothing changes)
local function checkOwnership()
    if type(isnetworkowner) ~= "function" then wLine("# CHECK ownership: executor has no isnetworkowner") return "no isnetworkowner" end
    pcall(scanMobs)
    local me = myRoot()
    local near, mine = 0, 0
    for _, m in ipairs(W.mobs) do
        if me and m.root.Parent and (m.root.Position - me.Position).Magnitude <= W.mobRange then
            near = near + 1
            local ok, own = pcall(isnetworkowner, m.root)
            if ok and own then mine = mine + 1 end
        end
    end
    wLine(string.format("# CHECK ownership: %d of %d nearby NPCs are owned by my client", mine, near))
    return mine .. " of " .. near .. " owned"
end
-- what this executor can do (decides which Watch parts work)
local function checkExecutor()
    local names = { "hookmetamethod", "getnamecallmethod", "newcclosure", "checkcaller", "decompile", "isnetworkowner", "appendfile",
        "getconnections", "firesignal", "fireproximityprompt", "firetouchinterest", "fireclickdetector", "getgc", "getsenv", "request", "queue_on_teleport", "setclipboard" }
    local have, miss = {}, {}
    for _, nm in ipairs(names) do
        local ok, f = pcall(function() return (getgenv and getgenv()[nm]) or _G[nm] end)
        if ok and type(f) == "function" then have[#have + 1] = nm else miss[#miss + 1] = nm end
    end
    local exName = "?"
    pcall(function() if type(identifyexecutor) == "function" then exName = tostring(identifyexecutor()) end end)
    wLine("# CHECK executor " .. exName .. " | has: " .. table.concat(have, " ") .. " | missing: " .. table.concat(miss, " "))
    return #have .. " of " .. #names .. " functions"
end

-- auto scan: the first time a map (PlaceId + version) is seen, do the light scans by themselves
local function autoScan()
    if not F.cfg.autoScan then return end
    pcall(function() if not game:IsLoaded() then game.Loaded:Wait() end end)
    local t0 = os.clock()
    while F.alive and not myRoot() and os.clock() - t0 < 60 do task.wait(1) end
    task.wait(10) -- let the map stream in
    if not F.alive or not F.cfg.autoScan then return end
    for _, s in ipairs({ { scanMe, "me" }, { scanMap, "map" }, { scanScreen, "screen" }, { scanGame, "game" } }) do
        if not alreadyScanned(s[2]) then
            runScan(s[1], s[2])
            task.wait(1)
        end
    end
    W.scanStatus = "auto scan done for this map"
end

--------------------------------------------------------------------------------
-- Remotes (live): every remote my client calls, as Luau code that can be pasted and run.
-- Needs the hook (W.outOn). Kept in memory only (300 remotes); the Record file gets the plain lines.
--------------------------------------------------------------------------------
local R = { list = {}, byKey = {}, selected = nil, dirty = true, total = 0, max = 300 }
W.remotes = R
local function isIdent(s) return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil end
local function instCode(o)
    if o == game then return "game" end
    if o == workspace then return "workspace" end
    local okP, inGame = pcall(function() return o:IsDescendantOf(game) end)
    if not okP or not inGame then return "nil --[[ " .. o.ClassName .. " " .. o.Name .. " (not in game) ]]" end
    local parts = {}
    local cur = o
    while cur and cur ~= game do
        if cur == LP then parts[#parts + 1] = "@LP" break end
        if cur.Parent == game then parts[#parts + 1] = "@S" .. cur.ClassName break end
        parts[#parts + 1] = cur.Name
        cur = cur.Parent
    end
    local s = ""
    for i = #parts, 1, -1 do
        local p = parts[i]
        if p == "@LP" then s = 'game:GetService("Players").LocalPlayer'
        elseif p:sub(1, 2) == "@S" then s = (p == "@SWorkspace") and "workspace" or ('game:GetService("' .. p:sub(3) .. '")')
        elseif isIdent(p) then s = s .. "." .. p
        else s = s .. "[" .. string.format("%q", p) .. "]" end
    end
    return s
end
local function num(n)
    if n ~= n then return "0/0" end
    if n == math.huge then return "math.huge" end
    if n == -math.huge then return "-math.huge" end
    if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
    return tostring(n)
end
local function toCode(v, indent, seen)
    local t = typeof(v)
    if t == "nil" or t == "boolean" then return tostring(v) end
    if t == "number" then return num(v) end
    if t == "string" then return string.format("%q", v) end
    if t == "Instance" then return instCode(v) end
    if t == "Vector3" then return "Vector3.new(" .. num(v.X) .. ", " .. num(v.Y) .. ", " .. num(v.Z) .. ")" end
    if t == "Vector2" then return "Vector2.new(" .. num(v.X) .. ", " .. num(v.Y) .. ")" end
    if t == "CFrame" then
        local c = { v:GetComponents() }
        for i = 1, #c do c[i] = num(c[i]) end
        return "CFrame.new(" .. table.concat(c, ", ") .. ")"
    end
    if t == "Color3" then return "Color3.new(" .. num(v.R) .. ", " .. num(v.G) .. ", " .. num(v.B) .. ")" end
    if t == "UDim" then return "UDim.new(" .. num(v.Scale) .. ", " .. num(v.Offset) .. ")" end
    if t == "UDim2" then return "UDim2.new(" .. num(v.X.Scale) .. ", " .. num(v.X.Offset) .. ", " .. num(v.Y.Scale) .. ", " .. num(v.Y.Offset) .. ")" end
    if t == "BrickColor" then return "BrickColor.new(" .. string.format("%q", v.Name) .. ")" end
    if t == "EnumItem" or t == "Enum" or t == "Enums" then return tostring(v) end
    if t == "Ray" then return "Ray.new(" .. toCode(v.Origin, indent, seen) .. ", " .. toCode(v.Direction, indent, seen) .. ")" end
    if t == "NumberRange" then return "NumberRange.new(" .. num(v.Min) .. ", " .. num(v.Max) .. ")" end
    if t == "table" then
        seen = seen or {}
        if seen[v] then return "nil --[[ cyclic table ]]" end
        if #indent > 24 then return "nil --[[ table too deep ]]" end
        seen[v] = true
        local inner = indent .. "    "
        local lines, n = {}, 0
        local arr = #v
        for i = 1, arr do
            n = n + 1
            lines[#lines + 1] = inner .. toCode(v[i], inner, seen) .. ","
        end
        for k, val in pairs(v) do
            if not (type(k) == "number" and k >= 1 and k <= arr and k == math.floor(k)) then
                n = n + 1
                if n > 200 then lines[#lines + 1] = inner .. "-- ... more" break end
                local key = isIdent(k) and k or ("[" .. toCode(k, inner, seen) .. "]")
                lines[#lines + 1] = inner .. key .. " = " .. toCode(val, inner, seen) .. ","
            end
        end
        seen[v] = nil
        if #lines == 0 then return "{}" end
        return "{\n" .. table.concat(lines, "\n") .. "\n" .. indent .. "}"
    end
    return "nil --[[ " .. t .. ": " .. tostring(v) .. " ]]"
end
local function entryCode(e)
    local out = {}
    out[#out + 1] = "-- " .. e.method .. " x" .. e.count .. " | last " .. e.at
    out[#out + 1] = "-- from: " .. (e.caller or "?")
    local n = e.args.n or #e.args
    local target = instCode(e.remote)
    if n == 0 then
        out[#out + 1] = target .. ":" .. e.method .. "()"
    else
        out[#out + 1] = "local args = {"
        for i = 1, n do out[#out + 1] = "    [" .. i .. "] = " .. toCode(e.args[i], "    ") .. "," end
        out[#out + 1] = "}"
        out[#out + 1] = target .. ":" .. e.method .. "(unpack(args, 1, " .. n .. "))"
    end
    return table.concat(out, "\n")
end
onLive = function(remote, method, args, caller)
    local key = fullName(remote) .. ":" .. method
    local e = R.byKey[key]
    if not e then
        if #R.list >= R.max then
            local old = table.remove(R.list, 1)
            R.byKey[old.key] = nil
            if R.selected == old then R.selected = nil end
        end
        e = { key = key, remote = remote, method = method, name = remote.Name, count = 0 }
        R.byKey[key] = e
        R.list[#R.list + 1] = e
    end
    e.count = e.count + 1
    e.args = args
    e.at = os.date("%H:%M:%S")
    e.caller = caller and fullName(caller) or nil
    R.total = R.total + 1
    R.dirty = true
end
local function liveClear() R.list, R.byKey, R.selected, R.total, R.dirty = {}, {}, nil, 0, true end
local function liveIgnore()
    local e = R.selected
    if not e then return end
    F.cfg.watchIgnore[e.name] = true
    saveAll()
    for i = #R.list, 1, -1 do
        if R.list[i].name == e.name then R.byKey[R.list[i].key] = nil table.remove(R.list, i) end
    end
    R.selected, R.dirty = nil, true
end
local function liveCopy()
    local e = R.selected
    if not e then return "pick a remote first" end
    local code = entryCode(e)
    wWrite(PLACE_DIR .. "/code_" .. (e.name:gsub("[^%w_%-]", "_")):sub(1, 40) .. ".lua", code)
    local okC = type(setclipboard) == "function" and pcall(setclipboard, code)
    return okC and "copied + saved to file" or "saved to file (no clipboard)"
end
-- Run: sends the selected call to the game again. The one action in Watch that is not read-only.
local function liveRun()
    local e = R.selected
    if not e then return "pick a remote first" end
    local n = e.args.n or #e.args
    local ok, err = pcall(function()
        if e.method == "InvokeServer" then
            task.spawn(function() pcall(function() e.remote:InvokeServer(unpack(e.args, 1, n)) end) end)
        else
            e.remote:FireServer(unpack(e.args, 1, n))
        end
    end)
    wLine("# RUN " .. e.key .. (ok and "" or (" failed: " .. tostring(err))))
    return ok and ("sent " .. e.name) or "failed"
end

F.conns[#F.conns + 1] = { Disconnect = function()
    pcall(flush)
    for _, c in ipairs(W.conns) do pcall(function() c:Disconnect() end) end
end }
--------------------------------------------------------------------------------
-- UI: own window in the moseeri hub (AA) style - wide, tabs across the top, two columns of cards.
-- Same theme values as AA (UIRef.Theme). No MacLib.
--------------------------------------------------------------------------------
local UIS = game:GetService("UserInputService")
local T = {
    bg = Color3.fromRGB(11, 11, 13), headBg = Color3.fromRGB(4, 4, 5), card = Color3.fromRGB(17, 17, 21),
    line = Color3.fromRGB(30, 30, 37), text = Color3.fromRGB(212, 212, 218), value = Color3.fromRGB(180, 180, 190),
    mute = Color3.fromRGB(138, 138, 148), faint = Color3.fromRGB(88, 88, 98), accent = Color3.fromRGB(138, 180, 255),
    onAccent = Color3.fromRGB(11, 11, 13), off = Color3.fromRGB(44, 44, 52), good = Color3.fromRGB(143, 209, 158),
    bad = Color3.fromRGB(232, 104, 104), white = Color3.fromRGB(236, 236, 242),
}
local UI = { pages = {}, tabs = {}, refreshers = {} }

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 8) }, o) end
local function stroke(o, c) new("UIStroke", { Color = c or T.line, Thickness = 1 }, o) end
local function label(parent, text, size, color, font, props)
    local l = new("TextLabel", {
        BackgroundTransparency = 1, Text = text, TextSize = size or 13, TextColor3 = color or T.text,
        Font = font or Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

local guiParent = (type(gethui) == "function" and gethui()) or game:GetService("CoreGui")
pcall(function() local o = guiParent:FindFirstChild("MoseeriWatch") if o then o:Destroy() end end)
pcall(function() local o = guiParent:FindFirstChild("MoseeriWatchToggle") if o then o:Destroy() end end)
local gui = new("ScreenGui", { Name = "MoseeriWatch", ResetOnSpawn = false, DisplayOrder = 998, IgnoreGuiInset = true })
local WIN_W, HEAD_H, TAB_H = 780, 92, 40
local win = new("Frame", { Size = UDim2.fromOffset(WIN_W, 300), Position = UDim2.new(0.5, -WIN_W / 2, 0, 150),
    BackgroundColor3 = T.bg, BorderSizePixel = 0, Active = true }, gui)
corner(win, 12)
stroke(win)
-- (11-14 test: a tap on an empty part of the window went through to the game and opened its Events page.
-- An invisible button under everything takes those taps)
new("TextButton", { Name = "Sink", Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Text = "", AutoButtonColor = false, ZIndex = 0 }, win)
local scale = new("UIScale", { Scale = 1 }, win)
pcall(function()
    local vp = workspace.CurrentCamera.ViewportSize
    scale.Scale = math.clamp(math.min(vp.X * 0.62 / WIN_W, vp.Y * 0.8 / 460), 0.55, 1.2)
end)

-- header: spaced title, subtitle, a few stars, the ··· button hides the window
local head = new("Frame", { Size = UDim2.new(1, 0, 0, HEAD_H), BackgroundColor3 = T.headBg, BorderSizePixel = 0 }, win)
corner(head, 12)
new("Frame", { Size = UDim2.new(1, 0, 0, 12), Position = UDim2.new(0, 0, 1, -12), BackgroundColor3 = T.headBg, BorderSizePixel = 0 }, head)
label(head, "M O S E E R I   W A T C H", 26, T.white, Enum.Font.GothamMedium, { Position = UDim2.fromOffset(28, 22), Size = UDim2.new(1, -120, 0, 32) })
label(head, "recorder · scanner", 12, T.mute, Enum.Font.Gotham, { Position = UDim2.fromOffset(28, 56), Size = UDim2.new(1, -120, 0, 16) })
local rng = Random.new(7)
for _ = 1, 26 do
    local s = rng:NextInteger(1, 2)
    new("Frame", { Size = UDim2.fromOffset(s, s), Position = UDim2.new(rng:NextNumber(0.35, 0.98), 0, rng:NextNumber(0.1, 0.9), 0),
        BackgroundColor3 = T.white, BackgroundTransparency = rng:NextNumber(0.3, 0.8), BorderSizePixel = 0 }, head)
end
local dots = new("TextButton", { Size = UDim2.fromOffset(40, 28), Position = UDim2.new(1, -56, 0, 18), BackgroundTransparency = 1,
    Text = "···", TextSize = 20, TextColor3 = T.mute, Font = Enum.Font.GothamBold }, head)

-- drag by the header (mouse and touch)
do
    local dragging, start, startPos
    -- (11-14 test: the window slid on later taps - the drag only ends when THIS touch ends, and only the same
    -- touch moves it)
    local dragInput
    head.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging, start, startPos, dragInput = true, input.Position, win.Position, input
            local c
            c = input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false dragInput = nil c:Disconnect() end
            end)
        end
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        local same = (input == dragInput) or (input.UserInputType == Enum.UserInputType.MouseMovement and dragInput and dragInput.UserInputType == Enum.UserInputType.MouseButton1)
        if same then
            local d = (input.Position - start) / scale.Scale
            win.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
    UIS.InputEnded:Connect(function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false dragInput = nil end
    end)
end

-- tabs
local tabBar = new("Frame", { Size = UDim2.new(1, -40, 0, TAB_H), Position = UDim2.fromOffset(20, HEAD_H), BackgroundTransparency = 1 }, win)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 18), SortOrder = Enum.SortOrder.LayoutOrder }, tabBar)
new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.fromOffset(0, HEAD_H + TAB_H), BackgroundColor3 = T.line, BorderSizePixel = 0 }, win)
local body = new("Frame", { Size = UDim2.new(1, -36, 0, 10), Position = UDim2.fromOffset(18, HEAD_H + TAB_H + 10), BackgroundTransparency = 1 }, win)

local function fitHeight(page)
    local h = 0
    for _, col in ipairs(page.cols) do
        local ch = 0
        for _, c in ipairs(col:GetChildren()) do
            if c:IsA("Frame") then ch = ch + c.AbsoluteSize.Y / scale.Scale + 10 end
        end
        if ch > h then h = ch end
    end
    win.Size = UDim2.fromOffset(WIN_W, HEAD_H + TAB_H + 20 + h)
end
function UI.show(name)
    for n, p in pairs(UI.pages) do p.frame.Visible = (n == name) end
    for n, t in pairs(UI.tabs) do
        t.btn.TextColor3 = (n == name) and T.white or T.mute
        t.bar.Visible = (n == name)
    end
    UI.current = name
    task.delay(0.15, function() pcall(fitHeight, UI.pages[name]) end)
end
function UI.page(name, order)
    local btn = new("TextButton", { AutoButtonColor = false, BackgroundTransparency = 1, Text = name, TextSize = 14,
        Font = Enum.Font.GothamMedium, TextColor3 = T.mute, LayoutOrder = order, Size = UDim2.new(0, 0, 1, 0), AutomaticSize = Enum.AutomaticSize.X }, tabBar)
    local bar = new("Frame", { Size = UDim2.new(1, 0, 0, 2), Position = UDim2.new(0, 0, 1, -2), BackgroundColor3 = T.accent, BorderSizePixel = 0, Visible = false }, btn)
    UI.tabs[name] = { btn = btn, bar = bar }
    local frame = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundTransparency = 1, Visible = false }, body)
    local cols = {}
    for i = 1, 2 do
        local col = new("Frame", { Size = UDim2.new(0.5, -6, 1, 0), Position = UDim2.new((i - 1) * 0.5, (i - 1) * 6, 0, 0), BackgroundTransparency = 1 }, frame)
        new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, col)
        cols[i] = col
    end
    local page = { frame = frame, cols = cols }
    UI.pages[name] = page
    btn.MouseButton1Click:Connect(function() UI.show(name) end)
    return page
end

-- a card: title + rows with a hairline between them
local cardN = 0
function UI.card(page, side, title)
    cardN = cardN + 1
    local c = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = T.card,
        BorderSizePixel = 0, LayoutOrder = cardN }, page.cols[side])
    corner(c, 10)
    new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14), PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 8) }, c)
    new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder }, c)
    label(c, title, 14, T.white, Enum.Font.GothamMedium, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 0 })
    return { frame = c, n = 0 }
end
local function row(card, text, h)
    card.n = card.n + 1
    local r = new("Frame", { Size = UDim2.new(1, 0, 0, h or 38), BackgroundTransparency = 1, LayoutOrder = card.n }, card.frame)
    if card.n > 1 then new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = T.line, BorderSizePixel = 0 }, r) end
    label(r, text, 13, T.text, Enum.Font.Gotham, { Size = UDim2.new(0.62, 0, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd })
    return r
end

-- switch
function UI.toggle(card, text, get, setv)
    local r = row(card, text)
    local word = label(r, "", 11, T.faint, Enum.Font.GothamMedium, { Size = UDim2.fromOffset(30, 20), Position = UDim2.new(1, -84, 0.5, -10), TextXAlignment = Enum.TextXAlignment.Right })
    local sw = new("TextButton", { AutoButtonColor = false, Text = "", Size = UDim2.fromOffset(46, 24), Position = UDim2.new(1, -46, 0.5, -12),
        BackgroundColor3 = T.off, BorderSizePixel = 0 }, r)
    corner(sw, 12)
    local knob = new("Frame", { Size = UDim2.fromOffset(18, 18), Position = UDim2.fromOffset(3, 3), BackgroundColor3 = T.white, BorderSizePixel = 0 }, sw)
    corner(knob, 8)
    local function paint()
        local on = get() and true or false
        sw.BackgroundColor3 = on and T.accent or T.off
        knob.Position = on and UDim2.fromOffset(25, 3) or UDim2.fromOffset(3, 3)
        word.Text = on and "ON" or "OFF"
        word.TextColor3 = on and T.accent or T.faint
    end
    sw.MouseButton1Click:Connect(function() pcall(setv, not get()) paint() end)
    paint()
    UI.refreshers[#UI.refreshers + 1] = paint
end
-- choice: the value on the right, a tap goes to the next option
function UI.choice(card, text, options, get, setv)
    local r = row(card, text)
    local b = new("TextButton", { AutoButtonColor = false, BackgroundColor3 = T.off, BorderSizePixel = 0, Size = UDim2.new(0.45, 0, 0, 26), Position = UDim2.new(0.55, 0, 0.5, -13),
        Font = Enum.Font.GothamMedium, TextSize = 12, TextColor3 = T.white, TextXAlignment = Enum.TextXAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd }, r)
    corner(b, 6)
    local function paint() b.Text = tostring(get()) .. "  ›" end
    b.MouseButton1Click:Connect(function()
        local cur, i = tostring(get()), 0
        for k, o in ipairs(options) do if tostring(o) == cur then i = k end end
        pcall(setv, options[i % #options + 1])
        paint()
    end)
    paint()
    UI.refreshers[#UI.refreshers + 1] = paint
end
-- number with - and +
function UI.stepper(card, text, lo, hi, get, setv, step)
    local r = row(card, text)
    local box = new("Frame", { Size = UDim2.fromOffset(104, 26), Position = UDim2.new(1, -104, 0.5, -13), BackgroundTransparency = 1 }, r)
    local v = label(box, "", 13, T.value, Enum.Font.GothamMedium, { Size = UDim2.new(1, 0, 1, 0), TextXAlignment = Enum.TextXAlignment.Center })
    local function btn(txt, x, d)
        local b = new("TextButton", { AutoButtonColor = false, Text = txt, TextSize = 15, Font = Enum.Font.GothamMedium, TextColor3 = T.text,
            BackgroundColor3 = T.off, Size = UDim2.fromOffset(26, 26), Position = UDim2.new(x, x == 0 and 0 or -26, 0, 0), BorderSizePixel = 0 }, box)
        corner(b, 6)
        b.MouseButton1Click:Connect(function() pcall(setv, math.clamp((tonumber(get()) or lo) + d, lo, hi)) v.Text = tostring(get()) end)
    end
    btn("−", 0, -(step or 1))
    btn("+", 1, (step or 1))
    v.Text = tostring(get())
    UI.refreshers[#UI.refreshers + 1] = function() v.Text = tostring(get()) end
end
-- outlined accent button, like AA "Setup ›"
function UI.button(card, text, btnText, fn)
    local r = row(card, text)
    local b = new("TextButton", { AutoButtonColor = false, Text = btnText .. "  ›", TextSize = 13, Font = Enum.Font.Gotham, TextColor3 = T.accent,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(110, 28), Position = UDim2.new(1, -110, 0.5, -14) }, r)
    corner(b, 7)
    stroke(b, T.accent)
    b.MouseButton1Click:Connect(function() task.spawn(function() pcall(fn) end) end)
end
-- label + live value
function UI.info(card, text, getText)
    local r = row(card, text)
    local v = label(r, "", 13, T.value, Enum.Font.Gotham, { Size = UDim2.new(0.6, 0, 1, 0), Position = UDim2.new(0.4, 0, 0, 0),
        TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd })
    UI.refreshers[#UI.refreshers + 1] = function() local ok, s = pcall(getText) v.Text = ok and tostring(s) or "-" end
end
function UI.note(card, text)
    card.n = card.n + 1
    label(card.frame, text, 12, T.mute, Enum.Font.Gotham, { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
        TextWrapped = true, LayoutOrder = card.n, TextYAlignment = Enum.TextYAlignment.Top })
end

-- pills: several on/off choices in one row (wraps)
function UI.pills(card, options, isOn, toggleOne)
    card.n = card.n + 1
    local holder = new("Frame", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, LayoutOrder = card.n }, card.frame)
    new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }, holder)
    new("UIGridLayout", { CellSize = UDim2.fromOffset(84, 26), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, holder)
    local paints = {}
    for i, o in ipairs(options) do
        local b = new("TextButton", { AutoButtonColor = false, Text = o, TextSize = 12, Font = Enum.Font.GothamMedium, LayoutOrder = i, BorderSizePixel = 0 }, holder)
        corner(b, 13)
        local function paint()
            local on = isOn(o)
            b.BackgroundColor3 = on and T.accent or T.off
            b.TextColor3 = on and T.onAccent or T.mute
        end
        b.MouseButton1Click:Connect(function() pcall(toggleOne, o) paint() end)
        paint()
        paints[#paints + 1] = paint
    end
    UI.refreshers[#UI.refreshers + 1] = function() for _, p in ipairs(paints) do p() end end
end
-- text box on the right of a row
function UI.input(card, text, placeholder, get, setv)
    local r = row(card, text)
    local box = new("TextBox", { Size = UDim2.new(0.5, 0, 0, 26), Position = UDim2.new(0.5, 0, 0.5, -13), BackgroundColor3 = T.off, BorderSizePixel = 0,
        Text = tostring(get() or ""), PlaceholderText = placeholder, PlaceholderColor3 = T.faint, TextColor3 = T.text, Font = Enum.Font.Gotham,
        TextSize = 12, ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left }, r)
    corner(box, 6)
    new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, box)
    box.FocusLost:Connect(function() pcall(setv, box.Text) end)
end

local function notify(msg)
    log(msg)
    pcall(function() game:GetService("StarterGui"):SetCore("SendNotification", { Title = "moseeri watch", Text = tostring(msg), Duration = 4 }) end)
end
local function cfgSet(key) return function(v) F.cfg[key] = v saveAll() end end
local function cfgGet(key) return function() return F.cfg[key] end end

--------------------------------------------------------------------------------
-- pages
--------------------------------------------------------------------------------
local function part(card, text, key) UI.toggle(card, text, function() return W[key] end, function(v) setPart(key, v) end) end
local function scanBtn(card, text, fn, name) UI.button(card, text, "Scan", function() runScan(fn, name) end) end

local recP = UI.page("Record", 1)
local rc = UI.card(recP, 1, "Record my play")
UI.toggle(rc, "Record", function() return W.on end, function(v) setWatch(v) end)
UI.input(rc, "Mark note", "floor 2 start", function() return W.note end, function(v) W.note = tostring(v or "") end)
UI.button(rc, "Mark this moment", "Mark", function() mark() end)
UI.info(rc, "Lines", function() return W.lines end)
UI.info(rc, "File", function() return W.file and (W.file:gsub("^.*/", "")) or "-" end)
UI.info(rc, "Last", function() return W.last ~= "" and W.last or "-" end)
local wh = UI.card(recP, 2, "What to record")
part(wh, "Server events", "inOn")
part(wh, "Mob attacks + my HP", "mobsOn")
part(wh, "My animations / tools", "selfOn")
part(wh, "My path", "pathOn")
part(wh, "Windows open / close", "guiOn")
part(wh, "My values (level, money)", "meOn")
part(wh, "New things near me", "newOn")
part(wh, "Prompts I use", "useOn")
part(wh, "My calls (hook) [mid risk]", "outOn")

local scanP = UI.page("Scan", 2)
local s1 = UI.card(scanP, 1, "Scan once")
UI.button(s1, "Everything (5 scans)", "Scan all", function() runScan(scanAll, "all") end)
scanBtn(s1, "Me: level, money, items", scanMe, "me")
scanBtn(s1, "Screen: windows, buttons", scanScreen, "screen")
scanBtn(s1, "Around me: this room", scanAround, "around")
scanBtn(s1, "Map: NPCs, prompts, doors", scanMap, "map")
scanBtn(s1, "Game: remotes, data tree", scanGame, "game")
UI.info(s1, "Status", function() return W.scanStatus end)
local s2 = UI.card(scanP, 2, "Deep")
UI.button(s2, "Game scripts [mid risk]", "Dump", function() runScan(dumpScripts, "scripts") end)
UI.note(s2, "Decompiles the game's client scripts to files. Slow. Use the new account first.")
local s3 = UI.card(scanP, 2, "Checks")
UI.button(s3, "Can I control mobs?", "Test", function() W.checkResult = checkOwnership() end)
UI.button(s3, "Executor functions", "Test", function() W.checkResult = checkExecutor() end)
UI.info(s3, "Result", function() return W.checkResult end)

-- Remotes (live): list on the left, code of the picked one on the right
local remP = UI.page("Remotes", 3)
local rl = UI.card(remP, 1, "Calls my client sends")
part(rl, "Catch calls (hook) [mid risk]", "outOn")
UI.info(rl, "Seen", function() return #R.list .. " remotes, " .. R.total .. " calls" end)
rl.n = rl.n + 1
local listFrame = new("ScrollingFrame", { Size = UDim2.new(1, 0, 0, 250), BackgroundColor3 = T.bg, BorderSizePixel = 0, LayoutOrder = rl.n,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y }, rl.frame)
corner(listFrame, 6)
new("UIListLayout", { Padding = UDim.new(0, 2), SortOrder = Enum.SortOrder.LayoutOrder }, listFrame)

local rv = UI.card(remP, 2, "Code")
rv.n = rv.n + 1
local codeScroll = new("ScrollingFrame", { Size = UDim2.new(1, 0, 0, 210), BackgroundColor3 = T.bg, BorderSizePixel = 0, LayoutOrder = rv.n,
    ScrollBarThickness = 4, CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.XY, ScrollingDirection = Enum.ScrollingDirection.XY }, rv.frame)
corner(codeScroll, 6)
local codeBox = new("TextBox", { Size = UDim2.new(1, -12, 0, 0), Position = UDim2.fromOffset(6, 4), AutomaticSize = Enum.AutomaticSize.XY, BackgroundTransparency = 1,
    Text = "-- turn on Catch calls, then tap a remote in the list", TextColor3 = T.value, Font = Enum.Font.Code, TextSize = 12, ClearTextOnFocus = false,
    TextEditable = false, MultiLine = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top }, codeScroll)
local liveMsg = "-"
UI.info(rv, "Result", function() return liveMsg end)
rv.n = rv.n + 1
local btnRow = new("Frame", { Size = UDim2.new(1, 0, 0, 34), BackgroundTransparency = 1, LayoutOrder = rv.n }, rv.frame)
new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Center }, btnRow)
local function liveBtn(text, color, fn)
    local b = new("TextButton", { AutoButtonColor = false, Text = text, TextSize = 12, Font = Enum.Font.GothamMedium, TextColor3 = color,
        BackgroundTransparency = 1, Size = UDim2.fromOffset(72, 26) }, btnRow)
    corner(b, 6)
    stroke(b, color)
    b.MouseButton1Click:Connect(function() task.spawn(function() pcall(fn, b) end) end)
    return b
end
local function showSelected()
    local e = R.selected
    if not e then codeBox.Text = "-- pick a remote in the list" return end
    local ok, code = pcall(entryCode, e)
    codeBox.Text = ok and code or ("-- could not build code: " .. tostring(code))
end
liveBtn("Copy", T.accent, function() liveMsg = liveCopy() end)
liveBtn("Ignore", T.mute, function() liveIgnore() showSelected() liveMsg = "ignored (saved)" end)
liveBtn("Clear", T.mute, function() liveClear() showSelected() liveMsg = "cleared" end)
-- Run sends to the game: first tap arms it, second tap within 3 s sends
local runArmed = 0
liveBtn("Run", T.bad, function(b)
    if os.clock() - runArmed > 3 then
        runArmed = os.clock()
        b.Text = "Sure?"
        liveMsg = "Run SENDS this call to the game. Tap again to send."
        task.delay(3, function() b.Text = "Run" end)
        return
    end
    runArmed = 0
    b.Text = "Run"
    liveMsg = liveRun()
end)
UI.note(rv, "Run is the only button here that sends to the game. Test account only.")

local rowPool = {}
local function drawList()
    if not R.dirty then return end
    R.dirty = false
    for i, e in ipairs(R.list) do
        local b = rowPool[i]
        if not b then
            b = new("TextButton", { AutoButtonColor = false, Size = UDim2.new(1, -6, 0, 24), BackgroundColor3 = T.card, BorderSizePixel = 0, LayoutOrder = i,
                Font = Enum.Font.Gotham, TextSize = 12, TextColor3 = T.text, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd }, listFrame)
            new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
            b.MouseButton1Click:Connect(function()
                R.selected = R.list[i]
                R.dirty = true
                showSelected()
            end)
            rowPool[i] = b
        end
        b.Visible = true
        b.Text = string.format("%s  x%d  %s", e.name, e.count, e.method == "InvokeServer" and "(invoke)" or "")
        b.BackgroundColor3 = (R.selected == e) and T.off or T.card
        b.TextColor3 = (R.selected == e) and T.white or T.text
    end
    for i = #R.list + 1, #rowPool do rowPool[i].Visible = false end
end
UI.refreshers[#UI.refreshers + 1] = drawList

local setP = UI.page("Settings", 4)
local se = UI.card(setP, 1, "Settings")
UI.toggle(se, "Auto scan new maps", function() return F.cfg.autoScan end, function(v) F.cfg.autoScan = v saveAll() end)
UI.button(se, "Forget ignored remotes", "Reset", function() F.cfg.watchIgnore = {} saveAll() end)
UI.input(se, "Skip names", "ping, mouse", function() return F.cfg.watchSkip end, function(v) F.cfg.watchSkip = tostring(v or "") saveAll() end)
UI.info(se, "Resume after teleport", function() return F.cfg.watchResume and "yes" or "no" end)
UI.info(se, "Version", function() return VERSION end)
UI.note(se, "Files: Workspace/mwatch/<game>/<map>/ - index.txt and known.txt per game.")

-- window button + floating Mark button (works while the window is hidden)
local tb = new("TextButton", { Name = "Toggle", Size = UDim2.fromOffset(52, 30), Position = UDim2.new(1, -200, 0, 120),
    BackgroundColor3 = T.headBg, BackgroundTransparency = 0.1, TextColor3 = T.accent, Font = Enum.Font.GothamBold, TextSize = 14, Text = "MW" }, gui)
corner(tb, 8)
stroke(tb, T.accent)
local mk = new("TextButton", { Name = "Mark", Size = UDim2.fromOffset(52, 30), Position = UDim2.new(1, -200, 0, 156), Visible = false,
    BackgroundColor3 = T.headBg, BackgroundTransparency = 0.1, TextColor3 = T.good, Font = Enum.Font.GothamBold, TextSize = 13, Text = "MARK" }, gui)
corner(mk, 8)
stroke(mk, T.good)
mk.MouseButton1Click:Connect(function() pcall(mark) mk.Text = "#" .. W.marks end)
local function setShown(v) win.Visible = v end
tb.MouseButton1Click:Connect(function() setShown(not win.Visible) end)
dots.MouseButton1Click:Connect(function() setShown(false) end)

gui.Parent = guiParent
UI.show("Record")

task.spawn(function()
    while F.alive do
        mk.Visible = W.on
        if win.Visible then
            for _, f in ipairs(UI.refreshers) do pcall(f) end
        end
        task.wait(1)
    end
end)

G.__mwatch_stop = function()
    F.alive = false
    for _, c in ipairs(F.conns) do pcall(function() c:Disconnect() end) end
    pcall(function() gui:Destroy() end)
end
G.__mwatch = F

ensureFolder()
-- keep recording across the game's own teleports (raids move you to another server): autoexecute reloads this file
if F.cfg.watchResume then pcall(setWatch, true, "watch resumed after reload") end
notify("Watch ready. MW button shows / hides the window.")
task.spawn(function() pcall(autoScan) end)
