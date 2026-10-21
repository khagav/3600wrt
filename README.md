# 3600wrt — Cudy TR3600 v1 自建固件（Kwrt / OpenWrt 25.12 基底）

在 [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt)（openwrt.ai 的線上編譯系統）之上，
疊加本倉庫的修正層與功能層，用 GitHub Actions 編譯 Cudy TR3600 v1 的固件。

本倉庫**不 vendoring 上游**：workflow 在執行時 clone `kiddin9/Kwrt` 與
`openwrt/openwrt`（預設 `25.12` / `openwrt-25.12`），再把 `overlay/` 與 `files/` 疊上去。

> 為什麼不用官方 OpenWrt：截至 **25.12.6**，官方 filogic 目標仍沒有 `cudy_tr3600-v1`
> （只有 ap3000 / m3000 / wr1300），ASU 與 ImageBuilder 都做不出這台機器。Kwrt 是唯一
> 帶 TR3600 DTS 的建置系統，而它的 kernel 是 **6.12.112**，與官方 25.12.6 同版。

---

## 功能總覽

### 板級修正（沒有這些，機器是壞的）

| 問題 | 根因 | 修正 |
|---|---|---|
| 風扇恆全速、不受控 | Kwrt DTS 把 pwm-fan 掛在 **PWM1 + `pwm1_pins`（PIN7，與 JTAG 共用）**，實機風扇在 **PWM0@PIN13**。掛錯時驅動照樣 bind、`cur_state` 照樣動（會騙人），但 PWM0 從未被 claim | `zz-tr3600-fixes.patch` 改成 `pwms = <&pwm 0 50000 0>` + `pinctrl-0 = <&pwm_pins>` |
| 風扇 idle 也在轉 | `mt7987.dtsi` 把 **40 °C** 對到 fan level 1 → 只要 >40 °C 就 50 % 常轉 | 曲線改 **68 / 78 / 88 °C**，`cooling-levels = <0 128 200 255>`；`luci-app-fan` 的 `on_temp` 同步改 68 |
| USB 4G 網卡插上沒網路 | Kwrt 沒有 `/lib/network/wwan/<vid>:<pid>` profile，hotplug 第一行就 `exit 0`；映像也沒有 usbnet kmod | `.config` 加全套 usbnet kmod；`uci-defaults` 建 `network.tether`；`hotplug.d/net` 綁實際 netdev |
| 升完固件 LuCI 版面錯亂 | Kwrt nginx 對 `/luci-static/` 不送 `Cache-Control`，vantage 的 cache-buster 又綁死主題版本 `?v=1.0.4` | uci-defaults 冪等加 `Cache-Control: no-cache` |
| `target/linux` 編譯失敗（mkimage `.its` 錯誤） | `CONFIG_TARGET_PER_DEVICE_ROOTFS=y` 讓未選中的 netgear 裝置產生空 rootfs 節點 | `.config` 設 `n`；`01-tr3600-netgear-rootfs-guard.patch` 雙保險 |

### 性能 / 穩定性

| 功能 | 實作 | 說明 |
|---|---|---|
| **HNAT / PPE 硬 NAT** | `kmod-mediatek_hnat` + `mtkhnat`，預設開 | 2.5G NAT 走硬體 fast path；VPN / SQM / mark 自動回退軟體 |
| **PPE hook 重綁** | `hotplug.d/iface/20-tr3600-hnat` | 4G tether 每次重新枚舉都會拆掉 hook，這支在 `wan/tether` ifup 時重開，避免默默掉回軟轉發 |
| **IRQ 綁核** | `usr/sbin/tr3600-irq-affinity` + `init.d/tr3600-tuning`（S95） | mtk_eth / mt7996e 的隊列中斷輪流綁到四核，避免單核 sirq 100 % |
| **TTL 偽裝** | `etc/nftables.d/90-tr3600-ttl.nft` | 所有往 WAN 的 IPv4 封包統一 TTL 64（`br-lan`/`lo` 除外）；`tr3600-ttl off` 可關 |
| **DNS 快取** | `cachesize 1000 → 10000` | dnsmasq 命中率提升，配 stubby DoT 更明顯 |
| 軟體 flow offload / fullcone | Kwrt 映像預設 | `flow_offloading=1`、`flow_offloading_hw=1`、`fullcone=1` |
| packet steering | Kwrt 映像預設 | `S25packet_steering` |

### 功能

- **首啟設置向導**：全新刷機後打開 `https://192.168.1.1/` 會被導向向導，設定**管理員密碼**與 **Wi-Fi（SSID + 密碼）**，完成後自動消失。
- **Wi-Fi 合一**：2.4G / 5G 共用同一個 SSID，預設 `wrt` / `w1relessc0de`（WPA2-PSK，6 GHz 自動用 WPA3-SAE）。
- **MAC 更換**：`tr3600-mac` 改 WAN / Wi-Fi MAC（random / set / reset），寫入 UCI 持久化。
- **4G 自癒看門狗**：重撥 → USB 重枚舉（`usb3en` 斷電或 unbind/bind）→ 選配重啟。
- **NAS / VPN / DNS**：WireGuard、OpenVPN、ZeroTier、Samba4、minidlna、stubby(DoT)、DDNS、UPnP、umdns、autoreboot。
- **風扇曲線 + LuCI 風扇頁**、**LuCI 主題**（aurora / vantage）。

> SQM 刻意不收：它和 HNAT 衝突（會把 fast path 打回軟體）。

---

## 倉庫結構

```
overlay/devices/mediatek_filogic/
├── patches/zz-tr3600-fixes.patch   # DTS 修正（風扇通道 + 溫控曲線）
└── .config                          # 只編 cudy_tr3600-v1 + usbnet + HNAT + 功能套件

files/                               # 整棵樹複製進 image 的 base-files
├── etc/uci-defaults/
│   ├── 97-tr3600-wifi          # SSID 合一、開兩個 radio、WPA2
│   ├── 98-tr3600-extras        # 4G 看門狗預設 + 啟用 + tuning + 向導狀態
│   └── 99-tr3600-defaults      # 風扇 on_temp、tether、nginx no-cache、DNS 快取、向導 pending
├── etc/hotplug.d/
│   ├── iface/20-tr3600-hnat    # WAN/tether ifup 時重開 PPE hook
│   └── net/25-usb-tether
├── etc/init.d/
│   ├── tr3600-4g-wwatch        # 每分鐘跑看門狗
│   └── tr3600-tuning           # 開機套用 IRQ 綁核
├── etc/nftables.d/90-tr3600-ttl.nft
├── etc/nginx/conf.d/tr3600-setup.locations   # 未完成設置時 "/" → 向導
├── usr/sbin/{tr3600-4g-wwatch,tr3600-mac,tr3600-ttl,tr3600-irq-affinity}
└── usr/lib/lua/luci/{controller/tr3600setup.lua,model/cbi/tr3600-setup.lua}

.github/workflows/build.yml
```

`files/` 用**完整 rootfs 路徑**（`files/etc/...`、`files/usr/...`），workflow 直接
`cp -a files/. <base-files>/`，並在編譯前檢查 15 個關鍵檔案都存在——舊 workflow 手寫
`install` 兩個檔案，導致後來新增的 4G 看門狗根本沒進 image。

---

## 怎麼用

1. **Actions → Build 3600wrt for Cudy TR3600 v1 → Run workflow**
   - `kwrt_ref`：預設 `25.12`
   - `openwrt_ref`：預設 `openwrt-25.12`
   - `kwrt_action`：填 `nocache` 可跳過建置快取
   - `upload_imagebuilder`：是否一併上傳 imagebuilder / initramfs
2. 編譯約 **1.5–3 小時**。
3. 產物：Artifacts → `3600wrt-mediatek_filogic-cudy_tr3600-v1`。

### 刷機

只刷 **`…cudy_tr3600-v1-squashfs-sysupgrade.bin`**。

> ⚠️ `mediatek/filogic` 的 bin 目錄混著別顆晶片的 BL2 loader，刷錯會變磚。
> artifact 只收 `*tr3600*` + `sha256sums` + `profiles.json` + manifest。

```sh
sysupgrade -n /tmp/fw.bin      # 全新刷機（清 /etc，會觸發向導）
```

### 首次開機

1. 電腦接 LAN（或連預設 Wi-Fi `wrt` / `w1relessc0de`）。
2. 瀏覽器打開 `https://192.168.1.1/` → 自動跳到**設置向導**。
3. 首次登入：用戶名 `root`，密碼**留空**（映像裡 root 無密碼）。
4. 設定管理員密碼（≥8 位）與 Wi-Fi → 完成後導向 LuCI 總覽。

---

## 命令列工具

```sh
tr3600-mac show
tr3600-mac wan  random|set aa:bb:cc:dd:ee:ff|reset
tr3600-mac wifi random|set ...|reset
tr3600-mac all  random|reset

tr3600-ttl status|on|off        # TTL 偽裝開關（會 reload firewall）
```

---

## 驗證（刷完在路由器上跑）

```sh
# 風扇必須綁在 PWM0
grep -H . /sys/kernel/debug/pwm            # 要看到 pwm-0 (pwm-fan)

# 溫控曲線（第一個 active trip = 68 °C）
cat /sys/class/thermal/thermal_zone0/trip_point_*_temp

# HNAT 生效
lsmod | grep -E 'mtk_hnat|hnat'
cat /sys/kernel/debug/hnat/hook_toggle     # 1
nft list chain inet fw4 tr3600_ttl         # TTL clamp 規則

# 4G tether
uci show network.tether; ifstatus tether | grep -E 'up|ipv4'

# 向導 / Wi-Fi
uci show tr3600.setup                      # done=1 表示已完成
uci show wireless | grep -E 'ssid|encryption'
```

---

## 已知限制

- **`luci-app-fan` 會覆寫 DTS 的 trip**：`/usr/libexec/fan-control` 每次開機把最低的 active
  trip 改成 `/etc/config/luci-fan` 的 `on_temp`。我們設 68 對齊；在 LuCI 風扇頁手改會蓋掉。
- **`trip_point_N_hyst` 用過即唯讀** → 改 hysteresis 只能改 DTS。
- **MT7990 PCIe 鏈路會掉 → kernel panic 重開**：硬體層（AER RxErr → Surprise Down）。
  可試槓桿：`chosen/bootargs` 的 `pci=pcie_bus_safe`、`pcie_ports=dpc-native`。
- **4G 網卡（Luat Air780EPM `19d1:0001`）USB 鏈路臨界**：掉線是裝置端供電/訊號問題。
- **TR3600 是 USB-C PD 供電（≤15 W）**：請用足瓦 PD 電源，這同時影響 PCIe panic 與 USB 掉線。

---

## 授權

- 上游： [kiddin9/Kwrt](https://github.com/kiddin9/Kwrt)（MIT）、[openwrt/openwrt](https://github.com/openwrt/openwrt)（GPL-2.0）
- 本倉庫只含自己的修正層，不重散布上游程式碼。
