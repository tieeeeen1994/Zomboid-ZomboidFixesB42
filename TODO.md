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

## Beta features: what playing each one should check

- [ ] BodyStatsEditor extras: the hotbar's body part toggles (each condition on another player, flip), the Health
      button next to Body in Player Stats (opens the window without asking; player must be loaded on the admin's
      client), and the health window's Full Health, Keep Treatment for a part and for the body (bandage,
      poultices, splint and stitches stay).
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
