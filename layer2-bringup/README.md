# Layer 2 — VCF Installer Bring-up (9.0 + 9.1)

把 VCF Installer 接到 4 台 nested ESXi，自動 bring up Management Domain (vCenter + NSX + SDDC Manager，9.0 還會多 Operations / Fleet / Collector)。

同一份 inventory 同時支援 VCF **9.0** 與 **9.1** 兩個版本，靠 `-Version` 切換模板。

## 三隻 PowerShell + 兩份 template

| 檔案 | 角色 |
|---|---|
| `vcf90-bringup.template.json` | VCF 9.0 JSON template (含 `vcfOperationsSpec` / `vcfOperationsFleetManagementSpec` / `vcfOperationsCollectorSpec`，`datastoreSpec.vsanSpec`，`networkSpec.includeIpAddressRanges` 等 9.0-only 欄位) |
| `vcf91-bringup.template.json` | VCF 9.1 JSON template (`skipChecks` 陣列、頂層 `vsanSpec`) |
| `Generate-BringupSpec.ps1` | 渲染 template + sops 解密 secrets + 套用 lab workaround → generated-bringup.json. 接 `-Version 9.0|9.1` |
| `Submit-Bringup.ps1` | 推到 VCF Installer API，先 validation 再 bring-up，poll 完成。9.0 / 9.1 共用 (端點都是 `/v1/sddcs`) |
| `New-VcfLab.ps1` | 一鍵 wrapper：產 spec → validate → 人類確認 → bring-up. 接 `-Version 9.0|9.1` |

## 跑法

前提：
1. 4 台 nested ESXi (對應版本：9.0 部署用 ESXi 9.0.2 OVA；9.1 升級流程見 [layer4-day2/](../layer4-day2/README.md))
2. `layer1-nested/Prepare-NestedESXi.ps1` 已跑過（advanced settings 套用完成）
3. VCF Installer appliance 已部署且可由執行機器連到
   - 9.0: `VCF-SDDC-Manager-Appliance-9.0.1.0.*.ova`
   - 9.1: `VCF-SDDC-Manager-Appliance-9.1.0.0.*.ova`
4. `inventory/lab.yaml` 填好 (`vcf.version` 與對應的 9.0/9.1 區塊)
5. `inventory/secrets/lab.yaml` 用 sops 加密好（有 age 私鑰）；9.0 多需 `operations.{root_pw,admin_pw}`

```powershell
cd layer2-bringup

# VCF 9.0 (預設依 inventory 的 vcf.version, 也可顯式指定)
pwsh ./New-VcfLab.ps1 -VcfInstaller https://<vcf-installer-ip-or-fqdn> -Version 9.0

# VCF 9.1
pwsh ./New-VcfLab.ps1 -VcfInstaller https://<vcf-installer-ip-or-fqdn> -Version 9.1
```

`Generate-BringupSpec.ps1` 會自己用 sops 解密 `inventory/secrets/lab.yaml`，不需要先 source 任何 env vars。

## Lab workarounds (依版本不同)

`-LabMode`（預設開）的行為按 VCF 版本分：

**VCF 9.1** — 在 spec 注入 `skipChecks` 陣列：
- `NESTED_CPU_CHECK`
- `NIC_COUNT_CHECK`
- `MIN_HOST_CHECK`
- `VSAN_ESA_HCL_CHECK`
- `ESX_THUMBPRINT_CHECK`

**VCF 9.0** — 9.0 沒有 `skipChecks` 陣列，旗標散在各 spec 內；`-LabMode` 會：
- 設 `skipEsxThumbprintValidation = true` (省 thumbprint 探測 / placeholder)
- 設 `skipGatewayPingValidation = true` (lab gateway 可能不回 ICMP)
- 強制 `datastoreSpec.vsanSpec.esaConfig.enabled = false` (nested ESA 對 HCL 嚴)
- 從 `hostSpecs[].sslThumbprint` 拔掉 `REPLACE_OR_SKIP` placeholder

正式環境加 `-SkipLabMode`。

### domainmanager timeout 調整

慢速 lab 還需把 VCF Installer / SDDC Manager 的 `domainmanager` timeout 參數調大,
避免 appliance OVF 佈署 / 服務啟動超時導致 bring-up 失敗:

- [timeout-tuning.md](timeout-tuning.md) — 調整的參數、受影響主機、備份與回退
- [timeout-tuning-operations-log.md](timeout-tuning-operations-log.md) — 實際操作指令(含取得 root 的 pty + su 方法)

## 待補

- [ ] VCF 9.1 OpenAPI 對齊欄位名（nsxtSpec? nsxSpec?），跑 `-ValidateOnly` 看 error 對齊
- [ ] VCF 9.0 OpenAPI 對齊欄位名 (`vcfOperationsSpec.nodes[].type` 是否還用 `master` 還是 `primary`，9.0.1+ 可能改)
- [ ] vCenter / NSX / SDDC Manager IP 拉進 inventory (目前 9.1 還靠 template 內 `default` 兜底)
- [ ] William Lam VCF 9.1 lab post 的 skipChecks 確切名稱對齊
- [ ] 多 workload domain → 拆到 layer3-postbringup/
