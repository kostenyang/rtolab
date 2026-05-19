# Layer 2 Bringup — current status (2026-05-19, ~10:40)

/goal: "deploy VCF 5.2.1 + VCF 9 完成" 進行中.

## ✅ Done

| Item | State |
|---|---|
| 12 nested ESXi VM 部署 + reachable | ✓ |
| ESXi hostname/FQDN/DNS/NTP/cert CN | ✓ |
| 3 installers (9.0 + 9.1 VCF Inst + 5.2.1 CB) web UI live | ✓ |
| `inventory/secrets/lab.yaml` 加 `vcf_installer.*` + `cloud_builder.root_pw` | ✓ |
| **VCF 9.1 bringup spec schema validation PASSES** | ✓ |
| **VCF 9.1 Security/Cert/SSH 階段 PASSES** | ✓ |
| VCF 9.x OpenAPI 拉回, schema 全套打對 (vsanSpec → datastoreSpec.vsanSpec, vmnicsToUplinks array, vspClusterSpec, IpRange.startIpAddress/endIpAddress, vlanId int, teamingPolicy lowercase, NSX TEP IpAddressPool, etc.) | ✓ |
| `Deploy-VcfInstaller.ps1` / `Regen-EsxiCert.ps1` / `Bake-MasterFinalize.ps1` / `clone-troubleshooting.md` | ✓ |
| VCF download tool token 驗證可用, releases list 全套抓得到 | ✓ |
| **VCF 9.1.0.0 binaries 開始下載** (`E:\vcf-depot-91`, ~46GB, java PID 6424) | 🔄 in progress |

## 🔄 In progress: VCF 9.1 binaries depot download

```
ID                                   | Component           | Size
9599b55f...           VCF_OPS_CLOUD_PROXY              2.8 GiB
8adb94df...           VRA (VCF Automation)            14.9 GiB  ← largest
0911b05e...           VIDB (Identity broker)           1.0 GiB
043bbcda...           NSX_T_MANAGER                    7.5 GiB
fe5daf52...           SDDC_MANAGER_VCF                 2.3 GiB
581cfc8b...           VCENTER                         12.0 GiB
2a4a0cfa...           VROPS                            3.1 GiB
TOTAL                                                 ~45.6 GiB
```

Speed ~5 Mbps from depot.broadcom.com → 估 18+ hours. Monitor task `b2ruc1jqg` 會在 java 死掉/完成時通知.

下載完之後:
1. 把 `E:\vcf-depot-91` 透過 `create_vcf9_depot_server_v3.sh` 起 HTTP depot (port 8888)
2. 透過 VCF Installer `/v1/system/depot-config` API 接 depot
3. Re-run validation — "Versions and Bundles" 應該過
4. Submit bring-up

## ⛔ Outstanding: 5.2.1 ESXi build

Cloud Builder 5.2.3 (這版才是現在 broadcom portal 有的) 要 ESXi build `25205845` (8.0U3l). 我們 nested 是 `24022510` (8.0U3 GA).

`skipEsxBuildValidation` flag 不認.

**未來解法 (同一個 token, 同一個下載工具)**: 
```
vcf-download-tool binaries download --depot-store=E:\vcf-depot-521 \
    --depot-download-token-file=c:\Users\Administrator\vcf-token.txt \
    --ceip=DISABLE --vcf-version=5.2.3.0 --component=ESX_HOST -t INSTALL
```
拿到 ESXi 8.0U3l offline depot zip, 跑 `esxcli software profile update` 升 4 台 5.2.1 nested ESXi → 再重 export OVA → redeploy → re-validate.

## 進度時間軸

| Commit | 內容 |
|---|---|
| `5635334` | nested ESXi clone fix scripts |
| `6a20f5f` | clone-troubleshooting.md |
| `3d6a460` | Deploy-VcfInstaller.ps1 + ESXi hostname fix + vSphere 7 vApp gotcha |
| `4c9412f` | Regen-EsxiCert.ps1 |
| `244a7d8` | STATUS.md initial blockers |
| `cbe6eb3` | VCF 9.1 template schema 從 OpenAPI 重寫 — schema 過了 |
| `6027ebf` | STATUS.md (binaries-block) |
| this | STATUS.md (download started) |
