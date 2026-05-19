# Layer 2 Bringup — current status

最後更新 2026-05-19, /goal "deploy VCF 5.2.1 + VCF 9 完成" 進行中.

## 已完成

| | 狀態 |
|---|---|
| 12 nested ESXi VM 部署 | ✓ 全 reachable @ 對應 IP |
| 12 nested ESXi hostname/FQDN | ✓ kosten-vcf{521,90,91}-esx0[1-4].rtolab.local |
| DNS forward + reverse (54 A + 56 PTR) | ✓ kosten AD 推完 |
| 5.2.1 master state.tgz: FollowHardwareMac=1 + cert regen | ✓ |
| 9.0 / 9.1 VCF Installer 部署 | ✓ HTTP 200 on /login |
| 5.2.1 Cloud Builder 部署 (33GB OVA) | ✓ HTTP 200 on /login, Basic auth OK |
| 5.2.1 nested ESXi SSL cert CN | ✓ regen 成 FQDN |
| 5.2.1 nested ESXi NTP server | ✓ 192.168.114.200 |
| 5.2.1 SDDC spec validation: 安全/憑證/SSH 階段 | ✓ pass |

## 5.2.1 剩下硬卡關

**ESXi build mismatch** — Cloud Builder 5.2.3 (`VMware-Cloud-Builder-5.2.3.0-25219033`) 寫死要 ESXi build `25205845` (= ESXi 8.0 U3l), 我們手上是 `24022510` (= ESXi 8.0 U3 GA, 從 OVA `Nested_ESXi8.0u3g_Appliance_Template_v1.ova` 出來).

驗證錯誤 (一字不漏):
```
[ESXI_BUILD_LOWER.error] ESXi Host kosten-vcf521-esx0X.rtolab.local
build is 24022510 but must be equal to 25205845
```

試過 `skipEsxBuildValidation: true` / `skipVersionChecks: true` — CB 5.2.3 不認, validation 仍 fail.

### 解法二選一

A) **下載 ESXi 8.0 U3l offline depot zip** (build 25205845) 從 customerconnect.vmware.com (需登入 + entitlement). 大小約 700 MB. 載到 jumpbox 後:
```powershell
# upload depot 到 datastore, 或 SCP 到每台 ESXi
scp VMware-ESXi-8.0U3l-25205845-depot.zip root@192.168.114.50:/vmfs/volumes/datastore1/
# SSH 進每台跑
esxcli software profile update -d /vmfs/volumes/datastore1/VMware-ESXi-8.0U3l-25205845-depot.zip \
    -p ESXi-8.0U3l-25205845-standard
reboot
```
再重 export master OVA + 重部 clones.

B) **找 5.2 (非 5.2.3) 的 Cloud Builder** 接受 8.0U3 GA — 但 5.2.1 已 deprecated, 5.2.2 也不一定接受.

## 9.0 / 9.1 卡關

**Bringup spec schema 不符 9.x API** — 我手刻的 `bringup.template.json` 是參考 5.2.1 (autodeployvcfm02.ps1) 加 VCF 9.x 假設. 實際 9.x validation 回:

```
[EMPTY_BRINGUP_CONFIGURATION_FIELD.error] vSAN Specification missing for SddcSpec
[MISSING_DVS_UPLINK_SPECIFICATION.error] vSphere Distributed Switch ... vmnicsToUplinks
[VSP_NOT_PROVIDED.error] VCF service runtime specification must be present
```

### 解法二選一

A) **用 VCF Installer 9.x 的 web wizard** (UI 知道正確 schema):
- https://192.168.114.34 (9.0)
- https://192.168.114.5  (9.1)
- 帳密 admin@local / VMware1!VMware1!
- Wizard 一步步填, 最後它會 generate + POST 正確 spec.

B) **抓 wizard 生成的 spec** (browser dev tools intercept POST `/v1/sddcs/validations` body), 拿回來填回 template, 之後 automation 才能跑.

## 目前 commit

```
4c9412f Regen-EsxiCert.ps1: SSH-driven /sbin/generate-certificates ...
222131d layer2-bringup: pwsh 7 cert fix + 9.1 template progress
3d6a460 Deploy-VcfInstaller.ps1 + ESXi hostname fix + vSphere 7 vApp gotcha doc
6a20f5f docs: nested ESXi clone troubleshooting
5635334 fix nested ESXi clones: rebind vmk0 MAC + correct gateway .254
```
