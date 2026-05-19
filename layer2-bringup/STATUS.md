# Layer 2 Bringup — current status (2026-05-19 ~12:30)

## ✅ Done (massive progress this session)

| Item | State |
|---|---|
| 12 nested ESXi reachable + hostname/FQDN/DNS/NTP/cert CN ok | ✓ |
| 3 installers (9.0 + 9.1 VCF Inst + 5.2.1 CB) web UI live | ✓ |
| `inventory/secrets/lab.yaml` 補 `vcf_installer.*` + `cloud_builder.root_pw` | ✓ |
| VCF 9.1 SddcSpec schema 全套對 (vsanSpec → datastoreSpec, vmnicsToUplinks, vspClusterSpec, IpRange.startIpAddress, vlanId int, teaming lowercase, NSX TEP IpAddressPool, nsxTeamings, nsxtSwitchConfig OVERLAY+VLAN tz) | ✓ |
| **VCF 9.1 Deployment Specification 階段 PASSES** | ✓ |
| **VCF 9.1 Security Configuration 階段 PASSES** (cert/SSH/key) | ✓ |
| Scripts: `Deploy-VcfInstaller.ps1` `Regen-EsxiCert.ps1` `Bake-MasterFinalize.ps1` `Configure-LocalDepot.ps1` `clone-troubleshooting.md` | ✓ |
| VCF 9.1 download tool token 驗證 (releases list/binaries download) | ✓ |
| VCF 9.1 binaries depot 拉下 41.3 GB / ~46 GB (6/7 main components 100%, 1 mid-flight when java died) | ✓ |
| ESXi 8.0U3i build `25205845` depot zip 拉到 `E:\vcf-depot-esxi-25205845` (629 MB) | ✓ |
| IIS 8888 HTTP depot serving `E:\vcf-depot-91` (檔案 200 + range request 206 都 ok, MIME 全套加完 .ova .tar .tgz .iso .sig .yaml .xml) | ✓ |
| **VCF Installer 9.1 `/v1/system/settings/depot` PUT 成功** (`DEPOT_CONNECTION_SUCCESSFUL`) | ✓ |
| **End-to-end validation 跑得到 vMotion/vSAN/NSX Network 階段** (之前只能跑到 Deployment Spec) | ✓ |

## ⛔ Outstanding blockers

驗證再跑時剩下這些, 大致分三類:

### A. Versions and Bundles — 缺 bundle 結構 metadata
```
[FAILED_TO_VALIDATE_COMPONENT_VERSIONS_NO_RELEASE.error]
  No release data found for version 9.1.0.0
[FAILED_TO_VALIDATE_COMPONENT_BINARIES_NULL_VERSION.error]
  Could not validate component binaries for the following components:
  VCF services runtime, VMware vCenter, Salt master, SDDC Manager,
  Fleet lifecycle, SDDC lifecycle, VMware NSX, Telemetry, Software
  depot, Salt RaaS, because no version is defined for them in release
  9.1.0.0
```
**原因**: depot tool `--automated-install` 拉下了 binary 檔 (OVA/ISO/tar), 但沒拉 per-bundle metadata XML (`/COMP/<X>/vmw/<bundleId>/upgrade_info.xml` 之類). Broadcom dl 確認那些 metadata 是公開的 (curl HTTPS HEAD 拿得到 133KB), 是 download tool 沒主動抓.

**未來修法**: 改用 `download-spec-file` mode 跑下 GET 拉所有 bundle 結構; 或手動 curl 補 metadata.

### B. ESX 校驗 — 跳過 (skipChecks)
```
[ESXI_VERSION_VALIDATION_STATUS.error] Validate ESX Host version and build failed
[VSAN_ESA_HOST_HCL_COMPATIBLE_ERROR.error] Host ... is not HCL compatible
[ESXI_SERVICE_RUNNING.warning] ntpd not running
```
**修法**: 重新加 `skipChecks` block 進 `Generate-BringupSpec.ps1` (之前 schema 重寫過程刪掉了). 加 `ESX_VERSION_CHECK` `VSAN_ESA_HCL_CHECK` `NIC_COUNT_CHECK` 等.

### C. vmkping VLAN 115/116/117 MTU 9000 失敗 (環境硬限制)
```
[VALIDATE_ESXI_VMKPING.error] ESX Host 'kosten-vcf91-esx01' -> '192.168.115.17'
  VLAN '115' with MTU 9000 fail to vmkping
```
**原因**: VLAN 114 (mgmt) physical switch 是 trunk 過了, 但 115/116/117 可能 physical switch 沒 trunk 過, 或外層 vDS portgroup 設定不對讓 nested ESXi 用這幾個 VLAN.

Outer vDS `selab-dswitch` MTU=9000 ok; trunk portgroup VLAN 0-4094 ok; MAC learning + forged transmits ok. 但實體 switch 可能只有 114 通過. → 需要實體網路調整 (user 側).

## ⏭️ 下一步

1. 加回 `skipChecks` 解 B
2. 補 bundle metadata 解 A (或拿到 download spec file)
3. C 看 user 那邊能否打通 physical VLAN 115/116/117

## 5.2.1

```
5.2.1 CB validation 已過 Security/SSH/Cert 階段, 卡 ESXi build 24022510 ≠ 25205845.
User 自己會抓另一個 CB 版本 (可能 5.2 GA 收 8.0U3 GA).
8.0U3i depot ISO 25205845 已下到 E:\vcf-depot-esxi-25205845, 隨時可拿來升 4 台
nested ESXi (esxcli software profile update + reboot + 重 export OVA + redeploy).
```

## 進度時間軸

| Commit | 內容 |
|---|---|
| `5635334` | nested ESXi clone fix scripts |
| `6a20f5f` | clone-troubleshooting.md |
| `3d6a460` | Deploy-VcfInstaller.ps1 + ESXi hostname fix + vSphere 7 vApp gotcha |
| `4c9412f` | Regen-EsxiCert.ps1 |
| `244a7d8`/`6027ebf`/`7b76cce`/`9a36806` | STATUS.md 一路 update |
| `cbe6eb3` | VCF 9.1 template schema 重寫 (從 OpenAPI 抽出真的 schema) |
| `2379e39` | Configure-LocalDepot.ps1 (PS HttpListener — 後被 IIS 取代) |
| this | STATUS.md (IIS depot + Installer 接上, validation 跑到 network 階段, 剩 3 類 blocker) |
