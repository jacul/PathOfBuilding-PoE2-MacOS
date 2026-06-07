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
