# Zomboid Fixes B42.20

A collection of fixes for Project Zomboid Build 42.20, mostly for multiplayer.

Steam Workshop ID: `3800148259` · Mod ID: `ZomboidFixesB42`

## Fixes

### Admin and debug

- **Fast item transfers.** With Fast Timed Actions on, moving items is quick in multiplayer, like it is in single player.
- **Animal gender.** Changing an animal's gender in the animal info window now changes the animal, and sticks for everyone instead of reverting. Vanilla only flips a hidden flag, so a sow made male keeps the sow model, the sow texture and no mate of her own; the animal is swapped to the matching type instead, so it looks and breeds like what it now is. Works on animals loose in the world, in a hutch, in a trailer and carried, and in single player as well.
- **Foraging debug menu.** Adding, moving and refreshing forage icons now works, and icons you add can be picked up.
- **Item editor.** Edits now save for items anywhere: crates, vehicles, the floor or another player's inventory.
- **Debug Add Fluid.** Adding fluid to a rain collector or any other fluid container in the world with the debug menu now really fills it. Vanilla's server command called `addFluid` without an amount, so it emptied the container instead, and it never synced the result, so the water only seemed to be there until you looked again.
- **Admin tag.** The red admin tag now shows for every admin panel cheat, not just some of them. A sandbox option can hide it completely.

### Gameplay

- **Negative weight items.** Items with negative weight, which let players carry or store more than they should, are deleted automatically.
- **Broken clothing.** Clothing torn apart while worn is dropped for everyone, not just on the wearer's screen, so it no longer comes back undamaged after relogging.
- **Metal shin armor run speed.** Vanilla had the run speed of Metal Shin Armor and Articulated Metal Shin Armor the wrong way round, so the articulated ones were slower. The values are swapped back.
- **Chickens lost in hutch nest boxes.** A hen laying an egg gives up her place inside the hutch while she sits in the nest box, so another bird can walk in and take it. If every place is taken when she finishes, the game deletes her rather than putting her back, and the player just sees a chicken that vanished. She is caught and put back instead.
- **Hutch dirt speed.** Vanilla rolls for nest box dirt once per laying hen every frame, roughly eighty times as fast as the hutch floor beside it, so a busy coop goes from clean to filthy in a couple of minutes. Both counters can be slowed to any share of normal.

### Other mods

- **Guns of Marz attachment tooltips.** The game lists every weapon an attachment fits on a single tooltip line, and a tooltip is only ever as narrow as its widest line, so once Guns of Marz has added thirty guns a scope or a laser throws a banner across the screen. The list is rebuilt under its heading and wrapped to a line length of your choosing. The heading the game writes is left above it with nothing after it: a tooltip layout can only be appended to, and Lua cannot read back a label the game has already written.

## Sandbox options

All options are on the **Zomboid Fixes B42.20** page.

| Option | Default |
| --- | --- |
| Hide Admin Tag While Cheating | Off |
| Delete Negative Weight Items | Off |
| Sync Broken Clothing | Off |
| Rescue Animals Lost In Hutch Nest Boxes | Off |
| Hutch Dirt Speed | 1 (vanilla) |
| Guns of Marz Tooltip Line Length | 0 (off) |

## Installation

Subscribe on the Steam Workshop, or copy `Contents/mods/ZomboidFixesB42` into your `Zomboid/mods` folder.

- Build 42.20 only.
- Must be installed on both the server and clients.
- Admin features stay admin-only.

## License

Copyright (C) 2026 Tien

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for more details.
