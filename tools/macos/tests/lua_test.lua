-- Unit tests for the macOS updater Lua scripts (macos/lua/*.lua).
-- Run with luajit from the repo root: luajit tools/macos/tests/lua_test.lua
-- Loads each script with the _TEST guard so only its pure helpers are returned
-- (no host globals, network or io are touched).

local passed, failed = 0, 0
local function ok(cond, name)
	if cond then
		passed = passed + 1
	else
		failed = failed + 1
		io.write("  FAIL: " .. name .. "\n")
	end
end
local function eq(actual, expected, name)
	ok(actual == expected, name .. " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")")
end

local function loadTestModule(path)
	_G._TEST = true
	local chunk = assert(loadfile(path))
	local mod = chunk()
	_G._TEST = nil
	assert(type(mod) == "table", path .. " did not return its test helpers")
	return mod
end

local UC = loadTestModule("macos/lua/UpdateCheck.lua")
local UA = loadTestModule("macos/lua/UpdateApply.lua")

-- parseReleaseTag
do
	local e, b = UC.parseReleaseTag("v0.19.0-macos.4")
	eq(e, "0.19.0", "parseReleaseTag engine")
	eq(b, "4", "parseReleaseTag build")
	local e2 = UC.parseReleaseTag("0.20.0-macos.10")
	eq(e2, "0.20.0", "parseReleaseTag without leading v")
	ok(UC.parseReleaseTag("v0.19.0-macos.4-beta") == nil, "parseReleaseTag rejects suffix")
	ok(UC.parseReleaseTag("v0.19.0") == nil, "parseReleaseTag rejects plain version")
	ok(UC.parseReleaseTag("nonsense") == nil, "parseReleaseTag rejects garbage")
end

-- isNewer
ok(UC.isNewer("0.19.0", 3, "0.19.0", 4) == true, "isNewer build bump")
ok(UC.isNewer("0.19.0", 4, "0.19.0", 3) == false, "isNewer older build")
ok(UC.isNewer("0.19.0", 3, "0.19.0", 3) == false, "isNewer same not newer")
ok(UC.isNewer("0.9.0", 9, "0.10.0", 1) == true, "isNewer 0.10 > 0.9")
ok(UC.isNewer("0.19.0", 1, "0.20.0", 1) == true, "isNewer engine bump")
ok(UC.isNewer("0.19.0", 2, "0.19.0", 10) == true, "isNewer build 10 > 2")
ok(UC.isNewer("0.20.0", 1, "0.19.0", 99) == false, "isNewer engine beats build")

-- parseManifestVersion
do
	local txt = '<PoBVersion>\n\t<Version number="0.19.0" platform="macos-arm64" macbuild="3" />\n</PoBVersion>'
	local n, p, b = UC.parseManifestVersion(txt)
	eq(n, "0.19.0", "parseManifestVersion number")
	eq(p, "macos-arm64", "parseManifestVersion platform")
	eq(b, 3, "parseManifestVersion build")
	local n2, p2, b2 = UC.parseManifestVersion('<Version number="0.21.0" />')
	eq(n2, "0.21.0", "parseManifestVersion bare number")
	ok(p2 == nil, "parseManifestVersion no platform")
	ok(b2 == nil, "parseManifestVersion no build")
	ok(UC.parseManifestVersion("garbage") == nil, "parseManifestVersion garbage")
end

-- parsePortVersion
do
	local e, b = UC.parsePortVersion("0.21.0-macos.7")
	eq(e, "0.21.0", "parsePortVersion engine")
	eq(b, "7", "parsePortVersion build")
	ok(UC.parsePortVersion("0.21.0") == nil, "parsePortVersion rejects bare engine version")
	ok(UC.parsePortVersion("garbage") == nil, "parsePortVersion rejects garbage")
end

-- buildUpdateChangelog
do
	local port =
		"VERSION[0.21.0-macos.7][2026/06/15]\n* seven\n\n" ..
		"VERSION[0.21.0-macos.6][2026/06/13]\n* six\n\n" ..
		"VERSION[0.20.0-macos.5][2026/06/12]\n* five\n"
	local engine =
		"VERSION[0.21.0][2026/06/13]\n* engine 21\n\n" ..
		"VERSION[0.20.0][2026/06/11]\n* engine 20\n"

	-- Port-only update: installed 0.21.0 build 6 -> only macos.7 is new. Engine
	-- section is included verbatim; the popup trims it (top header == running
	-- engine), so it is correct to ship it whole here.
	local portOnly = UC.buildUpdateChangelog(port, engine, "0.21.0", 6)
	ok(portOnly:find("0.21.0-macos.7", 1, true) ~= nil, "buildUpdateChangelog keeps newer port entry")
	ok(portOnly:find("* seven", 1, true) ~= nil, "buildUpdateChangelog keeps newer port body")
	ok(portOnly:find("0.21.0-macos.6", 1, true) == nil, "buildUpdateChangelog drops installed port entry")
	ok(portOnly:find("* six", 1, true) == nil, "buildUpdateChangelog drops installed port body")
	ok(portOnly:find("* five", 1, true) == nil, "buildUpdateChangelog drops older port body")
	ok(portOnly:find("* engine 21", 1, true) ~= nil, "buildUpdateChangelog appends engine changelog")

	-- Engine update: installed 0.20.0 build 5 -> macos.6 and macos.7 are new.
	local engineBump = UC.buildUpdateChangelog(port, engine, "0.20.0", 5)
	ok(engineBump:find("0.21.0-macos.7", 1, true) ~= nil, "buildUpdateChangelog (engine bump) keeps macos.7")
	ok(engineBump:find("0.21.0-macos.6", 1, true) ~= nil, "buildUpdateChangelog (engine bump) keeps macos.6")
	ok(engineBump:find("0.20.0-macos.5", 1, true) == nil, "buildUpdateChangelog (engine bump) drops installed macos.5")
	ok(engineBump:find("* engine 21", 1, true) ~= nil, "buildUpdateChangelog (engine bump) appends engine changelog")

	-- Missing port changelog (older bundle): fall back to the engine changelog.
	eq(UC.buildUpdateChangelog(nil, engine, "0.21.0", 6), engine, "buildUpdateChangelog falls back to engine text")
	eq(UC.buildUpdateChangelog("", "", "0.21.0", 6), "", "buildUpdateChangelog empty inputs -> empty")
end

-- shquote (UpdateCheck + UpdateApply share the same definition)
eq(UC.shquote("plain"), "'plain'", "shquote plain")
eq(UC.shquote("a b"), "'a b'", "shquote spaces")
eq(UC.shquote("O'Brien"), "'O'\\''Brien'", "shquote apostrophe")
eq(UA.shquote("O'Brien"), "'O'\\''Brien'", "UpdateApply shquote apostrophe")

-- UpdateApply.buildInstaller
do
	local app = "/Applications/Path of Building (PoE2).app"
	local staged = "/Users/o'brien/Library/Caches/PathOfBuilding-PoE2-Update/v0.19.0-macos.4/Path of Building (PoE2).app"
	local root = "/Users/o'brien/Library/Caches/PathOfBuilding-PoE2-Update"
	local s = UA.buildInstaller(app, staged, root)
	ok(s:sub(1, 9) == "#!/bin/sh", "installer shebang")
	ok(s:find("APP='/Applications/Path of Building (PoE2).app'", 1, true) ~= nil, "installer APP quoted with spaces")
	ok(s:find("'/Users/o'\\''brien/", 1, true) ~= nil, "installer escapes apostrophe in cache path")
	ok(s:find('pgrep -f "$APP/Contents/MacOS/"', 1, true) ~= nil, "installer waits via pgrep on bundle path")
	ok(s:find("xattr -dr com.apple.quarantine", 1, true) ~= nil, "installer clears quarantine")
	ok(s:find('mv "$APP" "$BAK"', 1, true) ~= nil, "installer backs up before swap")
	ok(s:find('open "$APP"', 1, true) ~= nil, "installer relaunches")
end

print(string.format("Lua helper tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
