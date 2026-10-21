-- 3600wrt: first-run setup wizard.
--
-- Sets the root password and the Wi-Fi credentials, then clears
-- /etc/tr3600-setup-pending so nginx stops redirecting "/" here.
--
-- The password fields are written to uci by CBI and deleted again in
-- on_after_commit - they are never left behind in /etc/config.

local sys  = require "luci.sys"
local uci  = require "luci.model.uci".cursor()
local disp = require "luci.dispatcher"

local m, s, o

-- make sure the section exists even on an upgraded system
if uci:get("tr3600", "setup", "done") == nil then
	uci:set("tr3600", "setup", "setup")
	uci:set("tr3600", "setup", "done", "0")
	uci:commit("tr3600")
end

m = Map("tr3600", translate("設置向導"),
	translate("首次使用請完成以下設置。管理員密碼與 Wi-Fi 會立即生效，完成後本頁不再自動彈出。"))

-- current Wi-Fi values, used as defaults
local cur_ssid, cur_key
uci:foreach("wireless", "wifi-iface", function(sec)
	if not cur_ssid and sec.mode == "ap" then
		cur_ssid = sec.ssid
		cur_key  = sec.key
	end
end)

local err = luci.http.formvalue("err")
if err == "pw" then
	m.message = translate("管理員密碼至少 8 位，請重新輸入。")
elseif err == "pw2" then
	m.message = translate("兩次輸入的管理員密碼不一致。")
elseif err == "ssid" then
	m.message = translate("Wi-Fi 名稱不能為空（最多 32 個字元）。")
elseif err == "key" then
	m.message = translate("Wi-Fi 密碼至少 8 位。")
end

s = m:section(NamedSection, "setup", "setup", translate("管理員與 Wi-Fi"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "password", translate("管理員密碼"),
	translate("用於 LuCI 與 SSH（root）。至少 8 位。"))
o.password = true
o.rmempty = false
o.datatype = "minlength(8)"

o = s:option(Value, "password2", translate("確認密碼"))
o.password = true
o.rmempty = false
o.datatype = "minlength(8)"

o = s:option(Value, "ssid", translate("Wi-Fi 名稱 (SSID)"),
	translate("2.4G / 5G 使用同一個名稱。"))
o.default = cur_ssid or "3600wrt"
o.rmempty = false
o.datatype = "maxlength(32)"

o = s:option(Value, "key", translate("Wi-Fi 密碼"),
	translate("WPA2-PSK，至少 8 位。"))
o.password = true
o.default = cur_key or ""
o.rmempty = false
o.datatype = "minlength(8)"

function m.on_after_commit(self)
	local pw   = uci:get("tr3600", "setup", "password")
	local pw2  = uci:get("tr3600", "setup", "password2")
	local ssid = uci:get("tr3600", "setup", "ssid")
	local key  = uci:get("tr3600", "setup", "key")

	local function fail(code)
		uci:delete("tr3600", "setup", "password")
		uci:delete("tr3600", "setup", "password2")
		uci:commit("tr3600")
		luci.http.redirect(disp.build_url("admin/tr3600-setup") .. "?err=" .. code)
	end

	if not pw or #pw < 8 then return fail("pw") end
	if pw ~= pw2 then return fail("pw2") end
	if not ssid or ssid == "" then return fail("ssid") end
	if not key or #key < 8 then return fail("key") end

	-- 1. admin password (LuCI + SSH)
	sys.user.setpasswd("root", pw)

	-- 2. Wi-Fi on every AP interface, same SSID on all bands
	local w = require("luci.model.uci").cursor()
	w:foreach("wireless", "wifi-iface", function(sec)
		if sec.mode == "ap" then
			local enc = (sec.encryption == "sae") and "sae" or "psk2"
			w:set("wireless", sec[".name"], "ssid", ssid)
			w:set("wireless", sec[".name"], "encryption", enc)
			w:set("wireless", sec[".name"], "key", key)
			w:set("wireless", sec[".name"], "disabled", "0")
		end
	end)
	w:foreach("wireless", "wifi-device", function(sec)
		w:set("wireless", sec[".name"], "disabled", "0")
	end)
	w:commit("wireless")

	-- 3. mark done, drop the plaintext password, stop the redirect
	w:set("tr3600", "setup", "done", "1")
	w:delete("tr3600", "setup", "password")
	w:delete("tr3600", "setup", "password2")
	w:commit("tr3600")

	os.remove("/etc/tr3600-setup-pending")
	sys.call("wifi reload >/dev/null 2>&1")

	luci.http.redirect(disp.build_url("admin/status/overview"))
end

return m
