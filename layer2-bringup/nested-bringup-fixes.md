# VCF 9.1 Nested Bringup — 關鍵修復彙整

整套 nested VCF 9.1 bringup 在 vcf-m02 lab 跑通的關鍵障礙與修法。依 bringup 流程順序排列。每一項都是「不做就會卡住」的硬傷。

---

## 1. vmk0 MAC 不可綁 vmnic0 HW MAC

**卡點**: `Migrate ESX Host Management vmknic(s) to vSphere Distributed Switch`
→ `VSPHERE_CONFIGURE_HOST_DVS_FAILED` / `HostCommunication` / host 變 NotResponding。

**根因**: `Fix-CloneNetwork.ps1` 舊版用 `--mac-address=$VMNIC0_MAC` + `/Net/FollowHardwareMac=1`
把 vmk0 MAC 綁成 vmnic0 的 HW MAC。vmk0 migrate 到 vDS pg-mgmt 後,teaming 是
LOADBALANCE_SRCID 跨 vmnic0+vmnic1。當流量走 vmnic1 出去,source MAC = vmnic0 MAC,
外層 dvSwitch 在兩個 port 看到同一個 MAC → MAC learning 崩掉 → host 失聯 → network rollback。

**修法**: 已修進 `scripts/Fix-CloneNetwork.ps1` (commit d843bbb) — 移除 `--mac-address`
與 `/Net/FollowHardwareMac`,讓 vmk0 自動生成獨立 MAC。William Lam 的 nested 腳本也是
auto-gen MAC,從不綁 vmnic0。

---

## 2. 外層 dvSwitch MAC learning / swsec 設定 (ESXi 7.0 outer)

**卡點**: nested ESXi 部好後 outer 看不到其管理 IP;或 vmk migration 後 L2 不通。

**根因**: 外層 trunk PG 雖設 Promiscuous/Forge/MacChange/MacLearning=True,但 ESXi 7.0.x
的 per-port runtime enforcement 不可靠 (port accepted flags 缺 promisc bit, swsec filter
drop 70-80% 封包)。新建 port (VM 開機 / vMotion / NIC reconnect) 都會帶 stale state。

**修法**:
- 推薦 (ESXi 7/8 native): trunk PG 設 **MAC Learning=True + ForgedTransmit=True**,
  Promiscuous 可不開 (William Lam: native MAC Learning 取代 promisc)。
- 我們的繞法: 每當 L2 卡住,toggle trunk PG `AllowPromiscuous` False→True 強制重推 policy
  到 port + reset swsec filter。
- 觸發 outbound: 從 nested ESXi vmk0 主動 ping gateway 幾次,逼 outer dvSwitch 學到新 MAC。
- 治本: outer host 裝 `dvfilter-maclearn` VIB + nested VM .vmx 加
  `ethernetN.filter4.name=dvfilter-maclearn` / `onFailure=failOpen` (我們 outer 7.0.3 沒裝)。

詳見 memory: `project_outer_swsec_stale.md`。

---

## 3. vCenter Network Rollback 必須關閉 (vmk migration)

**卡點**: vmk0 migrate to vDS 一動就 host 失聯 → 自動 rollback → 任務失敗。

**根因**: vSphere `config.vpxd.network.rollback=true` (預設) 在偵測到 host 短暫失聯
(nested 上 L2 收斂慢) 5 秒內就 revert,nested 環境撐不過這個窗口。

**修法**: 在 **inner vCenter** 設 `config.vpxd.network.rollback = false`。
注意:每次 vCSA 重新部署 (wipe→bringup) 都會重置回 true,要重設。

```powershell
$si = Get-View ServiceInstance
$asMgr = Get-View $si.Content.Setting
$opt = New-Object VMware.Vim.OptionValue
$opt.Key = 'config.vpxd.network.rollback'; $opt.Value = 'false'
$asMgr.UpdateOptions(@($opt))
```

---

## 4. nested ESXi 全部釘在同一台 outer host

**卡點**: vmk migration / VSP 在某些 outer host 上 L2 不通 (那台 swsec stale 沒清)。

**修法**: cluster DRS rule `MustRunOn` 把 4 台 nested ESXi 釘在一台已驗證 OK 的 outer host,
或 deploy 時就全部指到同一台 (`deploy-all-to-104.ps1`)。避免 DRS 把它們散到沒 toggle 過
swsec 的 outer host。注意 wipe 重建後 DRS VM group 引用會失效,要重設。

---

## 5. VSP/Fleet bundle 必須先下載 (VSP bootstrap 前)

**卡點**: `Bootstrap VCF Services Platform`
→ `PUBLIC_VSP_CLUSTER_BOOTSTRAP_FAILED` /
`java.lang.StringIndexOutOfBoundsException: Range [-1, 0)` @ `VspServiceImpl.getBootstrapTask`。

**根因**: VSP + VCF_FLEET_LCM bundle 在 SDDC Manager catalog 是 `downloadStatus=PENDING`
(從未下載)。`getBootstrapTask` 找不到 bundle 的 ova/cliArchive 路徑 → 對空字串 substring → 爆。

**修法**: bootstrap 前先觸發 4 個 bundle 下載 (2×VSP + 2×Fleet),等到 `downloadStatus=SUCCESSFUL`:

```powershell
# 找 VSP/Fleet bundle id
$b = Invoke-RestMethod "https://<sddc>/v1/bundles" -Headers $hdr -SkipCertificateCheck
# 對每個 id PATCH downloadNow
$body = @{ bundleDownloadSpec = @{ downloadNow = $true } } | ConvertTo-Json
Invoke-RestMethod "https://<sddc>/v1/bundles/$id" -Method PATCH -Headers $hdr -Body $body -SkipCertificateCheck
```

下載完 `getBootstrapTask` 會印 `Found VSP deliverables: {ova, cliArchive}`,bug 消失。

---

## 6. SDDC Manager VSP timeout 要拉長 (William Lam workaround)

**卡點**: VSP runtime cluster (K8s) 起不來,bootstrap stage `INFRA0002 - Waiting for VCF
services runtime cluster nodes to become ready` 等到 timeout (預設太短)。

**修法**: SDDC Manager `/etc/vmware/vcf/domainmanager/application.properties` 加:

```
vsp.bootstrap.task.timeout.minutes=240
vsp.bootstrap.command.timeout.minutes=200
orchestrator.task.retry.max=5
nsxt.manager.wait.minutes=180
edge.node.vm.creation.max.wait.minutes=90
```

然後 `systemctl restart domainmanager.service`。來源:William Lam VCF 9.1 Comprehensive
VCF Installer & SDDC Manager Configuration Workarounds。

---

## 7. VSP 部署需要的資源條件

**卡點**: VSP/VSPP appliance (4 vCPU / 10GB) 無法 power on,DRS migration loop。

**修法**:
- inner vCenter cluster **關 HA Admission Control** (否則保留容量擋住 VSPP placement):
  `ClusterDasConfigInfo.AdmissionControlEnabled = $false`。
- inner vSAN **Default Storage Policy 設 FTT=0** (nested 4 host 但容量小,省一半空間)。
- nested ESXi 給 **CPU/Mem reservation** (etcd 對延遲敏感):每台 8GHz CPU + 48GB mem
  熱套 (ReconfigVM,不需 reboot)。
- 外層也建議對這 4 台 nested ESXi 用專屬 FTT=0 policy (不動 global default)。

---

## 8. Domain 用 .local 的隱憂 (未證實但高度懷疑)

VMware 官方 "Bridging the .Local Gap" (2026-04) 指出 VCF 9.1 的 VIDB / Automation /
Supervisor 對 `.local` TLD 有 guardrail。我們 lab 用 `rtolab.local`,MGMT vCenter/NSX/
SDDC Manager 都過了,VSP 階段才卡 — 但實測根因是 bundle PENDING (#5)。若 #5/#6 修完
VSP 仍失敗,考慮改 domain 為 .net/.lab/.internal 重建。

---

## 一句話總結排錯順序

1. Fix-CloneNetwork 別綁 vmk0 MAC (已修進腳本)
2. 4 台 nested 釘同一 outer host + toggle trunk PG promisc reset swsec
3. inner vCenter `network.rollback=false`
4. VSP/Fleet bundle 先下載到 SUCCESSFUL
5. SDDC Manager 套 VSP timeout properties + restart domainmanager
6. 關 HA admission control + FTT=0 + nested ESXi reservation
7. PATCH retry bringup
