--[[
    Zomboid Fixes B42.20 -- client, no empty slices in the firearm radial menu

    Holding the reload key (or the right bumper) opens the firearm radial menu
    (client/ISUI/ISFirearmRadialMenu.lua). Its fillMenu (:246-273) asks a fixed list of
    commands for a slice each: for a gun that takes magazines Insert or Eject Magazine,
    Load Bullets into Magazine and Rack; for the others Load Rounds, Unload Rounds and
    Rack. A command that has nothing to offer right now adds no slice, and fillMenu then
    adds an empty one in its place (menu:addSlice(nil, nil, nil), :270) so every command
    keeps the same spot around the ring.

    So the menu often shows a slice with no icon and no text that does nothing when
    clicked. The usual one is Load Bullets into Magazine: CLoadBulletsInMagazine
    (:102-112) only fills it while the player carries a magazine that is not full, of the
    gun's one getMagazineType(), and rounds of that magazine's one getAmmoType() -- so
    with every magazine full, no loose rounds, or a mod's magazine or round the check does
    not know (Gunworks magazine profiles and ammo families), the spot is blank. Insert Magazine
    is blank with no usable magazine (getBestMagazine nil), Rack while
    ISReloadWeaponAction.canRack is false.

    This removes those placeholders just before the menu is shown (ISFirearmRadialMenu:
    display, which every vanilla caller runs right after fillMenu), so slices other mods
    add after vanilla's fillMenu (Tien's Magazine Bag wraps it at OnGameStart) are already
    there and are kept. A placeholder is a slice with no text, no texture and no command;
    the other slices are put back in their order with their commands and arguments. When
    every slice is a placeholder, the menu is left as vanilla built it, so the ring still
    opens and shows there is nothing to do. The Java RadialMenu sizes its slices from
    their count at every render, so fewer slices just makes each one wider.
--]]

require "ISUI/ISFirearmRadialMenu"

local function isEnabled()
    local vars = SandboxVars and SandboxVars.ZomboidFixesB42
    return vars ~= nil and vars.FirearmRadialNoBlanks == true
end

local function isPlaceholder(slice)
    return slice.text == nil and slice.texture == nil and (slice.command == nil or slice.command[1] == nil)
end

local function removePlaceholders(menu)
    if not menu or not menu.slices then return end
    local kept = {}
    for _, slice in ipairs(menu.slices) do
        if not isPlaceholder(slice) then table.insert(kept, slice) end
    end
    if #kept == #menu.slices or #kept == 0 then return end
    menu:clear()
    for _, slice in ipairs(kept) do
        local c = slice.command or {}
        menu:addSlice(slice.text, slice.texture, c[1], c[2], c[3], c[4], c[5], c[6], c[7])
    end
end

local previousDisplay = ISFirearmRadialMenu.display

function ISFirearmRadialMenu:display()
    if isEnabled() then
        removePlaceholders(getPlayerRadialMenu(self.playerNum))
    end
    return previousDisplay(self)
end
