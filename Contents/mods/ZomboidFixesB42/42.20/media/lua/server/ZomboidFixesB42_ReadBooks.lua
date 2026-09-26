--[[
    Zomboid Fixes B42.20 -- server, finished books stay read

    Whether a book with pages (a skill book) counts as read is the character's own
    record per book type, character:getAlreadyReadPages(fullType): the inventory's
    read tick (ISInventoryPane:isLiteratureRead) and the Literature window
    (ISLiteratureUI) both want it to equal getNumberOfPages().

    In multiplayer the server's copy of that record is the one kept: ServerPlayerDB
    saves the server's IsoPlayer (player.save), and a player who joins is loaded from
    it. The server only writes the record from ISReadABook:animEvent("ReadAPage"),
    the emulated page turns, and only when self.startPage is set:

        if self.item:getNumberOfPages() > 0 and self.startPage then
            ... self.character:setAlreadyReadPages(fullType, pagesRead)

    ISReadABook:complete sets the item to fully read and syncs it
    (syncItemFields; SyncItemFieldsPacket.processClient also sets the client's
    record), but never the server's record. So:

      * with the instant timed action cheat, getDuration returns 1 before it sets
        startPage, no page turn writes anything, and the book is read on screen but
        unread on the server -- and after the next login;
      * reading normally, the last page turn often fires just before the action ends,
        floor(pages x progress) < pages, and the book is kept a page short.

    So once complete has run (and not refused the book: forceStopped), the server's
    record is raised to the item's, which complete has just set to every page. It is
    only ever raised, never lowered.
--]]

if isClient() then return end

require "TimedActions/ISReadABook"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.BooksStayRead == true
end

local vanillaComplete = ISReadABook.complete

function ISReadABook:complete()
    local result = vanillaComplete(self)
    local item = self.item
    if isEnabled() and not self.forceStopped and item and item:getNumberOfPages() > 0 then
        local pages = item:getAlreadyReadPages()
        if pages > self.character:getAlreadyReadPages(item:getFullType()) then
            self.character:setAlreadyReadPages(item:getFullType(), pages)
        end
    end
    return result
end
