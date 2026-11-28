# TODO

Open work only. Done items are in git history, and everything learned while doing them is in CLAUDE.md.
For a new fix: check the bug is still there in the installed build (42.22.2; patch notes:
theindiestone.com/forums/topic/102705), then follow the mod conventions in CLAUDE.md (a sandbox option
per fix, default on, README / forum.txt / mod.info lines, Sandbox.json tooltip, `[BETA]` until played in
game).

## Open

- [ ] Made redundant by 42.22 (reviewed 2026-11-10, see CLAUDE.md "42.22 changes that touch this mod"), still in
      the mod and harmless meanwhile: MapSymbolsSave (vanilla now syncs map markings; turn the file into a one-time
      restore of markings saved in modData before 42.22, then drop it), the Fast Timed Actions half of FastTransfers
      (keep the fast forward transfers, drop the option), the two remembered tick boxes of UserPanelDisplay (keep
      Show game version / Show coordinates), and the paper map half of PrintMediaSync (the `onCheckMap` wrapper).
- [ ] 42.22 pen catch-up gap: an animal the worker puts back after its zone's `doMeta` stays frozen (`fromMeta`)
      until the next away and return (~7% of returns in the lupa port). BabyAnimalCatchUp rescues babies only;
      a general fix would make up any animal with no zone that turns up in a zone already made up.
- [ ] Deferred: security hardening of unchecked vanilla client commands. Full list in CLAUDE.md ("Vanilla
      client-command handlers with no permission check"). Most serious: `player.onHealthCheatCurrentPlayer`
      lets any client bite / infect any player; `object.clearContainerExplore` re-rolls any container's loot;
      vehicle `fixPart` / `setContainerContentAmount`; farming, campfire, tent and trap commands from anywhere.
      Idea not yet tried: shared Lua loads before server Lua, so a shared file can wrap
      `Events.OnClientCommand.Add` and catch vanilla's handlers as they register, then gate them.

### Confirmed in 42.21, not fixed yet (found 2026-10-13)

- [ ] An animal corpse hides other corpses in the loot window: `ISInventoryPage:refreshBackpacks` (~1721) `break`s
      the static-object loop at the first animal corpse, so a human corpse after it on that square gets no button.
      Fix: add the missing corpse buttons from `OnRefreshInventoryWindowContainers` ("beforeFloor"). Small.
- [ ] The crafting window resets recipe groups the player opened or closed on every refresh: Java
      `filterRecipeList` → `CraftRecipeListNodeCollection.setInitialExpandedStates` (~54) re-creates the nodes and sets
      each group open if something in it can be crafted. Fix: remember toggles per group (the list's `onMouseDown`
      ~428 / joypad ~486 call `setExpandedState` / `toggleExpandedState`) and reapply after `onUpdateRecipeList`.
- [ ] Duplicate lines in "Add ingredient" menus (soups, stews, salads): `doEvorecipeMenu` (~4276) only dedupes
      against the last use recorded for a type, and spices (Food `isSpice` and non-Food spice items) not at all, so
      30 salt packets give 30 "Salt (Spice)" lines. Fix: wrap `addItemInEvoRecipe` (~2028) during `doEvorecipeMenu`
      and skip a line whose text and greyed state are already in that submenu. Also shortens slow menus.
- [ ] Vehicle Blood debug window, "all vehicles": `ISVehicleBloodUI` (~77) calls `:get()` on `getCell():getVehicles()`,
      a Set in 42.21. Copy to an ArrayList first. Tiny.
- [ ] Debug "Add vehicle" spawns a random vehicle in MP (`addVehicle` ignores its arguments on a client): send
      `/addvehicle Script x,y,z`. Debug entries that only act on the admin's own game in MP: Set Alarm, Randomized
      Building, Spawn Survivor Horde, vehicle Jump / Landmine. Each would also get an admin hotbar entry.
- [ ] The vanilla Player Stats window shows made-up values for other players: fill it from the Body Stats
      editor's server snapshot.

### To check before fixing

- [ ] A queue of right-click Grabs may cancel itself: `ISGrabItemAction:isValid` turns false once the world item
      leaves the square, so a server move landing first stops the grab and the queue behind it. Test on a server.
- [ ] Mod key binds drop Shift/Ctrl/Alt (`PZAPI.ModOptions`): the options screen records and shows them, but only
      the bare key is saved. Keep them, or stop the screen recording them.
- [ ] A stale copy of a mod in `~/Zomboid/Workshop` hides the Steam update (also when joining a server): warn at
      the main menu. Not checked: whether Lua can tell which folder a mod loaded from.
- [ ] Sidebar hover tooltips are off by 10 px and show for hidden buttons (`ISEquippedItem:checkToolTip`); a layout
      fix with no option. TienCustomizableLeftSidebar may already cover it.
- [ ] Tien's Coolers cooler out of a player's hands (car trunk, floor, furniture) shows stale contents, and moving
      eggs in or out with Fast Timed Actions on leaves the progress bar hanging while the eggs still move (reported
      2026-10-19; a cooler the player carries is fine). Not explained yet: the floor and furniture sends reach the
      client in Java (BagContentsSync covers bags in cars and furniture; the floor needs nothing). A visible bar means the move went the vanilla way
      (the fast path has none), and "hangs but the eggs arrive" fits a vanilla batch whose later entry fails on
      the server (`Transaction.update` → Reject, nothing sent, earlier eggs stay moved): the server's cooler lacks
      an egg the client shows, or `updateItem` throws. Server ReworkedIce was off. Get first: the server log around
      the move (`transaction.update() threw`, `Transaction failed`, `Inconsistent`, `Quick transfer declined`,
      `[ZomboidFixesB42]`); the same move with a plain backpack (engine / this mod vs Tien's Coolers); the same
      move with Fast Timed Actions off.

### Ideas (own mod, or a big feature)

- [ ] Auto craft: when a recipe's ingredient is missing but can itself be crafted from what the player has, craft
      the ingredients first, then the recipe. Started researching on 2026-10-13, stopped before any findings. To
      settle first: whether a queued `ISHandcraftAction` captures its input items at queue time (if so, each later
      step must be planned when the queue reaches it, e.g. a client-only 1-tick action that builds a fresh
      `HandcraftLogic` from the current inventory and inserts the real craft after itself, waiting in MP for the
      previous craft's results to arrive); a reverse index item → recipes that output it (tags, output mappers,
      amounts, fluids); loops to avoid (pack / unpack, split / combine, dismantle); surfaces, benches, skills.
      Choices for the user: own mod or Zomboid Fixes, chain depth, confirm the plan first, use nearby containers,
      with or without a reworked crafting window. No existing B42 mod found that does it.
- [ ] Rework the crafting window: test recipes one at a time (visible ones first, the rest time-sliced with
      `Jobs`) instead of `HandcraftLogic.rebuildCachedRecipeInfo` over every recipe at once, keep group states,
      and run crafts through the vanilla action. Big; other mods' hooks into the vanilla window would not see it.

## Decided against, or not fixable from Lua

So they are not investigated again (details in CLAUDE.md):

- Houses that cannot be claimed as safehouses ("non-residential"; forum 96629, 100611): Java room-name whitelist
  in `SafeHouse.canBeSafehouse`, re-run by the server. Author's call; workaround `SafehouseAllowNonResidential`.
- Floor pickups straight into a bag still stop at its max item size (Java `TransactionManager.isConsistent`
  sums pending transactions); RemoveMaxItemSize lifts it.
- Barricade preview drawing a second plank on top of the first (visual only).
- Colour picker `mouseUp` typo: no callback reads it.
- FirearmRadialNoBlanks keeps no blanks for joypads either (blanks only make the menu more confusing).
- Engine food weight (very filling food weighs a lot per portion, forum 100315) and vegetable oil / ranch sauce /
  flour hunger turning positive (99705, evolved recipe code; the negative-weight leftovers are deleted).
- `AimingMod` / `IsAimedHandWeapon` do nothing in 42.21; JS-3T recoil pad / choke tubes need model attachments.
- Cooler_Seafood holes (`CanHaveHoles` is clothing only); crafted face shemaghs (maybe deliberate).
- TransferResync answering for any container within 8 tiles: not a leak (chunk data already carries contents).
- A ghost floor item the client lost to a wrong-index removal, and one player's cancelled transfer dropping
  another's with the same id: Java (see TransferResync in CLAUDE.md).
