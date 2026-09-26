# Zomboid Fixes B42.20 — working notes

Engine findings for Project Zomboid Build 42.20 (game version 42.20.4, revision b0bbce05d5),
recorded so they never have to be re-derived. Line numbers refer to the Vineflower
decompile described below and to the vanilla Lua of 42.20.4; they shift between builds.

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

- No Lua interpreter. Syntax-check with luaparser: `pip3 install --target <scratch>/py luaparser`, then
  `PYTHONPATH=<scratch>/py python3 -c "from luaparser import ast; ast.parse(open(f).read())"`. It only checks syntax;
  walking its AST for free names is a cheap way to spot typos in globals.
- Python 3 with Pillow and `sips` are available (image sizes, generating lists of game files).
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
  vanilla never uses `string.byte/char`, so avoid them. `tostring` of an integer-valued number gives "5", but
  `getText(key, n)` gives "5.0" — pass `string.format("%d", n)`.
- Files: `getFileWriter(name, createIfNull, append)` / `getFileReader(name, createIfNull)` (nil if missing) read and
  write `Zomboid/Lua/<name>`. Server identity on a client: `getServerIP()`, `getServerPort()` ("" in single player);
  save name: `getWorld():getWorld()` (`getCurrentSaveName()` is the full save folder path).
- Keys: `Events.OnKeyPressed(key)`, `getKeyName(key)`; mod key binds via `PZAPI.ModOptions` (see below).

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
- Sandbox vars do not exist yet when a mod file loads. `IsoWorld.init` calls `SandboxOptions.load` (server/SP; a client
  already has the server's) before `GlobalModData.init`, which fires `OnInitGlobalModData` — so load-time work that depends
  on an option (e.g. item script `DoParam`) goes there. There is no Lua event for sandbox options changing mid-game;
  re-check on a timer (`EveryTenMinutes`) if a load-time change must follow the option. UI strings go in `Translate/EN/IG_UI.json`
  as `IGUI_ZomboidFixesB42_*`.
- Every feature is listed in README.md, workshop.txt (`description=[*]...`) and mod.info (`description=- ...`); keep all three in step.

## Networking (Java)

- Packets are `INetworkPacket` classes annotated `@PacketSetting(requiredCapability=..., handlingType=...)`.
  `handlingType` bits: 1 = server handles, 2 = client handles, 4 = client while loading.
  `PacketTypes.PacketType.onServerPacket` drops a packet unless `PacketAuthorization.isAuthorized(connection, type)`
  (the sender's role must hold `requiredCapability`), then `parseServer` -> `isConsistent` -> anticheats -> `processServer`.
- `INetworkPacket.send(IsoPlayer, type, ...)` on the server goes to that player's own connection only;
  `INetworkPacket.send(type, ...)` on a client goes to the server.

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

Client commands: `ClientCommand` packet is priority 1, reliability 2 = RakNet RELIABLE (**not ordered**), capability
LoginOnServer. `PacketsCache.isLimitExceeded`: a client silently drops (cancels) packets of one type beyond
`MaxPacketsPerSecond` (server option, default 300) per second. `TableNetworkUtils` serialises string, double, boolean,
nested table (plus item, direction, dead body) keys/values; anything else is skipped.
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
  `cursor.skipWalk2 = true` or the build cheat is on; set `skipWalk2` for a pure picker. Vanilla's Horde Manager
  (`ISSpawnHordeUI:onSelectNewSquare`) and Tile Picker do not, so picking a square there makes the character walk to it.
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
`server/Vehicles/VehicleCommands.lua`: `vehicle.remove` (permanently removes any vehicle by id). Only their callers' UIs
are gated. Candidates for a hardening fix.

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
- `ISButton` draws everything in its own `prerender`/`render`; a subclass can replace both (call `self:updateTooltip()`).
  `onRightMouseUp(x, y)` is not handled by ISButton, so a subclass can take it.
- `ISScrollingListBox:prerender` calls `doDrawItem(y, item, alt)` for **every** row every frame (skip off-screen rows:
  visible while `y + h >= -getYScroll()` and `y <= -getYScroll() + height`); `onMouseDown(x, y)` gets `y` in content
  coordinates, so `rowAt(x, y)` works directly.
- `PZAPI.ModOptions:create(id, name)` / `addKeyBind(id, name, key, tooltip)` / `getOption(id):getValue()`. Saved values are
  only read back by `PZAPI.ModOptions:load()`, which vanilla calls when it builds the options screen — call it at
  `OnGameStart` to have saved key binds in game. A mod key bind **drops Shift/Ctrl/Alt**: the options screen records
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
- Textures: `tryGetTexture(name)` = `getSharedTexture` (loose files and pack entries) then `media/textures/`, nil if
  missing. Map symbols (`MapSymbolDefinitions.getInstance():getSymbolCount()/getSymbolByIndex(i)`, `getId()`,
  `getTexturePath()`, 91 in 42.20) are white, so they tint. Item icons: script item `getIcon()` (or
  `getIconsForTexture():get(0)`) as `Item_<icon>`; `ISUIElement:drawScriptItemIcon(scriptItem, x, y, a, w, h)`.
  Traits/professions: `CharacterTraitDefinition.getTraits()` / `CharacterProfessionDefinition.getProfessions()` →
  `getTexture()`. Tiles: `getWorld():getAllTilesName()` → `"<set>_<n>"`, n < 256. Lua cannot list folders.
- `getText(key, arg)` formats a Lua number as a Java Double ("1.0"); pass `string.format("%d", n)`.
- `UIManager.AddUI` / `RemoveElement` only queue; `UIManager.getUI()` (top-level Java elements, `ui:getTable()` →
  the Lua table) changes at the next `UIManager.update`. Base `close()` of ISPanel / ISPanelJoypad /
  ISCollapsableWindow only hides; vanilla reopens windows with `instance:close()` or `closeModal()`. Every forage,
  stash and world item icon is an `ISBaseIcon` (ISPanel) in the UIManager, appearing as the player moves.
- Foraging debug (`ISSearchManager.createDebugContextMenu`): `ISSearchManager.getManager(player)`,
  `getAndActivateZoneAtXY(x, y)` (nil outside a forage zone), `createSpecificIcon(square, fullType, zoneData, nil, nil, n)`,
  `createAllIconsOnSquare(square, catName|nil)`, `refreshZoneIcons(square)`, `moveAllZoneIconsToSquare(square)`, all
  local only; overlays `ISSearchManager.showDebug` / `showDebugLocations` (drawn only with showDebug, in search mode).
  `forageSystem.itemDefs` is keyed by full type, `catDefs` by name (`IGUI_SearchMode_Categories_<name>`).
- `media/ui/circle.png` is a white disc, handy for tinted status dots. `media/ui` holds ~1540 loose PNGs (moodles in
  32/48/64/80/96/128 folders, sidebar icons in 48/64/80/96/128 with `_<size>` suffixes, emotes, speed controls,
  `LootableMaps/map_*.png` = the map symbols). The sidebar Admin icon is grey (Off) / reddish (On), so it tints.
- Item icon names differ from item names (`Base.Pistol` → `Item_HandGun3`, `Base.NoiseTrap` → `Item_NoiseMaker`), and some
  items have no `Icon` in their script at all (`Base.Key1`, `Base.Screwdriver`, `Base.Hammer`), so resolve through the
  script item, never by guessing `Item_<name>`.

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
- `*_AdminHotbar*.lua` (client only): admin hotbar. Core (bar, slots, settings dialog, pickers, persistence per
  server in `Zomboid/Lua/ZomboidFixesB42_AdminHotbar_<ip>_<port>.ini`, sidebar button, ModOptions keys), Actions (the
  catalog, one `Hotbar.registerAction` per admin tool), Capture ("Add to Hotbar" in vanilla windows), Icons (icon refs
  `sym:` / `item:` / `tex:`, picker; the media/ui path list is generated from the install). A slot = action + settings;
  toggles read their state back from the game every 200 ms; `window = true` slots open the vanilla window.
  Actions marked `opensWindow` (plus openUI and the windows category) remember the UIs that appear within 1.5 s
  and a second click closes them. `slot.steps` = extra `{ action, settings, window }` run after the slot's own
  (`Hotbar.partsOf`): all resolved first (asked player / square / vehicle shared), one confirm, then each step after its own `delay` (ms, default 300, 0 = same frame, `Hotbar.stepDelay`);
  saved as `steps.#n.*` on the slot line. Focus (`Bar:updateFocus`): many vanilla windows never `bringToTop` on a
  click (ISInventoryPage), so on each press the bar brings itself, or the window it covers that was clicked, to the front.
  Single player: only with `-debug` (`isDebugEnabled()`), every capability assumed, each action has vanilla's single
  player branch, server-only actions greyed out; the sidebar button goes under the lowest button (no Admin button),
  slots saved to `ZomboidFixesB42_AdminHotbar_SinglePlayer.ini`.
