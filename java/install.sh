#!/usr/bin/env bash
# Installs the Java part of Zomboid Fixes B42 into the game folder, or removes it. Close the game first.
#   java/install.sh install     (shipped as install.bash) copy zfix-agent.jar to <game>/ZomboidFixesB42/ (java.ini only when there is none, so
#                               your choices stay) and add -javaagent right after PZ Optimization's
#   java/install.sh uninstall   take the argument out and delete <game>/ZomboidFixesB42/
# PZ_DIR = the game folder (on a Linux server: the folder with projectzomboid.jar). Files come from this script's own
# folder (the Workshop download) or, in the repository, Contents/mods/ZomboidFixesB42/42.20/java/ (java/build.sh).
# Steam's Verify integrity and game updates rewrite ProjectZomboid64.json: run install again after them.
# Windows: use install.ps1 instead (it also sets up the server start files and the launch option the game needs there).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src="$here"; [[ -f "$src/zfix-agent.jar" ]] || src="$here/../Contents/mods/ZomboidFixesB42/42.20/java" # shipped copy: files beside it
: "${PZ_DIR:?set PZ_DIR to the game folder}"
dst="$PZ_DIR/ZomboidFixesB42"
json="$PZ_DIR/ProjectZomboid64.json"
py=python3; command -v python3 >/dev/null || py="py -3"

# Ours goes right after PZ Optimization's agent, or first without it, and always before any other -javaagent.
edit_json() {
  $py - "$json" "$1" <<'PY'
import json, sys
p, mode = sys.argv[1], sys.argv[2]
ours, pzopt = "-javaagent:ZomboidFixesB42/zfix-agent.jar", "-javaagent:pzopt/agent/pzopt-agent.jar"
j = json.load(open(p)); v = [a for a in j.get("vmArgs", []) if a != ours]
if mode == "add":
    v.insert(v.index(pzopt) + 1 if pzopt in v else 0, ours)
j["vmArgs"] = v
json.dump(j, open(p, "w"), indent="\t")
print("launcher:", " ".join(a for a in v if a.startswith("-javaagent")) or "no agents")
PY
}

case "${1:-}" in
  install)
    [[ -f "$src/zfix-agent.jar" ]] || { echo "no $src/zfix-agent.jar: run java/build.sh first" >&2; exit 1; }
    mkdir -p "$dst"
    cp "$src/zfix-agent.jar" "$dst/"
    [[ -f "$dst/java.ini" ]] || cp "$src/java.ini" "$dst/"
    edit_json add
    echo "installed into $dst" ;;
  uninstall)
    edit_json remove
    rm -rf "$dst"
    echo "removed $dst" ;;
  *) echo "usage: $0 install|uninstall" >&2; exit 2 ;;
esac
