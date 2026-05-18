# IP Plan — rtolab.local 機房 + VCF 9.0 / 9.1 / 5.2.1 三版本共存

rtolab.local 是獨立機房；同一份 [lab.yaml](./lab.yaml) pre-allocate 三組 VCF **IP + FQDN**，每版本佔每個 /24 的一個 /28（16 IPs）+ /27 TEP pool，互不重疊。三組 FQDN 也同時存在 DNS — `kosten-vcf90-*` / `kosten-vcf91-*` / `kosten-vcf521-*`。

SELAB-Cluster underlay 共用四條 VLAN/portgroup：mgmt 114 / vmotion 115 / vsan 116 / overlay 117。

## 網路拓樸總覽

| Network | Role | Hosts |
|---|---|---|
| **172.16.10.0/24** | Windows jumpbox / automation host 段 | `selab-win2022-jump.rtolab.local` @ `.32` (這份 git + PowerShell 跑的機器) |
| **192.168.114.0/24** (pg114) | VCF mgmt + AD/DNS | kosten (AD @ .200) + VCF mgmt VMs (見下方) |
| **192.168.115.0/24** (pg115) | vMotion vmkernel | ESXi vmotion vmk (kosten-vcf*-esxNN-vmot) |
| **192.168.116.0/24** (pg116) | vSAN vmkernel | ESXi vsan vmk (kosten-vcf*-esxNN-vsan) |
| **192.168.117.0/24** (pg117) | NSX overlay TEP | NSX transport node 從 pool 拿 |
| **SELAB 中央 vC** | 跑 nested ESXi VMs 的外層 vCenter | `selabvc.rtolab.local` (IP 待填) |

## 主子網 IP 配置（每 /24）

| Component               | VCF 9.1 | VCF 9.0 | VCF 5.2.1 |
|-------------------------|---------|---------|-----------|
| ESXi host #1            | `.14`   | `.30`   | `.50`     |
| ESXi host #2            | `.15`   | `.31`   | `.51`     |
| ESXi host #3            | `.16`   | `.32`   | `.52`     |
| ESXi host #4            | `.17`   | `.33`   | `.53`     |
| VCF Installer / Cloud Builder | `.5` | `.34` | `.54`     |
| SDDC Manager            | `.10`   | `.35`   | `.55`     |
| vCenter (mgmt)          | `.11`   | `.36`   | `.56`     |
| NSX Manager node        | `.12`   | `.37`   | `.57`     |
| NSX Manager VIP         | `.13`   | `.38`   | `.58`     |
| VCF Operations          | (day-2) | `.40`   | n/a       |
| VCF Ops Fleet Mgmt      | (day-2) | `.41`   | n/a       |
| VCF Ops Collector       | (day-2) | `.42`   | n/a       |
| **Block**               | **.5 + .10-.17** | **.30-.49** | **.50-.69** |

ESXi vmotion 末段對齊 mgmt：`.115.14-.17 / .115.30-.33 / .115.50-.53`。vsan 同理用 `.116.x`。

## NSX TEP / Overlay Pool（VLAN 117，/24 切 /27）

| Version    | TEP range            |
|------------|----------------------|
| VCF 9.1    | `.32-.95`  (64 IPs)  |
| VCF 9.0    | `.96-.159` (64 IPs)  |
| VCF 5.2.1  | `.160-.223` (64 IPs) |

## DNS 預期記錄（rtolab.local + 4 條反向 zones）

權威 DNS = [`kosten.rtolab.local` @ 192.168.114.200](./lab.yaml#L25)。三版本 FQDN **同時並存**，IP 跟 FQDN 都各自獨立，所以 DNS 切版本不用改 record。

從 Windows jumpbox (172.16.10.32) 到 AD (192.168.114.200) 需要 routing。

### Zones (5 條, AD-integrated Primary, Secure dynamic update)

| Zone | 用途 |
|---|---|
| `rtolab.local`             | Forward (全 FQDN) |
| `10.16.172.in-addr.arpa`   | Reverse 172.16.10.0/24 (jumpbox 段) |
| `114.168.192.in-addr.arpa` | Reverse 192.168.114.0/24 (mgmt) |
| `115.168.192.in-addr.arpa` | Reverse 192.168.115.0/24 (vmotion) |
| `116.168.192.in-addr.arpa` | Reverse 192.168.116.0/24 (vsan) |

### Shared FQDN (固定, 三版本共用)

| FQDN | IP |
|---|---|
| `kosten.rtolab.local`             | 192.168.114.200 |
| `selab-win2022-jump.rtolab.local` | 172.16.10.32 |
| `selabvc.rtolab.local`            | (待填) |

### 每版本 mgmt VM FQDN (Role 命名: `kosten-vcf<v>-<role>`)

| Role           | VCF 9.0                              | VCF 9.1                              | VCF 5.2.1                            |
|----------------|--------------------------------------|--------------------------------------|--------------------------------------|
| SDDC Manager   | `kosten-vcf90-sddc`  @ `.114.35`     | `kosten-vcf91-sddc`  @ `.114.10`     | `kosten-vcf521-sddc`  @ `.114.55`    |
| inner vCenter  | `kosten-vcf90-vc`    @ `.114.36`     | `kosten-vcf91-vc`    @ `.114.11`     | `kosten-vcf521-vc`    @ `.114.56`    |
| NSX VIP        | `kosten-vcf90-nsx`   @ `.114.38`     | `kosten-vcf91-nsx`   @ `.114.13`     | `kosten-vcf521-nsx`   @ `.114.58`    |
| NSX node 1     | `kosten-vcf90-nsxn1` @ `.114.37`     | `kosten-vcf91-nsxn1` @ `.114.12`     | `kosten-vcf521-nsxn1` @ `.114.57`    |
| VCF Installer / CB | `kosten-vcf90-inst` @ `.114.34`  | `kosten-vcf91-inst` @ `.114.5`       | `kosten-vcf521-cb`   @ `.114.54`     |
| VCF Operations | `kosten-vcf90-ops`   @ `.114.40`     | —                                    | —                                    |
| Fleet Mgmt     | `kosten-vcf90-fleet` @ `.114.41`     | —                                    | —                                    |
| Collector      | `kosten-vcf90-coll`  @ `.114.42`     | —                                    | —                                    |

### 每版本 ESXi mgmt + vmotion + vsan vmkernel FQDN

| Host (per version) | mgmt vmk          | vmotion vmk            | vsan vmk              |
|--------------------|-------------------|------------------------|-----------------------|
| **VCF 9.0** esx01  | `kosten-vcf90-esx01` @ `.114.30` | `kosten-vcf90-esx01-vmot` @ `.115.30` | `kosten-vcf90-esx01-vsan` @ `.116.30` |
| VCF 9.0 esx02..04  | `…-esx02..04`      | `…-esx02..04-vmot`      | `…-esx02..04-vsan`     |
| **VCF 9.1** esx01..04 | `kosten-vcf91-esx01..04` @ `.114.14-.17` | `…-vmot` @ `.115.14-.17` | `…-vsan` @ `.116.14-.17` |
| **VCF 5.2.1** esx01..04 | `kosten-vcf521-esx01..04` @ `.114.50-.53` | `…-vmot` @ `.115.50-.53` | `…-vsan` @ `.116.50-.53` |

共 **54 條 forward A**（+ kosten/jumpbox 2 條 shared）**+ 對應 56 條 reverse PTR**，全由 [`scripts/Set-DnsRecords.ps1`](../scripts/Set-DnsRecords.ps1) 自動 push。

## 推 / 重推 DNS

```powershell
# 一次推完三版本 (預設行為)
pwsh .\scripts\Set-DnsRecords.ps1

# 限定單版本 (rare, 例如只更新 9.0 IP 漂移)
pwsh .\scripts\Set-DnsRecords.ps1 -Version 9.0

# 清掉舊的 short FQDN (sddc-mgr / vcf-* / esx01-04 等, 一次性)
pwsh .\scripts\Set-DnsRecords.ps1 -CleanupLegacy
```

腳本是 idempotent: 已正確的 skip, 漂移的 update, 新的 add。

## 切換 active version SOP

DNS 三版本同存，所以**不用動 DNS**，只要：

1. 改 [`lab.yaml`](./lab.yaml) 的 `vcf.version` (或 cmdline 用 `-Version`)
2. 在外層 vCenter (`selabvc.rtolab.local`) 上把舊版本的 nested ESXi VM 關機/快照 / 開新版本 VM (VM 名字後綴 `-91 / -90 / -521` 已預留)
3. `pwsh ./layer1-nested/Prepare-NestedESXi.ps1` 套 vSAN/LSOM workaround
4. `pwsh ./layer2-bringup/New-VcfLab.ps1 -VcfInstaller https://<installer-ip> -Version <X>`
