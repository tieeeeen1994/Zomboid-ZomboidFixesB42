--[[
    Zomboid Fixes B42.20 -- client, notebooks and notes in multiplayer

    Writing in a notebook is ISWriteSomething (shared/TimedActions, 42.21): an action
    with no end of its own (getDuration -1) that opens ISUIWriteJournal. Its OK and
    Cancel buttons call ISInventoryPaneContextMenu.onWriteSomethingClick (~2708),
    which copies the pages and the title into the client's notebook and then

        ISTimedActionQueue.clear(getPlayer())

    which stops the action, and ISWriteSomething:stop sends the notebook with
    syncItemFields. SyncItemFieldsPacket carries the custom name and the pages, so
    in 42.21 the text itself reaches the server, with two gaps:

      * getPlayer() is player 1. For a split-screen player the action is not
        stopped, so nothing is sent until their queue is cleared some other way.
        And on a server an action with no end is given 30 minutes
        (AnimEventEmulator.getDurationMax); a window left open longer ends the
        action without a sync, and the OK pressed after that sends nothing.
      * The lock (ISUIWriteJournal's padlock button, Literature.lockedBy, and the
        random lock of LOCK_ON_WRITE items written once) is set on the client's
        copy only: SyncItemFieldsPacket has no lockedBy. The server's copy, which
        it saves and hands to anyone the notebook is passed to, stays unlocked, so
        the lock is gone after a relog or for the next owner.

    So after vanilla's handler the notebook is sent at once with syncItemFields, the
    queue cleared is the writer's own, and the lock state goes to the server
    (server/ZomboidFixesB42_Notebook.lua), which checks who may change it.
--]]

if not isClient() then return end

require "ISUI/ISInventoryPaneContextMenu"

ZomboidFixesB42 = ZomboidFixesB42 or {}

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.NotebookSync == true
end

local vanillaOnWriteSomethingClick = ISInventoryPaneContextMenu.onWriteSomethingClick

function ISInventoryPaneContextMenu:onWriteSomethingClick(button, ...)
    local journal = button and button.parent
    local notebook = journal and journal.notebook
    local character = journal and journal.character
    if not isClient() or not isEnabled() or not notebook or not character then
        return vanillaOnWriteSomethingClick(self, button, ...)
    end

    -- Vanilla's body, with the writer's queue instead of player 1's.
    if button.internal == "OK" then
        for i, v in ipairs(journal.newPage) do
            notebook:addPage(i, v)
        end
        notebook:setName(journal.title:getText())
        notebook:setCustomName(true)
    end

    syncItemFields(character, notebook)
    local lockedBy = notebook:getLockedBy()
    sendClientCommand(character, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_NOTEBOOK_LOCK, {
        id = notebook:getID(),
        lockedBy = lockedBy,
    })

    ISTimedActionQueue.clear(character)
end
