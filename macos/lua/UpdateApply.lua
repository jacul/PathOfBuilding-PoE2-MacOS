-- Path of Building (PoE2) - macOS port
--
-- Drop-in replacement for upstream's UpdateApply.lua. `package_app.sh` copies
-- this over the bundled copy, so upstream's launch:ApplyUpdate("normal") runs it
-- (via LoadModule, in the main Lua state). UpdateCheck.lua has already
-- downloaded, verified and extracted the new .app into a cache dir; this hands
-- off to a small detached helper that waits for the app to quit, swaps the .app
-- in place, clears the download quarantine, and relaunches.
--
-- No native Update.exe-style helper is needed: macOS lets a detached /bin/sh
-- script replace a running bundle, and it waits for us by bundle path (pgrep)
-- rather than needing a PID.

-- ===========================================================================
-- Pure helpers. Also returned for unit tests via the _TEST guard; the drop-in
-- run never sets _TEST.
-- ===========================================================================

local function shquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build the detached installer shell script. It waits for the running app
-- (matched by bundle path) to quit, swaps the staged .app into place with a
-- rollback backup, clears quarantine, relaunches, and cleans the cache.
local function buildInstaller(appPath, stagedApp, stageRoot)
	return table.concat({
		"#!/bin/sh",
		"trap '' HUP",
		"APP=" .. shquote(appPath),
		"STAGED=" .. shquote(stagedApp),
		"STAGE_ROOT=" .. shquote(stageRoot),
		'exec >"$STAGE_ROOT/installer.log" 2>&1',
		-- Wait for this app to quit (max ~60s) so the bundle isn't in use.
		"i=0",
		'while pgrep -f "$APP/Contents/MacOS/" >/dev/null 2>&1; do',
		'\ti=$((i+1)); [ "$i" -ge 300 ] && break',
		"\tsleep 0.2",
		"done",
		'[ -d "$STAGED" ] || { open "$APP"; exit 1; }',
		'BAK="$STAGE_ROOT/previous.app"',
		'rm -rf "$BAK"',
		'if ! mv "$APP" "$BAK"; then open "$APP"; exit 1; fi',
		'if ! /usr/bin/ditto "$STAGED" "$APP"; then rm -rf "$APP"; mv "$BAK" "$APP"; open "$APP"; exit 1; fi',
		'/usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true',
		'open "$APP"',
		'rm -rf "$STAGE_ROOT"',
		"",
	}, "\n")
end

if _TEST then
	return {
		shquote = shquote,
		buildInstaller = buildInstaller,
	}
end

-- ===========================================================================
-- Drop-in script (runs in the main Lua state via LoadModule).
-- ===========================================================================

local home = os.getenv("HOME") or "/tmp"
local stageRoot = home .. "/Library/Caches/PathOfBuilding-PoE2-Update"

-- Which staged build did the check prepare?
local pending = io.open(stageRoot .. "/pending.txt", "r")
if not pending then
	print("No staged update to apply.")
	return
end
local tag = pending:read("*l")
pending:close()
if not tag or tag == "" then
	print("No staged update to apply.")
	return
end

local stageDir = stageRoot .. "/" .. tag
local stagedApp = stageDir .. "/Path of Building (PoE2).app"
if not io.open(stagedApp .. "/Contents/MacOS/PathOfBuilding-PoE2", "r") then
	print("Staged update is missing or incomplete.")
	return
end

-- Resolve the running bundle from the script path
-- (<App>.app/Contents/Resources/src).
local scriptPath = (GetScriptPath and GetScriptPath()) or "."
local appPath = scriptPath:gsub("/Contents/Resources/src$", "")
if appPath == scriptPath or not appPath:match("%.app$") then
	print("Couldn't locate the application bundle to update.")
	return
end

local installerPath = stageDir .. "/installer.sh"
local file = io.open(installerPath, "w")
if not file then
	print("Couldn't write the installer script.")
	return
end
file:write(buildInstaller(appPath, stagedApp, stageRoot))
file:close()

print("Applying update " .. tag .. "...")
-- Launch the helper detached (& returns immediately) and quit so it can replace
-- the bundle and relaunch us.
SpawnProcess("/bin/sh " .. shquote(installerPath) .. " >/dev/null 2>&1 &")
Exit()
