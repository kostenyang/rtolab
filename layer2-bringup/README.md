# Layer 2 — VCF Installer / Cloud Builder Bring-up

把 VCF Installer (9.x) 或 Cloud Builder (5.2.1) 接到 4 台 nested ESXi，自動 bring up Management Domain。三版本各自獨立資料夾，腳本 self-contained — 不再共用 dispatcher，每版本一份 Generate / Submit / New-VcfLab + 自己的 template，互不干擾。

```
layer2-bringup/
├── README.md                            # 本檔
├── timeout-tuning.md                    # 慢速 lab 的 domainmanager timeout workaround
├── timeout-tuning-operations-log.md
├── vcf90/                               # VCF 9.0 (含 VCF Operations 三件套)
│   ├── bringup.template.json
│   ├── Generate-BringupSpec.ps1         # 無 -Version 參數 (9.0 hardcoded)
│   ├── Submit-Bringup.ps1               # JWT auth, user=admin@local
│   └── New-VcfLab.ps1                   # 一鍵 wrapper
├── vcf91/                               # VCF 9.1 (skipChecks 陣列)
│   ├── bringup.template.json
│   ├── Generate-BringupSpec.ps1
│   ├── Submit-Bringup.ps1
│   └── New-VcfLab.ps1
└── vcf521/                              # VCF 5.2.1 (Cloud Builder)
    ├── bringup.template.json            # 含 pscSpecs / overLayTransportZone
    ├── Generate-BringupSpec.ps1
    ├── Submit-Bringup.ps1               # Basic Auth, user=admin
    └── New-VcfLab.ps1
```

## 跑法（單版本 self-contained）

前提：
1. Layer 1 Deploy-NestedESXi 已部好對應版本的 4 台 nested ESXi（mgmt/vmotion/vsan vmk OK）
2. `inventory/lab.yaml` 的 `vcf.versions["<V>"]` 填好，`hosts_by_version["<V>"]` 4 台
3. `inventory/secrets/lab.yaml` 填好（9.0 需 `operations.*`，5.2.1 需 `cloud_builder.admin_pw`）
4. VCF Installer / Cloud Builder appliance 已部署、IP 可達

```powershell
# VCF 9.0
cd layer2-bringup\vcf90
pwsh .\New-VcfLab.ps1 -VcfInstaller https://192.168.114.34

# VCF 9.1
cd layer2-bringup\vcf91
pwsh .\New-VcfLab.ps1 -VcfInstaller https://192.168.114.5

# VCF 5.2.1 (Cloud Builder URL, 不是 VCF Installer)
cd layer2-bringup\vcf521
pwsh .\New-VcfLab.ps1 -CloudBuilder https://192.168.114.54
```

各 wrapper 內部依序跑：
1. `Generate-BringupSpec.ps1 -LabMode` → 產生 `generated-bringup.json`（同資料夾，已 .gitignore）
2. `Submit-Bringup.ps1 ... -ValidateOnly` → 對 Installer/CB 跑 validation
3. 人類打 `YES` → `Submit-Bringup.ps1` 真的送 bring-up + poll

## Lab workarounds 差異（依版本）

| Version | -LabMode 做的事 |
|---|---|
| **9.0** | `skipEsxThumbprintValidation=true` + `skipGatewayPingValidation=true` + 強制 `datastoreSpec.vsanSpec.esaConfig.enabled=false` + 拔 `hostSpecs[].sslThumbprint` placeholder |
| **9.1** | 注入 `skipChecks` 陣列：`NESTED_CPU_CHECK` / `NIC_COUNT_CHECK` / `MIN_HOST_CHECK` / `VSAN_ESA_HCL_CHECK` / `ESX_THUMBPRINT_CHECK` |
| **5.2.1** | `skipEsxThumbprintValidation=true` + `deployWithoutLicenseKeys=true` + `ceipEnabled=false`；template 已預設 `excludedComponents=["AVN","EBGP"]` |

正式環境每個 wrapper 都加 `-SkipLabMode`。

## Auth 差異（依版本）

| Version | Endpoint | Auth | User | Env Var |
|---|---|---|---|---|
| **9.0** / **9.1** | VCF Installer `/v1/tokens` → JWT Bearer | `admin@local` | `VCF_INSTALLER_PW` |
| **5.2.1** | Cloud Builder Basic Auth on every call | `admin` | `CB_ADMIN_PW` |

## 切版本 SOP

DNS 三版本 FQDN 共存（[ip-plan.md](../inventory/ip-plan.md)），所以 swap version **不用動 DNS**：
1. 確認 inventory 的 `vcf.versions["<V>"]` 跟 `hosts_by_version["<V>"]` 都填好
2. 在外層 vC swap 對應的 nested ESXi VM（`-90` / `-91` / `-521` 後綴已預留）
3. `pwsh ./layer1-nested/Prepare-NestedESXi.ps1` 套 vSAN/LSOM workaround
4. `cd layer2-bringup\<vcfXX>; pwsh .\New-VcfLab.ps1 ...`

## 待補

- [ ] VCF 9.1 OpenAPI 對齊欄位名（`nsxtSpec` vs `nsxSpec`），跑 `-ValidateOnly` 看 error 對齊
- [ ] VCF 9.0 `vcfOperationsSpec.nodes[].type` 確認是 `master` 還是 `primary`（9.0.1+ 可能改）
- [ ] 多 workload domain → 拆到 layer3-postbringup/
