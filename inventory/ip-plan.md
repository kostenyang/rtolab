# IP Plan — rtolab.local 機房 + VCF 9.0 / 9.1 / 5.2.1 三版本共存

rtolab.local 是獨立機房；同一份 [lab.yaml](./lab.yaml) pre-allocate 三組 VCF IP，每版本佔每個 /24 的一個 /28（16 IPs）+ /27 TEP pool，互不重疊。
SELAB-Cluster underlay 共用四條 VLAN/portgroup：mgmt 114 / vmotion 115 / vsan 116 / overlay 117。

## 網路拓樸總覽

| Network | Role | Hosts |
|---|---|---|
| **172.16.10.0/24** | Windows jumpbox / automation host 段 | `selab-win2022-jump.rtolab.local` @ `.32` (這份 git + PowerShell 跑的機器) |
| **192.168.114.0/24** (pg114) | VCF mgmt + AD/DNS | kosten (AD) + VCF mgmt VMs (見下方) |
| **192.168.115.0/24** (pg115) | vMotion | 只 ESXi vmkernel |
| **192.168.116.0/24** (pg116) | vSAN | 只 ESXi vmkernel |
| **192.168.117.0/24** (pg117) | NSX overlay TEP | NSX transport node 拿 |
| **SELAB 中央 vC** | 跑 nested ESXi VMs 的外層 vCenter | `selabvc.rtolab.local` (IP 待填) |

## 主子網 IP 配置（每 /24）

| Component               | VCF 9.1 (existing) | VCF 9.0    | VCF 5.2.1  |
|-------------------------|--------------------|------------|------------|
| ESXi host #1            | `.14`              | `.30`      | `.50`      |
| ESXi host #2            | `.15`              | `.31`      | `.51`      |
| ESXi host #3            | `.16`              | `.32`      | `.52`      |
| ESXi host #4            | `.17`              | `.33`      | `.53`      |
| VCF Installer / Cloud Builder | `.5` (existing)| `.34`      | `.54`      |
| SDDC Manager            | `.10`              | `.35`      | `.55`      |
| vCenter (mgmt)          | `.11`              | `.36`      | `.56`      |
| NSX Manager node        | `.12`              | `.37`      | `.57`      |
| NSX Manager VIP         | `.13`              | `.38`      | `.58`      |
| VCF Operations          | (day-2)            | `.40`      | n/a        |
| VCF Ops Fleet Mgmt      | (day-2)            | `.41`      | n/a        |
| VCF Ops Collector       | (day-2)            | `.42`      | n/a        |
| **Block**               | **.5 + .10-.17**   | **.30-.49** | **.50-.69** |

（IP 三組 prefix 都用 `192.168.114.<x>` 即 mgmt subnet；vmotion 用 `192.168.115.<同末段>`，vsan 用 `192.168.116.<同末段>`，所以 ESXi vmotion / vsan 是 `.115.14-.17 / .115.30-.33 / .115.50-.53` 以此類推。）

## NSX TEP / Overlay Pool（VLAN 117，/24 切 /27）

| Version    | TEP range            | CIDR            |
|------------|----------------------|-----------------|
| VCF 9.1    | `.32-.95`  (64 IPs)  | 192.168.117.0/24 (用其中 64 個) |
| VCF 9.0    | `.96-.159` (64 IPs)  | 同上            |
| VCF 5.2.1  | `.160-.223` (64 IPs) | 同上            |

## DNS 預期記錄（rtolab.local）

DNS 解析由 [`kosten.rtolab.local` (192.168.114.200)](./lab.yaml#L25) 提供，跟 VCF mgmt VMs 同 subnet。
從 Windows jumpbox (172.16.10.32) 到 AD (192.168.114.200) 需有 routing；rtolab.local zone 三版本共用一份（VIP/SDDC FQDN 字面相同，差別只在 IP），所以**同時間只能跑一個版本**；切換版本前要更新 A record 指到對應 IP。

| FQDN                  | 9.1            | 9.0            | 5.2.1          |
|-----------------------|----------------|----------------|----------------|
| `sddc-mgr.rtolab.local`    | 192.168.114.10 | 192.168.114.35 | 192.168.114.55 |
| `vc-mgmt.rtolab.local`     | 192.168.114.11 | 192.168.114.36 | 192.168.114.56 |
| `nsx-mgmt-01.rtolab.local` | 192.168.114.12 | 192.168.114.37 | 192.168.114.57 |
| `nsx-mgmt.rtolab.local`    | 192.168.114.13 | 192.168.114.38 | 192.168.114.58 |
| `vcf-inst-91.rtolab.local` | 192.168.114.5  | —              | —              |
| `vcf-inst-90.rtolab.local` | —              | 192.168.114.34 | —              |
| `vcf-cb.rtolab.local`      | —              | —              | 192.168.114.54 |
| `vcf-ops.rtolab.local`     | —              | 192.168.114.40 | —              |
| `vcf-fleet.rtolab.local`   | —              | 192.168.114.41 | —              |
| `vcf-coll.rtolab.local`    | —              | 192.168.114.42 | —              |
| `esx01..04.rtolab.local`   | .114.14-.17    | .114.30-.33    | .114.50-.53    |
| `kosten.rtolab.local`        | 192.168.114.200 (固定, 三版本共用) |||
| `selab-win2022-jump.rtolab.local` | 172.16.10.32 (固定, 跨 subnet) |||
| `selabvc.rtolab.local`     | 外層 vC, 固定 (IP 待填) |||

> Installer / Cloud Builder appliance 三版本 FQDN 故意分開（`vcf-inst-91`、`vcf-inst-90`、`vcf-cb`），這樣三台 appliance 可以同時存在；SDDC Manager / vCenter / NSX 等 bring-up 後才生的 VM 共用名字。

## 切換版本 SOP

1. 改 [`lab.yaml`](./lab.yaml) 的 `vcf.version`（或 cmdline 用 `-Version`）
2. 更新 DNS A record 把 `sddc-mgr / vc-mgmt / nsx-mgmt / nsx-mgmt-01` 指到該版本 IP
3. 在外層 vCenter (`labvc.lab.com`) 上把舊版本的 nested ESXi VM 關機/快照 / 開新版本 VM（VM 名字後綴 `-91 / -90 / -521` 已預留）
4. `pwsh ./layer1-nested/Prepare-NestedESXi.ps1` 套 vSAN/LSOM workaround
5. `pwsh ./layer2-bringup/New-VcfLab.ps1 -VcfInstaller https://<installer-ip> -Version <X>`
