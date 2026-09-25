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
`/checkModsNeedUpdate` ManipulateMods · `/setaccesslevel`, `/grantadmin`, `/removeadmin` ChangeAccessLevel. Without the
`-true/-false` flag, the god mode / invisible / noclip commands flip the current state.

### Vanilla client-command handlers with **no permission check** (any client can call them)

`server/ClientCommands.lua`: `object.addFireOnSquare`, `object.addSmokeOnSquare`, `object.addExplosionOnSquare`
(the Brush Tool's fire control), `event.thunder` (Trigger Thunder window), `player.setWeight`, `object.addFluidDebug`,
`deadBody.addBody`, and most other `object.*`, `fireplace/bbq.setFuel`, `hutch.dirt/nestBoxDirt`, `animal.rename`.
`server/Vehicles/VehicleCommands.lua`: `vehicle.remove` (permanently removes any vehicle by id). Only their callers' UIs
are gated. Candidates for a hardening fix.

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
  `OnGameStart` to have saved key binds in game.
- Textures: `tryGetTexture(name)` = `getSharedTexture` (loose files and pack entries) then `media/textures/`, nil if
  missing. Map symbols (`MapSymbolDefinitions.getInstance():getSymbolCount()/getSymbolByIndex(i)`, `getId()`,
  `getTexturePath()`, 91 in 42.20) are white, so they tint. Item icons: script item `getIcon()` (or
  `getIconsForTexture():get(0)`) as `Item_<icon>`; `ISUIElement:drawScriptItemIcon(scriptItem, x, y, a, w, h)`.
  Traits/professions: `CharacterTraitDefinition.getTraits()` / `CharacterProfessionDefinition.getProfessions()` →
  `getTexture()`. Tiles: `getWorld():getAllTilesName()` → `"<set>_<n>"`, n < 256. Lua cannot list folders.
- `getText(key, arg)` formats a Lua number as a Java Double ("1.0"); pass `string.format("%d", n)`.
- `media/ui/circle.png` is a white disc, handy for tinted status dots.

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
