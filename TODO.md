# TODO

Open work only. Done items are in git history, and everything learned while doing them is in CLAUDE.md.
For a new fix: check the bug is still there in the installed build (42.21.0; patch notes:
theindiestone.com/forums/topic/101693), then follow the mod conventions in CLAUDE.md (a sandbox option
per fix, default on, README / forum.txt / mod.info lines, Sandbox.json tooltip, `[BETA]` until played in
game, and a test scenario in the Beta section below).

## Open

- [ ] Play every `[BETA]` feature in game and drop its label (what each needs is in the next section).
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

## Beta features: what playing each one should check

- [ ] GunworksGripSync (2026-10-26), with Guns of Tien (and Post-93) on a server, two clients: player B holds an Uzi,
      an MP5K or an MP7 (or Heavy Ordnance's RPG); A sees the custom pose. B walks out of A's range (over 5 s) and
      back, then relogs, then dies and respawns holding one: A sees the custom pose again within a fraction of a
      second each time (with the option off it stays vanilla until B changes weapons). B swaps guns and puts the gun
      away: the pose follows at once. Single player and split screen: a second player picking up the same gun as the
      first gets its pose. No errors without Gunworks loaded.

- [ ] GoMTooltipLineLength, Information lines (2026-10-19): with Guns of Tien, hover a Double Barrel (its sawn-off stock
      line), an M60 (its bipod line) and a 7.62x39 US round: every Information line wraps to the width of the item's own
      rows (a round's at least 40 digits wide), carried-over lines indented, nothing cut off; a scope's gun list still
      wraps; a gun with a magazine in still shows the corrected magazine line; a crafting window slot holding such an
      item shows one Information block, wrapped; option 0 gives Guns of Marz's own unwrapped tooltips back.
- [ ] TooltipStacking, with Dynamic Backpack Upgrades loaded before Plysken Attachments Reborn: hover a bag with
      attachment slots and an upgrade slot line; the attachment slot box sits under the upgrade lines, nothing
      overlaps, on the first frame after moving between items too; tick it off and the overlap is back.
- [ ] BodyStatsEditor extras: the hotbar's body part toggles (each condition on another player, flip), the Health
      button next to Body in Player Stats (opens the window without asking; player must be loaded on the admin's
      client), and the health window's Full Health, Keep Treatment for a part and for the body (bandage,
      poultices, splint and stitches stay) Right-click a body part in that window: the Cheat
      menu opens (it did not before the fix) and its Full Health / Keep Treatment entries work.
- [ ] AnimalGenderChange: all four branches (world, hutch, trailer, carried animal).
- [ ] RepairLostEntities: a killed server and a restored backup with rain collectors, drying racks and a bucket on
      the floor; chunk re-saves while a backup runs.
- [ ] One session each on a server: TransferResync, ReloadAnimTiming, WaterPlantOnce, RemoveBushToolWear,
      RemoveBushWholeSquare, VehicleBatteryDrain, GasTankWelding, GeneratorRefuelTime, WaterDispenserCheck,
      InstantBuildHandy, MapAdminCapabilities, RememberSeenRooms, BooksStayRead, NoStairAutoVault, GrabAmount,
      FirearmRadialNoBlanks, GoMMagazineTooltip, ReturnKeepsQueue (eat all, then a queued eat still runs),
      CraftClickQueue (several Craft clicks all craft), NoFastMoveFallDamage, ChopperControls, AdminFullBright,
      AdminSpawnProtection, and the admin debug fixes (FixDebugAddFluid, ForagingDebugFixes, NoWalkOnSquarePick,
      ServerOptionsTooltip).
- [ ] AdminFullBright persistence, on a server: turn Full Bright on (Always Day off), relog: Full Bright is on
      again and Always Day off; the bottom right cheat list says Full Bright, not Always Day (both with Always
      Day ticked too); turning Full Bright off leaves Always Day as it was. Same from the admin hotbar toggle,
      and in single player with -debug.
- [ ] BagContentsSync, on a server with Fast Timed Actions on and a second player watching: put eggs into and take
      them out of a cooler (and a backpack) in a car's trunk: no 10 s wait, both screens show the right contents at
      once; with Tien's Coolers, a spent bag of ice in a trunk cooler disappears for the watcher; a bag inside a
      bag in the trunk updates too (re-sent whole); with a container mod, a cooler on a shelf or in a crate updates
      the same way; option off: back to vanilla. No Lua errors in the server log.
- [ ] AdminGodVehicle, on a server with a second player watching: turn God Vehicle on, get in a car as a passenger
      while someone else drives; crash it into a wall and run down zombies (no part loses condition, nobody in it
      is hurt), idle with the headlights and radio on and the engine off (battery stays), drive a while (fuel,
      tires, brakes, suspension stay), let zombies thump a door and a window (no dent on either client, no broken
      glass), smash a window from outside (it stays), start the engine a few times (battery stays). Refuel and
      repair a part from outside while the admin sits in it (both go up and stay); a mechanic takes a tire off
      (it comes off). Get out: everything wears again. Relog: the option is still ticked. Same from the admin
      hotbar toggle, and in single player with -debug (crashes hurt the occupants there, parts still hold).
- [ ] AdminNoWear, on a server with a second player watching: carry a damaged, dull axe, a broken bat in a bag and
      a holed jacket; turn No Wear on: all full within a second, the jacket's holes gone for both players. Fight
      zombies with a low-condition weapon until it would break (never drops), chop a tree, craft with a tool, let
      zombies hit the clothing with the clothing wear rework on and off (no holes stay, no condition lost, nothing
      falls off). Set No Wear Items to Held, Worn And Attached: the bag's bat is no longer repaired. Relog: still
      on. Turn it off: wear works again. A moderator without Edit Item cannot turn it on. Single player with
      -debug. God Vehicle again after the shared power code moved (state survives a relog).
- [ ] AdminEndlessSupplies, on a server: carry a half-used battery, lighter and thread in a bag, a propane torch in
      hand; turn it on: all full within a second. Weld or craft until the torch would run out (it never does),
      sew, start fires; a depleted lighter kept at 0 fills again. Turn it off: charges drain again. Relog: still on.
      A moderator without Add Item cannot turn it on. Single player with -debug. Admin Powers now has 28 powers:
      14 and 14.
- [ ] RerollContainerFix, on a server with a second player at the same container: as admin, right-click a looted
      kitchen counter's button, Refill Container: new items appear for both players (vanilla often left it
      empty), the admin log has the line. The Reroll button after Take All does the same. Also an empty container,
      one outdoors (trash bin, mailbox), a shelf that shows its items, a fridge. No button on a corpse, a floor
      bag, a vehicle trunk; none for a moderator until they turn the LootZed power on, then it works. Single player
      with -debug and LootZed on: the button refreshes the window at once. Admin hotbar Reroll containers: pick a
      kitchen square (every counter, fridge and shelf there rerolled), keep-picking several squares, a square with
      no container says so; also Full Bright, God Vehicle, No Wear and Endless Supplies toggles on the hotbar.
- [ ] HutchRemoveEggCheat, on a server with the Animal Cheat on: right-click a nest box with eggs in the hutch
      window, Remove Egg; the egg shows in the inventory at once (not only after relog) and the nest box count
      drops for everyone; Remove Egg on a box another player just emptied logs no error.
- [ ] HutchGrabAllEggs: on a server with Timed Action Instant on, Grab Eggs on a nest box with 5-10 eggs takes
      every egg (vanilla took about a fifth); without the cheat it still takes them one by one and ends when the
      box is empty; walking away half way keeps only the eggs taken so far. Single player: Grab Eggs at fast
      forward takes them all.
- [ ] MakeUpSync, on a server with ClothingWearRework on: apply lipstick, it stays on after a few seconds and
      for other players; previewing in the make-up window keeps the preview on; apply a second lipstick over it;
      remove it with the window's Remove; relog: the make-up is still gone and nothing reappears. No
      "Dupe item ID" in the client log when applying.
- [ ] MedicalCheckNoReset, on a server: make a second player hungry, thirsty or stressed; medical-check them,
      and with the window still open check them again (and press the admin Health button twice): their moodles
      stay and the window keeps updating. Walking out of reach and back still refreshes the window.
- [ ] NotebookSync, on a server: write in a notebook and press OK, relog: the text is there; lock it, relog
      and hand it to another player: it is still locked and they cannot edit it; unlock it again as the
      writer. A write-once note (LOCK_ON_WRITE) stays locked for good. A second split-screen player's text is
      saved at OK.
- [ ] PadlockFixes, on a server: put a padlock on a door or gate, take it off with the key on a key ring: the
      key leaves the ring (no copy left on it), and Put Padlock is offered again at once for the padlock taken
      off (vanilla needed a relog); put it back on and the new key works.
- [ ] UITextFixes: a faction invitation names the faction (not "null faction"); the admin Manage Inventory
      window's title is centred; right-clicking a crop with a trowel or shovel in the inventory shows no
      greyed "Not enough soil to plant here." (single player too), while an indoor or upstairs floor still does.
- [ ] StuckActionTimeout, on a server: normal crafts, eating, reading and washing a pile of clothes (whose server
      time is longer than the bar) still finish and are never stopped; a stuck action (reproduce with
      EntityNetIDRefresh off: build a kiln, put and pick up an object on its tile, craft there) is stopped with
      "The server never finished that action" after about 15 s plus its own length, and the player can act again.
- [ ] EntityNetIDRefresh: the same kiln set-up with the option on crafts normally; no
      `NullPointerException ... loadComponent` in the server log; no server lag with many players.
- [ ] KeepContainerContents: a forged gold key ring holding keys is not offered (or greyed) in Scrap Smaller Gold
      Object, and is once emptied; a full sandbag in Scrap Sack and a hollow book with something inside in Make
      Hollow Book likewise; empty ones and the normal scrap items still work.
- [ ] BarricadeFixes, single player and server: the build panel lists 2 nails for a plank barricade and it
      takes 2; the barricade keeps its name in the build panel; with 1 plank, barricade one window, then the
      cursor is red on the next; clicking several windows quickly with one plank leaves the extra actions
      stopped (no full-length action building nothing); metal barricades unchanged.
- [ ] MechanicsXPLimit: uninstall and reinstall a part (XP), again (no XP), save and reload (or restart the server,
      or walk far away and back), again: still no XP until 24 game hours have passed; new vehicles still get XP.
- [ ] CraftResultSync, on a server: fillet a big and a small fish: the fillets show different calories and weights
      at once, without dropping them; a jar of food keeps its lid condition; batch crafts still work, no lag.
- [ ] MaxItemSizePerItem: drag 10 full M1911 magazines onto ALICE webbing with room: all go in at once; an item
      heavier than 1.3 is refused (red) while the rest go in; the transfer same type button fills the webbing.
- [ ] RemoveMaxItemSize (off by default): turned on, a heavy item goes into a wallet or toolbox up to capacity,
      also picked up from the floor and on a server; the tooltip has no max item size row; off again restores it.
- [ ] MapSymbolsSave, on a server: draw symbols and a note on a paper map, close it, relog: still there; drop it,
      walk far away and back, pick it up: still there; give it to another player: they see them; erase all,
      relog: gone; stash maps' printed annotations are not doubled.
- [ ] PrintMediaSync, on a server: read a brochure: its icon is on the world map's print media layer at once,
      locations revealed only with the auto-reveal option on; open a paper map, relog: still counted as read.
- [ ] ZombieCarDamageSync, on a server with a second player watching: sit in a car with the doors shut and the
      windows already smashed (or a car with no glass on that side), let zombies bang on it: the door and body
      panel conditions drop on both screens (mechanics window) and stay after relogging; windows still break as
      before; with God Vehicle on nothing drops; the server log has no Lua errors from zombieCarDamage.
- [ ] WashingTimeFix, single player and a server: wash a dirty shirt at a sink while very unhappy (or drunk):
      the bar takes about base time x the moodle factor once (unhappy level 4 = x2, not x4); with no moodles the
      time is unchanged; on a server the bar ends without sitting at 100%; with fast forward on a server washing
      still speeds up once (not speed squared).
- [ ] InventoryPerformance, single player and a server, with 1000 nails, 1000 rounds and 300 apples in the inventory
      and a crate of 1000 items next to you: walking, turning and opening doors with both windows open no longer
      stutters; a transfer of the 1000 nails into the crate finishes without the game hitching on each batch and both
      windows show the right counts at the end; the apple stack still splits into stale ones when they go stale;
      right-click on each stack: same options as with the option off, no freeze; Consolidate with many half-used
      drainables (thread, glue) opens quickly and its submenu is wide enough for every line; Place Item (3D) still
      offered (greyed with a favourite in the stack); dragging a stack still works.
- [ ] CraftingPerformance, with the same crate: open the crafting window, move items in and out (and have a
      second player drop items nearby on a server): the list refreshes within a second, without stutter in between;
      craft a batch of 10: the window refreshes once at the end and the craft count is right; cancel a batch half
      way: the window refreshes; pin it and walk: no stutter, the list follows; the build window the same.

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
