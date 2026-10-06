--[[
    Zomboid Fixes B42.20 -- server, notebook locks in multiplayer

    Puts the lock a player set on a notebook (ISUIWriteJournal's padlock button) on
    the server's copy, which SyncItemFieldsPacket never carries. See
    client/ZomboidFixesB42_Notebook.lua.

    The same rules as the window (ISUIWriteJournal:new ~321): only the player who
    locked it can change the lock, or someone allowed to edit any item (Capability
    EditItem, the item editor's own; vanilla's window lets isAdmin() through). A lock
    is the writer's username, or for an item tagged LOCK_ON_WRITE the random number
    the window sets so that nobody can unlock it again. Only a notebook in the
    sender's own inventory, by item ID.
--]]

if isClient() then return end

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NotebookSync == true
end

local function onNotebookLock(player, args)
    if not player or not isEnabled() then return end

    local id = tonumber(args.id)
    if not id then return end
    local notebook = ZomboidFixesB42.findItemById(player:getInventory(), id)
    if not notebook or not instanceof(notebook, "Literature") then return end

    local wanted = args.lockedBy
    if wanted == "" or type(wanted) ~= "string" then wanted = nil end
    local current = notebook:getLockedBy()
    if wanted == current then return end

    local username = player:getUsername()
    local role = player:getRole()
    local canEditAny = role ~= nil and role:hasCapability(Capability.EditItem)
    if current ~= nil and current ~= username and not canEditAny then
        print("[ZomboidFixesB42] " .. tostring(username) .. " tried to change the lock on a notebook locked by someone else")
        return
    end

    if wanted ~= nil and wanted ~= username then
        local randomLock = notebook:hasTag(ItemTag.LOCK_ON_WRITE) and string.match(wanted, "^%d+$") ~= nil
        if not randomLock then return end
    end

    notebook:setLockedBy(wanted)
end

local function onClientCommand(module, command, player, args)
    if module ~= ZomboidFixesB42.MODULE then return end
    if command ~= ZomboidFixesB42.CMD_NOTEBOOK_LOCK then return end
    onNotebookLock(player, args or {})
end

Events.OnClientCommand.Add(onClientCommand)
