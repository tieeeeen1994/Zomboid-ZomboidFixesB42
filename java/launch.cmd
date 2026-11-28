@echo off
rem Zomboid Fixes B42, Java part: Steam launch option wrapper for Windows (the same as PZ Optimization's pzopt-launch.cmd).
rem   "C:\Windows\System32\conhost.exe" --headless "<game folder>\ZomboidFixesB42\launch.cmd" %command%
rem Java loads an agent's instrument.dll before java.dll and jli.dll, which live in the game's jre64\bin. Steam starts
rem ProjectZomboid64.exe from the game folder, where Windows does not look, so the game would close at once. This puts
rem jre64\bin in front of PATH for this launch only and starts the game from its own folder (the agent path in
rem ProjectZomboid64.json is relative to it). %1 is the game exe Steam passes for %command%, the rest its arguments.
set "PATH=%~dp1jre64\bin;%PATH%"
cd /d "%~dp1"
%*
