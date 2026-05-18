# Nested ESXi 手動裝機 cheat sheet

12 台都已部好，每台 CDROM 已掛 ESXi installer ISO，開機進 installer Welcome screen。
**一次裝一台**，照下表順序（**9.1 最後做**）：

> Kickstart ISO 自動裝機暫時擱置 — PwSh.Fw.Iso 的 IMAPI2 wrapper 沒設 PlatformId=0xEF (UEFI)，custom ISO 出不來 UEFI 可開機。手動裝最快。

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
