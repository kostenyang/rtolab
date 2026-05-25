# VCF 9.1 — "Save VCF Management Components" 失敗修法

## 症狀

VCF Installer 在 "Deploy and configure VCF Management Platform" milestone 失敗於：

```
Task: Save VCF Management Components
Error: FAILED_TO_SAVE_OR_UPDATE_VCF_MGMT_COMPONENTS
Cause: 500 on PATCH https://<sddc-manager>/v1/system/vcf-management-components
       INVENTORY_INTERNAL_SERVER_ERROR
```

此時 vCenter / SDDC Manager / NSX / cluster 都已部完，但 VCF Operations / Automation / Management Services 全部 NOT_STARTED。

## 根因

Installer 把 SddcSpec 翻譯成 SDDC Manager inventory 寫入時，`fleetLcm` 元件被翻成 `fqdn=null`。SDDC Manager DB schema (`vcf_management_component.fqdn`) 是 `NOT NULL`，所以 SQL insert 失敗，整個 PATCH 500。

SDDC Manager `vcf-commonsvcs.log` 會看到：

```
ERROR: null value in column "fqdn" of relation "vcf_management_component" violates not-null constraint
  Detail: Failing row contains (FLEET_LCM, null, NEW, NOT_STARTED).
```

原因是 `vspClusterSpec.fleetFqdn` 在 bringup spec 裡沒填。VCF Installer OpenAPI 定義為：

> `fleetFqdn`: VSP cluster fleet FQDN. **This should be provided in VVF and primary VCF instance.** If building a secondary VCF instance, do not provide this field.

## 修法（事前預防）

在 bringup spec 的 `vspClusterSpec` 加 `fleetFqdn`，並在 DNS 加對應 A record：

```json
"vspClusterSpec": {
  "instanceFqdn": "<...>-vsp.example.com",
  "platformFqdn": "<...>-vspp.example.com",
  "fleetFqdn":    "<...>-fleet.example.com",   // <-- 必填
  ...
}
```

Template 已修正：[vcf91/bringup.template.json](./vcf91/bringup.template.json) (`vspClusterSpec.fleetFqdn`).

## 修法（事後 retry）

如果已經失敗，按以下順序：

1. **DNS** — 加 fleet FQDN A record（IP 從 VSP cluster pool 取一個空的）。
2. **SDDC Manager inventory** — 用 admin@local PATCH `https://<sddc>/v1/system/vcf-management-components`，把 `fleetLcm.fqdn` 連同其他元件 fqdn 一起塞進去：
   ```powershell
   $payload = @{
     fleetLcm = @{ fqdn='<...>-fleet.example.com'; deploymentStatus='NOT_STARTED'; deploymentType='NEW' }
     # 其他元件保留原 fqdn
   } | ConvertTo-Json -Depth 10
   Invoke-RestMethod -Method PATCH `
     -Uri "https://<sddc>/v1/system/vcf-management-components" `
     -Headers @{Authorization="Bearer $tok"; 'Content-Type'='application/json'} `
     -Body $payload -SkipCertificateCheck
   ```
3. **VCF Installer retry** — `PATCH /v1/sddcs/{id}` 帶完整 SddcSpec（含修正後的 `vspClusterSpec.fleetFqdn`）：
   ```powershell
   $spec = Invoke-RestMethod -Uri "https://<installer>/v1/sddcs/$sddcId/spec" -Headers @{Authorization="Bearer $tok"} -SkipCertificateCheck
   $spec.vspClusterSpec | Add-Member -NotePropertyName 'fleetFqdn' -NotePropertyValue '<...>-fleet.example.com' -Force
   Invoke-RestMethod -Method PATCH `
     -Uri "https://<installer>/v1/sddcs/$sddcId" `
     -Headers @{Authorization="Bearer $tok"; 'Content-Type'='application/json'} `
     -Body ($spec | ConvertTo-Json -Depth 50) -SkipCertificateCheck
   ```

## 驗證

retry 後查 `Save VCF Management Components` 應變成 `POSTVALIDATION_COMPLETED_WITH_SUCCESS`，milestone 推進到 "Deploy and configure VCF Management Platform"。

## 影響範圍

- VCF 9.1 primary instance bringup 必須帶 `fleetFqdn`。VVF 也需要。
- Secondary VCF instance bringup **不要**帶。
- VCF 9.0 schema 不同（沒有獨立 fleetLcm），不受此影響。
