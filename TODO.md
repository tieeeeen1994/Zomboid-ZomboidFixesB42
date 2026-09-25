# TODO

## Square pickers walk the character to the square

Vanilla's Horde Manager "Pick new square" (`ISSpawnHordeUI:onSelectNewSquare`) and the Tile Picker use
`ISSelectCursor`, which is an `ISBuildingObject`. Clicking a square runs `ISBuildingObject:tryBuild`, which walks the
player to the square (`walkTo`) before "building", unless the build cheat is on or the cursor has `skipWalk2 = true`.
Vanilla never sets it, so picking a square makes the character walk there.

Fix: set `skipWalk2 = true` on those cursors (e.g. wrap `ISSelectCursor.new`, since the class is only used as a
picker). New feature, so it needs its own sandbox option (default on), a tooltip, and a line in README.md,
workshop.txt and mod.info. The admin hotbar's own picks already set it (`Hotbar.pickSquare`).
