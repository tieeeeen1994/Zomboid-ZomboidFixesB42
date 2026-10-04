# Zomboid Fixes B42.20 — working notes

Engine findings for Project Zomboid Build 42.20 (game version 42.20.4, revision b0bbce05d5),
recorded so they never have to be re-derived. Line numbers refer to the Vineflower
decompile described below and to the vanilla Lua of 42.20.4; they shift between builds.
42.21 went Stable around 2026-09-28 (notes: theindiestone.com/forums/topic/101693); re-check line numbers and
whether a fix is still needed once the local install updates.

## Paths

- Game Lua: `~/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents/Java/media/lua`
- Game jar: `.../Project Zomboid.app/Contents/Java/projectzomboid.jar` (classes are Java 25, major version 69)
- Bundled JRE (no system Java on this Mac): `.../Project Zomboid.app/Contents/PlugIns/jre-aarch64/Contents/Home/bin/java`
- Mod root: `Contents/mods/ZomboidFixesB42/42.20/media/` (lua/client, lua/server, lua/shared, sandbox-options.txt, lua/shared/Translate/EN)

## Decompiling the game

No decompiler is installed. Vineflower handles the Java 25 classes (CFR 0.152 also works for single classes):

```sh
JAVA=".../Project Zomboid.app/Contents/PlugIns/jre-aarch64/Contents/Home/bin/java"
JAR=".../Project Zomboid.app/Contents/Java/projectzomboid.jar"
curl -sSLo vineflower.jar https://repo1.maven.org/maven2/org/vineflower/vineflower/1.11.1/vineflower-1.11.1.jar
mkdir classes src && (cd classes && unzip -q "$JAR" 'zombie/*')
"$JAVA" -Xmx6g -jar vineflower.jar -dgs=1 -rsy=1 -log=WARN -thr=8 classes src   # ~5080 classes -> ~3078 .java, a few minutes
```

Decompiling only a few classes takes seconds: `unzip -q -o "$JAR" 'zombie/Lua/LuaManager*.class'` (any glob) into an
empty folder and point Vineflower at it. `strings` fails on `.class` files on macOS ("fat file"); read constant-pool
names with Python instead (`re.findall(rb'[A-Za-z_][A-Za-z0-9_]{3,}', data)`), e.g. to check which enum constants
or methods exist.

## Tooling on this Mac

- Local MP test without Steam: `TienGiveItemMP/scripts/mptest.sh` (server + two clients, separate `-cachedir`s under
  `~/ZomboidTest`). Launch = the bundled JRE from `Contents/Java` with `-Dzomboid.steam=0 -Djava.library.path=.
  -classpath .:projectzomboid.jar`, main class `zombie.network.GameServer` (`-nosteam -cachedir= -servername
  -adminpassword`) or `zombie.gameStates.MainScreenState` (client, also needs `-XstartOnFirstThread`; `-nosteam` and
  `-cachedir=` work there too). Without Steam, mods are only searched in `<cachedir>/mods` (`ZomboidFileSystem`: the
  `~/Zomboid/Workshop` staging folders are scanned only in Steam mode), so symlink `<mod>/Contents/mods/<id>` there.
  A server's first run writes the full `Server/<name>.ini` around a partial one (`Mods=` accepts `id;id`, backslashes
  are stripped) plus `<name>_SandboxVars.lua`.

- No Lua interpreter. Syntax-check with luaparser: `pip3 install --target <scratch>/py luaparser`, then
  `PYTHONPATH=<scratch>/py python3 -c "from luaparser import ast; ast.parse(open(f).read())"`. It only checks syntax;
  walking its AST for free names is a cheap way to spot typos in globals.
- Python 3 with Pillow and `sips` are available (image sizes, generating lists of game files).
- On the Windows machine Python is the `py` launcher (`python3` is a Store stub). A real Lua (5.5) for running a mod
  file against mocked Java objects: `py -m pip install --target <scratch>/lupa lupa`, then
  `lupa.LuaRuntime().execute('loadfile([[harness.lua]])([[mod.lua]])')`. Mocks are plain Lua tables with methods
  (Python objects do not take `obj:method()` calls). `ZombieAttacksWearClothing` was checked that way, against a Lua port of
  vanilla's attack code.
- The shell is zsh: `$var[...]` is array subscripting, so `"$f[:.]"` inside a grep pattern breaks; use Python for
  such loops.

## Lua environment (Kahlua) and load order

- Files load alphabetically per folder, shared, then client, then server; `.` sorts before `_`, so
  `ZomboidFixesB42.lua` loads before `ZomboidFixesB42_X.lua`, and `ZomboidFixesB42_AdminHotbar.lua` before
  `ZomboidFixesB42_AdminHotbarActions.lua`. `require "ZomboidFixesB42_AdminHotbar"` (path relative to the lua/client,
  shared or server folder) forces an order.
- Client Lua already loads at the main menu (`isClient()` false there) and reloads with the server's mods when joining
  multiplayer. `media/lua/server` also loads on clients and in single player (hence the `if isClient() then return end`
  guards); a dedicated server does not load `media/lua/client`.
- Pitfalls: `cond and nil or x` always gives `x` (write an if); a `string.gsub` replacement string treats `%` as special
  (escape user text with `gsub(s, "%%", "%%%%")`); `string.gsub` returns two values, so wrap it in parentheses when
  returning or concatenating at the end of a list; there is no `next()`; `gsub` with a function replacement works;
  vanilla never uses `string.byte/char`, so avoid them. `coroutine` (create/resume/yield/status/running) **is**
  available (`J2SEPlatform.newEnvironment` registers CoroutineLib; vanilla never uses it); there are no threads for Lua
  (one `KahluaThread` on the main thread), so long work is time-sliced with coroutines resumed from `OnTick`. A coroutine
  cannot yield from inside a Lua function that Java called (a `table.sort` comparator, an event handler it calls).
  A Java `BufferedReader` / `LuaFileWriter` stays usable across yields. Kahlua is slow at string work: one
  `string.match` with 10 captures per line parses about twice as fast as splitting with `gmatch` into a table
  (~2000 lines/s of a 10-field record at 8 ms per 100 ms tick on this Mac).
  A dedicated server with `PauseEmpty=true` (default) does not tick while nobody is online, so `OnTick` work waits.
  `tostring` of an integer-valued number gives "5", but
  `getText(key, n)` gives "5.0" — pass `string.format("%d", n)`. A literal `%` in a translation string must be
  written `%%` even when the key takes no arguments (vanilla: `"%% full"`): the Translator runs every string through
  Java's formatter at load and a lone `%` logs `UnknownFormatConversionException ... ERROR: Formatting "<key>"`. Escaped double quotes (`\"`) inside a
  translation string do not work in game; quote with single quotes instead.
- Server load from Lua: `getServerFPS()` is a constant 10; `getAverageFPS` / `getCPUTime` read `GameWindow` (client
  loop). `getPerformanceLocal()` (`PerformanceStatistic`) has `avg-update-period`, `max-update-period`, `min-update-period`
  (ms per server update), `fps`, memory counters, but the table is refilled only every `MultiplayerStatisticsPeriod`
  seconds (server option, default 1, 0 = never; `StatisticManager.update` from `GameServer` ~1146). Timing `OnTick` intervals with
  `getTimestampMs()` yourself always works (~100 ms per server update when healthy).
- Files: `getFileWriter(name, createIfNull, append)` / `getFileReader(name, createIfNull)` (nil if missing) read and
  write `Zomboid/Lua/<name>`. Server identity on a client: `getServerIP()`, `getServerPort()` ("" in single player);
  save name: `getWorld():getWorld()` (`getCurrentSaveName()` is the full save folder path).
- Keys: `Events.OnKeyPressed(key)`, `getKeyName(key)`; mod key binds via `PZAPI.ModOptions` (see below).
  `OnKeyPressed` fires when a key is **released** (`GameKeyboard.update`); `OnKeyStartPressed` when it goes down,
  `OnKeyKeepPressed` every frame while held (none of them while a text box has focus or a UI element takes the key).
  `isKeyDown(key)` and `isMouseButtonDown(0)` poll the current state.

## Mod conventions

- One feature = `client/ZomboidFixesB42_<Feature>.lua` + `server/ZomboidFixesB42_<Feature>.lua` (+ `shared/` if both need it).
  Each file opens with a long block comment explaining the vanilla bug and the Java behind it, then guards with
  `if isClient() then return end` (server files) / `if not isClient() then return end` (client-only MP files).
- Client/server commands go through `sendClientCommand(player, ZomboidFixesB42.MODULE, ZomboidFixesB42.CMD_*, args)`;
  command names are constants in `shared/ZomboidFixesB42.lua`. Each server file registers its own `Events.OnClientCommand`
  handler and ignores other commands.
- Server handlers always check the sender's capability (`player:getRole():hasCapability(Capability.X)`), clamp and
  validate every argument, and log admin actions with `print("[ZomboidFixesB42] ...")`.
- **Every** feature has its own sandbox option (`page = ZomboidFixesB42`) with a name and a long `_tooltip` in
  `Translate/EN/Sandbox.json`, read at run time as `SandboxVars.ZomboidFixesB42.<Option>` through a file-local `isEnabled()`.
  Client overrides fall back to vanilla when off; server handlers ignore (or refuse with a reply, if the client waits)
  commands when off. Every option defaults to **on** (opt out, not opt in); numeric ones default to a working value,
  not their "off" value. The few that default off (HideAdminTag, AdminSpawnProtection = 0) are marked
  "(off by default)" on their line in README/workshop/mod.info; non-obvious numeric defaults are stated there too. Beta ones are titled `[BETA] ...`. README/workshop/mod.info mark only `(beta)`, never "optional".
- `type = string` sandbox options work (text box in the sandbox screens, `CustomStringSandboxOption`, no length limit),
  but their `default` cannot contain a comma: `ScriptParser.readBlock` ends a value at every comma. Lists default to
  semicolons and the code accepts commas too (the value set in game is a quoted Lua string).
- Sandbox vars do not exist yet when a mod file loads. `IsoWorld.init` calls `SandboxOptions.load` (server/SP; a client
  already has the server's) before `GlobalModData.init`, which fires `OnInitGlobalModData` — so load-time work that depends
  on an option (e.g. item script `DoParam`) goes there. There is no Lua event for sandbox options changing mid-game;
  re-check on a timer (`EveryTenMinutes`) if a load-time change must follow the option. Recipe edits must wait for
  `OnLoadMapZones` (see "Item and recipe scripts at run time"). Leaving a game runs `ScriptManager.Reset` + `Load`
  without always reloading Lua, so a file-level "already applied" flag must be cleared at world load.
  UI strings go in `Translate/EN/IG_UI.json` as `IGUI_ZomboidFixesB42_*`.
- Every feature is listed in README.md, forum.txt (one post, the pinned Discussions thread: what it does + its sandbox
  option) and mod.info (`description=- ...`); keep all three in step. workshop.txt lists no features, only the intro and
  a pointer to that thread: Steam caps the Workshop description at 8000 characters, and a longer one fails the in-game
  upload with `Failed to update workshop item, result=8` (every upload from 2026-09-29 to 10-04 failed that way, so
  the server kept an old copy).

## Networking (Java)

- Packets are `INetworkPacket` classes annotated `@PacketSetting(requiredCapability=..., handlingType=...)`.
  `handlingType` bits: 1 = server handles, 2 = client handles, 4 = client while loading.
  `PacketTypes.PacketType.onServerPacket` drops a packet unless `PacketAuthorization.isAuthorized(connection, type)`
  (the sender's role must hold `requiredCapability`), then `parseServer` -> `isConsistent` -> anticheats -> `processServer`.
- A client moving its own player (Lua `setX/Y/Z`) is checked by the server's anti-cheats on the next PlayerPacket
  (Power, Speed, NoClip, + Player for the reliable one; any option but 4 = on, "log" included). `AntiCheatNoClip`
  (42.21) compares with `connection.releventPos` and refuses a move **up** a level without stairs, a sheet rope or a
  burnt-out square (straight up is 3D length exactly 1.0, under the "basement" branch's > 1.0; down always passes).
  `react` runs whatever the policy: `GameServer.sendTeleport` back to `releventPos`, packet dropped. Admins
  (`CantBeKickedByAnticheat`) are bounced without any log line. Only `sendTeleport` sets the 500 ms exemption, and
  no Lua path reaches it; `AntiCheat.isEnabled` reads the option live (`getServerOptions():getOptionByName(...)`
  `:setValue(4)`). `*_SewersClimbOut.lua` holds it off per climb. Speed is skipped for teleport-capable roles.
- `INetworkPacket.send(IsoPlayer, type, ...)` on the server goes to that player's own connection only;
  `INetworkPacket.send(type, ...)` on a client goes to the server.
- `GameServer.sendAddItemToContainer` / `sendAddItemsToContainer` / `sendRemoveItem(s)FromContainer` /
  `sendReplaceItemInContainer` (~2448): a container whose `getCharacter()` is a player (the main inventory, or any bag
  nested in it) goes to **that player only**; otherwise to clients near the container's parent object or world item.
  So the server can move an item from one player's inventory into another's with `DoRemoveItem` +
  `sendRemoveItemFromContainer` and `AddItem` + `sendAddItemToContainer` (TienGiveItemMP does).
- Sounds (42.21): on a client `character:playSound(name)` (`CharacterSoundEmitter.playSound` -> `FMODSoundEmitter.playSound`,
  same in pzopt's copy) plays locally **and sends a `PlaySoundPacket`** for that character (none for an invisible player),
  and `stopSound` / `stopOrTriggerSound` send a `StopSoundPacket` by sound name; the server relays both to the other
  connections near the character (70 tiles or the clip distance, never back to the sender), which play it with
  `playSoundImpl` / stop it with `stopOrTriggerSoundByName`. This holds for **any** character, a remote one included:
  a client calling `playSound` on another player's character makes every other nearby client, that player too, play it.
  Local only: `getEmitter():playSoundImpl(name, nil)` (0 for a remote invisible player), `stopSoundLocal(h)`,
  `stopOrTriggerSoundLocal(h)`. So `ISHandcraftAction` (craft and completion sounds via `playSound`) is heard by
  everyone, while `ISAddItemInRecipe` (`playSoundImpl`) is not; `*_CraftSounds.lua` relays only the ingredient sound
  and replays it with the local calls. Other clients also hear anim XML `PlaySound` events (every client animating the
  character runs them). Lua's `sendPlaySound(sound, loop, object)` is server only and goes to every relevant client,
  the owner included, with no handle to stop it. A remote player's action animation
  does sync: `BaseAction.setActionAnim` enters `PlayerActionsState` on a client, whose state params carry the action's
  anim variables captured at that moment (a variable set after `setActionAnim` is missed) and hand models;
  `IsPerformingAnAction` reaches remote copies through the `NetworkPlayerVariables` flag.

### Player stats are server-authoritative

`zombie/network/NetworkPlayerManager.java` runs on the server for every online player and pushes to the
**owning client only**:

| every | packets | contents |
|---|---|---|
| 0.5 s | PlayerHealth | health |
| 1 s | PlayerStats, PlayerEffects, PlayerXp | PlayerStats = `Stats.save` (all CharacterStats) + `Nutrition.save` + TimeSinceLastSmoke + `BodyDamage.saveMainFields` |
| 2 s | PlayerDamage, PlayerInjuries | body damage / wounds |

`BodyDamage.saveMainFields` = CatchACold, HasACold, ColdStrength, TimeToSneezeOrCough, ReduceFakeInfection,
HealthFromFoodTimer, painReduction, coldReduction, infectionTime, infectionMortalityDuration, ColdDamageStage.

Consequence: anything a client sets only on its own copy of a stat is overwritten by the server within a second.
Anything the **server** sets reaches the owning client by itself within a second.

Other packet contents: PlayerDamage = MaxWeight + CorpseSicknessRate + full `BodyDamage.save` (every body part incl.
infected/fake-infected flags, wetness, health, then main fields + thermoregulator). PlayerHealth = each body part's health.
PlayerEffects = sleeping-tablet/beta/depress/pain effects. PlayerXp (`XP.save`) = **traits**, total XP, per-perk XP
**and perk levels** — so trait and skill-level changes made on the server reach the owner within a second too.
NOT carried by anything: `BodyDamage.isInfected` (general flag), `isIsFakeInfected`, `isIsOnFire` — server-only state.

The client does not simulate its own body: `BodyDamage.Update` (~2097) returns immediately on a client for the local
alive player, and for **remote** players it calls `RestoreToFullHealth()` every update. So another player's
stats/body/nutrition on an admin's client are fake (full health, default stats). **The vanilla Player Stats
("Check Stats") window is therefore not accurate for other players** (weight etc. are stale/default). Anything that
shows another player's live values must ask the server.

Zombie attacks on players and clothing wear (42.21): `BodyDamage.AddRandomDamageFromZombie` (~1251) runs on the client
that owns the zombie (`AttackState` "AttackCollisionCheck"; remote zombies run `AttackNetworkState`). Its outcomes:
thump (`Rand.Next(100) <= baseChance`, no wound) and blocked (`Rand.Next(100) < getBodyPartClothingDefense`) call
`addHoleFromZombieAttacks` and send nothing; only a wound that gets through sends `ZombieHitPlayerPacket`, and the server
rolls the whole attack again (`Bite.process`). Condition loss (`BloodClothingType.setConditionAndSync`: hole =
`getCondLossPerHole`, `CanHaveHoles = false` armor 1 in `ConditionLowerChanceOneIn`) does nothing on a client, so in
MP blocked hits never wear clothing (100-defense armor never breaks). Defense stays full until condition 0. Lua sees
each hole attempt as a synchronous `OnClothingUpdated` (from `IsoGameCharacter.addHole`), with no part; the zombie's
`AttackDidDamage` is true for a thump too. `SyncVisualsPacket` (client `player:syncVisuals()`, reliability 3, ordering 0)
carries every worn item's holes **and condition** and the server applies them (`setConditionNoSound`); after each hit
it rolls, the server sends its own copy back the same way (`GameServer.syncVisuals`), overwriting the owner's.
Worn lists: `setWornItem` / `removeWornItem` send `SyncClothing` themselves (server: to everyone, with SyncVisuals;
client: to the server). `SyncClothingPacket.process` (both sides) unwears every worn item not listed and, for a listed one
neither worn nor in the inventory, `CreateItem(type)` + `setID` and wears it outside any container, copying tint and
texture **only for remote players**: the owner's copy has the script's default look (a white scarf for a green one) and
is never saved. A client's `ItemContainer.Remove` (RemoveInventoryItemFromContainer) does not unwear. So a SyncClothing
from the client crossing the server's Unwear of an item it broke (a hit rolled on the server) leaves such a copy on both
sides with the real item's ID while the real item lies on the floor. `ItemContainer.AddItem` refuses an ID the
container already has (`Error, container already has id`), as does the client's AddInventoryItemToContainer (`Dupe item ID`).

Client commands: `ClientCommand` packet is priority 1, reliability 2 = RakNet RELIABLE (**not ordered**), capability
LoginOnServer. `PacketsCache.isLimitExceeded`: a client silently drops (cancels) packets of one type beyond
`MaxPacketsPerSecond` (server option, default 300) per second. `TableNetworkUtils` serialises string, double, boolean,
nested table (plus item, direction, dead body) keys/values; anything else is skipped.
Packet ordering: `SyncItemFieldsPacket` and `SyncHandWeaponFieldsPacket` are reliability 2 (RELIABLE, **unordered**),
`NetTimedActionPacket` is 3 (RELIABLE_ORDERED), so a server-run timed action's Done can reach the client before the item
and weapon syncs the server sent just before it. Vanilla firearm actions change items only when `not isClient()`
(`ISInsertMagazine:loadAmmo`, `ISEjectMagazine:unloadAmmo`, `ISLoadBulletsInMagazine` InsertBullet), and the next
queued action begins in the same call that handles the Done, so client code planning from the inventory right after
such an action can see the state from before it (TienMagazineBag's `ContinueReload` waits for it). A synced HandWeapon
is updated in place (`getItemWithID` then setters: count, chambered, containsClip, spent rounds, jammed, parts, modData).
`ISInsertMagazine:perform` on an MP client queues an `ISRackFirearm` whenever the client's copy shows no chambered
round and at least `getAmmoPerShoot()` rounds; for a gun with `HaveChamber = false` (revolvers) `canRack` is true, and
`rackBullet` gives one round back. Whether it is queued depends on that sync having arrived.
`sendClientCommand(player, ...)` in single player goes to `SinglePlayerClient` (OnClientCommand fires), but
`sendServerCommand` does nothing outside a server — so a request/reply feature needs its own single-player path.
Server-side Lua has no `getPlayerFromUsername` (it is client-only, `GameClient.instance`); walk `getOnlinePlayers()`.
`getPlayerByOnlineID` works on both. `writeLog(loggerName, text)` writes to the server's `<date>_<logger>.txt`
(`/addxp` etc. use the "admin" logger).

### Stat sync functions available to Lua (`zombie/Lua/LuaManager.java` ~11840)

- `syncBodyPart(bodyPart, mask)` — server only, sends BodyPartSync to the part's owner.
- `syncPlayerStats(player, mask)` — server only, sends SyncPlayerStatsPacket to that player (requires `isExistInTheWorld()`).
  `mask` = bits over `CharacterStat.ORDERED_STATS`; `-1` means "the whole Nutrition instead".
- `sendPlayerStat(player, CharacterStat)` / `sendPlayerNutrition(player)` — client only, silently do nothing unless the
  local role has `Capability.CanModifyBodyStats`. Send SyncPlayerStatsPacket to the server.
- `SyncPlayerStatsPacket` (`requiredCapability = CanModifyBodyStats`, handlingType 3): on the server it just loads the
  values into the addressed player (the PlayerID in the packet — not necessarily the sender) and does nothing else:
  no reply, no relay.

### CharacterStat (`zombie/characters/CharacterStat.java`), id / min / max / default

ORDERED_STATS order (bit index for SyncPlayerStatsPacket): Anger 0–1 (0), Boredom 0–100 (0), Discomfort 0–100 (0),
Endurance 0–1 (1), Fatigue 0–1 (0), Fitness -1–1 (0), FoodSickness 0–100 (0), Hunger 0–1 (0), Idleness 0–1 (0),
Intoxication 0–100 (0), Morale 0–1 (1), NicotineWithdrawal 0–0.51 (0), Pain 0–100 (0), Panic 0–100 (0),
Poison 0–100 (0), Sanity 0–1 (1), Sickness 0–1 (0), Stress 0–1 (0), Temperature 20–40 (37), Thirst 0–1 (0),
Unhappiness 0–100 (0), Wetness 0–100 (0), ZombieFever 0–100 (0), ZombieInfection 0–100 (0).
Lua: `player:getStats():get(CharacterStat.X)` / `:set(CharacterStat.X, v)` (`set` clamps to min/max).

### What overrides each stat on the server (so a plain `set` may not stick)

- **Fitness**: `IsoGameCharacter.calculateStats -> updateFitness` sets it from the Fitness skill level every tick
  (`level / 5 - 1`). Change the level instead: `setPerkLevelDebug(Perks.Fitness, l)` + `getXp():setXPToLevel(Perks.Fitness, l)`,
  then fire `LevelPerk` so `XpUpdate.levelPerk` swaps Unfit/Out of Shape/Fit/Athletic. `XP.AddXP` is unreliable for
  admins: it does nothing while asleep, and for Fitness when `Nutrition.canAddFitnessXp()` is false (weight trouble).
- **Pain**: `BodyDamage.Update` (~2340) sets it to the body parts' pain minus painReduction whenever it is above that
  (it only creeps up slowly when below). Vanilla's panel says "pain and sickness cannot be adjusted manually".
- **Sickness**: nothing writes it any more (only read by the thermoregulator and moodles) — a set sticks.
- **Temperature**: `Thermoregulator.updateHeatDeltas` (~843) lerps the core temperature halfway to the stat each update,
  then writes the stat back — a set converges and then drifts naturally.
- **Wetness**: `BodyDamage.UpdateWetness` (~780) sets stat and every body part to `avg(parts) + (stat - avg) * 0.1`,
  so setting only the stat loses 90% immediately. Set every body part's wetness too.
- **Discomfort**: lerped slowly towards a target from clothing/bed/moodles (~3195); a set sticks and drifts.
- **ZombieInfection**: while `BodyDamage.isInfected()`, recomputed as
  `(hoursSurvived - infectionTime) / infectionMortalityDuration * 100` (mortality 1 = instant 100, 7 = never).
  Move `infectionTime` to change it; it must stay >= 0 (`GameTime.checkHours` treats negative as "now").
  `BodyDamage.Update` also re-sets `isInfected` from any infected body part every tick.
- **Morale** only moves while stressed (vanilla panel note). **Fatigue** is reset on the server when sleep is not
  allowed/needed (`calculateStats`).

### Other body setters

- `BodyDamage.setIsOnFire` is only a flag used to decide "burnt to death"; really setting someone on fire is
  `IsoGameCharacter.SetOnFire()` / `StopBurning()`.
- `setIsFakeInfected(b)` sets the flag and only body part 0's fake infection.
- `RestoreToFullHealth` clears infection with setInfected(false), setIsFakeInfected(false), setInfectionTime(-1),
  setInfectionMortalityDuration(-1), plus every body part.
- `AddGeneralHealth(v)` spreads v over damaged parts only; `ReduceGeneralHealth(v)` over all parts; then
  `calculateOverallHealth()`.
- `Nutrition.setWeight(w)` with w < 35 clamps to 35 **and damages the character** every call. Weight traits
  (Emaciated/Very Underweight/Underweight/Overweight/Obese) are only re-applied by `applyTraitFromWeight` every 2000
  nutrition updates, server side. Nutrition setters clamp: carbs/lipids/proteins -500..1000, calories -2200..3700.
- `setTimeSinceLastSmoke` clamps 0..10. `BodyPart.setWetness` clamps 0..100.
- `IsoPlayer.setGhostMode` just calls `setInvisible` in this build. God mode / invisibility for another player only
  replicate through `GameServer.sendPlayerExtraInfo` (not Lua-callable on the server; the Lua global
  `sendPlayerExtraInfo` is client-only), i.e. the chat commands `/godmodplayer "user" -true|-false` and
  `/invisibleplayer "user" -true|-false` (the latter also sets ghost mode).
- Setting another player's skill level from a client, vanilla style: `/addxp "user" Perk=amount -false`
  (`AddXPCommand`, needs Capability.AddXP; negative amounts lower the level).

### Time speed and timed actions in multiplayer

- **Paramount: fast forward starting mid-action must keep working.** The speed buttons and keys vote the moment they
  are pressed, so fast forward can start, change speed or stop in the middle of any action, and other players' votes
  can start it in the middle of yours. Every path that follows the speed has to keep handling an action already under
  way (running actions retimed with `netAction:setDuration`, anim events and cooking catching up, transfers speeding up
  from their next batch). Auto fast forward holds its vote back only during `AutoFastForwardFinishFirstActions`
  (item moves by default, cast when the item on its way arrives); that is never a reason to drop or weaken mid-action
  support.
- `ISBaseTimedAction.begin` = `create()` + `character:StartAction`, and Java then calls the table's `waitToStart`
  (`rawget`, so a field on the instance wins over the class) every update until it returns false, then `start()`. An
  action not started yet never `hasStalled`, so holding it is safe. Many vanilla `waitToStart`s turn the character to
  the target (`faceThisObject` / `shouldBeTurning`). `ISTimedActionQueue:onCompleted` begins the next action in the
  same call, so a queue of actions has no idle tick between them; a walk (`ISWalkToTimedAction`) ends in the
  character's update with `isPlayerMoving()` still set for that frame. `isItemTransactionDone(0)` is true (id 0 = no
  transaction), so a transfer batch held back from opening must keep vanilla's `update` from polling it.
- `GameTime.getMultiplier()` = `multiplier` (what `setMultiplier` sets) × fpsMultiplier (server: 60 / FPS, it runs at
  10) × bias × perObjectMultiplier × 0.8; the server's clock advances by it and reaches clients by `SyncClockPacket`
  every 10 s. Only `IsoPlayer`'s zombie-within-4-tiles check (runs on the server too) and `SpeedControls` reset it.
  The dedicated server runs `IngameState.update`, so `Events.OnTick` fires there.
- Timed actions run **on the server** (`zombie/core/NetTimedAction`, `ActionManager`): at start
  `endTime = serverTimeMs + adjustMaxTime(getDuration()) * 20`, real milliseconds, **no multiplier**; completed when
  `getServerTimeMills()` passes it, then a Done packet ends the client's copy. The server calls `adjustMaxTime` only
  there (the table is built with `Type.new(args)` and gets `netAction` = the Java action; `create()` is client side).
  PZ's `KahluaTableImpl.rawget` falls back to the metatable, so class methods are found. `netAction:setDuration(ms)`
  moves a running action's end (`endTime = startTime + ms`).
- Items on a server update only every 5 real s (`IsoCell` ProcessItems) with a real-time step
  (`InventoryItem.calculateTimeMultiplier`), so heat and cooking ignore the multiplier; `getCell():getProcessItems()` is
  public, and `*_FastForwardCooking.lua` pays the missing heat and cooking steps. Item transfers are timed by Java
  `Transaction.getDuration` (real ms, `TransactionManager` not exposed to Lua), so during fast forward each batch is
  sent as a server-timed move instead (`createItemTransaction` wrapped in `*_Transfer.lua`, `*_FastForwardTransfer.lua`).
- A transfer action is a queue of batches (`checkQueueList`: same full type and weight <= 0.1 up to 20 per batch, else one
  item), each its own transaction opened in `start`/`perform`, so fast forward applies from the next batch. The batch
  already running when it starts ends at normal speed; its bar advances by the client's `GameTime.getMultiplier()`
  (`BaseAction.update`), so it fills early and waits on `setWaitForFinished`. Transaction ids are numbered by each client
  (`Transaction.lastId`, a byte), and the server handles a cancel (Reject) with `removeIf(id == id)` over every player's
  transactions, so one player's cancelled transfer can drop another's with the same id.
- How a transaction fails (42.21, `zombie/core/TransactionManager`, `Transaction`, `ItemTransactionPacket`): the server
  checks `isConsistent` only on Request (Reject packet if it fails), then at `endTime` runs `Transaction.update` →
  `updateItem` per entry. If that returns false or throws (`"transaction.update() threw. Rejecting transaction"` in the
  server log), the state becomes Reject **and nothing is sent**; entries already moved stay moved. The client's copy is
  dropped by its own timeout (reported duration + 10 s, or 20 s with none), after which `isItemTransactionDone(id)` is true
  (`allMatch` on an empty stream), so `ISInventoryTransferAction` "completes" having changed nothing. A floor item is
  addressed by **item ID** (`ContainerID` WorldObject, `findObject` walks the square's world objects); if the server has
  no such item, `isConsistent` still accepts (source null, itemId -1 skips every check), the server logs
  `ERROR: sendItemsToContainer: can't find world item with id=N` and `updateItem` returns false later. So a ghost floor
  item (on the client only) gives a bar that hangs ~10-20 s, then nothing; it stays on the client's floor until the chunk
  reloads. On success the server sends `RemoveItemFromSquare` (`GameServer.RemoveItemFromMap`, to clients relevant to the
  square) addressed by **object index** on the square, not item ID (`RemoveItemFromSquarePacket.processClient` removes
  whatever the client has at that index, or nothing if out of range), then `AddInventoryItemToContainer` to the owner
  (skipped with `Error: Dupe item ID` if the client already has that ID there; a bag destination is found by the bag's ID,
  `can't find inventory container` if not), then Done. A client whose object list on that square differs from the
  server's removes the wrong object or none, which is one way ghost floor items are born.
- Transaction globals from Lua (`LuaManager$GlobalObject` ~9650): `isItemTransactionDone(id)` / `isItemTransactionRejected(id)`
  are `allMatch` over the client's entries with that id, so **both are true for an id no longer in the list** (timed out,
  or removed): both = gone, rejected only = Reject packet, done only = Done packet, neither = waiting. Id 0 reads done and
  rejected. `getItemTransactionDuration(id)` = ms / 20 in integer division, so it is 0 both before the Accept and for an
  absent id (Java's -1 / 20). `removeItemTransaction(id, false)` drops the client's entry without telling the server.
  The client entry's clock starts at `createItemTransaction`; the Accept sets its duration (`setStateFromPacket`).
- `ISGrabItemAction` (right-click Grab, forage icons) never waits on the server: no `setWaitForFinished`, `maxTime`
  becomes the server's duration, and perform -> `transferItem` drops the transaction and ends, whatever the server did.
  Its transaction is created with `nil` items and an `"object"` source container whose parent is the world item.
- The fast transfer path (`*_Transfer.lua` / `*_Server.lua`, Fast Timed Actions cheat and fast forward's timed
  batches) used to decline floor items outside the 3x3 around the **server's** position of the player (trails the
  client's while walking) and to check the main inventory's weight, which vanilla's server never does; a declined item
  was dropped from the batch, so the transfer silently did nothing while vanilla (cheat off) worked. Its `start` also
  opened a vanilla transaction and cancelled it at once, i.e. sent a Reject per batch (see the removeIf note above).
- 37 vanilla actions work on `emulateAnimEvent(netAction, periodMs, event)` (Java `AnimEventEmulator`, real-time period,
  not exposed): milking, shearing, reading, fitness, drinking, fluids, reloading... `*_FastForwardAnimEvents.lua` fires
  (speed - 1) extra `netAction:animEvent` per period, stopping on the table's `complete`/`serverStop` or `getProgress() >= 1`.
  `emulateAnimEventOnce` (magazine eject/insert, racking, petting) is fired early on the game clock and the action's own
  `animEvent` wrapper swallows Java's later copy. Every reloading action has `getDuration() -1`: it ends on its events only.
- Reload timing (42.21): the reload actions' `serverStart` fire their events every `getReloadTime(chr, BASE) = BASE /
  ReloadSpeed` ms; the client clip plays at the same `ReloadSpeed` (`m_SpeedScale`), but BASE is hand-written: shell 833 vs
  `Bob_Reload_Shotgun_Load` 700, revolver 950 vs 767, lever 1000 vs 700, bolt no mag 590 vs 700, double barrel 2500 / sawn
  1000 vs 2133, rifle mag insert 1500 vs 1733, eject 1200 vs 1500 / 1733 (load clip reversed), shotgun rack 600 vs 1400
  (aimed 767), other racks 1200 vs 1333 handgun / 1767 bolt (aimed 1667) / 1133 lever (aimed 1200). Finishing events are at
  `End` (Rack*/Unload* nodes `x_extends` the Load* node and override its event by `x_name`). Clip length = (last key -
  first key) / AnimTicksPerSecond (4800) in `media/anims_X/Bob/<clip>.X`. `*_ReloadTiming.lua` answers `getReloadTime`
  with the clip length while a reload `serverStart` runs. Gunworks (mod id SWMG) times its profiled guns with
  `ReloadAnim.getActionDurationMs` (`require "WeaponSystems/Utils/ReloadAnim"`, `GetHandlerForGun(gun)`).

### Vehicle parts and batteries

- `VehicleParts.update()` runs the parts' Lua `update` functions only where the vehicle is simulated (nothing on a
  client); `updatePart` calls one only once a whole game minute has passed since its `lastUpdated`, with
  `elapsedMinutes` = game minutes since (so ~1.0x while loaded). A vehicle whose parts need no update still runs
  `drainBatteryUpdateHack` (engine off: lit lights, turned-on radios, active lightbar/siren).
- `DrainableComboItem` stores whole uses: `setUsedDelta(v)` = `setCurrentUsesFloat` clamps 0..1 and rounds
  `v / useDelta`; `getCurrentUsesFloat() = uses * useDelta`. Car batteries have `UseDelta = 0.00001`, so a 2.5-use
  change rounds to 2 or 3 — carry the remainder when drains are small.
- Every battery drain goes through `VehicleUtils.chargeBattery(vehicle, delta)` (`server/Vehicles/Vehicles.lua`
  ~1306 in 42.21): headlights (each lit headlight part) / radio / lightbar / siren -0.000025 a minute with the engine
  off, heater -0.000035 while running. Vanilla adds `delta` twice (fixed by `*_VehicleBattery.lua`). Engine charging
  (+0.001 a minute) is in `Vehicles.Update.Battery` and does not use it. Charge reaches clients through
  `vehicle:transmitPartUsedDelta(part)`, sent when `VehicleUtils.compareFloats(old, new, 2)` (2 decimals, or
  crossing 0 / 1).

### Animals, hutches and animal zones in multiplayer

- Hutch state runs on the server only (`IsoHutch.isOwner()` = `!GameClient.client`). `IsoHutch.update` syncs the whole
  hutch (doors, dirt, every nest box's eggs) every 3.5 s (`sendUpdate`), so a client's nest box eggs are overwritten
  within seconds. Animals in a hutch travel in AnimalPacket (`location` 1, `hutchNestBox`, `hutchPosition`).
- `DesignationZone.update()` (from `IsoWorld.update`, every 2.5 s real time) runs **on clients too**: `checkStreamed`
  flips `streamed` from the zone's two corner squares and, on coming back, calls `doMeta(hours away)`. On a client
  `DesignationZoneAnimal.doMeta` replays those hours on its own copy of the loose animals (`updateStatsAway`): hens lay
  ground eggs, feathers drop, ground food is eaten, all local and never sent. `streamed`/`hourLastSeen` have no setter
  (`getClassFieldVal` reads them only with `-debug`), so Lua can only repair afterwards. Hutched hens are not in
  the zone's animal list and are not affected.
- A client world item keeps the server's item ID (chunk data and AddItemToMap serialise it), and
  `IsoGridSquare.removeWorldObject` is local only, so a client can drop an item the server does not have by ID.

### Entities, meta storage and chunk saves (42.21)

- Components (`zombie/entity/ComponentType.java`) with flag 2 "run in meta": FluidContainer, CraftLogic, FurnaceLogic,
  MashingLogic, DryingLogic, DryingCraftLogic, Resources. On chunk unload `IsoChunk.removeFromWorld` calls
  `removeFromWorldToMeta` on every square object (world items included) and `GameEntityManager.UnregisterEntity` moves
  **all** of an IsoObject's components into a `MetaEntity` if one of them qualifies (FluidContainer only while
  `getRainCatcher() > 0`, the others always), leaving a `MetaTagComponent(storedID)`. MetaEntities are saved only in
  `<save>/entity_data.bin` (`GameEntityManager.Save`, truncate-then-write, not under `IsoChunk.WriteLock`). Vanilla
  entities that go to meta: RainCollector(_Tarp), RainCollectorRound(_Tarp), Amphora, Well, every drying rack; plus
  every world item whose item script's FluidContainer has `RainFactor` (buckets, pots, bowls, mugs...).
- `RegisterEntity` (on `addToWorld`) removes the MetaTag and moves the MetaEntity's components back; if the ID is not
  found it returns and the object has **no components** (saved like that for good). It sets `requiresHotSave` on the
  chunk, but `ServerMap.ServerCell.update` only hot-saves when `!GameServer.server`: a dedicated server writes a loaded
  chunk only on unload or a full save (`SaveWorldEveryMinutes` default 0), while any unload of another chunk with a
  MetaTag object rewrites entity_data.bin (`IsoGridSquare.save` sets `needSave`, saved within 1 s by
  `ServerMap.preupdate`). Crash/kill/backup copy in between = lost entity. A chunk written with the components while
  entity_data.bin still holds its MetaEntity makes `RegisterEntity` find the stale one and return early: the object is
  never added to the engine, the stale MetaEntity lives forever. Giving the object a MetaTag with its own
  `getEntityNetID()` and calling `addToWorld` again adopts and drops the stale one.
- IsoObject entity net ID = x + y<<16 + z<<32 + objectIndex<<40 (floors index 0). `isAddedToEngine()` is set
  synchronously. Lua: `GameEntityFactory.CreateIsoObjectEntity(obj, script, true)` (throws if it already has
  components), `AddComponent(e, true, c)`, `TransferComponent`, `RemoveComponentType`;
  `ComponentType.X:CreateComponent()` / `:CreateComponentFromScript(script)`; entity script of a sprite:
  `SpriteConfigManager.GetObjectInfoList()` → `info:getScript()` (`getAllTileNames()`, `getParent()` = GameEntityScript;
  `getObjectInfoFromSprite` is a linear search).
- Client sync: `obj:sendSyncEntity(nil)` (server, all components) only reaches client copies **registered** by entity
  net ID, i.e. that had components when added (a MetaTag copy from a disk-served chunk counts, and requests a sync
  itself); `obj:sync()` (SyncIsoObject, by square + index) creates a missing FluidContainer on the client. Loaded
  chunks are served to clients from server memory (`PlayerDownloadServer`, `chunk.loaded`), others from disk.
- `IsoChunk:Save(true)` from Lua writes a loaded chunk on the main thread under `IsoChunk.WriteLock`, which
  `ZipBackup` holds for a whole backup (periodic backups run on a thread; startup/version ones before the world loads);
  vanilla never saves on the main thread during a backup (`QueuedSaveAll` waits for `!ZipBackup.isRunning()`).
- `MapObjects.OnLoadWithSprite(names, fn, priority)` runs per object after `addToWorld`, dispatched in Java by sprite
  name; one callback per sprite **and priority** (same priority replaces), higher first; vanilla uses 5.
  `SpriteConfigManager` is filled by `ScriptManager.PostTileDefinitions` in `IsoWorld.init`, right before
  `OnLoadedTileDefinitions`; server Lua loads earlier (`GameServer.doMinimumInit`). `LoadChunk(chunk)` fires at the end
  of `doLoadGridsquare` (server too); `chunk:getGridSquare(x, y, z)` takes chunk-local x, y and a world z.
- `getCell():getVehicles()` is a **Set** in 42.21 (vanilla `ISVehicleBloodUI` still calls `:get`); copy it with
  `ArrayList.new()` + `addAll`. `sendReplaceItemInContainer(container, item, item)` re-sends an item (same ID) to the
  owner or players near the container; the client removes by ID and adds the parsed copy (hand/hotbar keep the old one).
- Dead bodies have a persistent ID: `IsoDeadBody:getObjectIDAsLong()` (`zombie/network/id/ObjectID`, type DeadBody,
  a short, "permanent": written in `IsoDeadBody.save`, so in the chunk data clients get, and the type's last ID is
  saved by `ObjectIDManager`). Allocated only on the server / single player (`addObject` returns early on a client
  for -1), so a client copy can read -1 until the server's ID arrives (vanilla `ISButcherAnimal` checks for it).
  Wraps at 65536, skipping IDs of loaded bodies only. Better than the index in `square:getDeadBodys()`, which shifts.
- IsoObject/IsoThumpable/IsoWorldInventoryObject `addToWorld` can run twice on a server (process lists are sets or
  checked); the classes in `zombie/iso/objects` with their own override (stoves, doors, generators...) may not.

### Map files (42.20)

B42 map formats (lotheader, lotpack, chunkdata with its undocumented type 5 / bit 32, biome PNGs, worldmap.xml), where
they differ from the game's own converter `zombie/pot/POT*`, and how worldgen fills squares a lot leaves empty: see
`~/Zomboid/Workshop/NagaCity/CLAUDE.md`, whose `tools/pzmap` reads and writes them byte-identical to vanilla.
A mod's map folder must be in `common/media/maps/`: `MapGroups.createGroups` only looks in the version folder's
`media/maps/` when `common/media/maps/` exists, so a map only under `42/` is silently ignored.
Street names: each lot directory's `media/maps/<dir>/streets.xml` (`zombie/worldMap/streets/WorldMapStreetsXML`:
`<streets version="1"><street name="..." width="n"><points><point x="" y=""/>`, float world coordinates, name required)
is drawn as street labels on the world map (`ISMapDefinitions` `MapUtils.initDefaultStreetData`) and registered as
"Nav" zones (`IsoWorld.registerNavZones` from `metazoneHandler` on `OnLoadMapZones`; rects for straight pieces,
polyline zones for diagonal runs, `width` wide; names containing a railroad word are skipped), which randomized
vehicle stories and road foraging use. Vanilla, Raven Creek and NagaCity ship one.

### Item and recipe scripts at run time (42.21)

- Order in `IsoWorld.init`: `SandboxOptions.load` → `OnInitGlobalModData` → `WorldDictionary.init` +
  `ScriptManager.PostWorldDictionaryInit` (every craftRecipe resolves its inputs and output mappers here) →
  `OnLoadMapZones` (fires on client, server and SP) → `OnLoadedMapZones`. `ItemTags.Init` (tag → items map, not exposed)
  runs when the item scripts load, before any Lua. Scripts are reset and reloaded on leaving a game.
- `Item.DoParam(param, value)` (two-arg form is public; empty value clears a string property). Replaces: Weight,
  ReplaceOnUse, ClothingItemExtra, BloodLocation, MountOn, CombatSpeedModifier, sounds, SpawnWith. Appends: Tags. Read
  live from the script: ClothingItemExtra, SpawnWith (`ItemPickerJava`), BloodLocation (covered parts), HandWeapon
  sounds, Food weight (scaled). Copied into the instance at `InstanceItem` and **not saved**: clothing combat speed /
  condition chance / chance to fall, container sounds, WeaponPart MountOn, food ReplaceOnUse, item weight (saved only
  when custom). Saved per instance: food nutrition (calories, carbs, lipids, proteins, base hunger).
- Tag caches: `ItemTags.tagItemMap` (read only by `InputScript.OnPostWorldDictionaryInit`); each tags[...] input's
  `itemScriptCache` = `input:getPossibleInputItems()` (mutable ArrayList; `CraftRecipeManager` matches with
  `input.containsItem`); `ScriptManager.getItemsTag(tag)` (lazy, mutable list); `Item.getUsedInRecipes()`. Per-item input
  amounts (`25:Base.X`) live in private `items`/`amounts` lists: no Lua way to change them. `ItemTag.get(ResourceLocation.of("base:x"))`.
- `OutputMapper.getOutputItem` takes the first entry whose pattern items each match the most recent item of a distinct
  registered input (inputs written `mappers[name]`); `registerInputScript` and `getEntrees()` (mutable) are public;
  `OutputEntree` fields are not readable from Lua. Build a resolved entry in `OutputMapper.new(name)` +
  `addOutputEntree(result, ArrayList)` + `OnPostWorldDictionaryInit()` (no recipe name = no side effects) and move it.
  Mapper syntax `Result = A;B` (every item must match). Get a recipe's mapper from `output:getOutputMapper()`.
- `CraftRecipe:Load(name, "craftRecipe X { OnCreate = Fn, }")` on a loaded recipe sets that key (blocks would be
  appended). OnCreate is looked up by name at every craft (`CraftRecipeData.initLuaFunctions`), called with
  `(craftRecipeData, character)` from `ISHandcraftAction:performRecipe` (server / SP only) after the outputs were added
  with `Actions.addOrDropItem`; performRecipe then stores, for a single result, `modData[consumedFullType] = count`
  of every consumed (non-keep) item — e.g. `modData["Base.ClayBowl"]`.
- `Fixing` (repairs): `ScriptManager.instance:getFixing("Base.Fix X")`, `getRequiredItem()` (mutable list of full types,
  what `FixingManager.getFixes` matches), `getFixers()` (mutable LinkedList); a Fixer comes from
  `Fixing.new():Load(name, "fixing n { Fixer = Base.X; Aiming=2, }")`.
- Food weight: `Food.getActualWeight` = script weight × (hunger / script HungerChange) (with ReplaceOnUse: the empty
  item's weight plus the rest scaled), so portions from very filling food get heavy — engine, not data.
- In 42.21 `HandWeapon.getAimingMod()` returns 1.0 and `IsoPlayer.IsUsingAimHandWeapon` is never called: the item script
  `AimingMod` / `IsAimedHandWeapon` do nothing. A weapon part on a model with no matching attachment point is drawn at the
  gun's origin (`AnimatedModel.transformToParent`).

### Hands, hand models and attacks (42.20)

- Primary = **right** hand: `getPrimaryHandItem()` returns a field named `leftHandItem` (`IsoGameCharacter` ~3205), but its
  model goes on `Bip01_Prop1`, which `IsoPlayer.onAnimPlayerCreated` reparents to `Bip01_R_Hand`; secondary =
  `rightHandItem` field, `Bip01_Prop2`, left hand.
- Attacks only use the primary item: `SwipeStatePlayer.doAttack` (~130) sets `useHandWeapon` to `getPrimaryHandItem()` or
  `bareHands`; a weapon in the secondary hand alone never swings.
- `WeaponType.getWeaponType`: a one-handed melee weapon stays `1handed` (or `knife` / `heavy` / `throwing` by SwingAnim)
  even when it is in both hands; only `inv1 == inv2 && isTwoHandWeapon()` gives `2handed`.
- Hand models (`ModelManager` ~640): `isHideWeaponModel` hides both, `isHideEquippedHandR` drops the primary,
  `isHideEquippedHandL` the secondary (both are animation variables `hideEquippedHandR/L` too, so anim events may reset
  them; Lua setters exist). The secondary is drawn only when it is not the primary item, so the same item in both hands
  with `setHideEquippedHandR(true)` is drawn **in the left hand** while Java attacks with it as primary. A timed action's
  `overrideHandModels` replaces both; `chr.overridePrimary/SecondaryHandModel` are public fields with no setter (not
  reachable from Lua).

## Roles and capabilities

`zombie/characters/Capability.java` is the full list. Default roles (`zombie/characters/Roles.java` ~358–490):
`admin` has every capability; `moderator` has every one except UseMovablesCheat, SaveWorld, QuitWorld,
ChangeAndReloadServerOptions, ReloadLuaFiles, BypassLuaChecksum, RolesWrite, ConnectWithDebug; `gm` and `observer`
have hand-picked lists (observer: god/invisible/noclip himself, CanSeePlayersStats, UseDebugContextMenu, ...).
Body-stat editing belongs to `Capability.CanModifyBodyStats` (admin and moderator by default); its vanilla tooltip says
"Use the Body section of General Debuggers in the Debug Menu panel."

## Debug menu and admin UI (Lua)

- `client/DebugUIs/DebugMenu/ISDebugMenu.lua`: `ISDebugMenu.OnOpenPanel` only opens with `getCore():getDebug()`
  (the `-debug` launch flag) or `ISDebugMenu.forceEnable`. So without `-debug` an admin never sees General Debuggers.
- `client/DebugUIs/DebugMenu/General/ISStatsAndBody.lua` is the Body panel. It edits `getPlayer()` only, sliders
  write the local copy and then call `sendPlayerStat` / `sendPlayerNutrition`. Everything else it edits
  (HealthFromFoodTimer, TimeSinceLastSmoke, ColdDamageStage, OverallBodyHealth, ColdStrength, the Fitness perk level,
  the IsInfected / IsFakeInfected / IsOnFire / Ghost / GodMod / Invisible tick boxes) is local only and is reverted
  by the server's 1 s sync, or never reaches the server at all.
- `client/ISUI/AdminPanel/ISAdminPanelUI.lua`: the admin panel. Buttons are created in `create()` then sorted.
- `client/ISUI/PlayerStats/ISPlayerStatsUI.lua`: "Player Stats" window, `ISPlayerStatsUI:new(x, y, w, h, playerChecked, admin)`.
  Opened from the admin panel (self), from the scoreboard "Check Stats" (`ISMiniScoreboardUI`, needs CanSeePlayersStats,
  target from `getPlayerFromUsername`, nil if the client has never seen that player) and from the world context menu
  (`ISWorldObjectContextMenu.onCheckStats`). Edit buttons need `CanModifyPlayerStatsInThePlayerStatsUI`.
- Vanilla `server/ClientCommands.lua` `Commands.player.setWeight` sets another player's weight by online ID with **no
  access check at all** (any client can call it).
- All of `media/lua/client` loads without `-debug`, including `DebugUIs/` (ISDebugUtils, ISDebugSubPanelBase,
  ISSliderPanel in `RadioCom/ISUIRadio/`), so debug UI building blocks can be reused in normal windows.
- `ISSliderPanel:setCurrentValue(v, ignoreOnChange)` rounds to the step, clamps, and fires `onValueChange(target, v, slider)`
  unless ignored; it does nothing while `slider.disabled`. It fires on every mouse move while dragging (`dragInside`).
  Vanilla's panel writes `slider.currentValue` directly in prerender to display without firing.
- `ISTickBox` callback: `method(target, index, selected, arg1, arg2, tickBox)`, called after `selected[index]` flips;
  clicks are ignored while `tickBox.enable` is false. Add it to its parent before `addOption`.
- `ISAdminPanelUI:create()` lays out every child it has at the end, sorted by title into two columns, then adds Close.
  A child added before calling the original `create` is laid out with the rest.
- `ISMiniScoreboardUI:doPlayerListContextMenu(player, x, y)` builds its menu from `ISContextMenu.get` and does not return it;
  `player` is a plain table with `username`.
- `ISPlayerStatsUI:render()` positions every button every frame (Manage Inventory at the bottom of the right column);
  `updateButtons()` is called from render.

## The whole admin surface (inventory for the admin hotbar)

Where every admin tool lives, and how it runs, so a feature touching "all admin tools" starts here.

- **Admin Powers**: `ISAdminPowerUI.OptionList` (public registry, 24 entries: Invisible, GodMod, NoClip, FastMove,
  TimedActionInstant, UnlimitedCarry/Endurance/Ammo, KnowAllRecipes, Build/Farming/Fishing/Health/Mechanics/Moveable
  cheats, CanSeeAll, CanHearAll, ZombiesDontAttack, BrushTool, LootZed, LootLog, AnimalCheat, AnimalExtraValues,
  AlwaysDay). Each option: `id, text, tooltip, capability, getValue(self), setValue(self, v)` reading `self.player`.
  Save = `option.player = p; option:setValue(v)` for each, then `sendPlayerExtraInfo(p)`; gated by
  `role:hasAdminPower()` + the option's capability.
- **Admin panel windows**: `ISAdminPanelUI:onOptionMouseDown(button)` opens each by `button.internal` (CHECKSTATS,
  ADMINPOWER, ITEMLIST, SEEOPTIONS, NONPVPZONE, SEEFACTIONS, SEEROLES, SEEUSERS, SEESAFEHOUSES, SAFEZONE, SEETICKETS,
  MINISCOREBOARD, SANDBOX, CLIMATE, STATISTICS, PVPLOGTOOL, ZONE_EDITOR) and only calls `self:updateButtons()` on the
  panel afterwards, so it can be called with a stub `{ updateButtons = function() end }`. Capabilities: see its
  `updateButtons`. The sidebar Admin button shows for `role:hasAdminTool()`.
- **Tools menu** (`client/DebugUIs/AdminContextMenu.lua`, `OnFillWorldObjectContextMenu`, gate `isClient() and (isAdmin()
  or getAccessLevel() == "moderator")`, added with `addDebugOption("Tools")`): Teleport (`ISTeleportDebugUI`), Remove item
  tool, Spawn Vehicle (`ISSpawnVehicleUI`), Horde Manager (`ISSpawnHordeUI:new(0, 0, player, square)`), Trigger Thunder
  (`ISTriggerThunderUI`), Make noise (`addSound(player, x, y, z, radius, volume)`; a client's world sound is sent to the
  server by `WorldSoundManager`), Remove All Zombies, plus Vehicle and Door submenus for the clicked object.
- **Debug menu** (`client/DebugUIs/DebugContextMenu.lua`): built by **Java** (`ISWorldObjectContextMenuLogic` calls
  `DebugContextMenu.doDebugMenu`), shown in MP to any role with `UseDebugContextMenu` (no `-debug` needed). Main (teleport,
  remove item tool, spawn vehicle, horde manager, spawn points, player model / cursor show-hide), UIs (tile picker, filming
  tools...), Brush Tool, Ramps, Make Noise, Objects (door/window/fence/generator/campfire/mannequin/compost debug), DeadBody,
  Zombies (remove all, add zombie, select + per-zombie actions), Animals (remove all, cheat toggle, add enclosure, add
  animal by type/breed: `animal.add {type, breed, x, y, z, skeleton}`), Players (teleport players here =
  `teleportPlayers(player)`, TeleportUserAction needs TeleportPlayerToAnotherPlayer), Vehicles (add = `addVehicle`, remove =
  `removeVehicle(player, vehicle)`, remove all = `removeAllVehicles` → `/remove vehicles`), Randomized Road/Zone/Building
  stories (`sendDebugStory(square, 0|1, name)`, DebugStory packet needs CreateStory; zone stories refused next to a fence,
  `square:hasFenceInVicinity()`; building stories run client side only).
- `addVehicle(script, x, y, z)` on a client **ignores its arguments** and sends `/addvehicle <random script>`.
- `ISSelectCursor:new(character, ui, nil)` + `getCell():setDrag(cursor, playerNum)` picks a square; it calls
  `ui:onSquareSelected(square)` (method call on `ui`, the third argument is ignored) and is only valid while `ui.cursor ~= nil`.
  It is an `ISBuildingObject`, so `tryBuild` first **walks the player to the square** (`walkTo`) unless
  `cursor.skipWalk2 = true` or the build cheat is on; set `skipWalk2` for a pure picker. Its `create` removes the cursor
  before reporting the square (replace `create` on the instance to keep picking); Java calls the cursor's `deactivate`
  whenever `setDrag` removes or replaces it (Esc = `ToggleEscapeMenu`). **Nothing ends a pick cursor on right-click**: the
  right-click opens the world context menu (`ISObjectClickHandler.doRClick` on `OnObjectRightMouseButtonUp`), whose
  `createMenu` clears the cursor, so the menu opens too. `OnRightMouseDown` (not fired over UI) then `OnRightMouseUp` and
  `OnObjectRightMouseButtonUp` fire from one `UIManager.updateMouseButtons` call; the hotbar's pickers end on the
  down and wrap `doRClick` to eat that release's menu. Vanilla's Horde Manager
  (`ISSpawnHordeUI:onSelectNewSquare`) and Tile Picker do not, so picking a square there makes the character walk to it.
- Brush Tool painting: `ISBrushToolTileCursor:new(sprite, northSprite, character)` + `setDrag` (what "Choose tile" does)
  never removes itself, so each click places again. In MP its `tryBuild` sends `sendAddObjectToMap(square, sprite)` =
  `AddObjectToMapPacket`, `requiredCapability = AddItem` (not the Brush Tool power); the server runs
  `CellLoader.DoTileObjectCreation` and relays it, clients get `OnTileObjectAdded`. `BrushToolChooseTileUI.OnKeyPressed`
  swaps any drag with `isTileCursor` for the next tile on '[' / ']' (keys 26/27). The hotbar's "Paint a tile" holds
  one (`Hotbar.holdCursor`: right-click / Esc / second click end it, no context menu).
- Online players for a picker: `scoreboardUpdate()` → `Events.OnScoreboardUpdate(usernames, displayNames, steamIDs)`
  (everyone online); `getOnlinePlayers()` on a client only holds the players it has loaded.
- Climate Control (`ISAdmPanelClimate`): `getClimateManager():getClimateFloat(i)` (0..12: desaturation, global light,
  night, precipitation, temperature, fog, wind, wind angle, clouds, ambient, view distance, daylight, humidity),
  `getClimateBool(0)` (snow), `getClimateColor(0)` (global light) each with `isEnableAdmin/setEnableAdmin`,
  `getAdminValue/setAdminValue` (colour: `setAdminValueExterior/Interior(r, g, b, a)`), then
  `transmitClientChangeAdminVars()`; `transmitRequestAdminVars()` refreshes the client's copy. Weather tab:
  `transmitTriggerStorm/Tropical/Blizzard(hours)`, `transmitGenerateWeather(strength, 0 warm | 1 cold)`,
  `transmitStopWeather()`. `isRaining()` exists.
- Server options: `ServerOptions.getInstance():getPublicOptions()` (names), `getOptionByName(n)` (ConfigOption;
  `instanceof(o, "BooleanConfigOption")`); the window sends `/changeoption Name "value"` then `/reloadoptions` and updates
  its local copy with `option:asConfigOption():setValueFromObject(v)`.

### Chat commands (`zombie/commands/serverCommands`, exact syntax and capability)

`/additem ["user"] "M.Type" [count]` AddItem · `/addkey "user" id ["name"]` AddItem · `/addvehicle Script [x,y,z | "user"]`
ManipulateVehicle (z must be 0) · `/addxp "user" Perk=n [-true|-false]` AddXP · `/alarm` (executor must be in a room)
MakeEventsAlarmGunshot · `/gunshot` (meta gunshot) MakeEventsAlarmGunshot · `/chopper [start|stop]` MakeEventsAlarmGunshot ·
`/lightning ["user"]` MakeEventsAlarmGunshot · `/thunder ["user"]` StartStopRain · `/startrain [0-100]`, `/stoprain`,
`/startstorm [hours]`, `/stopweather` StartStopRain · `/createhorde n ["user"]` and
`/createhorde2 -x -y -z -count -radius -outfit -crawler -isFallOnFront -isFakeDead -knockedDown -isInvulnerable -isSitting
-health -isRecordingAnims -heightOffset -isRagdolling -onFire` (count ≤ 500) CreateHorde ·
`/removezombies -x -y -z -radius [-reanimated]` or `-remove true` ManipulateZombie · `/remove animals|zombies|corpses|vehicles`
**AnimalCheats for every subsystem** · `/godmod(e) [-true|-false]`, `/godmodplayer "user" [-true|-false]`,
`/invisible`, `/invisibleplayer`, `/noclip "user" [-true|-false]` (others need ToggleNoclipEveryone) ·
`/teleport "user"` TeleportToPlayer · `/teleportplayer "a" "b"` TeleportPlayerToAnotherPlayer ·
`/teleportto ["user"] x,y,z` TeleportToCoordinates · `/kick "user" [-r "reason"]` KickUser ·
`/banuser "user" [-ip] [-r "reason"]`, `/voiceban "user" -true|-false` BanUnbanUser · `/servermsg "text"`
DisplayServerMessage · `/save` SaveWorld · `/changeoption`, `/reloadoptions` ChangeAndReloadServerOptions ·
`/checkModsNeedUpdate` ManipulateMods · `/setaccesslevel`, `/grantadmin`, `/removeadmin` ChangeAccessLevel ·
`/unbanuser "user"` BanUnbanUser · `/removeitem "M.Type" n` EditItem (the **executor's own** inventory, 0 = all) ·
`/removemapsymbolsforuser "user"` EditMapSymbols · `/releasesafehouse "title"`, `/addtosafehouse "title" "user"`,
`/kickfromsafehouse "title" "user"` CanSetupSafehouses (found by title) · `/setTimeSpeed n` (`/sts`) ConnectWithDebug.
Debug menu entries that only act on the client in MP: Set Alarm (`def:setAlarmed`), Randomized Building,
Spawn Survivor Horde, vehicle Jump / Landmine. Without the
`-true/-false` flag, the god mode / invisible / noclip commands flip the current state.

### Vanilla client-command handlers with **no permission check** (any client can call them)

`server/ClientCommands.lua`: `object.addFireOnSquare`, `object.addSmokeOnSquare`, `object.addExplosionOnSquare`
(the Brush Tool's fire control), `event.thunder` (Trigger Thunder window), `player.setWeight`, `object.addFluidDebug`,
`deadBody.addBody`, and most other `object.*`, `fireplace/bbq.setFuel`, `hutch.dirt/nestBoxDirt`, `animal.rename`.
Worst: `player.onHealthCheatCurrentPlayer` (~451) toggles bite/infection/fractures/burns on **any** player by
`args.id` (remote kill); `player.onVehicleSleep` / `onDropHeavyItem` act on any player by id;
`object.clearContainerExplore` re-rolls any container's loot; `object.setWaterAmount` (no max, no vanilla caller),
`addWaterContainer` / `removeFluidContainer`; `stove.setOvenParamsAndToggle` (any stove, any temperature);
`object.emptyTrash`; `map.setKnownInSquares` (no clamp, reveals the whole map). `server/Vehicles/VehicleCommands.lua`:
`fixPart`, `setContainerContentAmount`, `crash`, `setHSV/setSkinIndex`, door/window/tire/key/trailer commands all act on
any vehicle anywhere. `vehicle.remove` **is** guarded, in Java: `GameServer.receiveClientCommand` (~2335) only passes it
to Lua for `Core.debug`, `Capability.GeneralCheats` or `isDismantleAllowed()`; every other command is only logged.
Global object systems (farming, campfire, traps, feeding troughs) reach Lua through
`SGlobalObjectNetwork.receiveClientCommand` with no Java check: `farmingCommands` `cheat`/`kill`/`destroy`/`harvest`
from anywhere, campfire `setFuel`/`removeCampfire` (gives 3 stones every time), `camping_tent.removeTent`, traps
`remove`/`removeAnimal`/`addAnimalDebug`, trough `addFeed`/`addWater` (any amount). `forageServer.OnClientCommand`
calls any `forageServer` function a client names (`clearData` wipes the server's forage mod data).
`ISLogSystem.writeLog` writes any text to any server logger. Farming `water` (`farmingCommands.lua`) waters any
plant by coordinates with any `uses` (only `ISWaterPlantAction`'s client `update` sends it; not sent while `*_WaterPlant.lua` is on). Only their callers' UIs are gated. Candidates for a
hardening fix. Not fixable from Lua: `SyncItemFieldsPacket` (LoginOnServer only) trusts the client's condition, ammo,
name, pages, modData and clothing holes for any item whose container resolves.

What `new`'s arguments can be (`PZNetKahluaTableImpl.save/load`, 42.20): string, double, boolean, Lua table, InventoryItem
(sent as ContainerID + item ID, resolved in the server's copy of that container, nil if absent), IsoPlayer (PlayerID, so
**another player** works: `ISApplyBandage` otherPlayer), IsoObject, ItemContainer, BodyPart, VehiclePart, BaseVehicle,
IsoGridSquare, dead body, animal, recipes, FluidContainer, and a Java **`ArrayList` of one value type** (type of element 0;
elements that load as nil are left out, so a list of items arrives with the missing ones dropped). A client-side
`LuaTimedActionNew` only becomes a server action when the class has a `complete` method (else
`useCustomRemoteTimedActionSync`); every Request makes the server `ActionManager.stopPlayerActions` for that player first.
Server duration ms = the table's `getDuration()` (through `adjustMaxTime` on the server only) × 20.
Vanilla inventory → floor timing: Java `Transaction.getDuration` = max over the entries of `maxTime` × 20 ms, where
`maxTime` = 120 (50 from the main inventory to outside the character or from outside into it; bag capacity factor
`capacityWeight / maxWeight` >= 0.4 for packing) × min(actualWeight, 3), × 0.1 main inventory → floor, × 0.2 world
container → floor, × 0.5 Dexterous, × 2 All Thumbs or awkward gloves; no moodle/hand-pain `adjustMaxTime`. So a drop from
the main inventory takes 100 ms per weight unit, capped at 300 ms. Items <= 0.1 weight of one type batch 20 per
transaction (`checkQueueList`); a separate Java hack zeroes the time of up to 19 same-type light grabs from the floor
within 2 s. `ISDropWorldItemAction:getDuration` uses the same main-inventory → floor formula.
Vanilla Trade (`ISWorldObjectContextMenuLogic`, Java-built): offered for a clicked player who is not asleep, not an
animal, not invisible unless the role has `SeesInvisiblePlayers`; greyed out ("get closer") when `|dx| > 2 or |dy| > 2`;
named with `getDisguisedDisplayName()`. `ISTradingUI` shows "too far away" on the same 2-tile rule.
Server-side timed actions: `NetTimedAction` only calls `new`, `getDuration`, `adjustMaxTime`, `serverStart`,
`serverStop`, `animEvent`, `complete`, `isUsingTimeout` — never `isValid`, `update` or `perform`. A Lua error in
`complete()` makes `ActionManager` send Reject (the changes made before the error stay). Client-only globals
called from a shared action's `complete`/`animEvent` error on a server (42.20's `ISWorldObjectContextMenu.checkWeapon`;
42.21 moved it to the shared `ItemUtils.checkWeapon`). The server's table is `Type.new(...)` called with the client
table's values of `new`'s **parameter names** (`NetTimedAction.set` reads the prototype's locvars), so anything the
client sets in `new` under another name or in `start()` (`ISRemoveBush.weapon`) is missing there; set it in `serverStart`
(`ISChopTreeAction.axe` does). Single player runs `start`, the real anim events and `complete` (Java
`LuaTimedActionNew.complete` when not a client). Anim events with no `m_EventName` (the RemoveBushAxe/Knife/LongBlade
xmls) never reach `animEvent`.
Server hand changes sync themselves: `setPrimaryHandItem`/`setSecondaryHandItem` set `handItemShouldSendToClients` and
`IsoGameCharacter.preupdate` sends `EquipPacket` to the owner, whose client sends it back for the server to relay to
everyone. A server action's `serverStop` runs only when the action is cancelled (client Reject, or `stopPlayerActions` on
disconnect: `ActionManager.remove` → `NetTimedAction.stop`), never after `complete`; `netAction:getProgress()` =
(now - start) / (end - start), not clamped (above 1 once past the end). On a client `InventoryItem:UseAndSync()` is
`Use(false, false, GameServer.server)`, i.e. a plain local `Use` with no sync; `SyncItemFieldsPacket` carries the whole
FluidContainer, so a client-side `adjustAmount` + `syncItemFields` sets the server's fluid amount.
Actions whose client `update` does the work (`ISWaterPlantAction`: per-use `water` command + can use) and whose server
`complete` does it again from `new`'s full arguments double it in MP (`*_WaterPlant.lua`).
`sendServerCommand(p, 'ui', 'dirtyUI')` (ItemUtils, ISBuildUtil, ISMultiStageBuild, GraveHelper) never
matches the client's `Commands.ui.DirtyUI` (exact-name lookup); `*_RemoveBush.lua` answers it.

### Single player vs a server (what breaks, what to call instead)

- A single player character's role is `Roles.getDefaultForNewUser()` (`IsoPlayer.role` default): **no admin
  capability**, so `hasCapability`, `hasAdminTool`, `hasAdminPower` are all false. Vanilla gates its single player admin
  tools on `isDebugEnabled()` instead (Admin Powers, DebugContextMenu, Player Stats edit buttons); the admin panel's
  buttons all follow the role, so it closes itself in single player.
- `getAccessLevel()` reads `GameClient.connection` → **NullPointerException in single player**. `isAdmin()` is safe
  (false). `getPlayerFromUsername` only searches a server's players; single player names are forename+surname
  (`IsoPlayer.updateUsername`), search `getSpecificPlayer(0..getNumActivePlayers()-1)`. `getOnlinePlayers()` is empty.
- Chat commands (`SendCommandToServer`), `sendPlayerExtraInfo`, `sendDebugStory`, `scoreboardUpdate`,
  `teleportPlayers` are network only. `transmitClimatePacket` (every `transmit*` of ClimateManager) does nothing outside
  a client or server; `transmitServer*` (start/stop rain, storm, stop weather, lightning) only work on the server.
- `sendClientCommand` in single player reaches the server Lua (`ClientCommands.lua`, `VehicleCommands.lua` load with
  `if isClient() then return end`), but handlers that check `player:getRole():hasCapability(...)` refuse (the role).
  `checkPermissions(player, cap)` (vehicle commands) returns true outside a server. Unchecked handlers (fire, smoke,
  explosion) work.
- Single player equivalents: `player:teleportTo(x, y, z)`; `instanceItem(type)` + `getInventory():AddItem` (Item List);
  `addZombiesInOutfit(x, y, z, 1, outfit, femaleChance, crawler, fallOnFront, fakeDead, knockedDown, invulnerable,
  sitting, health, recordingAnims, heightOffset, ragdoll, onFire)` (Horde Manager); `addVehicle(script, x, y, z)` uses
  its coordinates (empty script = random); `getClimateManager():triggerCustomWeatherStage(WeatherPeriod.STAGE_STORM |
  STAGE_TROPICAL_STORM | STAGE_BLIZZARD, hours)`, `triggerCustomWeather(strength, warmFront)`, `stopWeatherAndThunder()`,
  rain = precipitation float 3 `setAdminValue` + `setEnableAdmin` (what /startrain does); `getThunderStorm():
  triggerThunderEvent(x, y, strike, light, rumble)` runs locally outside a server; `getAmbientStreamManager():doGunEvent()`,
  `:doAlarm(roomDef)` + `buildingDef:setAlarmed(true)` (/alarm); `testHelicopter()` / `endHelicopter()` (both modes).
- Vanilla functions that already branch on `isClient()`, safe to call in both: `DebugContextMenu.AddAnimal`,
  `OnGetBuildingKey(nil, playerNum)`, `doRandomizedVehicleStory(square, rvs)`, `doRandomizedZoneStory(square, rzs)`,
  `onAddEnclosure(player)`, `onTeleportValid`, `removeAllVehicles(player)`, `removeVehicle(player, vehicle)`,
  `AdminContextMenu.onHordeManager/onSpawnVehicle/onTeleportUI`. Single player only: `DebugContextMenu.OnRemoveAllZombies()`,
  `OnRemoveAllAnimals()`.

### UI building blocks learned for the hotbar

- `ISEquippedItem:initialise()` stacks sidebar buttons at `prev:getBottom() + 15`, sized to the sidebar texture
  (read `adminBtn:getWidth()`); `adminBtn`/`warManagerBtn` exist only when `isClient()`. `prerender()` re-places
  `warManagerBtn` under `adminBtn` every frame; `shrinkWrap()` sizes the panel to its ISButtons.
  The buttons exist only for player 0's sidebar; the gap is a file-local `UI_BORDER_SPACING` (10) + 5. Icons are
  `media/ui/Sidebar/<w>/<Name>_Off|On_<w>.png`, w = 48/64/80/96/128 from `getOptionSidebarSize()` (6 = font size - 1),
  height w * 0.75; changing the option rebuilds the sidebar (`checkSidebarSizeOption` → `launchEquippedItem`), so
  wrappers of `initialise` run again. Hover tooltips (`addMouseOverToolTipItem`) read the element's live bounds. To put
  a button in the middle of the stack, wrap `initialise` and move every child at or below the anchor's bottom down
  (TienLastSeenWhere does it under Inventory). Tutorial mode hides most buttons in `prerender`.
- More sidebar internals (TienCustomizableLeftSidebar relies on them): the Furniture and Map hover popups are top-level
  panels placed only at creation (`10 + btn:getX/Y()` = the sidebar's absolute position + the button's) and shown while
  the button `isMouseOver()`; `movableTooltip` (child, at the Furniture button's y) and `radialIcon` (safety countdown,
  at the safety button's y) are separate children; vanilla's safety background and countdown text are drawn in
  `prerender` at the safety button's position. Every frame `prerender` sets the visibility of Admin (role), Safety
  (server option `SafetySystem`, which leaves a gap when off), War (`getWarNearest()`) and Furniture, and the War button's
  y. `shrinkWrap` counts invisible buttons too. `checkToolTip` compares the absolute mouse position with the buttons'
  relative bounds (off by the sidebar's 10 px offset) and ignores visibility. The Building button sits at x = 5. Button
  `onclick`s are bound at creation to the then `ISEquippedItem.onOptionMouseDown`, so wrapping it after the sidebar
  exists changes nothing for its buttons.
- Java UI dispatch (`zombie/ui/UIElement`): `render` = Lua `prerender`, children, Lua `render`, so positions set in a
  `prerender` apply the same frame; a child lying entirely above or below its parent is not drawn unless the parent has
  `renderClippedChildren`. `isMouseOver()` only tests bounds, not visibility. Right-click goes to the children first
  (topmost first), then to the parent's Lua `onRightMouseUp`; a Lua handler returning nil counts as consumed, and
  `ISUIElement` defines an empty one, so every Lua panel swallows right-clicks unless it returns false.
- `ISButton` draws everything in its own `prerender`/`render`; a subclass can replace both (call `self:updateTooltip()`).
  `onRightMouseUp(x, y)` is not handled by ISButton, so a subclass can take it.
- `ISScrollingListBox:prerender` calls `doDrawItem(y, item, alt)` for **every** row every frame (skip off-screen rows:
  visible while `y + h >= -getYScroll()` and `y <= -getYScroll() + height`); `onMouseDown(x, y)` gets `y` in content
  coordinates, so `rowAt(x, y)` works directly.
- `PZAPI.ModOptions:create(id, name)` / `addKeyBind(id, name, key, tooltip)` / `getOption(id):getValue()`. Saved values are
  only read back by `PZAPI.ModOptions:load()`, which vanilla calls when it builds the options screen — call it at
  `OnGameStart` to have saved key binds in game. (The in-game options screen is built by vanilla's own `OnGameStart`
  handler `LoadMainScreenPanelIngame` → `MainOptions:create` → `addModOptionsPanel` → `load()`, so values read later
  than that, e.g. when a context menu opens, are the saved ones without calling it.) A mod key bind **drops Shift/Ctrl/Alt**: the options screen records
  and shows them (`MainOptions.keyPressHandler` sets `keyCode, shift, ctrl, alt` on `option.element`), but
  `getValue()` is the bare key and ModOptions.ini saves only it; the screen copies `option.shift/ctrl` (not `alt`)
  back into its entry. Vanilla's own rule is `Core.invalidBindingShiftCtrl` (raw keys 42/54 Shift, 29/157 Ctrl,
  56/184 Alt). So mod keys belong in the **vanilla key bindings** instead: append `{ value = "[Section]" }` and
  `{ value = "Name", key = 0 }` to the global `keyBinding` table (shared/keyBinding.lua) at load;
  `MainOptions.loadKeys` (run when the options screen is built) calls `getCore():addKeyBinding(name, key, altKey,
  shift, ctrl, alt)` and restores/saves them in `keysB42.ini`; test with `getCore():isKey(name, key)`. Labels:
  `UI_optionscreen_binding_<name>` (section: name without brackets) in `Translate/EN/UI.json`; no tooltips. The label
  column is sized by the widest internal name, so keep names short. `MainOptions.keys` holds each bind's
  `key/shift/ctrl/alt`; `MainOptions.saveKeys` writes from the screen's `MainOptions.keyText` and clears Core's keys
  (follow it with `loadKeys`). The admin hotbar's keys are there ("ZF Admin Hotbar ...").
  keysB42.ini is rewritten from scratch with only the binds known right now (`saveKeys` on Apply, `create` after a
  key version upgrade, pzopt's copy of it), so vanilla drops the keys of mods that are not loaded; `*_KeepModOptions.lua`
  wraps the global `getFileWriter` for that file and appends the old lines nobody wrote.
- Textures: `tryGetTexture(name)` = `getSharedTexture` (loose files and pack entries) then `media/textures/`, nil if
  missing. Map symbols (`MapSymbolDefinitions.getInstance():getSymbolCount()/getSymbolByIndex(i)`, `getId()`,
  `getTexturePath()`, 91 in 42.20) are white, so they tint. Item icons: script item `getIcon()` (or
  `getIconsForTexture():get(0)`) as `Item_<icon>`; `ISUIElement:drawScriptItemIcon(scriptItem, x, y, a, w, h)`.
  Traits/professions: `CharacterTraitDefinition.getTraits()` / `CharacterProfessionDefinition.getProfessions()` →
  `getTexture()`. Tiles: `getWorld():getAllTilesName()` → `"<set>_<n>"`, n < 256. Lua cannot list folders.
- `getText(key, arg)` formats a Lua number as a Java Double ("1.0"); pass `string.format("%d", n)`.
- Item tooltips (`ObjectTooltip.Layout` / `LayoutItem`) keep every row's text in public fields: Lua can add rows, never
  read or remove them. `getNumClassFields` / `getClassField` / `getClassFieldVal` throw "Not in debug" without `-debug`
  (`LuaManager.validateReflectionAccess`). `item:DoTooltipEmbedded(tooltip, layout, 0)` fills a layout without drawing
  it; the caller renders it at the y worked out again by hand (`*_GoMTooltips.lua`). A gun's ammo row (`HandWeapon.DoTooltip`)
  is shown only while `getMaxAmmo() > 0` and is labelled with `getMagazineType()`'s display name, cached per item in a private
  `bulletName`. Gunworks' insert (its `ISInsertMagazine:loadAmmo`, on the server) sets the gun's MagazineType/MaxAmmo and saves
  `modData.MagazineType`, and its `complete` attaches the magazine as a `Clip` (or `Magazine`) weapon part;
  `SyncHandWeaponFieldsPacket` carries the parts and modData but neither of those, so the client keeps the previous pair
  until `Magazine.RestoreMagazineType` (game start, OnCreatePlayer, OnEquipPrimary/Secondary), and the cached name can
  stay wrong after that.
- Item bytes (`InventoryItem.save` / `HandWeapon.save`, used for saves and every network copy) carry `currentAmmoCount`
  but not `ammoType`, `maxAmmo` or `magazineType`, and `SyncItemFieldsPacket` carries only the count: a rebuilt item has
  its script values again, and a client/server difference in them never heals. Gunworks uses a magazine's `ammoType` as
  the round type picked for it (`Ammo.MagazineAmmoProfileSetter`, mirrored by its `magazineAmmoProfile` command) and a
  gun's `magazineType` as the last magazine inserted. Vanilla's radial "Load Bullets into Spare Magazine"
  (`CLoadBulletsInMagazine`, local to `ISFirearmRadialMenu.lua`) only looks for magazines of the gun's one
  `getMagazineType()` and rounds of the magazine's one `getAmmoType()`, so with Gunworks profiles and ammo families it
  is often missing or loads the magazine's default round.
- Radial menus (`ISRadialMenu`): each slice is `{ text, texture, command = { fn, arg1..arg6 } }` in `menu.slices`;
  there is no remove, so rebuild with `clear()` + `addSlice`. Java `RadialMenu.render` draws nothing with 0 slices and
  sizes slices by `360 / max(count, 2)`. `ISFirearmRadialMenu:fillMenu` adds `addSlice(nil, nil, nil)` for every
  command that offered nothing (fixed spots); every vanilla caller runs `display()` right after, which is where
  `*_FirearmRadialBlanks.lua` drops them (after other mods' `fillMenu` wrappers). `ISBackButtonWheel` uses blanks on
  purpose for its joypad layout.
- `UIManager.AddUI` / `RemoveElement` only queue; `UIManager.getUI()` (top-level Java elements, `ui:getTable()` →
  the Lua table) changes at the next `UIManager.update`. Base `close()` of ISPanel / ISPanelJoypad /
  ISCollapsableWindow only hides; vanilla reopens windows with `instance:close()` or `closeModal()`. Every forage,
  stash and world item icon is an `ISBaseIcon` (ISPanel) in the UIManager, appearing as the player moves.
- A top-level `ISToolTip` a window makes should get it as owner (`setOwner`): `ISToolTip:prerender` removes a tooltip
  whose owner is no longer `isReallyVisible()` (hidden, or for a top-level element gone from `UIManager.getUI()`).
  `ISRolesList` and `ISAdminPowerUI` do; the admin Server Options window (`ISServerOptions`) does not and has no
  `onMouseMoveOutside`, so its option tooltip outlived the window and followed the mouse (`*_ServerOptionsTooltip.lua`).
- Foraging debug (`ISSearchManager.createDebugContextMenu`): `ISSearchManager.getManager(player)`,
  `getAndActivateZoneAtXY(x, y)` (nil outside a forage zone), `createSpecificIcon(square, fullType, zoneData, nil, nil, n)`,
  `createAllIconsOnSquare(square, catName|nil)`, `refreshZoneIcons(square)`, `moveAllZoneIconsToSquare(square)`, all
  local only; overlays `ISSearchManager.showDebug` / `showDebugLocations` (drawn only with showDebug, in search mode).
  `forageSystem.itemDefs` is keyed by full type, `catDefs` by name (`IGUI_SearchMode_Categories_<name>`).
- `media/ui/circle.png` is a white disc, handy for tinted status dots. `media/ui` holds ~1540 loose PNGs (moodles in
  32/48/64/80/96/128 folders, sidebar icons in 48/64/80/96/128 with `_<size>` suffixes, emotes, speed controls,
  `LootableMaps/map_*.png` = the map symbols). The sidebar Admin icon is grey (Off) / reddish (On), so it tints.
  `Moodles/<size>/_Moodles_BGsolid.png` is a white shaded disc (the game tints it good / bad), `_Moodles_BGoutline.png`
  a dark disc with a white ring; moodle glyphs (`Status_Thirst`, `Mood_Pained`...) are full colour on transparent.
  `Sidebar/<w>/HandMain_Off` / `HandSecondary_Off` are plain dark discs, no hand drawn.
- Item icon names differ from item names (`Base.Pistol` → `Item_HandGun3`, `Base.NoiseTrap` → `Item_NoiseMaker`), and some
  items have no `Icon` in their script at all (`Base.Key1`, `Base.Screwdriver`, `Base.Hammer`), so resolve through the
  script item, never by guessing `Item_<name>`. Item icons for poster art live in `media/texturepacks/UI2.pack` (B42
  icons, e.g. `Item_Whiskey`) and `UI.pack` (older ones only there: `Item_BaseballBat`, `Item_PillsPainkiller`); both
  use the same entry format (TienInspectWeapon / TienActionableHotbar `scripts/make_art.py` read them).
- The vanilla equipment hotbar (`client/Hotbar/ISHotbar.lua`, 42.20): slot click (`onMouseUp`) and number key
  (`onKeyPressed`, ignored while the action queue is busy, attacking, paused or on a joypad) both call
  `ISHotbar:activateSlot(slotIndex)` (~548): `canBeActivated` non-HandWeapons toggle, else `equipItem` (~575): unequip
  if held, else `ISEquipWeaponAction(both_hands = isTwoHandWeapon(), primary = both_hands or IsWeapon())` (a bat always
  goes two-handed, a non-weapon to the off hand). Right-click on a filled slot (`doMenu` ~82) =
  `ISInventoryPaneContextMenu.createMenu(playerNum, true, {item}, x, y)` + an Attach submenu. Only items whose script
  `AttachmentType` is a key of a slot's `attachments` (`ISHotbarAttachDefinition`) can be slotted: 353 vanilla items,
  ~320 of them weapons (no drinks or pills). Plysken Attachments Reborn replaces `activateSlot` outright (equips only
  HandWeapon / InventoryContainer / Radio, wears clothing) and adds ~110 attachable items. TienActionableHotbar wraps
  `activateSlot` at `OnGameStart` to run a context menu option instead.
- Context menu internals (`ISUI/ISContextMenu.lua`): an option is a pooled table `{ name, target, onSelect,
  param1..param10, subOption, notAvailable, isDisabled, checkMark, iconTexture, itemForTexture, toolTip }` (pool reused
  with `table.wipe`, so copy what you keep); a click runs `ISContextMenu.globalPlayerContext = player`, `closeAll()`,
  then `onSelect(target, param1..param10)` (~65). Submenus are numbered instances of the player's root menu
  (`getNew` → `instanceMap`, `addSubMenu` stores the number in `option.subOption`, `menu:getSubMenu(n)`). The tick of
  `setOptionChecked` is drawn where the option's icon goes. Building a menu and calling `closeAll()` in the same frame
  should never show it (UI draws later in the frame; not yet confirmed in game), so an item's menu can be built just to
  read or run its options; `createMenu` returns early (nil)
  while paused or in the tutorial, and returns nil with the menu hidden when no item applies.

### UI API cheat sheet (vanilla signatures, 42.20)

- Any `addChild` instantiates the child (and the parent) if needed; `getChildren()` is a table keyed by id; a child's
  class name is `child.Type` (from `derive`). `ISLabel:new(x, y, height, text, r, g, b, a, font, bLeft)`.
- `ISComboBox:new(x, y, w, h, target, onChange)` (onChange may be nil), `addOptionWithData(text, data)`,
  `getOptionData(i)`, `selected` (index), `selectData(data)`, `setEditable(true)` for a typed filter.
- `ISTextEntryBox:new(text, x, y, w, h)` → `initialise()`, `instantiate()` before `setOnlyNumbers`,
  `setPlaceholderText`, `setClearButton(true)`; `getText()` / `getInternalText()`; change callback
  `entry.onTextChangeFunction(entry.target, entry)`.
- `ISTickBox:new(x, y, w, h, name, target, method)` (method may be nil); `selected[i]`.
- `ISScrollingListBox`: `addItem(text, item)`, `clear()`, `items[i].item`, `selected`, `itemheight`, `font`,
  `setOnMouseDownFunction(target, fn)` / `setOnMouseDoubleClick(target, fn)` → `fn(target, items[selected].item)`;
  replace `doDrawItem(y, item, alt)` (called as `list:doDrawItem`) and return the next y.
- Grab menus (42.21): loot windows `ISInventoryPaneContextMenu.doGrabMenu(context, items, player)` (~4204, called at
  ~626) adds Grab one / half / all to the root menu when a stack has >= 2 items (`#k.items > 2`, first is a dummy);
  handlers take `(items, player)` and flatten with `ISInventoryPane.getActualItems`, `onGrabItems` walks once and queues
  one transfer per item (corpses → `ISGrabCorpseItem`). Search mode icons: `ISBaseIcon:doGrabSubMenu(context,
  plInvOption, inventory)` (Foraging/ISBaseIcon.lua ~68) builds a submenu from `itemObjTable` (keyed by item, `pairs`)
  and calls `self:onClickContext(0, 0, contextMenu, inventory, items)`; only `ISWorldItemIcon` (`doPickup`) takes the
  item list. `context:insertOptionAfter(name, text, target, fn, ...)` inserts next to an option by its text
  (appends if not found). `*_GrabAmount.lua` adds "Grab amount..." to both.
- Resizable column headers: `ISResizableButton` (file `ISUI/ISResizeableButton.lua`, note the spelling) drags its right
  edge, or its left edge with `resizeLeft = true` (vanilla inventory: Type header right, Category header left), clamps
  to `minimumWidth` / `maximumWidth` and calls `onresize = { fn, target, arg }`. Its `new` writes `minimumWidth` (and
  `resizing`) on the **class**, so set `minimumWidth` on the instance after `new`. It grabs only the 4 px inside its own
  resizing edge and adds up each move's `dx` (no anchor), so an `onresize` that recomputes widths from a layout which
  differs from the header's width by even 1 px creeps a pixel per move event; TienLastSeenWhere replaced it with an
  absolute drag (grab offset + mouse position, either side of the line). `ISButton:setVisible(true)` re-reads
  `mouseOver`, so calling it every frame undoes a `mouseOver = false` set to hide the hover highlight. Window geometry that survives
  restarts: `ISLayoutManager.RegisterWindow(name, Class, window)` (restores at once from `layout.ini`, per screen
  resolution) calls `Class.RestoreLayout(window, name, layout)` / `SaveLayout` (on `OnPostSave`); `DefaultSaveWindow`
  / `DefaultRestoreWindow` handle x, y, size and **visibility** (`layout.visible == "true"` shows the window), extra
  string keys can be added to `layout`. Setting a mod option from Lua: `PZAPI.ModOptions:getOptions(id):getOption(o)`
  `:setValue(v)` (combo: 1-based index, also updates its options-screen element), then `PZAPI.ModOptions:save()`
  rewrites ModOptions.ini from every mod's in-memory values.
- `ISTextEntryBox:onCommandEntered()` is called by Java on Enter (`UITextBox2.onKeyEnter` → `onCommandEntered` →
  `UIManager.tableget(table, "onCommandEntered")`, single-line boxes only; multi-line ones insert a newline). `ISTextBox`
  does not wire it, so Enter does nothing in vanilla text dialogs unless an instance field `entry.onCommandEntered` is
  set. Closing the dialog from it is safe in game: the only default bind on Enter, `ALT_TOGGLE_CHAT`, is defined in
  `KeybindId` and keyBinding.lua but read by nothing (chat opens on `TOGGLE_CHAT` = T).
- `ISModalDialog:new(x, y, w, h, text, yesno, target, onclick)` → `onclick(target, button)`, `button.internal == "YES"`.
- `ISTextBox:new(x, y, w, h, title, default, target, onclick)` → `onclick(target, button)`, `button.internal == "OK"`,
  text in `button.parent.entry:getText()`; `setOnlyNumbers(true)` after `initialise()`.
- `ISColorPicker:new(x, y)`, `pickedTarget`, `setInitialColor(ColorInfo.new(r, g, b, 1))`,
  `setPickedFunc(fn)` → `fn(pickedTarget, { r, g, b }, mouseUp)`; it removes itself once picked.
- `ISContextMenu.get(playerNum, x, y)`; `addOption(text, target, fn, args...)` → `fn(target, args...)`;
  `ISContextMenu:getNew(parent)` + `addSubMenu(option, sub)`; find a vanilla submenu with
  `getOptionFromName(name)` + `getSubMenu(option.subOption)`; `option.notAvailable = true` greys it; tooltip:
  `option.toolTip = ISWorldObjectContextMenu.addToolTip()` then set `.description`; `setOptionChecked(option, bool)`.
  To add to a menu a vanilla function builds without returning it, wrap `ISContextMenu.get` for the duration of the call
  (nested wrappers from several files work).
- `ISButton:new(x, y, w, h, title, target, onclick)` → `onclick(target, button)`; `tooltip` string (with `\n`);
  `setImage`, `textureColor = { r, g, b, a }`, `enableAcceptColor/enableCancelColor`, `setEnable`.
- Feedback over a player's head: `HaloTextHelper.addText(player, text)` / `addBadText`.
- World markers (`zombie/iso/WorldMarkers.java`, `getWorldMarkers()`, client only, each returns an object with `:remove()`;
  textures in `media/textures/highlights/`): `addDirectionArrow(chr, x, y, z, texName|nil, r, g, b, a)` (Horde Manager /
  Tile Picker `addMarker`) is a **screen-space** marker, not drawn on the ground: target on screen (< 300 tiles) =
  `dir_arrow_down` hovering over the square (`dir_arrow_stairs_up` when the target is on a higher floor; for a lower floor
  the code picks `texStairsUp` again, a vanilla typo, so `dir_arrow_stairs_down` never shows), off screen = `texName`
  (default `dir_arrow_up`, 48x48) rotated toward it where the line from screen centre crosses the inner screen border.
  `addPlayerHomingPoint(chr, x, y, r, g, b, a)` (search mode icons, tutorial) = `arrow_triangle` (32x32) near the player,
  turning (lerped) to point at the target. `addGridSquareMarker(square, r, g, b, doAlpha, radius)` = `circle_center` +
  `circle_only_highlight` ellipse on the floor (+ `setScaleCircleTexture`); the 10-argument form takes the two texture
  names first. A grid square marker is a floor sprite (`IsoSpriteInstance.render` in `IsoCell` ~1065, before shadows and
  characters), drawn only while its z equals the player's; its texture is fixed at creation
  (`media/textures/highlights/<name>.png`, width scaled to 64 × tileScale per tile size unit, so mods can add their own
  there) and `setPos(x, y, z)` takes **ints** (snaps per tile).
- Drawing on the floor from Lua: **not possible with the B42 renderer.** Only the legacy `IsoCell` render path (~1092)
  fires `Events.OnPostFloorLayerDraw(z)` (and OnPostFloorSquareDraw / OnPostTileDraw / OnPostWallSquareDraw /
  OnPostCharactersSquareDraw); the default 42.x renderer, `zombie/iso/fboRenderChunk/FBORenderCell`, fires no Lua
  event at all (confirmed in game: an arrow drawn from OnPostFloorLayerDraw never showed). FBORenderCell does render
  `WorldMarkers` grid square markers. So a mod draws world-anchored things in the UI pass: `Events.OnPreUIDraw`
  (UIManager, before the UI, after the world) with `isoToScreenX/Y(playerNum, x, y, z)` (forage icons use it) and
  `getRenderer():renderPoly(tex, x1, y1, ..., y4, r, g, b, a)` (screen coordinates; textured, u0/v0 at vertex 1, then
  TL, TR, BR, BL), drawn over characters and walls. `getRenderer()` = `SpriteRenderer` (exposed); `IsoUtils` and
  `IsoCamera` are exposed too. To mark an object instead: `obj:setHighlighted(playerNum, true, false)` (third arg
  renderOnce) + `obj:setHighlightColor(playerNum, r, g, b, a)` tints its sprite (world items too, `IsoWorldInventoryObject`);
  vanilla's loot window turns highlights off when the mouse leaves a container button, so re-apply every frame to keep
  one. The loot and inventory pages highlight the parent of their shown container themselves
  (`ISInventoryPage:updateContainerHighlight`: `setHighlighted` + `getCore():getObjectHighlitedColor()`, outline too when
  the container-outline option is on; parent = `page:getContainerParent(c)`: the IsoObject, or a bag's world item) and
  outline a hovered button's container; a mod writing another colour on the same object every frame makes it flicker,
  so step aside while it is shown. `ISInventoryPage.OnObjectHighlighted(playerNum, object, true|false)` registers an
  object in `ObjectsHighlightedElsewhere`, which the page then never un-highlights. Characters also have `setOutlineHighlight(playerNum, b)` / `setOutlineHighlightCol(playerNum, r, g, b, a)`.
- Stairs (IsoGridSquare ~2546-2670, ~10248): a staircase is three squares on the **lower** z, typed `IsoObjectType`
  stairsBN/MN/TN (north-facing: T at the smallest y, B at T.y + 2, climbed towards -y) or stairsBW/MW/TW (T at the smallest
  x, climbed towards -x); the top leads onto z + 1 at the square beyond T. `square:getStairs()` (the type, or MAX),
  `HasStairs()`, `HasStairsNorth/West()`, `HasStairTop()`, `HasStairsBelow()`, `getStairsDirection()` (N, W or nil),
  `isSameStaircase(x, y, z)`. Sheet ropes: field `haveSheetRope`, `getSheetRope()`. Bottom = `HasStairs() and not
  HasElevatedFloor()` (elevated = M and T squares).
- `ISUIElement:drawTextureAllPoint(tex, tlx, tly, trx, try, brx, bry, blx, bly, r, g, b, a)` goes straight to
  `SpriteRenderer` (`UIElement.DrawTexture`, 4-point overload): **absolute screen coordinates**, no element offset, no
  scroll (add `getAbsoluteX/Y()` and, in a list, `getYScroll()`). Textured `renderPoly` / this map u0,v0 to vertex 1, then
  TL, TR, BR, BL.
- Item tags (42.20): script `Item:getTags()` is a `Set<ItemTag>` (iterate with `:iterator()`); `tostring(tag)` = its
  ResourceLocation, e.g. `"base:saw"`.
- `PZAPI.ModOptions` also has `addColorPicker(id, name, r, g, b, a, tooltip)` (`getValue()` = `{ r, g, b, a }`),
  `addSlider(id, name, min, max, step, value, tooltip)`, `addTextEntry`, `addMultipleTickBox`, `addButton`. A combo's
  `addItem(textKey, selected)` translates the key itself; `getValue()` = 1-based index.
  `MainOptions:addModOptionsPanel` (42.21) also runs `getText` on every page/option **name and tooltip**, so pass
  translation keys, not `getText(key)`: `getText` of a string that is not a key and contains `%` (e.g. the translated
  "Arrow size (%)") goes to `Translator.reportMissingArgumentsFromPastAbuse`, whose log line is built with
  `String.format` → `UnknownFormatConversionException: Conversion = ')'` at MainOptions.lua:3025, and the whole Mods
  options page fails to build (at the main menu and again on every Lua reload).
- Enum sandbox option value labels: `Sandbox_<valueTranslation or translation>_option<n>` (`SandboxOptions` ~1651).
- `getFileWriter(name, create, append)` creates missing folders (`mkdirs`) and only accepts .ini/.cfg/.txt/.log/.json;
  `..` is refused (`hasRelativePath`); both read and write under `<cachedir>/Lua`. On a dedicated server that is the
  server's cache folder.
- Death events: `OnCharacterDeath(character)` fires everywhere `IsoGameCharacter.OnDeath` runs, server included;
  `OnPlayerDeath(player)` only for a **local** player on a client / single player (`IsoPlayer.OnDeath`, `!GameServer.server`).
- `square:getLightLevel(playerNum)` (forage uses it, vanilla reading checks compare with 0.43). `ISGrabItemAction:new(player,
  worldItem, ISWorldObjectContextMenu.grabItemTime(player, worldItem))` picks a floor item up;
  `ISInventoryTransferUtil.newInventoryTransferAction(player, item, src, dest)` for containers. `ISBaseTimedAction` has no
  generic `setOnComplete` (only some subclasses); poll `ISTimedActionQueue.isPlayerDoingAction(player)` instead.

### Loot window: what the player is shown (42.20, `ISInventoryPage` / `ISInventoryPane`)

- No vanilla event says "player N is looking at container C". The loot page (`not page.onCharacter`) is open when
  `page:isReallyVisible() and not page.isCollapsed` (vanilla's open/close sound test, `updateContainerOpenCloseSounds`
  ~1072); the shown container is `page.inventoryPane.inventory`, `page.player` the player number. Expanding a collapsed
  page refreshes nothing, so poll (wrapping `ISInventoryPage.update` works). `isExplored()` is not "seen":
  `refreshBackpacks` calls `checkExplored` on every container in reach, even while collapsed.
- `refreshBackpacks` (~1537): player page = main inventory + equipped bags + keyrings; in a vehicle every part with
  `getItemContainer()` and `canAccessContainer`; on foot the 3x3 squares that `canReachTo` and the safehouse allow: floor
  items into the fake `GetFloorContainer(playerNum)` (bags on the floor get their own button), corpses from
  `getStaticMovingObjects()` (an **animal** corpse `break`s the loop, skipping the rest of that square's static objects),
  every `getContainerByIndex(i)` of every object, then an adjacent vehicle's parts, then the Floor button.
  `OnRefreshInventoryWindowContainers(page, "begin" | "beforeFloor" | "buttonsAdded" | "end")` fires during it.
- A bag inside a container gets no button and is never shown in line; its contents are visible only once it is on the
  floor, in a vehicle seat or trunk, or equipped. `ISInventoryPane.refreshContainer` lists `inventory:getItems()` only
  (not recursive); it reruns when `inventory:isDrawDirty()`, so MP contents arriving after
  `requestServerItemsForContainer` show up later.
- `ISObjectClickHandler.doClick` (container branch ~281) only drives **player 0**'s loot window
  (`getPlayerLoot(0):setNewContainer(c)`, then un-collapse: `isCollapsed = false`, `clearMaxDrawHeight()`,
  `collapseCounter = -30`). `ISOpenContainerTimedAction` is no longer queued by vanilla. Select a container in the window
  with `page:setForceSelectedContainer(c, ms)` + `page:selectButtonForContainer(c)`.
- Every other UI that lists nearby items (handcraft, build, recipe tooltips, health, radials) takes
  `ISInventoryPaneContextMenu.getContainers(character)` = every loot button's container (except locked thumpables).
- Container locator helpers: `container:getContainingItem()` (a bag; `bag:getWorldItem()` when on the floor),
  `getVehiclePart()`, `getParent()` (IsoObject / IsoDeadBody), `isInCharacterInventory(player)`, `getSourceGrid()`.
- Directions: `IsoDirections` N = (0, -1), i.e. world -y (drawn up-right on screen, up on the world map); E = +x.
  `IsoDirections.fromAngle(dx, dy)` (8-way, `atan2(dy, dx)`) / `cardinalFromAngle(dx, dy)` (4-way), `dx()`/`dy()`,
  `toString()` = "N", "NE"... Vanilla shows them untranslated (`ISAnimalTracksUI` prints `getDir():toString()`); no
  direction-name strings exist in Translate/EN. A world offset (dx, dy) appears on screen along (dx - dy, (dx + dy) / 2).
- Containers are filled on first view: `ISInventoryPage` (~1106, `checkExplored` ~1511), `ISObjectClickHandler` (~309) and
  `ISOpenContainerTimedAction` call `ItemPicker.fillContainer` (SP) or `container:requestServerItemsForContainer()` (MP)
  when `not container:isExplored()`, then `setExplored(true)`. The loot window's Floor is a per-player
  `ItemContainer.new("floor")` rebuilt in `refreshBackpacks` (~1637) from `getWorldObjects()` of the 3x3 squares around
  the player that `canReachTo` and `SafeHouse.isSafehouseAllowLoot` allow; a floor bag adds its own container button.
  Square visibility: `square:isCanSee(playerNum)`, `isCouldSee(playerNum)`, `isSeen(playerNum)` read the per-player
  lighting flags `bCanSee` / `bCouldSee` / `bSeen` (IsoGridSquare ~9170-9370; vanilla click handlers gate on `isSeen(0)`,
  cursors on `isCouldSee`). Exact meaning not traced further.
- Drag and drop inside a panel: on `onMouseDown` remember the mouse, in `onMouseMove` and `onMouseMoveOutside` (both
  keep arriving while the button is pressed) start the drag past a few pixels with `self:setCapture(true)`, finish in
  `onMouseUp` / `onMouseUpOutside` (release the capture, reset `pressed` so ISButton does not also click). A ghost that
  follows the mouse is a top-level panel with `setAlwaysOnTop(true)` and `setWantMouseEvents(false)`, moved in its own
  `prerender`. The admin hotbar's slot reordering is the worked example.

### Data lists available to Lua

- Items: `getScriptManager():getAllItems()` (Item List skips `getObsolete()` and `isHidden()`), `getItem(fullType)`,
  `getDisplayName()`, `getFullName()`; `instanceItem("Module.Type")`.
- Vehicles: `getScriptManager():getAllVehicleScripts()`, `getVehicle(fullName)`, display name
  `getText("IGUI_VehicleName" .. script:getName())`; `player:getVehicle()`, `player:getNearVehicle()`,
  `vehicle:isHotwired()`, `isAlarmed()`, `getId()`; vehicle client commands take `{ vehicle = id, ... }`
  (`cheatHotwire {hotwired, broken}`, `setAlarmed {alarmed}`, `repair`, `getKey`).
- Zombie outfits: `getAllOutfits(false)` (male) / `getAllOutfits(true)` (female), ArrayLists with `contains`.
- Animals: `getAllAnimalsDefinitions()` → `getAnimalType()`, `getGroup()`, `getBreeds()` (`getName()`),
  `canBeSkeleton()`; `AnimalDefinitions.getDef(type):getBreedByName(name)`; names `IGUI_AnimalType_<type>`,
  `IGUI_Breed_<breed>`.
- Perks: `for i = 1, Perks.getMaxIndex() do local perk = PerkFactory.getPerk(Perks.fromIndex(i - 1))`, skip
  `perk:getParent() == Perks.None`; id for `/addxp` = `tostring(perk:getType())`; back with `Perks.FromString(id)`.
- Stories: `getWorld():getRandomizedVehicleStoryList()` / `getRandomizedZoneList()` → `getName()`.
- Players: `getNumActivePlayers()` + `getSpecificPlayer(i)` (local); `player:teleportTo(x, y, z)`.

## Features built on these findings

- `*_BodyStats.lua` (shared/server/client): admin body stats editor. Server applies every change
  (`BodyStats.apply`) and replies with a full snapshot; the window polls every second, batches slider changes every
  200 ms, numbers each change (session + seq per field, stale ones dropped server side) and shows the dragged value
  until acked. Gate: `Capability.CanModifyBodyStats` + target role position <= admin's.
  Body part conditions (option `BodyPartConditions`, hotbar `players.bodyPart`) are extra fields keyed
  `Part:<BodyPartType>:<condition>` resolved by `BodyStats.getField` but not in `getFields()`, set like vanilla's
  `onHealthCheatCurrentPlayer` (which has no access check) then `syncBodyPart`; value `flip` for another player's
  part, whose body this client cannot read.
- `*_AdminHotbar*.lua` (client only): admin hotbar. Core (bar, slots, settings dialog, pickers, persistence per
  server in `Zomboid/Lua/ZomboidFixesB42_AdminHotbar_<ip>_<port>.ini`, sidebar button, ModOptions keys), Actions (the
  catalog, one `Hotbar.registerAction` per admin tool), Capture ("Add to Hotbar" in vanilla windows), Icons (icon refs
  `sym:` / `item:` / `tex:`, picker; the media/ui path list is generated from the install). A slot = action + settings;
  toggles read their state back from the game every 200 ms; `window = true` slots open the vanilla window.
  Actions marked `opensWindow` (plus openUI and the windows category) remember the UIs that appear within 1.5 s
  and a second click closes them. `slot.steps` = extra `{ action, settings, window }` run after the slot's own
  (`Hotbar.partsOf`): all resolved first (asked player / square / vehicle shared), one confirm, then each step after its own `delay` (ms, default 300, 0 = same frame, `Hotbar.stepDelay`); the slot's `syncMode` ("On click", `Hotbar.syncModeOf`) sets how toggles turn: `flip` (saved explicitly; nil on load = older slot, becomes `update` if a step follows) flips every toggle from its own state; `update` flips part 1 and each step with `follow` (`same`/`opposite`, nil = independent) takes the state part 1 asked for at click time (`runParts` passes it on; own flip when part 1 is no toggle or its state is unknown); `only` does not run part 1 and turns the followers to its current state (independent and non-toggle steps skipped, nothing when the state is unknown); new steps default to `follow = same`;
  saved as `steps.#n.*` on the slot line. `slot.repeatMode` (`click` / `hold`, `repeatMs` >= 100, `repeatTimes` 0 = no
  limit): the first run resolves and confirms as usual (answers memoised), each later run re-resolves synchronously
  with them from `onRepeatTick` (at most one run a frame, a stall's backlog dropped); `hold`
  starts on `SlotButton:onMouseDown` / `OnKeyStartPressed` and polls `isMouseButtonDown(0)` / `isKeyDown(key)`, and
  falls back to `click` when the first run had to ask or confirm. Keep-picking slots ignore it. Focus (`Bar:updateFocus`): many vanilla windows never `bringToTop` on a
  click (ISInventoryPage), so on each press the bar brings itself, or the window it covers that was clicked, to the front.
  Single player: only with `-debug` (`isDebugEnabled()`), every capability assumed, each action has vanilla's single
  player branch, server-only actions greyed out; the sidebar button goes under the lowest button (no Admin button),
  slots saved to `ZomboidFixesB42_AdminHotbar_SinglePlayer.ini`.
- `*_FastForward*.lua` + `*_Transfer.lua`: multiplayer fast forward. A speed button or key is a vote; the server runs
  the slowest speed voted once every living player votes (`setMultiplier`), retimes running actions, fires the missing
  anim events, pays the missing cooking and times transfer batches. Auto fast forward (a right-clicked, yellow button)
  votes after `AutoFastForwardDelay` seconds busy, at once and mid-action, shaped by two string options of action
  `Type` names: `AutoFastForwardIgnoredActions` (never busy, never an action finishing; `Fishing` = `FishingState`) and
  `AutoFastForwardFinishFirstActions` (vote only as one starts, `AUTO_START_MS`, else after it). A listed transfer
  votes as a batch opens instead (`castAutoVoteForBatch`, asked by the `createItemTransaction` wrapper), and that batch
  waits (`zfixDeferred`, `maxTime` still -1) until the server's broadcast lists the vote (`autoVoteSettled`, at most
  `AUTO_HOLD_MS`), then opens at the new speed; while it waits, only movement keys or a moving vehicle count as moving.
  Corpse transfers (never timed) wait for the whole transfer. Manual votes stay immediate (see the paramount rule in
  "Time speed and timed actions in multiplayer").
- `shared/ZomboidFixesB42_Jobs.lua` (no option, infrastructure): time-sliced coroutine jobs. `Jobs.Start(name, fn)`
  (replaces a job of that name), `Jobs.Step()` in loops (yields once the tick's budget is spent, checked every 25
  calls), `Jobs.WaitWhile(fn)`, `Jobs.Finish(name)` (runs one to the end now, for a caller that cannot wait),
  `Jobs.Sort(list, less)` (stable bottom-up merge sort that steps; `table.sort` cannot yield). One budget per tick for
  all jobs: 8 ms on a server, 3 ms on a client, halved down to 1 ms while ticks are slow (server > 130 ms, client > 50 ms),
  +1 ms after 3 healthy seconds. Each mod keeps its own copy (TienLastSeenWhere has one), no shared library.
  Users: Lost Entities (chunk world items, joining players, loading vehicles), the admin hotbar icon picker (Items tab,
  tile sets; the short tabs are built on the spot) and the hotbar's item list (`items()`, prepared at `OnGameStart` for
  someone who can use the bar, finished on the spot if asked first).
- `server/ZomboidFixesB42_LostEntities.lua` (option `RepairLostEntities`): MapObjects load callbacks on every sprite of
  an entity that goes to meta rebuild component-less ones from their script and re-register ones the engine turned
  away (MetaTag trick); `LoadChunk` queues the chunk and a job does the same for its world items (empty container from
  the item script; a chunk whose anchor square no longer belongs to it is skipped); joining
  players' inventories and loading vehicles get rain-catching items without a FluidContainer fixed
  (`sendReplaceItemInContainer`); chunks holding such objects are saved again after load, 2 per tick, unless
  `BackupsPeriod` > 0.
- `*_TransferResync.lua` (client/server, option `TransferResync`): watches every vanilla transaction of
  `ISInventoryTransferAction` / `ISGrabItemAction` and asks the server where the items really are
  (`ZomboidFixesB42.resyncTransfer` -> `locateTransferItem`: dst, src, player inventory, ground within reach, none) when
  one is late (2.5 s past its end), gone (timed out; held open by wrapping `isItemTransactionDone/Rejected`, retried once
  if the items are still at the source), refused, or a grab ended without the item arriving. The server re-sends with
  `sendAddItemToContainer` what the client does not show (for the inventory tree only if the client holds it nowhere
  in it); the client drops world items and world/vehicle container items the server does not have there (never from its
  own inventory). `clearGhostsOf` drops a floor copy of an item that has arrived in the inventory. Fast transfers
  send floor hints (`encodeFloorHints`, `findItemOnGroundNear`), log why they decline, and fall back to a vanilla
  transaction for declined items still at the source. Not fixable from Lua: a real floor item the client lost to a
  wrong-index removal (no way to send one world item to one client), and the cross-player Reject of vanilla cancels.
- `client/ZomboidFixesB42_ZombieAttacksWearClothing.lua` (option `ZombieAttacksWearClothing`, beta): on each `OnClothingUpdated` while one
  of this client's zombies can hit the player, weighs every vanilla outcome (part chances, thump / blocked scratch /
  blocked bite / through, hole attempt) against a per-frame snapshot of the layers' holes, keeps the cases whose
  predicted holes match what changed, picks one, and finishes it as the server would (hole cost, or armor's 1 in N);
  then `syncVisuals()`. Breaks go through `*_BrokenClothing.lua`.
- `*_BrokenClothing.lua` (option `SyncBrokenClothing`) also clears worn ghosts on the client every tick: a worn item not in
  the main inventory for 2 s is swapped for the inventory item with its ID, or taken off when no item with that ID is
  anywhere in the inventory (left alone when it is in a bag); the client's SyncClothing then drops the server's copy.
- `client/ZomboidFixesB42_AdminFullBright.lua` (option `AdminFullBright`): an Admin Powers option (`ISAdminPowerUI.AddOption`,
  file named to load before `*_AdminHotbarActions.lua`, which turns every option into a hotbar toggle). Always Day
  (ClimateManager day/ambient values while `isAlwaysDayCheat`) lights only the outdoors; the native lighting lights
  interiors only from windows, room lights and light sources. `FBORenderChunk.NoLighting` / `ForceSkyLightLevel` are
  debug-only (`BooleanDebugOption.getValue` = default without `-debug`), `IsoRoomLight` is not exposed, and per-square
  lighting is overwritten natively and cached in the chunk renders. So it adds `IsoLightSource`s with
  `getCell():addLamppost` (radius capped at 20, falloff (1 - d/r)^2, walls block, dropped by `checkLights` outside the
  loaded area, `removeLamppost(light)` = life 0) every 4 tiles through the rects of the rooms near the player
  (`getMetaGrid():getRoomsIntersecting(x, y, w, h, list)`, `RoomDef:getRects()`), client only.
- `shared/ZomboidFixesB42_ScriptFixes.lua` + `*_ItemFixesClothing/Weapons/Food.lua`: item and recipe data fixes, one option
  each, applied at `OnLoadMapZones` and re-checked every ten minutes (`ScriptFixes.register(option, apply, revert)`,
  `setParams`, `addTag`/`removeTag`, `newMapperEntry`, `setRecipeCall`, `newFixer`, `onBeforeUse` hooks in
  ISEatFoodAction / ISDumpContentsAction / ISAddItemInRecipe for per-instance ReplaceOnUse).
