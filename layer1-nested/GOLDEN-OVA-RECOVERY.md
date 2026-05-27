# Golden OVA Clone Recovery SOP (2026-05-27)

## 問題

`E:\custom-ova\rtolab-nested-esxi9.1.ova` 是在 master VM 上**還沒** `Bake-MasterFinalize`（沒設 `/Net/FollowHardwareMac=1`）就 export 出來的。所以每次從 OVA clone 出新 VM，4 個 VM 會共用：

- vmk0 MAC（OVA master 的，**不**是 vNIC HW MAC）→ ARP 戰爭，只 1 個 VM 通網
- SSL cert（CN=localhost.localdomain）→ VCF 驗證 `ESXI_HOST_CERTIFICATE_CN_NOT_VALID`
- IP / hostname（OVA master 的）→ 4 VMs 共同 IP

`local.sh` first-boot 機制理論上會修，但 ESXi 9.1 把 `/usr/bin/vmware-rpctool` 拿掉了，`local.sh` 拿不到 guestinfo 就 `exit 0` 沒做事。

## SOP（從乾淨 OVA deploy 後跑）

```powershell
# 0. Deploy 4 個 VMs（注意要包 esx01，預設 -Hosts 跳過 esx01）
pwsh scripts/Deploy-FromGoldenOva.ps1 -Versions 9.1 -Hosts esx01,esx02,esx03,esx04

# 1. 修 vmk0 MAC：bind 到 vmnic0 (Guest Ops via vCenter, 不需網路)
pwsh scripts/Fix-CloneNetwork.ps1 -Versions 9.1 -Hosts esx01,esx02,esx03,esx04

# 2. 套 IP / gateway / hostname / DNS
pwsh scripts/Apply-CloneIp.ps1 -Versions 9.1 -Hosts esx01,esx02,esx03,esx04

# 3. Regen SSL cert (CN -> 正確 FQDN)
pwsh scripts/Regen-EsxiCert.ps1 -EsxiHosts 192.168.114.14,192.168.114.15,192.168.114.16,192.168.114.17

# 4. SSH 進每個 host 跑 auto-backup.sh 持久化（GuestOps sandbox 內跑會 fail）
# Apply-CloneIp 內 auto-backup.sh 從 GuestOps 跑會撞 "Operation not permitted"
# 必須改從 SSH 跑（網路通了之後）
for ip in .14 .15 .16 .17; do
  ssh root@192.168.114.$ip 'touch /etc/rtolab-configured; /sbin/auto-backup.sh'
done
```

## 已踩雷

### A. SSH host keys 還是共用的
4 VM 的 SSH host keys 都從 OVA 來，所以 fingerprint 相同。validator 不會 fail（thumbprint 對得上即可），但有「post-quantum」warning。若要分散，做完 cert regen 後跑：
```sh
rm -f /etc/ssh/ssh_host_*
/etc/init.d/SSH restart  # 自動 regen
/sbin/auto-backup.sh
```

### B. hostname 容易被 reset 回 `localhost`
`/etc/init.d/hostd restart` 之後，如果之前的 hostname 沒被 persist 透過 `auto-backup.sh`，會回 OVA 預設的 `localhost`。SSL cert regen 用 hostname 為 CN，所以必須**先確認 hostname 對才 regen cert**：
```sh
esxcli system hostname set --fqdn=kosten-vcf91-esxXX.rtolab.local
/sbin/generate-certificates
/etc/init.d/hostd restart
/etc/init.d/rhttpproxy restart
/sbin/auto-backup.sh
```

### C. Switch MAC table cache 卡舊
換 vmk0 MAC 後，上游 switch MAC table 可能還記著舊 MAC。從 automation host 看到部分 VM 突然 unreachable。修：force vmk0 down/up 觸發 GARP：
```sh
esxcli network ip interface set --interface-name=vmk0 --enabled=false
sleep 3
esxcli network ip interface set --interface-name=vmk0 --enabled=true
```

### D. Submit-Bringup.ps1 把 WARNING 當失敗
validator 回 `resultStatus=WARNING`（vSAN 容量、time sync、capacity 等 WARNING）script 會 throw。直接 POST /v1/sddcs 即可：
```powershell
Invoke-RestMethod -Method POST -Uri "https://192.168.114.5/v1/sddcs" `
  -Headers @{Authorization="Bearer $tok"; 'Content-Type'='application/json'} `
  -Body (Get-Content -Raw generated-bringup.json) -SkipCertificateCheck
```

### E. 必須在 bringup spec 注入 sshThumbprint + sslThumbprint
否則 validator 的 SSH probe (GenerateTempKnownHosts) 會撞 OVA-baked 共用 SSH key + cert 的問題。每個 hostSpecs[] 加：
```json
{
  "hostname": "kosten-vcf91-esxXX",
  "credentials": {...},
  "sshThumbprint": "SHA256:...",  // ssh-keyscan -t rsa | ssh-keygen -lf -
  "sslThumbprint": "XX:XX:..."     // openssl x509 -fingerprint -sha256
}
```

## 長期修法（一勞永逸）

跑 `Bake-MasterFinalize.ps1` 把 `/Net/FollowHardwareMac=1` 塞進 master 的 state.tgz **再** export OVA。9.1 OVA 還沒做，待 user 排：

```powershell
pwsh scripts/Bake-MasterFinalize.ps1 -EsxiHost 192.168.114.14
pwsh scripts/Export-NestedEsxiOva.ps1 -VMName vcf-m02-esx01-91
# 蓋掉舊 OVA: E:\custom-ova\rtolab-nested-esxi9.1.ova
```

之後從這支 OVA clone 出來的 VM vmk0 會自動用 vmnic0 MAC，不再 ARP 衝突。但 SSL/SSH 共用問題仍存在 — 還是要跑 Regen-EsxiCert 跟 SSH key regen。
