-- Path of Building (PoE2) - macOS port
--
-- Drop-in replacement for upstream's Windows file-by-file UpdateCheck.lua.
-- `package_app.sh` copies this over the bundled copy, so upstream's
-- launch:CheckForUpdate runs it unchanged (as a subscript). It reports its
-- result through the normal return value, so the stock toast notification, the
-- "Update Ready" button and the startup/periodic auto-check all work as upstream.
--
-- The macOS app ships as a whole .app, so an "update" is a newer GitHub release
-- of this port. Like upstream (which downloads during the check), this checks
-- the latest release, and when newer downloads + verifies + extracts the new
-- .app into a cache dir, then returns "normal" so ApplyUpdate (our UpdateApply.lua
-- replacement) can swap it in. Returns "none" when up to date.
--
-- Subscript contract (from launch:CheckForUpdate):
--   args:     connectionProtocol, proxyURL, noSSL
--   globals:  GetScriptPath, GetRuntimePath, GetWorkDir, MakeDir
--   sub-calls: ConPrintf, UpdateProgress
--   returns:  "none" | "normal" | (nil, errMsg)
local connectionProtocol, proxyURL, noSSL = ...

local repo = "jacul/PathOfBuilding-PoE2-MacOS"
local zipName = "PathOfBuilding-PoE2-macos-arm64.zip"
local appName = "Path of Building (PoE2).app"

local scriptPath = (GetScriptPath and GetScriptPath()) or "."
local runtimePath = (GetRuntimePath and GetRuntimePath()) or "."

-- Subscripts only inherit package.preload (C modules), not package.path, so
-- point it at runtime/lua before requiring the bundled pure-Lua dkjson.
package.path = runtimePath .. "/lua/?.lua;" .. runtimePath .. "/lua/?/init.lua;" .. package.path
local curl = require("lcurl.safe")
local dkjson = require("dkjson")

local function shquote(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end
local function run(cmd)
	return os.execute(cmd) == 0
end

-- Read the bundled manifest (engine version, platform, macOS build counter)
-- with a simple pattern match (avoids requiring the xml module).
local function readLocalVersion()
	local file = io.open(scriptPath .. "/manifest.xml", "r")
	if not file then
		return nil
	end
	local text = file:read("*a")
	file:close()
	local versionTag = text:match("<Version%f[%s][^>]*/>")
	if not versionTag then
		return nil
	end
	local number = versionTag:match('number%s*=%s*"([^"]*)"')
	local platform = versionTag:match('platform%s*=%s*"([^"]*)"')
	local build = tonumber(versionTag:match('macbuild%s*=%s*"([^"]*)"'))
	return number, platform, build
end

-- Component-wise numeric version compare; falls back to the port build counter.
local function parseParts(str)
	local parts = {}
	for n in tostring(str or ""):gmatch("%d+") do
		parts[#parts + 1] = tonumber(n)
	end
	return parts
end
local function isNewer(engineA, buildA, engineB, buildB)
	local a, b = parseParts(engineA), parseParts(engineB)
	for i = 1, math.max(#a, #b) do
		local av, bv = a[i] or 0, b[i] or 0
		if bv ~= av then
			return bv > av
		end
	end
	return (buildB or 0) > (buildA or 0)
end

local function httpDownload(url, outPath)
	local sink
	if outPath then
		sink = io.open(outPath, "wb")
		if not sink then
			return nil, "cannot write to " .. outPath
		end
	end
	local body = {}
	local easy = curl.easy()
	easy:setopt_url(url)
	easy:setopt(curl.OPT_USERAGENT, "PathOfBuilding-macOS-Updater")
	easy:setopt(curl.OPT_ACCEPT_ENCODING, "")
	easy:setopt(curl.OPT_FOLLOWLOCATION, 1)
	if connectionProtocol then
		easy:setopt(curl.OPT_IPRESOLVE, connectionProtocol)
	end
	if proxyURL then
		easy:setopt(curl.OPT_PROXY, proxyURL)
	end
	if noSSL then
		easy:setopt(curl.OPT_SSL_VERIFYPEER, 0)
		easy:setopt(curl.OPT_SSL_VERIFYHOST, 0)
	end
	easy:setopt_writefunction(function(data)
		if sink then
			sink:write(data)
		else
			body[#body + 1] = data
		end
		return true
	end)
	local _, err = easy:perform()
	local code = easy:getinfo(curl.INFO_RESPONSE_CODE)
	easy:close()
	if sink then
		sink:close()
	end
	if err then
		return nil, err:msg()
	end
	if code ~= 200 then
		return nil, "HTTP " .. tostring(code)
	end
	return outPath or table.concat(body)
end

ConPrintf("Checking for update...")

local localEngine, platform, localBuild = readLocalVersion()
if platform ~= "macos-arm64" then
	-- Dev run / untagged manifest: no in-app update.
	return "none"
end
localBuild = localBuild or 0

-- Latest release metadata. Treat a failure to reach GitHub as "no update" so the
-- silent startup/auto check never nags with an error toast when offline.
local body, err = httpDownload("https://api.github.com/repos/" .. repo .. "/releases/latest")
if not body then
	ConPrintf("Update check skipped: %s", tostring(err))
	return "none"
end
local release = dkjson.decode(body)
local tag = release and release.tag_name
local remoteEngine, remoteBuild = tostring(tag or ""):match("^v?([%d%.]+)%-macos%.(%d+)$")
if not remoteEngine then
	return nil, "Couldn't read the latest version from GitHub."
end
remoteBuild = tonumber(remoteBuild)

if not isNewer(localEngine, localBuild, remoteEngine, remoteBuild) then
	ConPrintf("No update available.")
	return "none"
end

-- Resolve the download URLs for the .app zip and its checksum.
local zipUrl, shaUrl
for _, asset in ipairs(release.assets or {}) do
	if asset.name == zipName then
		zipUrl = asset.browser_download_url
	elseif asset.name == zipName .. ".sha256" then
		shaUrl = asset.browser_download_url
	end
end
if not zipUrl or not shaUrl then
	return nil, "This release is missing the expected download assets."
end

-- Stage outside the .app (so the bundle can be swapped) in a persistent,
-- user-writable cache keyed by tag, so a re-check doesn't re-download.
local home = os.getenv("HOME") or "/tmp"
local stageRoot = home .. "/Library/Caches/PathOfBuilding-PoE2-Update"
local stageDir = stageRoot .. "/" .. tag
local stagedApp = stageDir .. "/" .. appName
local readyMarker = stageDir .. "/.ready"

local function alreadyStaged()
	local file = io.open(readyMarker, "r")
	if file then
		file:close()
		return true
	end
	return false
end

if not alreadyStaged() then
	-- Drop any stale staged versions, then fetch this one.
	run("/bin/rm -rf " .. shquote(stageRoot))
	if not run("/bin/mkdir -p " .. shquote(stageDir)) then
		return nil, "Couldn't create the update cache folder."
	end

	UpdateProgress("Downloading update...")
	ConPrintf("Downloading %s", tag)
	local ok, derr = httpDownload(zipUrl, stageDir .. "/" .. zipName)
	if not ok then
		return nil, "Download failed: " .. tostring(derr)
	end
	ok, derr = httpDownload(shaUrl, stageDir .. "/" .. zipName .. ".sha256")
	if not ok then
		return nil, "Couldn't download the checksum: " .. tostring(derr)
	end

	UpdateProgress("Verifying...")
	if not run("cd " .. shquote(stageDir) .. " && /usr/bin/shasum -a 256 -c " .. shquote(zipName .. ".sha256")) then
		return nil, "Checksum verification failed (the download may be incomplete or corrupt)."
	end

	UpdateProgress("Extracting...")
	if not run("/usr/bin/ditto -x -k " .. shquote(stageDir .. "/" .. zipName) .. " " .. shquote(stageDir)) then
		return nil, "Couldn't extract the update archive."
	end
	local stagedExe = io.open(stagedApp .. "/Contents/MacOS/PathOfBuilding-PoE2", "r")
	if not stagedExe then
		return nil, "The extracted update looks invalid."
	end
	stagedExe:close()

	-- The zip is no longer needed; mark the staged app ready.
	run("/bin/rm -f " .. shquote(stageDir .. "/" .. zipName))
	local marker = io.open(readyMarker, "w")
	if marker then
		marker:write(tag)
		marker:close()
	end
end

-- Record which staged build ApplyUpdate should install.
local pending = io.open(stageRoot .. "/pending.txt", "w")
if pending then
	pending:write(tag)
	pending:close()
end

-- Best effort: surface the new changelog so the stock "Update" popup can show
-- what changed (ignored if the bundle isn't writable).
run("/bin/cp " .. shquote(stagedApp .. "/Contents/Resources/changelog.txt") .. " " .. shquote(scriptPath .. "/changelog.txt") .. " 2>/dev/null")

ConPrintf("Update %s downloaded and ready to apply.", tag)
return "normal"
