# Layer 2 Bringup — current status (2026-05-19)

/goal: "deploy VCF 5.2.1 + VCF 9 完成" 中.

## ✅ Done

| Item | State |
|---|---|
| 12 nested ESXi VM 部署 | ✓ 全 reachable |
| ESXi hostname/FQDN/DNS/NTP/cert CN | ✓ |
| 3 installers (9.0 + 9.1 VCF Inst + 5.2.1 CB) | ✓ web UI HTTP 200 |
| `inventory/secrets/lab.yaml` 加 `vcf_installer` + `cloud_builder.root_pw` | ✓ |
| **VCF 9.1 bringup spec schema validation PASSES** | ✓ |
| **VCF 9.1 Security Configuration check PASSES** (cert/SSH/key) | ✓ |
| `Deploy-VcfInstaller.ps1` | ✓ |
| `Regen-EsxiCert.ps1` | ✓ |
| `Bake-MasterFinalize.ps1` | ✓ |
| `clone-troubleshooting.md` | ✓ |
| VCF 9.x OpenAPI 抓回來放 `layer2-bringup/vcf91/vcf-installer-openapi.json` (gitignore'd) | ✓ |

## ⛔ Outstanding hard blockers (need external resources)

### 5.2.1 — ESXi build mismatch
Cloud Builder 5.2.3 (the only OVA on disk) writes死要 ESXi build `25205845` (= 8.0U3l). 我們 nested ESXi 是 build `24022510` (= 8.0U3 GA). 沒 8.0U3l offline depot zip → 無法升級, 也無法繞 (試過 `skipEsxBuildValidation`, CB 不認).

```
[ESXI_BUILD_LOWER.error] build is 24022510 but must be equal to 25205845
```

**解法**: 從 customerconnect.vmware.com 下 `VMware-ESXi-8.0U3l-25205845-depot.zip` (~700MB) → `esxcli software profile update` on 4 hosts → reboot → re-export OVA → redeploy clones → retry validation.

### 9.0 / 9.1 — VCF depot binaries 缺
9.1 spec schema 全過了, security 全過了. 卡在 "Versions and Bundles":
```
[COMPATIBLE_RELEASES_NOT_FOUND.error]   Could not retrieve supported releases
[VALIDATE_COMPONENT_BINARIES.error]     Not all required component binaries for selected versions are available locally
```

VCF Installer 沒 internet 到 `depot.vmware.com` (000 response), 也沒人 pre-download VCF 9.1 LCM bundles 給它. **這些 bundle 大概 50GB+**, 包含 vCenter ISO / NSX OVA / SDDC Manager appliance / ESXi depot / VCF Operations 三件套 / 等等. 需要:
- VMware customer entitlement + token `tpkugIojkHvXMVu2Pf8V6ErxKIn8q7sG`
- `vcf-download-tool-9.1.0.0.tar.gz` 跑 `binaries download --release 9.1.0` 把全套 pull 下來
- 在 jumpbox 或另一台機架 offline depot server (HTTP, port 8888) 服務之 (參考 `E:\SCRIPT\vcf9offlinescript\create_vcf9_depot_server_v3.sh`, 已是 9.1 native HTTP no-auth depot 設定)
- 把 installer 透過 `/v1/system/depot-config` API 接到 offline depot URL

**短路徑** (如果 jumpbox 能下載): 在 jumpbox 跑 `E:\9.0\vcf-download-tool\bin\vcf-download-tool.bat binaries download --release 9.1.0 --depot-tool-config-path ...`, 看會不會直接拉.

## 進度時間軸 (本 session)

| Commit | 內容 |
|---|---|
| `5635334` | nested ESXi clone fix scripts |
| `6a20f5f` | clone-troubleshooting.md (gateway .254 + vmk0 MAC + GuestOps sandbox + MAC churn) |
| `3d6a460` | Deploy-VcfInstaller.ps1 + ESXi hostname fix + vSphere 7 vApp gotcha |
| `4c9412f` | Regen-EsxiCert.ps1 (cert CN fix) |
| `244a7d8` | STATUS.md initial blockers |
| `cbe6eb3` | VCF 9.1 template schema 從 OpenAPI 重寫 — schema 過了 |
| this commit | STATUS.md updated 反映 schema-pass + binaries-block |
