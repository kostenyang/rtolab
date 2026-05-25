<#  Deploy NSX Edge Cluster (1 Medium Edge, STATIC T0, VLAN 114 uplink)
    to VCF 9.1 management domain vcf-m02. Required for Supervisor / VKS.
    Uses SDDC Mgr API POST /v1/edge-clusters. #>
$ErrorActionPreference='Stop'
$base='https://192.168.114.10'
$tok=(Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/tokens" -ContentType 'application/json' -Body (@{username='administrator@vsphere.local';password='VMware1!VMware1!'}|ConvertTo-Json)).accessToken
$h=@{Authorization="Bearer $tok";'Content-Type'='application/json'}

# Get domain + cluster ids
$dom=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/domains" -Headers $h).elements | Where-Object { $_.name -eq 'vcf-m02' }
$cl=(Invoke-RestMethod -SkipCertificateCheck -Uri "$base/v1/clusters" -Headers $h).elements | Where-Object { $_.name -eq 'vcf-m02-cl01' }
Write-Host ("domain id: $($dom.id)  cluster id: $($cl.id)")

# Edge Cluster spec — iter#6: DNS-aligned hostnames (.70/.71), edgeTep1IP/2IP field rename,
# T0 STATIC config (no BGP peers, defaults)
$spec=@{
  edgeClusterName       = 'vcf-m02-edge-cl01'
  edgeClusterType       = 'NSX-T'
  edgeClusterProfileType= 'DEFAULT'
  edgeRootPassword      = 'VMware1!VMware1!'
  edgeAdminPassword     = 'VMware1!VMware1!'
  edgeAuditPassword     = 'VMware1!VMware1!'
  edgeFormFactor        = 'MEDIUM'
  tier0ServicesHighAvailability = 'ACTIVE_STANDBY'
  tier0RoutingType      = 'STATIC'
  mtu                   = 1600
  asn                   = 65000
  tier0Name             = 'vcf-m02-t0-gw01'
  tier1Name             = 'vcf-m02-t1-gw01'
  internalTransitSubnets= @('169.254.0.0/24')
  transitSubnets        = @('100.64.0.0/16')
  edgeNodeSpecs = @(
    @{
      edgeNodeName     = 'kosten-vcf91-en01.rtolab.local'
      managementIP     = '192.168.114.70/24'
      managementGateway= '192.168.114.254'
      edgeTep1IP       = '192.168.117.30/24'
      edgeTep2IP       = '192.168.117.31/24'
      edgeTepGateway   = '192.168.117.254'
      edgeTepVlan      = 117
      clusterId        = $cl.id
      interRackCluster = $false
      uplinkNetworks   = @(
        @{ uplinkVlan = 114; uplinkInterfaceIP = '192.168.114.72/24' }
      )
    },
    @{
      edgeNodeName     = 'kosten-vcf91-en02.rtolab.local'
      managementIP     = '192.168.114.71/24'
      managementGateway= '192.168.114.254'
      edgeTep1IP       = '192.168.117.28/24'
      edgeTep2IP       = '192.168.117.29/24'
      edgeTepGateway   = '192.168.117.254'
      edgeTepVlan      = 117
      clusterId        = $cl.id
      interRackCluster = $false
      uplinkNetworks   = @(
        @{ uplinkVlan = 114; uplinkInterfaceIP = '192.168.114.73/24' }
      )
    }
  )
}
$body=$spec | ConvertTo-Json -Depth 10
Write-Host '--- POST /v1/edge-clusters ---'
try{
  $r=Invoke-RestMethod -SkipCertificateCheck -Method Post -Uri "$base/v1/edge-clusters?skipValidations=true" -Headers $h -Body $body -TimeoutSec 60
  Write-Host 'EDGE CLUSTER DEPLOY ACCEPTED:'
  $r | ConvertTo-Json -Depth 5
  if($r.id){ $r.id | Set-Content -NoNewline scripts/_edge_task_id.txt }
}catch{
  Write-Host ('Status: ' + $_.Exception.Response.StatusCode)
  Write-Host 'Body:'
  Write-Host $_.ErrorDetails.Message
}
