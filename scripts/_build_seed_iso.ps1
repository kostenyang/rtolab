# Build a NoCloud cloud-init seed ISO (volume label CIDATA) for the Ubuntu depot VM.
$ErrorActionPreference = 'Stop'
$work = 'C:\Users\Administrator\rtolab\_seed'
if (Test-Path $work) { Remove-Item $work -Recurse -Force }
New-Item -ItemType Directory -Path $work | Out-Null

$metaData = "instance-id: rtolab-depot-$(Get-Random)`nlocal-hostname: rtolab-depotsrv`n"
$userData = @"
#cloud-config
ssh_pwauth: true
disable_root: false
chpasswd:
  expire: false
  list: |
    root:VMware1!VMware1!
    ubuntu:VMware1!VMware1!
write_files:
  - path: /etc/netplan/99-static.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          alleth:
            match:
              name: "e*"
            dhcp4: false
            addresses: [172.16.10.50/24]
            gateway4: 172.16.10.254
            nameservers:
              addresses: [192.168.114.200, 8.8.8.8]
runcmd:
  - rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml
  - netplan apply
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh
"@
[IO.File]::WriteAllText("$work\meta-data", ($metaData -replace "`r`n","`n"), (New-Object Text.UTF8Encoding $false))
[IO.File]::WriteAllText("$work\user-data", ($userData -replace "`r`n","`n"), (New-Object Text.UTF8Encoding $false))

Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoWriter {
  public static void Write(object comStream, string path) {
    IStream stream = (IStream)comStream;
    using (FileStream fs = File.Create(path)) {
      byte[] buf = new byte[1048576];
      IntPtr read = Marshal.AllocHGlobal(4);
      try {
        while (true) {
          stream.Read(buf, buf.Length, read);
          int n = Marshal.ReadInt32(read);
          if (n <= 0) break;
          fs.Write(buf, 0, n);
        }
      } finally { Marshal.FreeHGlobal(read); }
    }
  }
}
'@

$isoPath = 'C:\Users\Administrator\rtolab\_seed.iso'
if (Test-Path $isoPath) { Remove-Item $isoPath -Force }
$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.VolumeName = 'CIDATA'
$fsi.FileSystemsToCreate = 3
$fsi.Root.AddTree($work, $false)
$result = $fsi.CreateResultImage()
[IsoWriter]::Write($result.ImageStream, $isoPath)
Write-Host "seed ISO built: $isoPath  ($((Get-Item $isoPath).Length) bytes)"
