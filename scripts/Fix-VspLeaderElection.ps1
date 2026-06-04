<#
.SYNOPSIS
    Bump kube-controller-manager / kube-scheduler leader-election timeouts on a VSP
    Supervisor control-plane node, so they survive high etcd fsync latency during the
    VCF Automation pod burst on (double-)nested vSAN.

.DESCRIPTION
    On nested-on-nested vSAN the VSP Supervisor etcd wal_fsync spikes (25-100ms+) when
    VCF Automation starts dozens of pods concurrently. The default leader-election renew
    deadline (10s) is then too tight: kube-controller-manager / kube-scheduler lose the
    leader lease, exit, and CrashLoopBackOff -> the "Install Service (VCF Automation)"
    bring-up step stalls.

    This script SSHes to the Supervisor control-plane node and inserts, right after
    `- --leader-elect=true` in BOTH static pod manifests:
        - --leader-elect-lease-duration=120s
        - --leader-elect-renew-deadline=100s
        - --leader-elect-retry-period=20s
    kubelet detects the manifest change and restarts each static pod once with the new
    flags. Idempotent (skips if already present). Backups go to /root (NOT the manifests
    dir, so kubelet won't try to run them).

.PARAMETER ControlPlaneIp
    Real IP of the Supervisor control-plane node — the vspp VM that holds BOTH its node
    IP and the K8s API VIP, and has /etc/kubernetes/admin.conf. Find it in the inner
    vCenter: the vspp-* VM whose guest NICs include the API VIP.

.PARAMETER NodeUser / NodePassword
    SSH/sudo creds. Default vmware-system-user / VMware1!VMware1!. NOTE: Supervisor node
    passwords rotate (vSphere with Tanzu); if auth fails, re-fetch via the inner vCenter
    /usr/lib/vmware/wcp/decryptK8Pwd.py.

.EXAMPLE
    pwsh ./scripts/Fix-VspLeaderElection.ps1 -ControlPlaneIp 192.168.114.20
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ControlPlaneIp,
    [string] $NodeUser = 'vmware-system-user',
    [string] $NodePassword = 'VMware1!VMware1!'
)
$ErrorActionPreference = 'Stop'
Import-Module Posh-SSH

$cred = New-Object System.Management.Automation.PSCredential($NodeUser, (ConvertTo-SecureString $NodePassword -AsPlainText -Force))

# Remote script: backup -> awk-insert 3 flags after --leader-elect=true -> cat> (keep
# perms) -> wait for kubelet restart -> verify Running + flag active. Idempotent.
$remote = @'
#!/bin/bash
set -e
export KUBECONFIG=/etc/kubernetes/admin.conf
for f in kube-controller-manager kube-scheduler; do
  F=/etc/kubernetes/manifests/$f.yaml
  if grep -q 'leader-elect-renew-deadline' "$F"; then echo "$f: already patched, skip"; continue; fi
  cp -p "$F" "/root/$f.yaml.bak-$(date +%Y%m%d-%H%M%S)"
  awk '/- --leader-elect=true/{print; \
       print "    - --leader-elect-lease-duration=120s"; \
       print "    - --leader-elect-renew-deadline=100s"; \
       print "    - --leader-elect-retry-period=20s"; next}1' "$F" > /tmp/$f.new
  n=$(grep -c 'leader-elect-' /tmp/$f.new)
  if [ -s /tmp/$f.new ] && [ "$n" -ge 3 ]; then cat /tmp/$f.new > "$F"; echo "$f: PATCHED"; \
  else echo "$f: SANITY FAILED (lines=$n), NOT applied"; fi
  rm -f /tmp/$f.new
done
echo "waiting 40s for kubelet to restart static pods..."; sleep 40
kubectl get pods -n kube-system 2>/dev/null | grep -E 'controller-manager|scheduler-kosten' | \
  awk '{printf "  %-46s %-10s restarts=%s age=%s\n",$1,$3,$4,$5}'
for f in kube-controller-manager kube-scheduler; do
  p=$(kubectl get pods -n kube-system 2>/dev/null | grep "$f-kosten" | awk '{print $1}')
  echo -n "  $f flag: "; kubectl get pod -n kube-system $p -o jsonpath='{.spec.containers[0].command}' 2>/dev/null \
    | grep -o 'leader-elect-renew-deadline=100s' || echo '(not visible)'
done
'@ -replace "`r`n", "`n"

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($remote))
$s = New-SSHSession -ComputerName $ControlPlaneIp -Credential $cred -AcceptKey -ConnectionTimeout 20 -Force
try {
    Invoke-SSHCommand -SessionId $s.SessionId -Command "echo '$b64' | base64 -d > /tmp/fix_le.sh" -TimeOut 20 | Out-Null
    $r = Invoke-SSHCommand -SessionId $s.SessionId -Command "echo '$NodePassword' | sudo -S bash /tmp/fix_le.sh 2>&1" -TimeOut 120
    $r.Output | ForEach-Object { Write-Host $_ }
} finally {
    Remove-SSHSession -SessionId $s.SessionId | Out-Null
}
