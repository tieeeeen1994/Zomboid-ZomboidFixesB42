# TODO

Candidate vanilla fixes, to take one at a time. Line numbers are from 42.20.4; the install is now
**42.21.0** (rev 4a0e9546ec), so for each item first re-check that the bug is still there in 42.21
(patch notes: theindiestone.com/forums/topic/101693) and follow the usual rules: a sandbox option per
fix (default on; only REALLY closely related fixes share one), README / forum.txt / mod.info lines,
Sandbox.json tooltip, `[BETA]` until it has been played in game.

## Identified by the author

- [x] Some context menu items display tooltips, which absolutely covered the next menu for that context menu. If possible, just remove the tooltip.
      Done 2026-10-05 (changed to): this mod's menu tooltips go left of the menu and are drawn behind
      the open menus (`client/*_MenuTooltips.lua`, `ZomboidFixesB42.sideTooltip`); vanilla's untouched.

- [x] The body part menu can be accessed by the stats of the player. but the body enu is accessed by needing to ask permission from player to check their body. We also need to add an easy way for admins to check their health as well. Possibly another button next to Body.
      Done 2026-10-05: Health button next to Body in Player Stats (`client/*_HealthCheck.lua`, CanMedicalCheat,
      player must be loaded on the admin's client), under BodyStatsEditor. Not played yet.

- [x] The Admin Hotbar feature for health and body part toggles does not have the option to fully heal the part.
      Done 2026-10-05: body part condition "Healed (treatment kept)". Not played yet.

- [x] Health body parts menu (even in vanilla) should have an option to heal the part but still contains the poultice data and the bandage data. Right now healing just removes the bandage and poultice data.
      Done 2026-10-05: Cheat menu gets Full Health, Keep Treatment (part) and (Body), through the body stats
      set command; bandage, poultices, splint and stitches stay (stitches left fully healed). Not played yet.

## 0. First: 42.21 regression check

- [x] Check every existing feature still works on 42.21 at the Lua level: done in the 2026-10-05 review
      (every wrapped vanilla function exists with the same signature, every fixed bug is still in 42.21,
      none redundant). ReadBooks still needed: 42.21 counts pages from `startPage` and ends early once all
      are read (`ISReadABook.lua:416-420`), but `complete` still never sets the character's own record.
- [ ] Play every `[BETA]` feature in game and drop its label (see section 5 for what each needs).
- [x] Update the line numbers in CLAUDE.md to 42.21: done 2026-10-05 (every `~N` re-checked against a fresh
      Vineflower decompile of the 42.21.0 jar and the 42.21.0 Lua). The line numbers in this file are still 42.20.4's.

## 1. Small Lua bug fixes

- [x] **Vehicle batteries drain at double speed.** `VehicleUtils.chargeBattery`
      (`server/Vehicles/Vehicles.lua` ~1306) adds `delta` twice: `max(charge + delta, 0)` then
      `min(charge + delta, 1)`. Engine charging does not go through it. Done: `*_VehicleBattery.lua`,
      option `VehicleBatteryDrain`.
- [x] ~~Health panel cheats on another player hit the admin.~~ Not a bug (re-checked 2026-10-05 on 42.21): in
      `ISHealthPanel` `player` is the patient and `otherPlayer` the doctor, so `onCheatOtherPlayer` sends the
      patient's id from the doctor, and the patient's own client applies it (flow in CLAUDE.md, "Health panel").
      `healthFull` / `healthFullBody` reading `player` only matter for a client sending
      `onHealthCheatCurrentPlayer` with someone else's id (section 4); `healthFullBody` syncing one part heals
      itself within 2 s (PlayerDamage).
- [x] **Welding an installed gas tank loses the materials.** `ISFixVehiclePartAction.lua` ~41 reads an
      undefined `part`, so `complete()` errors after the sheet metal and torch are used and the action
      is rejected (still in 42.21; only "Fix Gas Tank Welding" reaches that line). Done:
      `server/*_GasTankWelding.lua`, option `GasTankWelding`.
- [x] **Client-only `checkWeapon` called on the server.** 42.21 moved it to the shared
      `ItemUtils.checkWeapon` (sledgehammer destroy fixed by vanilla; ground cover's call is dead code).
      Left: `ISRemoveBush` never has its tool on the server (set in client `start()`) nor fires "Chop"
      with a tool in single player, so bushes never wore the tool; `'ui' 'dirtyUI'` never reached the
      client's `DirtyUI`. Done: `*_RemoveBush.lua`, option `RemoveBushToolWear`.
- [x] **Pickaxing ground cover never wears the pickaxe.** `ISPickAxeGroundCoverItem.lua` ~146:
      `self.pickaxe` is never assigned (still in 42.21). Done: `server/*_PickAxeWear.lua`, merged into
      option `RemoveBushToolWear` (key kept so servers keep their setting; shown as "Clearing Bushes, Rocks
      And Stumps Wears The Tool"), which also answers the `dirtyUI` refresh after a broken tool is swapped.
- [x] **Water dispenser bottle duplication.** `ISAddTakeDispenserBottle.lua` ~6 compares with an
      undefined `bottle` (always true) and `complete()` does not re-check (still in 42.21; also a bottle
      put on from a bag stays there, `Remove` on the main inventory only). Done:
      `shared/*_WaterDispenser.lua`, option `WaterDispenserCheck`.
- [x] **Composter "Get compost" submenu broken.** `client/ContextMenuCode.lua` ~92 used
      `predicateNotFull` / `predicateEmptySandbag`, locals of `ISWorldObjectContextMenu.lua`. Fixed by
      vanilla in 42.21: the code moved to `ISWorldObjectContextMenu.handleCompost` (~355), where those
      locals are in scope; nothing left to do.
- [x] **Plants watered twice in MP.** `ISWaterPlantAction`: the client's `update` sends `water` per
      use, then the server's `complete` waters again with the full uses and uses the item again.
      Done: `*_WaterPlant.lua` (server alone waters, clamped to the can; `serverStop` pours the part
      done on cancel), option `WaterPlantOnce`.
- [ ] **Egg taken from a nest box is invisible.** `animal.removeEggFromNestBox`
      (`server/ClientCommands.lua` ~772) adds the egg without `sendAddItemToContainer`.
- [ ] **Remove Bush skips neighbouring bushes.** `object.removeBush` (`server/ClientCommands.lua` ~122)
      removes while iterating forward (`i = i - 1` does nothing); `ZombRand(1) == 0` is always true.
      `shovelGround` (~180) errors on a nil `emptyBag`.
- [ ] **Removed make-up comes back in MP.** `ISMakeUpUI.onRemoveMakeUp` (~114) removes it on the
      client only (apply uses `ISApplyMakeUp`).
- [ ] **Notebook text lost in MP.** `ISInventoryPaneContextMenu.onWriteSomethingClick` (~2713) never
      calls `syncItemFields`; `ISUIWriteJournal` `setLockedBy` is not synced either. 42.21 fixed "notes
      in a backpack notebook not saving": check what is left.
- [ ] **Faction invite says "null faction".** `ISFactionUI.lua` ~410 passes an undefined
      `factionName` (the parameter is `faction`).
- [ ] **Padlock unlock sends the padlock too early.** `ISPadlockAction.lua` ~40: sent with
      `sendAddItemToContainer` before `setNumberOfKey` / `setKeyId`.
- [ ] Cosmetic typos: `ISColorPicker.lua` ~151 / `ISColorPickerHSB.lua` ~275 pass a nil global
      `mouseUp`; `ISPlayerStatsManageInvUI.lua` ~215 `playerUsername` vs `self.playerUsername`;
      `ISFarmingMenu.lua` ~141 undefined `currentPlant`.
- [x] Generators: pickup action completes but gives no item (`ISTakeGenerator.lua` ~43, `instanceItem`
      nil; forum 101307); add-fuel time ignores the amount (101661).
      Done 2026-10-05: refuel timed from the fuel that fits (`shared/*_GeneratorFuel.lua`, GeneratorRefuelTime).
      Pickup needs nothing on 42.21: `IsoGenerator.getGeneratorItemType` falls back to Base.Generator.
- [ ] Medical-checking another player twice clears their negative statuses (forum 99627).
- [ ] Scrapping gold jewellery used as a key ring deletes every key on it (forum 101057).
- [ ] Barricading needs 2 nails but uses 1; runs with no plank left and builds nothing (100019, 100313).
- [ ] "Eat all" then queueing another eat: the eaten item's auto-return cancels the queue (99717);
      queued crafts: only 2 run (100495).
- [ ] Mechanics "XP once per part" limit (`get/addMechanicsItem`) is not saved, lost on reload (97845).
- [ ] Fish fillets show 205 kcal until dropped (100231).

## 2. Item / recipe data fixes (options `ItemDataFixes` and `RecipeFixes`)

Done in 42.21 through `shared/ZomboidFixesB42_ScriptFixes.lua` (DoParam, tags with their recipe input
caches, output mapper entries, recipe OnCreate, repair fixers; applied from `OnLoadMapZones`, after
`PostWorldDictionaryInit`, and re-checked every ten minutes) and `*_ItemFixesClothing/Weapons/Food.lua`.
None of these has been tried in game yet, so both options are beta. Since 3.0.0 they share two options:
`ItemDataFixes` (item properties) and `RecipeFixes` (recipe and repair edits: smelting, sharpening, forged
pot, copper saucepan, clay bowls, seed packets, sawn-off repair); the names below are the fixes' names
in the log.

- [x] Spiked metal thigh armour `ClothingItemExtra` -> the left piece. Option `SpikedThighArmorSide`.
- [x] Sawn-off double-barrel shotgun repair (beta): added to "Fix DoubleBarrelShotgun" as required item
      and fixer. Option `SawnOffDoubleBarrelRepair`.
- [x] Copper saucepan pasta/rice split into bowls (beta). Option `CopperSaucepanBowls`.
- [x] Forged pot pasta gives back `Base.PotForged` (also fixes loaded pots before eating/emptying).
      Option `ForgedPotPasta`.
- [x] Spiked articulated metal shoulder pads smeltable. Option `SpikedShoulderPadSmelting`.
- [x] Sawn-off pump shotgun insert/eject start/stop sounds (eject sound: the full shotgun's). Option
      `SawnOffShotgunSounds`. Not done: `AimingMod` / `IsAimedHandWeapon` do nothing in 42.21
      (`HandWeapon.getAimingMod()` returns 1.0, `IsoPlayer.IsUsingAimHandWeapon` is never called).
- [x] Kneepads and gaiters spawn in pairs. Option `KneepadGaiterPairs`.
- [x] Full bow tie weight 0.1. Option `BowTieWeight`.
- [x] x2 scope mounts on the pump shotgun and the sawn-off (both have the model part and the scope
      attachment points). Option `ShotgunScopeMount`. Not done: the JS-3T's recoil pad / choke tubes, its
      model (`JS3T_Shotgun` in models_weapons.txt) has no `recoilpad` / `choketube` attachment, so the
      part would be drawn at the gun's origin; would need attachment offsets added to the model script.
- [x] Katana and broken Katana sharpenable. Option `KatanaSharpening`.
- [x] Full chainmail sleeves combat speed R 0.95 / L 0.97. Option `ChainmailSleeveSpeed`.
- [x] Tire shoulder pads: left ConditionLowerChanceOneIn 2, BloodLocation UpperArm_L/R. Option
      `TireShoulderPads`. (The football L/R shoulder pads also use UpperBody; left alone.)
- [x] Leek / CannedLeek carbohydrates, grapefruit (300 g values). Option `FoodNutrition`.
- [x] Clay bowl portions (beta): bowl input registered in Make2/Make4Bowls' bowlType mapper plus
      [pot, ClayBowl] / [pot, Bowl] entries in front; beans/oatmeal/cereal use vanilla's
      `modData["Base.ClayBowl"]` record to return the clay bowl; PlaceCakeInBakingPan gets an OnCreate.
      Option `ClayBowlPortions`.
- [x] Pumpkin / sunflower seed packets (beta): opening a packet the player made gives 25 (OnCreate, from
      performRecipe's modData record), since input amounts cannot be changed from Lua. Option `SeedPacketCount`.
- [x] Weights: .44 box 0.48 / carton 4.8 (pie slices 0.2 dropped later, see section 5). Option `ItemWeights`. Not done (engine, not
      data): pasta bowl ~6 kg (100315) and the heavy slices of a very filling pie both come from
      `Food.getActualWeight` scaling the script weight by hunger / script hunger; vegetable oil hunger
      turning positive (99705) is evolved recipe code (also ranch sauce, flour).
- [x] Minor: (HotDrinkRed -> Base.Mugl, dropped later: nothing makes it), Rangers shirt BloodLocation Shirt, red cap ChanceToFall 60,
      Cooler_Seafood sounds; names in `Translate/EN/ItemName.json` (always on). Option `MinorItemFixes`.
      Not done: Cooler_Seafood `CanHaveHoles` (only read for Clothing); crafted face shemaghs (maybe
      deliberate).

## 3. Admin / QoL features

- [x] **Timed Action Instant ignored by item transfers in MP** (forum 99241): already covered by
      `FastTransfers` (`*_Transfer.lua`, every `ISInventoryTransferAction`, loot window floor included; Java
      `Transaction.getDuration` never reads the cheat). Handy + instant build (forum 100841): Java
      `BuildAction.getDuration` gives (1 - 50) x 20 ms, a negative duration becomes 30 min
      (`AnimEventEmulator.getDurationMax`). Done: `server/*_InstantBuildHandy.lua`, option `InstantBuildHandy`
      (Handy held off instant players while the server builds the object, back at the next OnTick).
- [x] World "Grab" (`ISGrabItemAction`, world context menu and forage icons) still waits the server's
      transaction time under Timed Action Instant (up to ~3 s for heavy items). Done: `FastTransfers` now
      also takes grabs off the transaction (`*_Transfer.lua`, "Grabbing from the ground"); not tried in game.
- [x] **World map admin features check `getAccessLevel() == "admin"`** instead of capabilities
      (`ISWorldMap.lua` ~36, 166, 911, `ISMiniMap.lua` ~130): moderators and custom roles can't teleport
      from the map (100607). Seeing remote players is Java and already by capability (CanSeeAll). Done:
      `client/*_WorldMapAdmin.lua`, option `MapAdminCapabilities` (TeleportToCoordinates or UseDebugContextMenu).
- [ ] **ALICE belt / webbing MaxItemSize checked against the whole dragged stack**, 1-4 magazines per
      drag (`ISInventoryPane.lua` ~1429, `ISInventoryPaneContextMenu.hasRoomForAny`; 98673, 101849).
- [ ] **Houses can't be claimed as safehouses** ("non-residential"; 96629, 100611, TIS frequently
      reported list). Find the real check in Java; maybe a server claim command with a fixed test.
- [x] **Explored rooms reset on every relog in MP** (99809, re-confirmed on 42.21): rooms go dark again.
      The per-square "seen" bits are saved with the chunk only in single player (`IsoGridSquare.save/load`),
      and clients never load map_meta.bin (room explored flags). Done: `client/*_SeenRooms.lua`, option
      `RememberSeenRooms` (client file per server and account of explored rooms, re-applied as chunks load).
- [ ] Map items in MP: symbols lost on relog (96433), brochures don't mark the map (Steam).
- [x] Water containers break after a server restart (92679, 93595). Meta entities lost between chunk and
      entity_data.bin saves (dedicated servers never hot-save). Done: `*_LostEntities.lua`, option
      `RepairLostEntities`. Not covered: broken items put in a crate before the fix (fixed once carried at login).
- [ ] Timed actions stuck at 100% block the queue (forge, kiln, bulk crafting; 94615, 100905).
- [x] **Clothing wear down rework** (option `ClothingWearRework`, beta; replaces `ZombieAttacksWearClothing`
      and `SyncBrokenClothing`). The victim's client rolls every zombie attack that lands on it (own and other
      players' zombies) and sends each thump / blocked swing as its own event when the swing ends; the server
      applies it with vanilla's `addHoleFromZombieAttacks`, syncs once per tick and guards applied swings for
      5 s against client syncs; broken items and worn ghosts handled as before
      (`client/` + `server/ZomboidFixesB42_ClothingWear.lua`). Code done and shipped as beta in 3.0.0; what to
      check in game is under section 5. Open: the wound and the wear are separate rolls (same odds, same
      average); a fake local hole pushed by a client sync before the server's copy arrives becomes real
      (vanilla does that too); a condition raise within 5 s of a swing (repair) is taken back; fake-dead and
      vehicle attacks are not rolled.

## 4. Deferred: security hardening of unchecked client commands

Not chosen for now; full list in CLAUDE.md ("Vanilla client-command handlers with no permission
check"). Most serious: `player.onHealthCheatCurrentPlayer` lets any client bite / infect any player;
`object.clearContainerExplore` re-rolls any container's loot; vehicle `fixPart` /
`setContainerContentAmount`; farming, campfire, tent and trap commands from anywhere.

## 5. Found in the 2026-10-05 feature review (not fixed yet)

Bugs that hurt players:
- [x] ~~DeleteNegativeWeightItems deletes vanilla food.~~ Intended (author, 2026-10-05): a condiment only goes
      negative when the cooking/crafting desync leaves it behind after it was used up and should have been
      deleted, so deleting it is right, and keeping it lets a container's load go below zero (capacity abuse).
- [x] **Washing is shortened twice under fast forward**: `ISWashClothing:getDuration` calls
      `adjustMaxTime` itself (`ISWashClothing.lua:215`), so the server's wrapped `adjustMaxTime` applies the
      speed twice (speed squared). Fixed in `server/*_FastForward.lua`: the inner call stays vanilla
      (`DURATION_CALLS_ADJUST`).
- [x] Fast forward timed transfers: the server accepts `timedTransfer` even at normal speed
      (`*_FastForwardTransfer.lua` ~94-114), and the reach check is 8 tiles flat with no height check
      (`*_Server.lua` ~50-58). Done: refused at speed 1 (the client falls back to vanilla), and the shared
      `ZomboidFixesB42.isContainerInReach` also requires less than one level up or down (instant transfers,
      timed transfers and TransferResync). Vanilla's `TransactionManager.isConsistent` has no distance check
      for ordinary containers (5 tiles for vehicles), so this was never worse than vanilla.
- [x] SeedPacketCount also gives 25 seeds for looted packets (they spawn, `Distributions.lua` ~20154).
      `ISHandcraftAction:performRecipe` records `modData["Base.PumpkinSeed"] = 25` on a crafted packet:
      give back that amount instead. Done: only packets with that record get the missing seeds (capped at 25).

Wrong data in the item fixes:
- [x] Shin armor run speeds broke the family pattern. Done (author: "normalize the pattern on the offending
      parts"): `ShinArmorSpeed` in `*_ItemFixesClothing.lua` gives the shin pieces the thigh's pattern
      (spiked -0.05, articulated +0.05): spiked (scrap) metal 0.85, articulated 0.95, spiked articulated
      0.90; plain metal and scrap stay 0.90. The old swap (`*_ArmorStats.lua`) is removed.
- [x] ItemWeights pie slice 0.2 overcorrects: per hunger point a vanilla pie slice (0.5 at -30) is already
      lighter than a cake slice (0.2 at -7). Done: pie part dropped, .44 kept.
- [x] FoodNutrition misses CannedLeek Proteins 15.2 (should be 4 x 1.3 = 5.2). Done, and CannedLeek_Open
      (the opened jar, same values) was missing from the fix entirely; both get carbs 50.4, proteins 5.2.
- [x] MinorItemFixes' HotDrinkRed part is dead: no recipe, mapper, evolved recipe or loot gives
      HotDrinkRed in 42.21. Done: removed (params and the onBeforeUse hook).

Dead or duplicate code:
- [x] ForagingDebugFixes part 4 (pickup) never runs in MP: vanilla `ISForageAction:complete` already calls
      `forageServer.onPickup` on the server and Java runs `complete` only off a client
      (`LuaTimedActionNew.complete`). Done: client override, server `CMD_FORAGE_PICKUP` handler and constant,
      and the tooltip sentence removed. Debug icons stay pickable through part 1 (server registration), which
      is what made them pickable in the author's test.
- [x] NISFShiftRange likely duplicates the `NISF_ShiftRange.lua` that Nick's Inventory Selection Fix
      (workshop 3782920935) already ships, credited to this fix. Check whether Nick's copy works, then drop
      ours or document why both are needed.
      Removed 2026-10-05: Nick's 1.0.1 ships the same code; it only seemed broken because a local 1.0.0
      copy in ~/Zomboid/Workshop (no NISF_ShiftRange.lua) took precedence over the subscribed one.

Smaller issues:
- [x] GoMTooltipLineLength defaults to 200, which barely wraps; its tooltip says around 40 reads well.
      Done 2026-10-05: 200 stays (fits any screen, tooltip not too tall); the tooltip now says so.
- [x] FirearmRadialNoBlanks: vanilla keeps the blanks so each action keeps its slot, which matters on a
      joypad; leave them while a joypad drives the menu.
      Not doing (2026-10-05): every mod that changes the radial menu leaves no blanks, and blanks only
      make the menu more confusing, joypad included.
- [x] SewersClimbOut: any climb turns the server-wide NoClip anticheat off for up to 15 s, and saving
      server options in that window writes it off to the ini. Consider default off.
      Removed 2026-10-05: setting AntiCheatNoClip to disabled does the same without the risk.
- [x] TransferResync: a client can ask for the items of any container within 8 tiles (small info leak).
      Not a leak (2026-10-05): chunk data already carries every container's items (`IsoObject.save`), and
      vanilla's RequestItemsForContainer fills any unexplored container with no distance check at all.
- [x] AdminFullBright: its Admin Powers entry shows even with the option off, and a missing SandboxVars
      table counts as on (every other option counts it as off).
      Done 2026-10-05: left out of the Admin Powers window and greyed out on the hotbar while off;
      a missing SandboxVars table now counts as off.
- [x] ItemEditorSync: `server/*_ItemEdit.lua:18` requires a client-folder file; on a dedicated server it
      may not load, and the setter whitelist then falls back to any `set*` method (still limited to the
      Edit Item capability). Check the server log for "could not rebuild".
      Left as is (2026-10-05): it does fail there (no fonts, see the file header), but the fallback stops
      nothing an Edit Item holder could not do anyway.
- [x] AdminSpawnProtection walks the online players every tick even when set to 0.
      Done 2026-10-05: skipped while 0; the first tick after it is turned on only records who is online.
- [x] `shared/ZomboidFixesB42.lua:16-17` says new fixes default off (they are on); some options read
      `~= false`, others `== true`: unify.
      Done 2026-10-05: every option reads `vars ~= nil and vars.X == true` (off until known to be on);
      comment fixed.

Beta features: what playing each one should check
- [ ] FastTransfers' new grab path (not beta itself, the option was played before the grabs were added): with
      Timed Action Instant on a server, right-click Grab one item, Grab all of a pile of nails (batches of 20),
      search mode icons, and a build cursor picking up planks; items arrive at once, actions queued after the
      grab (eat, equip) still run, nothing is left as a floor ghost.
- [ ] ClothingWearRework, on a server: events arrive for zombies another player owns, one per swing; own
      zombies' local fake holes disappear after the server's sync; armor condition goes down at about the
      single player rate and survives relog; a break drops the item for everyone with no ghost copy; no extra
      lag in a horde.
- [ ] Body part toggles (hotbar, under `BodyStatsEditor`): each condition on another player, flip.
- [ ] AnimalGenderChange: all four branches (world, hutch, trailer, carried animal).
- [ ] RepairLostEntities: a killed server and a restored backup with rain collectors, drying racks and
      a bucket on the floor; chunk re-saves while a backup runs.
- [ ] TransferResync, ReloadAnimTiming, WaterPlantOnce, RemoveBushToolWear, VehicleBatteryDrain,
      GasTankWelding, WaterDispenserCheck, InstantBuildHandy, MapAdminCapabilities, RememberSeenRooms,
      BooksStayRead, NoStairAutoVault, GrabAmount,
      FirearmRadialNoBlanks, GoMMagazineTooltip, the admin
      debug fixes (FixDebugAddFluid, ForagingDebugFixes, NoWalkOnSquarePick, ServerOptionsTooltip),
      AdminSpawnProtection: one session each on a server.
- [ ] ItemDataFixes and RecipeFixes: each fix in its tooltip, and switching the option off mid-game
      reverts it (ScriptFixes revert path).
