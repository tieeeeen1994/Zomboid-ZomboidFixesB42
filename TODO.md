# TODO

Candidate vanilla fixes, to take one at a time. Line numbers are from 42.20.4; the install is now
**42.21.0** (rev 4a0e9546ec), so for each item first re-check that the bug is still there in 42.21
(patch notes: theindiestone.com/forums/topic/101693) and follow the usual rules: a sandbox option per
fix (default on; only REALLY closely related fixes share one), README / forum.txt / mod.info lines,
Sandbox.json tooltip, `[BETA]` until it has been played in game.

## Identified by the author

- [ ] Some context menu items display tooltips, which absolutely covered the next menu for that context menu. If possible, just remove the tooltip.

- [ ] The body part menu can be accessed by the stats of the player. but the body enu is accessed by needing to ask permission from player to check their body. We also need to add an easy way for admins to check their health as well. Possibly another button next to Body.

- [ ] The Admin Hotbar feature for health and body part toggles does not have the option to fully heal the part.

- [ ] Health body parts menu (even in vanilla) should have an option to heal the part but still contains the poultice data and the bandage data. Right now healing just removes the bandage and poultice data.

## 0. First: 42.21 regression check

- [x] Check every existing feature still works on 42.21 at the Lua level: done in the 2026-10-05 review
      (every wrapped vanilla function exists with the same signature, every fixed bug is still in 42.21,
      none redundant). ReadBooks still needed: 42.21 counts pages from `startPage` and ends early once all
      are read (`ISReadABook.lua:416-420`), but `complete` still never sets the character's own record.
- [ ] Play every `[BETA]` feature in game and drop its label (see section 5 for what each needs).
- [ ] Update the line numbers in CLAUDE.md to 42.21 as they are touched.

## 0b. In progress

- [ ] **Clothing wear down rework** (option `ClothingWearRework`, beta; replaces `ZombieAttacksWearClothing`
      and `SyncBrokenClothing`). The victim's client rolls every zombie attack that lands on it (own and other
      players' zombies) and sends each thump / blocked swing as its own event when the swing ends; the server
      applies it with vanilla's `addHoleFromZombieAttacks`, syncs once per tick and guards applied swings for
      5 s against client syncs; broken items and worn ghosts handled as before
      (`client/` + `server/ZomboidFixesB42_ClothingWear.lua`). Not tried in game yet. To check on a server:
      events arrive for zombies another player owns, one per swing; own zombies' local fake holes disappear after
      the server's sync; armor condition goes down at about the single player rate and survives relog; a break
      drops the item for everyone with no ghost copy; no extra lag in a horde. Open: the wound and the wear are
      separate rolls (same odds, same average); a fake local hole pushed by a client sync before the server's
      copy arrives becomes real (vanilla does that too); a condition raise within 5 s of a swing (repair) is
      taken back; fake-dead and vehicle attacks are not rolled.

## 1. Small Lua bug fixes

- [x] **Vehicle batteries drain at double speed.** `VehicleUtils.chargeBattery`
      (`server/Vehicles/Vehicles.lua` ~1306) adds `delta` twice: `max(charge + delta, 0)` then
      `min(charge + delta, 1)`. Engine charging does not go through it. Done: `*_VehicleBattery.lua`,
      option `VehicleBatteryDrain`.
- [ ] **Health panel cheats on another player hit the admin.** `ISHealthPanel.onCheatOtherPlayer`
      (`client/XpSystem/ISUI/ISHealthPanel.lua` ~330) sends `id = player:getOnlineID()` (the admin)
      instead of `otherPlayer`. Also `healthFull` / `healthFullBody` (`server/ClientCommands.lua`
      ~547-558) use `player` instead of `otherPlayer`, and `healthFullBody` syncs only one body part.
- [ ] **Welding an installed gas tank loses the materials.** `ISFixVehiclePartAction.lua` ~41 reads an
      undefined `part`, so `complete()` errors after the sheet metal and torch are used and the action
      is rejected. Fix: `self.vehiclePart:getContainerContentAmount()`.
- [x] **Client-only `checkWeapon` called on the server.** 42.21 moved it to the shared
      `ItemUtils.checkWeapon` (sledgehammer destroy fixed by vanilla; ground cover's call is dead code).
      Left: `ISRemoveBush` never has its tool on the server (set in client `start()`) nor fires "Chop"
      with a tool in single player, so bushes never wore the tool; `'ui' 'dirtyUI'` never reached the
      client's `DirtyUI`. Done: `*_RemoveBush.lua`, option `RemoveBushToolWear`.
- [ ] **Pickaxing ground cover never wears the pickaxe.** `ISPickAxeGroundCoverItem.lua` ~146:
      `self.pickaxe` is never assigned.
- [ ] **Water dispenser bottle duplication.** `ISAddTakeDispenserBottle.lua` ~6 compares with an
      undefined `bottle` (always true) and `complete()` does not re-check.
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
- [ ] Generators: pickup action completes but gives no item (`ISTakeGenerator.lua` ~43, `instanceItem`
      nil; forum 101307); add-fuel time ignores the amount (101661).
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
- [x] Pumpkin / sunflower seed packets (beta): opening gives 25 (OnCreate), since input amounts cannot
      be changed from Lua. Option `SeedPacketCount`.
- [x] Weights: pie slices 0.2, .44 box 0.48 / carton 4.8. Option `ItemWeights`. Not done (engine, not
      data): pasta bowl ~6 kg (100315) and the heavy slices of a very filling pie both come from
      `Food.getActualWeight` scaling the script weight by hunger / script hunger; vegetable oil hunger
      turning positive (99705) is evolved recipe code (also ranch sauce, flour).
- [x] Minor: HotDrinkRed -> Base.Mugl, Rangers shirt BloodLocation Shirt, red cap ChanceToFall 60,
      Cooler_Seafood sounds; names in `Translate/EN/ItemName.json` (always on). Option `MinorItemFixes`.
      Not done: Cooler_Seafood `CanHaveHoles` (only read for Clothing); crafted face shemaghs (maybe
      deliberate).

## 3. Admin / QoL features

- [ ] **Timed Action Instant ignored by item transfers in MP** (forum 99241): reuse `*_Transfer.lua`'s
      `createItemTransaction` wrapper for an instant server move. Check first whether FastTransfers
      (`FastTransfers`, the Fast Timed Actions cheat path) already covers this, and close it if so. Also Handy + instant build gives a
      negative server duration (`BuildAction.getDuration` 1 - 50, forum 100841).
- [ ] **World map admin features check `getAccessLevel() == "admin"`** instead of capabilities
      (`ISWorldMap.lua` ~36, 166, 911, `ISMiniMap.lua` ~130): moderators and custom roles can't see
      players or teleport (100607). Mind `getAccessLevel()` NPEs in single player.
- [ ] **ALICE belt / webbing MaxItemSize checked against the whole dragged stack**, 1-4 magazines per
      drag (`ISInventoryPane.lua` ~1429, `ISInventoryPaneContextMenu.hasRoomForAny`; 98673, 101849).
- [ ] **Houses can't be claimed as safehouses** ("non-residential"; 96629, 100611, TIS frequently
      reported list). Find the real check in Java; maybe a server claim command with a fixed test.
- [ ] **Explored rooms reset on every relog in MP** (99809, re-confirmed on 42.21): save explored room
      ids per player per server and re-apply.
- [ ] Map items in MP: symbols lost on relog (96433), brochures don't mark the map (Steam).
- [x] Water containers break after a server restart (92679, 93595). Meta entities lost between chunk and
      entity_data.bin saves (dedicated servers never hot-save). Done: `*_LostEntities.lua`, option
      `RepairLostEntities`. Not covered: broken items put in a crate before the fix (fixed once carried at login).
- [ ] Timed actions stuck at 100% block the queue (forge, kiln, bulk crafting; 94615, 100905).

## 4. Deferred: security hardening of unchecked client commands

Not chosen for now; full list in CLAUDE.md ("Vanilla client-command handlers with no permission
check"). Most serious: `player.onHealthCheatCurrentPlayer` lets any client bite / infect any player;
`object.clearContainerExplore` re-rolls any container's loot; vehicle `fixPart` /
`setContainerContentAmount`; farming, campfire, tent and trap commands from anywhere.

## 5. Found in the 2026-10-05 feature review (not fixed yet)

Bugs that hurt players:
- [ ] **DeleteNegativeWeightItems deletes vanilla food.** Food weight scales by hunger / script hunger
      (`Food.getActualWeight`), and vegetable oil, ranch sauce and flour can end up with positive hunger
      (evolved recipe code, forum 99705), so their weight goes negative and the feature deletes them. Skip
      such food (or repair its hunger) instead of deleting it.
- [ ] **Washing is shortened twice under fast forward**: `ISWashClothing:getDuration` calls
      `adjustMaxTime` itself (`ISWashClothing.lua:215`), so the server's wrapped `adjustMaxTime` applies the
      speed twice (speed squared).
- [ ] Fast forward timed transfers: the server accepts `timedTransfer` even at normal speed
      (`*_FastForwardTransfer.lua` ~94-114), and the reach check is 8 tiles flat with no height check
      (`*_Server.lua` ~50-58).
- [ ] SeedPacketCount also gives 25 seeds for looted packets (they spawn, `Distributions.lua` ~20154).
      `ISHandcraftAction:performRecipe` records `modData["Base.PumpkinSeed"] = 25` on a crafted packet:
      give back that amount instead.

Wrong data in the item fixes:
- [ ] Shin armor: swapping makes the plain Metal Shin Armor (0.85) slower than its spiked version (0.9),
      while vanilla's pattern is articulated pieces getting a higher value (thigh 0.95 vs 0.9). Raise the
      articulated shin pieces instead and leave Greave at 0.9; move it from `*_ArmorStats.lua` into
      ScriptFixes.
- [ ] ItemWeights pie slice 0.2 overcorrects: per hunger point a vanilla pie slice (0.5 at -30) is already
      lighter than a cake slice (0.2 at -7). Drop the pie part, keep .44.
- [ ] FoodNutrition misses CannedLeek Proteins 15.2 (should be 4 x 1.3 = 5.2).
- [ ] MinorItemFixes' HotDrinkRed part is dead: no recipe, mapper, evolved recipe or loot gives
      HotDrinkRed in 42.21.

Dead or duplicate code:
- [ ] ForagingDebugFixes part 4 (pickup) never runs in MP: vanilla `ISForageAction:complete` already calls
      `forageServer.onPickup` on the server and Java runs `complete` only off a client. Drop
      `client/*_Foraging.lua` ~211-226 and `server/*_Foraging.lua` ~170-187, and the tooltip line saying
      vanilla never hands over the items.
- [ ] NISFShiftRange likely duplicates the `NISF_ShiftRange.lua` that Nick's Inventory Selection Fix
      (workshop 3782920935) already ships, credited to this fix. Check whether Nick's copy works, then drop
      ours or document why both are needed.

Smaller issues:
- [ ] GoMTooltipLineLength defaults to 200, which barely wraps; its tooltip says around 40 reads well.
- [ ] FirearmRadialNoBlanks: vanilla keeps the blanks so each action keeps its slot, which matters on a
      joypad; leave them while a joypad drives the menu.
- [ ] SewersClimbOut: any climb turns the server-wide NoClip anticheat off for up to 15 s, and saving
      server options in that window writes it off to the ini. Consider default off.
- [ ] TransferResync: a client can ask for the items of any container within 8 tiles (small info leak).
- [ ] AdminFullBright: its Admin Powers entry shows even with the option off, and a missing SandboxVars
      table counts as on (every other option counts it as off).
- [ ] ItemEditorSync: `server/*_ItemEdit.lua:18` requires a client-folder file; on a dedicated server it
      may not load, and the setter whitelist then falls back to any `set*` method (still limited to the
      Edit Item capability). Check the server log for "could not rebuild".
- [ ] AdminSpawnProtection walks the online players every tick even when set to 0.
- [ ] `shared/ZomboidFixesB42.lua:16-17` says new fixes default off (they are on); some options read
      `~= false`, others `== true`: unify.

Beta features: what playing each one should check
- [ ] Body part toggles (hotbar, under `BodyStatsEditor`): each condition on another player, flip.
- [ ] AnimalGenderChange: all four branches (world, hutch, trailer, carried animal).
- [ ] RepairLostEntities: a killed server and a restored backup with rain collectors, drying racks and
      a bucket on the floor; chunk re-saves while a backup runs.
- [ ] TransferResync, ReloadAnimTiming, WaterPlantOnce, RemoveBushToolWear, VehicleBatteryDrain,
      BooksStayRead, NoStairAutoVault, GrabAmount, FirearmRadialNoBlanks, GoMMagazineTooltip, the admin
      debug fixes (FixDebugAddFluid, ForagingDebugFixes, NoWalkOnSquarePick, ServerOptionsTooltip),
      AdminSpawnProtection: one session each on a server.
- [ ] ItemDataFixes and RecipeFixes: each fix in its tooltip, and switching the option off mid-game
      reverts it (ScriptFixes revert path).
