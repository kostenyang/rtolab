# VCF 9.1 + Automation — 安裝 / 帳密 / 改密碼 / 除錯 速查

> 本份是 9.1 management domain（含 VCF Automation / Operations）裝好之後的維運速查：
> **怎麼安裝、帳號密碼、怎麼改密碼、怎麼除錯**。
> 搭配 [k8s-access-and-checks.md](./k8s-access-and-checks.md)（K8s 登入/檢查）與
> [vcf-operations-automation-deploy-troubleshooting.md](./vcf-operations-automation-deploy-troubleshooting.md)（部署排錯敘事）一起看。
>
> ⚠️ 本 lab 全部用預設密碼 `VMware1!VMware1!`（私有 lab repo，刻意明文留存以便重建）。
> 正式環境請改掉並改用 sops 加密的 `inventory/secrets/`。

---

## 1. 怎麼安裝（installer workflow 為主）

整套 VCF 9.1 + Automation 用 **VCF Installer 原生 bring-up workflow** 一次送上去，不手動拆步驟。

```powershell
# Layer 2 一鍵：validate → 送 bring-up → 每 60s poll 到 SUCCESS
pwsh ./layer2-bringup/vcf91/New-VcfLab.ps1 -VcfInstaller https://192.168.114.5

# 或只送 spec（已 bake 完整 Option B：VCF + Automation + Operations + Collector + License + vIDB）
pwsh ./layer2-bringup/vcf91/Submit-Bringup.ps1 -VcfInstaller https://192.168.114.5 `
     -SpecFile ./layer2-bringup/vcf91/generated-bringup.json
```

- spec 範本 `bringup.template.json` 已內建 5 個 Option B 區塊，值都從 `inventory/lab.yaml`
  的 `vcf.versions.9.1.management_domain.{automation,operations,license_server,vidb}` 算出來。
- `datastoreSpec.vsanSpec`：**OSA**（`esaConfig.enabled=false`）、`failuresToTolerate=0`（FTT=0）。
- 卡關時優先用 installer 原生 **retry/resume**（`PATCH /v1/sddcs/{id}` = retrySddc），少手動刪 VM / 改 spec。

### 1.1 成功關鍵（這次能一路綠燈的根因修復）

上次 VCFA 元件崩潰的根因是**底層實體 CPU 爭用** → VSP Supervisor etcd `wal_fsync` 飆到秒級
→ kube-controller-manager / scheduler leader-election crashloop → Fleet LCM timeout。修復組合：

1. **底層 .4 / .6 兩台實體機專用**，其他 VM 用 DRS affinity 趕走。
2. 4 台 nested ESXi 記憶體拉到 **128GB** + **CPU 保留** + per-host MUST affinity（esx01/02→.4、esx03/04→.6）。
3. vSAN **FTT=0**。

效果：bring-up 全程 **312/312、0 失敗**；VSP etcd **0 重啟**、node load ~5（修復前是 135）。
即使 VCFA pod burst 時 cm/scheduler 抖了幾下（restarts 6/5）也用 slow-path 自救、沒掉 lease，
**連備好的 `scripts/Fix-VspLeaderElection.ps1` 都沒用上**。

> 備用：若 VCFA burst 時 etcd fsync >25ms 或 cm/scheduler restart 持續跳升，套：
> `pwsh ./scripts/Fix-VspLeaderElection.ps1 -ControlPlaneIp <vsp-cp-real-ip>`（idempotent）。

---

## 2. 帳號密碼 + VIP（9.1 management domain）

| 元件 | FQDN / VIP | IP | 帳號 | 密碼 |
|---|---|---|---|---|
| VCF Installer | kosten-vcf91-inst | 192.168.114.5 | `admin@local`；SSH `vcf` | `VMware1!VMware1!` |
| SDDC Manager | kosten-vcf91-sddc | 192.168.114.10 | `administrator@vsphere.local`；root；本地 `vcf` | `VMware1!VMware1!` |
| vCenter (inner) | kosten-vcf91-vc | 192.168.114.11 | `administrator@vsphere.local`；root | `VMware1!VMware1!` |
| NSX Manager | kosten-vcf91-nsx (VIP) | 192.168.114.13（node1 .12） | `admin`（root / audit 同密碼） | `VMware1!VMware1!` |
| **VCF Automation** | **kosten-vcf91-auto** | **192.168.114.77** | `admin`（經 vIDB）；或 SSO `administrator@vsphere.local` | `VMware1!VMware1!` |
| VCFA platform VIP | kosten-vcf91-vcfa-platform | 192.168.114.87 | — | — |
| VCF Operations | kosten-vcf91-ops | 192.168.114.75 | `admin`；root | `VMware1!VMware1!` |
| VCF Ops Collector | kosten-vcf91-ops-coll | 192.168.114.76 | root | `VMware1!VMware1!` |
| VCF Identity Broker (vIDB) | kosten-vcf91-vidb | 192.168.114.86 | `admin` | `VMware1!VMware1!` |
| License Server | kosten-vcf91-lic | 192.168.114.85 | — | — |
| VSP Supervisor (mgmt) | platformFqdn kosten-vcf91-vspp；API VIP .19 | nodes 192.168.114.20–.23 | SSH `vmware-system-user`（**會輪替**） | `VMware1!VMware1!`（失效見 §4.5） |
| Nested ESXi | kosten-vcf91-esx01..04 | 192.168.114.14–.17 | `root` | `VMware1!VMware1!` |
| Physical ESXi（底層專用） | — | 172.16.10.4 / .6 | `root` | 見 `inventory/secrets/lab.yaml` |

- VCFA node IP pool：.78–.83（VIP .77 / .87 從 pool 取）；internal cluster CIDR `172.27.0.0/16`。
- 登入 VCFA：`https://kosten-vcf91-auto.rtolab.local`（根路徑回 404 正常，主控台在子路徑，登入導向 vIDB .86）。
- Windows jump host 的 hosts 已加好以上 FQDN（`C:\Windows\System32\drivers\etc\hosts`，2026-06-08）。

---

## 3. 怎麼改密碼

### 3.1 VCF 管理式輪替（建議 — SDDC Manager 統一管）
VCF 受管元件（vCenter / NSX / ESXi / SDDC 內部服務）的密碼由 SDDC Manager 管，用 credentials API 輪替：

```powershell
$sddc='192.168.114.10'
$h=@{Authorization="Bearer $token"}   # token 見 Submit-Bringup 的 /v1/tokens 流程
# 列出受管帳密
Invoke-RestMethod -SkipCertificateCheck "https://$sddc/v1/credentials" -Headers $h
# 自動 ROTATE（系統產生新密碼）或 UPDATE（指定新密碼）
$body=@{ operationType='ROTATE'; elements=@(@{ resourceName='kosten-vcf91-vc.rtolab.local'; resourceType='VCENTER'; credentials=@(@{ credentialType='SSO'; username='administrator@vsphere.local' }) }) } | ConvertTo-Json -Depth 6
Invoke-RestMethod -SkipCertificateCheck -Method Patch "https://$sddc/v1/credentials" -Headers $h -Body $body -ContentType 'application/json'
```

> 直接改受管元件密碼但不經 SDDC Manager，會造成 SDDC Manager 與元件**密碼不同步**、後續 day-2 失敗。能走 credentials API 就別手動改。

### 3.2 個別元件（非受管 / 應急）
- **VCFA admin（local，經 vIDB）**：VCFA UI → Identity & Access Management；或 appliance `vracli` / appliance root `passwd`。
- **SSO `administrator@vsphere.local`**：vCenter UI → Administration → SSO → Users；或 vCenter shell `dir-cli password reset --account administrator`。
- **vCenter / SDDC / Ops appliance root**：SSH 進 appliance → `passwd`（root 密碼有效期到期會擋登入，VAMI 也可改）。
- **NSX `admin` / root / audit**：NSX UI → System → Users，或 CLI `set user admin password`。
- **Nested ESXi root**：`esxcli system account set -i root -p '<new>' -c '<new>'`，或用 `scripts/` 內 GuestOps 方式批次改。
- **vIDB `admin`**：vIDB appliance / VAMI。

### 3.3 VSP Supervisor 節點（特例）
Supervisor 節點密碼**由 vSphere with Tanzu 自動輪替**，不要手動改。要登入時去 §4.5 重新取當前密碼。

---

## 4. 怎麼除錯

### 4.1 看 bring-up 進度（installer API）
```powershell
$base='https://192.168.114.5'; $sddcId=(Get-Content ./scripts/_sddcid.txt)
$t=Invoke-RestMethod -SkipCertificateCheck -Method Post "$base/v1/tokens" -Body (@{username='admin@local';password='VMware1!VMware1!'}|ConvertTo-Json) -ContentType 'application/json'
$h=@{Authorization="Bearer $($t.accessToken)"}
$s=Invoke-RestMethod -SkipCertificateCheck "$base/v1/sddcs/$sddcId" -Headers $h
$s.milestones | ForEach-Object { '[{0,-24}] {1}' -f $_.status,$_.name }
$done=($s.sddcSubTasks|?{$_.status -like 'POSTVALID*'}).Count
"done=$done/$($s.sddcSubTasks.Count)  running: $(($s.sddcSubTasks|?{$_.status -eq 'IN_PROGRESS'}).name)"
```

### 4.2 VSP Supervisor 健康（etcd / leader-election）
先用 [k8s-access-and-checks.md §0.1](./k8s-access-and-checks.md) 從 inner vCenter 動態找控制平面 real IP
（`*vspp*` VM 中**持有 2 個 IP**那台 = API VIP holder），再 SSH：
```bash
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl get pods -n kube-system | grep -E 'etcd|controller-manager|scheduler'   # 看 RESTARTS
ep=$(kubectl get pods -n kube-system --no-headers | grep etcd- | awk '{print $1}' | head -1)
kubectl exec -n kube-system $ep -- etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key endpoint status -w table   # IS LEADER / RAFT TERM
```
判讀：`wal_fsync` 健康 <10ms、警戒 >25ms、危險 >100ms；RAFT TERM 不變 = leader 沒換 = 穩。
cm/scheduler restarts 持續跳升才套 `scripts/Fix-VspLeaderElection.ps1`。

### 4.3 VCF Automation pod 狀態
SSH 進 VCFA 平台節點（inner vCenter 找 `*vcfa*` VM），`prelude` namespace 是 VCFA app：
```bash
kubectl get pods -n prelude            # 主要應用 pod
kubectl get pods -A | grep -vE 'Running|Completed'   # 撈非健康
kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

### 4.4 SSH / sudo 取權限（兩個 K8s 節點）
非互動 SSH 沒 tty，sudo 一律 `echo '<pw>' | sudo -S ...`：
```bash
ssh vmware-system-user@<vsp-cp-real-ip>
echo 'VMware1!VMware1!' | sudo -S sh -c 'kubectl get pods -n kube-system'
```
installer / SDDC Manager 要 root 看 log 時用 pty+su：
```bash
(sleep 2; echo '<root-pw>') | script -qec "su - root -c '<cmd>'" /dev/null
```

### 4.5 Supervisor 節點密碼失效時重新取
節點密碼會輪替；從 **inner vCenter** 重新解出當前 root 密碼：
```bash
/usr/lib/vmware/wcp/decryptK8Pwd.py     # 在 inner vCenter appliance 上跑，印出 IP + pwd
```

### 4.6 其他常用排錯參考
- domainmanager timeout 調大、SWSEC stale filter（toggle PG promisc False/True）、Golden OVA clone 陷阱
  → 見 [vcf-operations-automation-deploy-troubleshooting.md](./vcf-operations-automation-deploy-troubleshooting.md) 與 `layer2-bringup/nested-bringup-fixes.md`。
