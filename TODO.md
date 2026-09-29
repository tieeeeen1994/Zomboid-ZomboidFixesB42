# TODO

Candidate vanilla fixes, to take one at a time. Line numbers are from 42.20.4; the install is now
**42.21.0** (rev 4a0e9546ec), so for each item first re-check that the bug is still there in 42.21
(patch notes: theindiestone.com/forums/topic/101693) and follow the usual rules: one sandbox option
per fix (default on), README / workshop.txt / mod.info lines, Sandbox.json tooltip.

## 0. First: 42.21 regression check

- [ ] Check every existing feature still works on 42.21: the vanilla functions each file wraps still
      exist with the same signatures (AdminHotbar*, FastForward*/Transfer, then the rest). Drop any fix
      vanilla made redundant (42.21 fixed reading progress stalls, which overlaps ReadBooks).
- [ ] Update the line numbers in CLAUDE.md to 42.21 as they are touched.

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

## 2. Item / recipe data fixes (one option each)

Script edits in the ArmorStats style (DoParam from `OnInitGlobalModData` + `EveryTenMinutes`, vanilla
values restored when off). Check for each property whether DoParam replaces or appends and whether a
cache has to be refreshed (Tags, ClothingItemExtra, SpawnWith, MountOn). Fixing entries and recipe
mappers may need another way than DoParam.

- [ ] Spiked metal thigh armour (`ThighMetalSpike_R`, `ThighScrapMetalSpike_R`): `ClothingItemExtra`
      points at itself, so it can't be moved to the left thigh (`items/clothing.txt` ~22913, ~23984).
- [ ] Sawn-off double-barrel shotgun has no repair (`fixing.txt`); every other gun has one.
- [ ] Copper saucepan pasta/rice can't be split into bowls: Make2/Make4Bowls `potType` lacks
      `SaucepanCopper = PastaPanCopper` (`recipes_cooking.txt` ~378, ~462); RicePanCopper lacks
      `base:canbedividedinbowls` and its bowlType entries.
- [ ] Pasta eaten from a forged pot gives back a normal pot: `WaterPotForgedPasta` `ReplaceOnUse =
      Base.Pot` (`food.txt` ~11252), should be `Base.PotForged`.
- [ ] Spiked articulated metal shoulder pads lose `base:smeltablesteelmedium` (clothing.txt ~23259).
- [ ] Sawn-off pump shotgun: no Insert/Eject Start/Stop sounds (the `SawnOffJS2000Shotgun*` sounds
      exist), no `AimingMod = 2.0` / `IsAimedHandWeapon = true` (weapon.txt ~11579). Check in Java what
      the two aim fields do first.
- [ ] Kneepads and gaiters spawn one piece: `SpawnWith` only on Kneepad_Right and Gaiter_Left.
- [ ] Full bow tie weighs 1.0 (no `Weight`; others 0.1), clothing.txt ~9583.
- [ ] JS-3T shotgun has models for recoil pad / choke tubes but their `MountOn` leaves it out
      (weaponpart.txt ~105, ~188, ~206); the sawn-off has an x2 scope model but it can't mount.
- [ ] Katana and broken Katana lack `base:sharpenable` (the only 2 of 14 long blades).
- [ ] Full chainmail sleeves: `CombatSpeedModifier` R 0.97 / L 0.95 looks swapped (clothing.txt ~16445).
- [ ] Tire shoulder pads: left `ConditionLowerChanceOneIn = 5` (right and others 2); both use
      `BloodLocation = UpperBody` instead of `UpperArm_L/R` (clothing.txt ~14679-14720).
- [ ] Leek nutrition: 140 carbs for 54 calories (food.txt ~14452, carried into CannedLeek); grapefruit
      15 kcal with 101 carbs / 17.6 protein (~8752).
- [ ] Clay bowl portions come back as normal bowls (OutputMapper takes the first match); also
      MakeBowlOfBeans / Oatmeal / Cereal and PlaceCakeInBakingPan.
- [ ] Pumpkin / sunflower seed packets take 25 seeds, opening gives 5 (`recipes_farming.txt`).
- [ ] Weights: pie slice weighs the whole pie (100429), pasta bowl ~6 kg (100315), .44 box (101095);
      vegetable oil hunger sign (99705).
- [ ] Minor: `HotDrinkRed` `ReplaceOnUse = Base.MugRed` (no such item); missing EN names HotDrinkMetal /
      Copper / Gold / Silver / Tumbler, FruitSaladClay; Shirt_Baseball_Rangers `BloodLocation =
      UpperBody`; Hat_BaseballCapRed `ChanceToFall = 80` (others 60); Cooler_Seafood missing sounds and
      `CanHaveHoles = false`. Crafted face shemaghs keep full-face stats (maybe deliberate).

## 3. Admin / QoL features

- [ ] **Timed Action Instant ignored by item transfers in MP** (forum 99241): reuse `*_Transfer.lua`'s
      `createItemTransaction` wrapper for an instant server move. Also Handy + instant build gives a
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
