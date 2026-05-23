# VKS (Supervisor) setup — VCF 9.1 lab

Enable Supervisor on `vcf-m02-cl01` so VCF Automation can consume vSphere namespaces and TKG clusters.

## Status
- ✅ Content library `tkr-content` created (LOCAL, id `09eeb663-298d-4b76-a12c-65d0d495bd64`, on `vcf-m02-cl01-ds-vsan01`).
- ⏸️ Supervisor not enabled yet — vCenter `cluster-compatibility` returns `compatible: false`:
  - `vcenter.wcp.ncp.cluster.incompatible` — cluster missing compatible NSX-T VDS
  - `vcenter.wcp.nsx.vds.incompatible.no_edge_cluster` — no valid edge cluster bound to that VDS
  These auto-resolve when SDDC Manager's Workload Management deploy orchestrates NSX/VDS together.

## Why SDDC Manager UI, not API
SDDC Manager's public REST (`openapi.json`) does not expose Supervisor/Workload-Management endpoints — those are UI-only (private endpoints behind vSphere SSO). vCenter has the canonical API (`PUT /api/vcenter/namespace-management/clusters/{id}`) but enabling Supervisor that way also needs NSX transport-zone + edge-cluster preparation that SDDC Manager UI does for you. So drive this from the SDDC Mgr UI.

## UI path

https://192.168.114.10 → log in as `administrator@vsphere.local` / `VMware1!VMware1!` → **Workload Management** → **Deploy** (or **Get Started** if first time).

## Values to enter — copy these in exactly

### Cluster & vCenter
| Field | Value |
|---|---|
| vCenter | `kosten-vcf91-vc.rtolab.local` |
| Cluster | `vcf-m02-cl01` (in `vcf-m02`) |
| Workload domain | `vcf-m02` |

### Supervisor sizing & storage
| Field | Value | Note |
|---|---|---|
| Supervisor control-plane size | **Tiny** | Lab — minimize footprint |
| Ephemeral storage policy | `Management Storage Policy - Single Node` | **FTT=0** to match the rest of the lab |
| Master / control-plane storage policy | `Management Storage Policy - Single Node` | FTT=0 |
| Image storage policy | `Management Storage Policy - Single Node` | FTT=0 |

> `Management Storage Policy - Single Node` was confirmed `VSAN.hostFailuresToTolerate=0`; the others are RAID-1 (FTT=1) or higher and waste capacity in this 4-host nested lab.

### Supervisor management network
| Field | Value |
|---|---|
| Network mode | DHCP off / **Static** |
| Portgroup | the management VDS portgroup (the one carrying VLAN 114) |
| Starting IP | **192.168.114.30** |
| Number of IPs | **5** (so .30 – .34) |
| Subnet mask | `255.255.255.0` |
| Gateway | `192.168.114.254` |
| DNS servers | `192.168.114.200` |
| DNS search domains | `rtolab.local` |
| NTP servers | `192.168.114.200` |
| Floating IP / VIP | Supervisor will pick from the same pool (first free IP) — no manual entry needed |

### NSX workload networking (no dynamic routing in this lab — all-private CIDRs)
| Field | Value | Note |
|---|---|---|
| NSX Edge cluster | the existing VCF edge cluster | SDDC Mgr should auto-select |
| Pod CIDR | `10.244.0.0/21` | Internal to NSX, never advertised — no BGP needed |
| Service CIDR | `10.96.0.0/24` | Internal to NSX |
| Ingress CIDR | `10.10.10.0/24` | LB VIPs; private (Automation reaches Supervisor via mgmt VIP `.30`, not via these) |
| Egress CIDR | `10.10.20.0/24` | NSX SNATs outbound traffic to mgmt subnet — upstream sees egress as coming from NSX Edge uplink, not the workload pod IP |

> Because none of Pod/Service/Ingress/Egress CIDRs need to be reachable from *outside* the lab, we don't need BGP. VCF Automation talks to Supervisor API at `https://192.168.114.30` (or whichever floating IP it gets) on the routable mgmt subnet.

### Content library
| Field | Value |
|---|---|
| Library | `tkr-content` (LOCAL, already created) |

### Workload domain (vSphere namespace) — set up after Supervisor finishes
Once Supervisor reaches `Running`, create at least one vSphere namespace for VCF Automation to consume:
- **Name**: `vcfa-ns01` (anything)
- **Storage policy**: same FTT=0 policy
- **VM classes**: keep defaults (best-effort-{xsmall, small, medium}, guaranteed-{...})
- **Content library**: tkr-content
- **Permissions**: at least one DevOps user (e.g., new SSO user `vcfauto-devops@vsphere.local`) with `Owner` role

## Populating tkr-content with TKR images (manual — needed before TKG cluster deploy)

The library is empty. To deploy TKG clusters from Supervisor, push TKR OVAs:

1. On the depot VM (172.16.10.50) or any internet-attached host, download a TKR OVA from Broadcom: `ob-XXXXXX-tkg-vsphere-photon-3-...ova` (file names like `photon-3-kube-v1.27.5+vmware.1-tkg-1-...ova`). The list of TKRs is at `https://wp-content.vmware.com/v2/latest/lib.json` (one OVA per `kube-vN.NN.M` release).
2. From a host with PowerCLI + network to vCenter:
   ```powershell
   Connect-VIServer kosten-vcf91-vc.rtolab.local -User administrator@vsphere.local
   $lib = Get-ContentLibrary -Name tkr-content
   New-ContentLibraryItem -ContentLibrary $lib -Name 'photon-3-kube-v1.27.5+vmware.1-tkg-1' -Files 'C:\path\to\photon-3-kube-v1.27.5+vmware.1-tkg-1.ova'
   ```
3. Repeat for each TKR you want available to Supervisor.

Alternative: change the library to a Subscribed library pointed at `https://wp-content.vmware.com/v2/latest/lib.json` once vCenter has outbound HTTPS to internet — but in this lab vCenter is inside the nested cluster so that path is blocked unless we proxy via depot VM.

## After Supervisor + namespace are up

Deploy VCF Automation via SDDC Mgr → **VCF Automation** → **Deploy**. It will discover the Supervisor and let you bind the new namespace as a deployment target. Standard VCF lab creds `VMware1!VMware1!` everywhere.

---
*Related: [vcf91-installed](../.claude/projects/c--Users-Administrator-rtolab/memory/vcf91_redo_pending_hardware.md), [vcf91-installer-api](../.claude/projects/c--Users-Administrator-rtolab/memory/vcf91_installer_api.md)*
