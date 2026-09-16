# Zomboid Fixes B42.20

A collection of fixes for Project Zomboid Build 42.20, mostly for multiplayer.

Steam Workshop ID: `3800148259` · Mod ID: `ZomboidFixesB42`

## Fixes

### Admin and debug

- **Fast item transfers.** With Fast Timed Actions on, moving items is quick in multiplayer, like it is in single player.
- **Animal gender.** Changing an animal's gender in the animal info window now sticks for everyone instead of reverting.
- **Foraging debug menu.** Adding, moving and refreshing forage icons now works, and icons you add can be picked up.
- **Item editor.** Edits now save for items anywhere: crates, vehicles, the floor or another player's inventory.
- **Admin tag.** The red admin tag now shows for every admin panel cheat, not just some of them. A sandbox option can hide it completely.

### Gameplay

- **Negative weight items.** Items with negative weight, which let players carry or store more than they should, are deleted automatically.
- **Broken clothing.** Clothing torn apart while worn is dropped for everyone, not just on the wearer's screen, so it no longer comes back undamaged after relogging.
- **Metal shin armor run speed.** Vanilla had the run speed of Metal Shin Armor and Articulated Metal Shin Armor the wrong way round, so the articulated ones were slower. The values are swapped back.

## Sandbox options

All options are on the **Zomboid Fixes B42.20** page.

| Option | Default |
| --- | --- |
| Hide Admin Tag While Cheating | Off |
| Delete Negative Weight Items | Off |
| Sync Broken Clothing | Off |

## Installation

Subscribe on the Steam Workshop, or copy `Contents/mods/ZomboidFixesB42` into your `Zomboid/mods` folder.

- Build 42.20 only.
- Must be installed on both the server and clients.
- Admin features stay admin-only.

## License

Copyright (C) 2026 Tien

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the [GNU General Public License](LICENSE) for more details.
