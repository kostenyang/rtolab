# Nested ESXi 手動裝機 cheat sheet

12 台都已部好，每台 CDROM 已掛 ESXi installer ISO，開機進 installer Welcome screen。

> **聰明做法（推薦）**: 一版本只手裝 **1 台 master** + 加 `/etc/rc.local.d/local.sh` first-boot script + ConvertTo-Template + clone 給另外 3 台 + 設 guestinfo OVF properties → 開機自動配 IP/hostname。
>
> **參考**: https://vtam.nl/2025/08/21/how-to-create-your-own-nested-esxi-ova/ (William Lam 的 nested ESXi OVA 也是這個套路)
>
> **手裝次數**: 3 次（不是 12 次）
>
> 詳見下方〈聰明流程〉，本份 cheat sheet 上方是〈純手裝〉路線（fallback）。

> **註**: Kickstart ISO 自動裝機暫時擱置 — PwSh.Fw.Iso 的 IMAPI2 wrapper 沒設 PlatformId=0xEF (UEFI)，custom ISO 出不來 UEFI 可開機。

## 通用值（所有 VM）

| 項目 | 值 |
|---|---|
| Root password | `VMware1!VMware1!` |
| Netmask | `255.255.255.0` |
| Gateway | `192.168.114.1` |
| VLAN ID (mgmt vmk) | `114` |
| DNS server | `192.168.114.200` |
| Install disk | **Hard disk 1, 10 GB** (← 不要選 100/700 GB 那兩顆 NVMe，那是 vSAN cache/capacity 用) |

## 安裝步驟（每台 VM 重複）

1. **vCenter UI → 開 VM console**（IE/Edge: Web Console, 或 VMRC）
2. ESXi installer Welcome → `Enter`
3. EULA → `F11`
4. 選 disk: 找 `10.00 GiB Local VMware ATA SCSI Disk`（注意是 SCSI，不是 NVMe）→ `Enter`
5. Keyboard → 預設 US Default → `Enter`
6. Root password → `VMware1!VMware1!`（打兩次）→ `Enter`
7. CPU/Hardware compat 警告 → `F11` confirm
8. 等裝（~3-5 min）→ Installation Complete → `Enter` reboot
9. **重要**: reboot 時要從 disk boot, 不要再從 ISO boot。**vCenter UI → Edit Settings → CD/DVD drive → 取消 "Connect at Power On"** 或者直接拔 ISO，避免下次又進 installer
10. ESXi 起來 → 黃黑 DCUI 畫面 → `F2` Customize System → root / `VMware1!VMware1!` 登入
11. **Configure Management Network** → 進去後一個一個改：
    - **IPv4 Configuration** → Static → 填這台的 IP（見下表）
    - **DNS Configuration** → Hostname = 短名（如 `kosten-vcf521-esx01`），Primary DNS = `192.168.114.200`
    - **Custom DNS Suffixes** → `rtolab.local`
    - **VLAN (optional)** → `114`
    - `Esc` 離開 → `Y` Restart Management Network
12. **Test Management Network** → ping AD / DNS → should pass
13. `Esc` Logout

驗證：從 jumpbox 跑 `Test-NetConnection <IP> -CommonTCPPort SSH` 應該通。

---

## 安裝順序（9.1 最後）

### 先做 VCF 5.2.1（ESXi 8.0u3）— 4 台

| # | VM Name | Hostname | IP | 狀態 |
|---|---|---|---|---|
| 1 | `vcf-m02-esx01-521` | `kosten-vcf521-esx01` | `192.168.114.50` | 進行中 |
| 2 | `vcf-m02-esx02-521` | `kosten-vcf521-esx02` | `192.168.114.51` | |
| 3 | `vcf-m02-esx03-521` | `kosten-vcf521-esx03` | `192.168.114.52` | |
| 4 | `vcf-m02-esx04-521` | `kosten-vcf521-esx04` | `192.168.114.53` | |

### 再做 VCF 9.0（ESXi 9.0.2）— 4 台

| # | VM Name | Hostname | IP |
|---|---|---|---|
| 5 | `vcf-m02-esx01-90` | `kosten-vcf90-esx01` | `192.168.114.30` |
| 6 | `vcf-m02-esx02-90` | `kosten-vcf90-esx02` | `192.168.114.31` |
| 7 | `vcf-m02-esx03-90` | `kosten-vcf90-esx03` | `192.168.114.32` |
| 8 | `vcf-m02-esx04-90` | `kosten-vcf90-esx04` | `192.168.114.33` |

### 最後做 VCF 9.1（ESXi 9.1.0）— 4 台

| # | VM Name | Hostname | IP |
|---|---|---|---|
| 9  | `vcf-m02-esx01-91` | `kosten-vcf91-esx01` | `192.168.114.14` |
| 10 | `vcf-m02-esx02-91` | `kosten-vcf91-esx02` | `192.168.114.15` |
| 11 | `vcf-m02-esx03-91` | `kosten-vcf91-esx03` | `192.168.114.16` |
| 12 | `vcf-m02-esx04-91` | `kosten-vcf91-esx04` | `192.168.114.17` |

---

## 裝完後（每版 4 台都好）

跑 `pwsh scripts\ConvertTo-NestedTemplate.ps1 -Versions 5.2.1`（或 9.0/9.1）凍 template。

或一次全凍：`pwsh scripts\ConvertTo-NestedTemplate.ps1`。

---

## 聰明流程（每版只手裝 1 台 master + clone）

### Step 1: 手裝 master (esx01 系列)
照上方〈手動裝機〉一台手裝 `vcf-m02-esx01-521`、`vcf-m02-esx01-90`、`vcf-m02-esx01-91` 共 3 台 master，先用任意能用的 IP 上線（或先用 DHCP，反正等下會被 first-boot script 覆蓋）。

### Step 2: SSH 進 master 加 first-boot script
ESXi 起來、可 ping 到後，從 jumpbox SSH 進去：

```bash
ssh root@<master-ip>
# 貼下方 local.sh 到 /etc/rc.local.d/local.sh
# chmod +x /etc/rc.local.d/local.sh
# /sbin/auto-backup.sh    # 把 local.sh 寫進 boot bank
```

`local.sh` 內容（讀 guestinfo OVF properties, 套 hostname/IP/network)：
```sh
#!/bin/sh
# rtolab nested ESXi first-boot configurator
# 從 VMware Tools guestinfo (OVF vApp properties) 讀, 套到 ESXi

HOSTNAME=$(/usr/bin/vmware-rpctool 'info-get guestinfo.hostname' 2>/dev/null)
IPADDR=$(/usr/bin/vmware-rpctool 'info-get guestinfo.ipaddress' 2>/dev/null)
NETMASK=$(/usr/bin/vmware-rpctool 'info-get guestinfo.netmask' 2>/dev/null)
GATEWAY=$(/usr/bin/vmware-rpctool 'info-get guestinfo.gateway' 2>/dev/null)
VLAN=$(/usr/bin/vmware-rpctool 'info-get guestinfo.vlan' 2>/dev/null)
DNS=$(/usr/bin/vmware-rpctool 'info-get guestinfo.dns' 2>/dev/null)
DOMAIN=$(/usr/bin/vmware-rpctool 'info-get guestinfo.domain' 2>/dev/null)

# 還沒設過? 第一次開機才跑
if [ -f /etc/rtolab-configured ]; then
    exit 0
fi
[ -z "$HOSTNAME" ] && exit 0   # 沒 guestinfo, 不要跑

esxcli system hostname set --fqdn="$HOSTNAME"
esxcli network ip interface ipv4 set -i vmk0 -t static -I "$IPADDR" -N "$NETMASK" -g "$GATEWAY"
esxcli network ip route ipv4 add --gateway "$GATEWAY" --network default
[ -n "$DNS" ] && esxcli network ip dns server add --server="$DNS"
[ -n "$DOMAIN" ] && esxcli network ip dns search add --domain="$DOMAIN"
[ -n "$VLAN" ] && esxcli network vswitch standard portgroup set -p "Management Network" --vlan-id="$VLAN"

vim-cmd hostsvc/enable_ssh
vim-cmd hostsvc/start_ssh

touch /etc/rtolab-configured
```

### Step 3: 把 master 轉 template
```powershell
pwsh scripts\ConvertTo-NestedTemplate.ps1 -VMNamePattern vcf-m02-esx01-521
```

### Step 4: Clone template + 設 guestinfo + 開機
寫小腳本 (TODO): `Clone-NestedFromTemplate.ps1`
- 從 template 開新 VM (esx02-04)
- 設 `guestinfo.hostname` / `guestinfo.ipaddress` / 等 OVF properties
- 開機 → local.sh 第一次跑 → 自動配

開機後 local.sh 自動把 IP 套好, 不用 DCUI。

### Step 5: 其餘 9.0 / 9.1 版本重複

---

## VCF Download Tool (E:\9.0\vcf-download-tool\)

已解開 (9.0.2 build 25151284)。download VCF 9 binaries / metadata 用：

```powershell
# 看可下載 release
E:\9.0\vcf-download-tool\bin\vcf-download-tool.bat releases list

# 認證 (用 token tpkugIojkHvXMVu2Pf8V6ErxKIn8q7sG, 已存 secrets/lab.yaml.vcf9_download_token)
# 下載 VCF 9.0.2 全套 binary
E:\9.0\vcf-download-tool\bin\vcf-download-tool.bat binaries download --release 9.0.2 ...
```

詳細用法 `vcf-download-tool.bat --help` 或 `vcf-download-tool.bat <command> --help`。

