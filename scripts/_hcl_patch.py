#!/usr/bin/env python3
# Inject nested-ESXi virtual NVMe (15AD:07F0) into the vSAN HCL all.json so the
# VCF 9.1 bring-up vSAN ESA HCL check passes for a nested lab.
import json, time, sys, os

P = sys.argv[1] if len(sys.argv) > 1 else '/depot/PROD/vsan/hcl/all.json'
d = json.load(open(P))
data = d['data']

VID, DID, SVID, SSID = '15AD', '07F0', '15AD', '07F0'
DRV = 'nvme_pcie'
DRVVER = '1.4.0.8-1vmw.910'

def has(lst):
    for e in lst:
        if str(e.get('vid','')).upper()==VID and str(e.get('did','')).upper()==DID:
            return True
    return False

esa_support = {"tier": ["vSANESA-Singletier"], "mode": ["vSAN ESA"]}
fw_list = [{"firmware": fw, "vsanSupport": esa_support}
           for fw in ("1.3", "1.0", "1.2", "VMW1", "1.4")]
rel91 = {"ESXi 9.1": {DRV: {DRVVER: {"type": "inbox", "componentName": None,
                                     "componentVersion": None, "firmwares": fw_list}}}}

ssd_entry = {
    "id": 990001,
    "productid": "VMware Virtual NVMe Disk",
    "model": "VMware Virtual NVMe Disk",
    "vendor": "NVMe",
    "partnername": "VMware",
    "capacity": 0,
    "partnumber": "VMware-Virtual-NVMe",
    "devicetype": "NVMe",
    "flashtype": "TLC",
    "vid": VID, "did": DID, "svid": SVID, "ssid": SSID,
    "vsanSupport": {"mode": ["vSAN", "vSAN ESA"],
                    "tier": ["vSANESA-Singletier", "AF-Cache", "AF-Cap"]},
    "vcglink": "https://compatibilityguide.broadcom.com/",
    "releases": rel91,
}

ctl_entry = {
    "id": 990002,
    "model": "VMware NVMe SSD Controller",
    "vendor": "VMware",
    "vid": VID, "did": DID, "ssid": SSID, "svid": SVID,
    "vcglink": "https://compatibilityguide.broadcom.com/",
    "releases": {"ESXi 9.1": {
        "vsanSupport": ["All Flash:vSAN ESA", "All Flash:Pass-Through", "Hybrid:Pass-Through"],
        DRV: {DRVVER: {"type": "inbox", "componentName": None, "componentVersion": None,
                       "firmwares": [{"vsanSupport": ["All Flash:Pass-Through"]}]}}}},
}

changed = False
if not has(data['ssd']):
    data['ssd'].append(ssd_entry); changed = True
    print('added ssd entry')
else:
    print('ssd entry already present')
if not has(data['controller']):
    data['controller'].append(ctl_entry); changed = True
    print('added controller entry')
else:
    print('controller entry already present')

if changed:
    d['totalCount'] = d.get('totalCount', 0) + 2
    d['timestamp'] = int(time.time())
    json.dump(d, open(P, 'w'))
    lu = {"timestamp": int(time.time()),
          "jsonUpdatedTime": time.strftime('%b %d, %Y, %I:%M %p UTC', time.gmtime())}
    lup = os.path.join(os.path.dirname(P), 'lastupdatedtime.json')
    if os.path.exists(lup):
        json.dump(lu, open(lup, 'w'))
    print('written; totalCount=%d' % d['totalCount'])
else:
    print('no change')
