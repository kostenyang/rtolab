# Nested ESXi clone troubleshooting

Master → OVA → clone × 9 流程踩過的雷, 留給未來 (or 其他人) 重做 5.2.1 / 9.0 / 9.1 三組環境時參考.

## TL;DR — 兩個被混在一起的問題

被 jumpbox `Test-Connection` 同時擋住, 看起來像同一個 bug, 拆開才看清:

1. **Gateway 設錯** (inventory 寫 `.1`, 實際是 `.254`)
2. **vmk0 卡在 master state.tgz 的舊 MAC** (clone 拿的新 vNIC MAC 不被認)

修這兩個的順序很重要 — 沒先修 (2), clone 內部就不通任何東西; 沒修 (1), clone 內部 OK 但 jumpbox 永遠看不到 (return path 死在不存在的 gateway).

---

## 問題 1: gateway `.1` vs `.254`

`install-cheatsheet.md` 跟早期 inventory 都寫 `gateway 192.168.114.1`, 但 SELAB underlay 的 gateway 其實是 `.254` (跟 `172.16.10.254` 同 convention). `.1` 根本不存在.

### 判斷方法

從 clone (或 master) 內部跑:
```sh
ping 192.168.114.200    # AD/kosten — 同 VLAN L2, 不用 gateway
ping 192.168.114.1      # 應該的 gateway
ping 192.168.114.254    # 真正的 gateway
esxcli network ip neighbor list
```
如果 `.200` 通但 `.1` ARP `incomplete` → gateway 設錯. `.254` 通 → 就是 `.254`.

### 修法

[inventory/lab.yaml](../inventory/lab.yaml#L60-L64) `network.{mgmt,vmotion,vsan,overlay}.gateway` 改 `.254`. 已存在的 host 不會自動套, 要重跑 [Apply-CloneIp.ps1](Apply-CloneIp.ps1).

---

## 問題 2: vmk0 MAC 卡在 master 的舊 binding

ESXi 把 vmk0 ↔ MAC 的 binding 存在 `state.tgz` 裡. 從 master OVA 部出來的 clone 雖然 vCenter 給了新的 vNIC HW MAC (vmnic0), 但 ESXi boot 起來 vmk0 還是 bind 到 master 留下來的舊 MAC. → vmk0 收到的 frame destination MAC 對不上 → 整個 mgmt 不通.

### 症狀

```sh
esxcli network nic list | grep vmnic0
#   vmnic0 ... 00:50:56:a5:a0:40 ← clone 的新 MAC

esxcli network ip interface list
#   vmk0 MAC: 00:50:56:67:16:58 ← 舊的, 不是 vmnic0
```

### 為什麼 `/Net/FollowHardwareMac=1` post-boot 沒救

我先試 post-boot 設 `=1` 然後 `vmk0` enable/disable cycle, 沒用. 因為:
- 這個 advanced setting 只在 **boot 時** 跟著 state.tgz 載 vmk0 設定那一刻 evaluate
- 而且如果 `auto-backup.sh` 跑不起來 (見下面那個雷), 改了也只活在 RAM, reboot 就還原成 `=0`

### 修法 (硬幹)

直接把 vmk0 砍了重 add, 明確指定 MAC = vmnic0 的:

```sh
VMNIC0_MAC=$(esxcli network nic list | awk '/vmnic0/{print $8}')
esxcli network ip interface remove --interface-name=vmk0
esxcli network ip interface add  --interface-name=vmk0 \
    --portgroup-name='Management Network' --mac-address="$VMNIC0_MAC"
```

包成 [Fix-CloneNetwork.ps1](Fix-CloneNetwork.ps1), 透過 GuestOps 跑 — 不需要 SSH (因為 clone 那時候根本還 ping 不到).

### 給未來 master 用的長期解法

部 master 時 (Configure-NestedEsxiSsh 階段) 就先把 `/Net/FollowHardwareMac=1` 烤進 state.tgz:

```powershell
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost <master-ip>
```

之後從這個 master 再 export 出來的 OVA, 部 clone 第一次 boot 時 vmk0 會自動 bind 到當下 HW MAC (vmnic0), 不用手動 fix.

> **注意**: 我們現有的 3 個 master OVA (esxi8 / esxi9.0 / esxi9.1) — 9.0/9.1 烤是烤了, 但 `auto-backup.sh` 在 master 上能寫 boot bank (SSH-root 不被擋); 5.2.1 OVA 我**重 export 過**了, 烤完才 export, 已經內建 `=1`. 9.0/9.1 OVA 是當時 export 時還沒烤, 之後要 redeploy clone 應該也要重 export.

---

## 小坑備忘

### A. `esxcli ... ipv4 set -g X` 剛 add 時會炸

```
Cannot set an interface gateway when the default gateway for the netstack 'defaultTcpipStack' is not configured.
```

vmk0 剛 `add` 完, netstack 沒 default route, 不給設 interface-level gateway. 但你又不能先 `route add default` (route add 也要求網段裡有 vmk).

兩階段:
```sh
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK       # 不帶 -g
esxcli network ip route ipv4 add  --gateway $GW --network default            # 現在 vmk 有 IP 了, 可加 route
esxcli network ip interface ipv4 set -i vmk0 -t static -I $IP -N $MASK -g $GW # 回頭寫 interface gateway 欄位
```
codified 在 [Apply-CloneIp.ps1](Apply-CloneIp.ps1) `$sh` 段.

### B. GuestOps API 是 sandbox, 不是 full root

VMware Tools 的 `StartProgramInGuest` 在 ESXi 9.x 上跑出來的 root 進程, 一堆 syscall 被擋:

| 操作 | GuestOps | SSH |
|------|----------|-----|
| `ping`, `nc`, raw socket | ❌ "socket() returns -1 (Operation not permitted)" | ✓ |
| `touch /etc/<anything>` | ❌ "Operation not permitted" | ✓ |
| `/sbin/auto-backup.sh` | ❌ "Access denied by vmkernel access control policy" (crypto-util 開不了 kernel key) | ✓ |
| `esxcli ...` (settings/network) | ✓ | ✓ |

所以 flow 是:
1. clone 剛部好不通 → 只能用 GuestOps 跑 `esxcli` 把 IP 設好
2. clone IP 通了 → 改 SSH 進去做 persist (`auto-backup.sh`) 跟其他 privileged ops

### C. Upstream MAC table 會 churn

```
attempt  1: X
attempt  2: X
attempt  3: OK
attempt  4: OK
```

剛配好 IP 從 jumpbox `ping` 第一次失敗, 過 10-20 秒突然就通. 是 upstream 物理 switch 的 MAC table / 上游 router 的 ARP cache 在重學. 三個版本 12 台 clone 在同一個 trunk portgroup 上, MAC 數量會超過小型 switch 的 per-port limit, LRU eviction → 偶爾就掉.

如果某台**一直**不通:
```sh
esxcli network ip interface set --interface-name=vmk0 --enabled=false
sleep 2
esxcli network ip interface set --interface-name=vmk0 --enabled=true
```
強制送 gratuitous ARP, upstream 重學. esx01-521 (.50) 最後就是這樣救回來的.

---

## Recipe: 從零再做一次

```powershell
# 1. 部 12 個 nested VM (空殼)
pwsh scripts/Deploy-NestedESXi.ps1

# 2. 手裝 3 個 master (DCUI, gateway 用 .254 不是 cheat sheet 寫的 .1)
#    照 install-cheatsheet.md 的「聰明流程」, 各裝 1 台

# 3. SSH 進每個 master, 跑:
pwsh scripts/Configure-NestedEsxiSsh.ps1 -EsxiHost 192.168.114.50  # 521
pwsh scripts/Configure-NestedEsxiSsh.ps1 -EsxiHost 192.168.114.30  # 9.0
pwsh scripts/Configure-NestedEsxiSsh.ps1 -EsxiHost 192.168.114.14  # 9.1

# 4. 烤 FollowHardwareMac=1 + auto-backup
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost 192.168.114.50
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost 192.168.114.30
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost 192.168.114.14

# 5. Export 三個 OVA
pwsh scripts/Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-521
pwsh scripts/Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-90
pwsh scripts/Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-91

# 6. 從 OVA 部 9 台 clone (esx02-04 × 3 版)
pwsh scripts/Deploy-FromGoldenOva.ps1 -WipeFirst

# 7. 修 clone vmk0 MAC (因為 ExtraConfig guestinfo.* 沒走 OVF transport,
#    local.sh 讀不到, 還是要手動 fix)
pwsh scripts/Fix-CloneNetwork.ps1     # 重 bind vmk0 到 vmnic0 MAC
pwsh scripts/Apply-CloneIp.ps1        # 套 IP / gateway / hostname / DNS

# 8. 從 jumpbox 驗證 12 台全通
@('192.168.114.50','.51','.52','.53','.30','.31','.32','.33','.14','.15','.16','.17') |
    %{ Test-Connection $_ -Count 2 -Quiet }
```

如果 step 8 有 X, 大多是 MAC churn — 等 30 秒 retry, 或對該台跑 vmk0 enable/disable cycle.
