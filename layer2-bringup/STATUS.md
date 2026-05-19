# Layer 2 Bringup — current status (2026-05-19 10:44)

/goal: "deploy VCF 5.2.1 + VCF 9 完成" 進行中. 兩個 depot download 同時跑.

## ✅ Done

| Item | State |
|---|---|
| 12 nested ESXi VM 部署 + reachable | ✓ |
| ESXi hostname/FQDN/DNS/NTP/cert CN | ✓ |
| 3 installers (9.0 + 9.1 VCF Inst + 5.2.1 CB) web UI live | ✓ |
| `inventory/secrets/lab.yaml` 加 `vcf_installer.*` + `cloud_builder.root_pw` | ✓ |
| **VCF 9.1 bringup spec schema validation PASSES** (Deployment Spec + Security) | ✓ |
| VCF 9.x OpenAPI schema 全 match (datastoreSpec.vsanSpec / vmnicsToUplinks / vspClusterSpec / IpRange.startIpAddress / vlanId int / teaming lowercase / NSX TEP IpAddressPool / nsxTeamings / nsxtSwitchConfig OVERLAY+VLAN tz) | ✓ |
| `Deploy-VcfInstaller.ps1` / `Regen-EsxiCert.ps1` / `Bake-MasterFinalize.ps1` / `clone-troubleshooting.md` / `Configure-LocalDepot.ps1` | ✓ |
| VCF download tool token 驗證可用 | ✓ |

## 🔄 In progress

### VCF 9.1 depot download (schtasks `VcfDepot91`, java PID 11500)
- Target: `E:\vcf-depot-91`, ~46GB total
- Components: VCF_OPS_CLOUD_PROXY (2.8) + VCENTER (12) + VRA (14.9) + VROPS (3.1) + NSX (7.5) + SDDC_MANAGER (2.3) + VIDB (1.0)
- Speed: ~4-5 Mbps from `dl.broadcom.com`. ETA ~18+ hours.
- Already on disk: ~7GB (partial files resumed from previous attempts via HTTP 206 Range)
- Monitor: `bwo3263b3` (30min heartbeat, emits DONE on ≥44GB)

### VCF 5.2.3 ESXi component download (schtasks `VcfDepot521Esxi`, java PID 16204)
- Target: `E:\vcf-depot-521-esxi` — 只下 ESX_HOST component
- For: 升 5.2.1 nested hosts 8.0U3 GA (`24022510`) → 8.0U3l (`25205845`) 解 CB 5.2.3 build check
- ~700 MB - 3 GB

## ⏭️ Pending (autorunnable once both depots done)

```powershell
# 1. Configure VCF Installer 9.1 to use local depot
pwsh layer2-bringup/vcf91/Configure-LocalDepot.ps1

# 2. Re-validate (Versions and Bundles 應該過了)
$env:VCF_INSTALLER_PW = 'VMware1!VMware1!'
pwsh layer2-bringup/vcf91/Submit-Bringup.ps1 -VcfInstaller https://192.168.114.5 -ValidateOnly

# 3. 過了的話 submit bringup (要 1-2 hr)
pwsh layer2-bringup/vcf91/Submit-Bringup.ps1 -VcfInstaller https://192.168.114.5

# 4. 5.2.1 esxi 升 8.0U3l + re-export OVA + redeploy clones
# (從 E:\vcf-depot-521-esxi\PROD\COMP\ESX_HOST\ 取 depot zip)
```

## 進度時間軸

| Commit | 內容 |
|---|---|
| `5635334` | nested ESXi clone fix scripts |
| `6a20f5f` | clone-troubleshooting.md |
| `3d6a460` | Deploy-VcfInstaller.ps1 + ESXi hostname fix + vSphere 7 vApp gotcha |
| `4c9412f` | Regen-EsxiCert.ps1 |
| `244a7d8` | STATUS.md initial |
| `cbe6eb3` | VCF 9.1 template schema 從 OpenAPI 重寫 — schema 過了 |
| `6027ebf` / `7b76cce` | STATUS.md updates |
| `2379e39` | Configure-LocalDepot.ps1 |
| this | STATUS.md (parallel downloads) |
