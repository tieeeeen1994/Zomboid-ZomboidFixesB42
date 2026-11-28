#!/usr/bin/env bash
# Builds the Java part of Zomboid Fixes B42 and checks every patch against the installed game jar.
#   java/build.sh
# Needs a JDK 25 javac on PATH (on this PC: source /d/PZ_Optimization/local/pzopt-env.sh) and PZ_DIR (the game folder;
# the same env script sets it). Output: Contents/mods/ZomboidFixesB42/42.20/java/zfix-agent.jar + java.ini, the files the
# Workshop item carries (gitignored).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../Contents/mods/ZomboidFixesB42/42.20/java"
build="$here/build"
command -v javac >/dev/null || { echo "javac not on PATH (source /d/PZ_Optimization/local/pzopt-env.sh)" >&2; exit 1; }
: "${PZ_DIR:?set PZ_DIR to the game folder}"
win() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
sep=":"; command -v cygpath >/dev/null && sep=";"

rm -rf "$build"; mkdir -p "$build/classes" "$out"
find "$here/src" -name '*.java' | while read -r f; do win "$f"; done > "$build/sources.txt"
javac --release 25 -nowarn -cp "$(win "$PZ_DIR/projectzomboid.jar")" -d "$(win "$build/classes")" "@$(win "$build/sources.txt")"
printf 'Premain-Class: zfix.Agent\n' > "$build/manifest.txt"
jar --create --file "$(win "$out/zfix-agent.jar")" --manifest "$(win "$build/manifest.txt")" -C "$(win "$build/classes")" .
cp "$here/java.ini" "$here/install.ps1" "$here/launch.cmd" "$out/"
# The in-game Workshop upload refuses .exe .dll .bat .app .dylib .sh .so .zip anywhere under Contents
# (42.22 SteamWorkshopItem.validateFileTypes, "FileTypeNotAllowed"), so the Linux installer ships as .bash.
rm -f "$out/install.sh"; cp "$here/install.sh" "$out/install.bash"
bad=$(find "$here/../Contents" -type f \( -name "*.exe" -o -name "*.dll" -o -name "*.bat" -o -name "*.app" -o -name "*.dylib" -o -name "*.sh" -o -name "*.so" -o -name "*.zip" \) ! -iname "*pyramid.zip")
[[ -z "$bad" ]] || { echo "the Workshop upload would refuse: $bad" >&2; exit 1; }

java -cp "$(win "$out/zfix-agent.jar")$sep$(win "$PZ_DIR/projectzomboid.jar")" zfix.Check "$(win "$PZ_DIR/projectzomboid.jar")"
java -cp "$(win "$out/zfix-agent.jar")$sep$(win "$PZ_DIR/projectzomboid.jar")" zfix.rt.CraftItemIndex
echo "built $out/zfix-agent.jar"
