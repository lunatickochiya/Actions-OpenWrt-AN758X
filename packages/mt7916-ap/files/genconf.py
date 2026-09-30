#!/usr/bin/env python3
"""
Derive the mt_wifi CONFIG_* set for MT7916 from the driver's own Kconfig files,
so we build with the same feature set MediaTek ships instead of hand-picking.

Strategy: take every bool option whose Kconfig `default` is y and whose
`depends on` is satisfied by the already-selected set, close transitively
(defaults -> depends -> select).
"""
import re
import sys

KCONFIGS = [
    "/tmp/mtsrc/mt_wifi/embedded/Kconfig",
    "/tmp/mtsrc/mt_wifi_ap/Kconfig",
]

# What we deliberately force, regardless of Kconfig defaults.
SEED = {
    "SUPPORT_OPENWRT",
    "MT_AP_SUPPORT",          # the mt_wifi_ap build (module)
    "WIFI_DRIVER",
    "CHIP_MT7916", "FIRST_IF_MT7916", "SECOND_IF_NONE",
    "7916_USE_PCI", "MT_MAC", "RTMP_MAC", "RTMP_MAC_PCI",
    "DOT11_N_SUPPORT",
    "DOT11_VHT_AC", "DOT11_HE_AX",   # MT7916 is an 802.11ax chip
    "PROPRIETARY_DRIVER",
}

# Options that must stay off even if Kconfig says otherwise:
# this is the AP module build, STA support lives in its own tree.
BLOCK = {
    "STA_SUPPORT", "MT_STA_SUPPORT", "RTMP_STA_SUPPORT",
    "CFG80211_SUPPORT",          # driver ships its own AP stack
    "CONNINFRA_APSOC",           # MT798x SoC glue (conninfra/consys), absent on AN7581
    "WLAN_SERVICE",
    "ATE_SUPPORT",
    "6G_SUPPORT", "6G_AFC_SUPPORT",
    "CHIP_MT7986", "CHIP_MT7981", "CHIP_MT7915", "CHIP_MT7622", "CHIP_MT7615E",
    "CHIP_AXE", "CHIP_MT7663E", "CHIP_MT7663U", "CHIP_MT7626",
}

def parse(path):
    opts, order = {}, []
    cur = None
    for line in open(path, errors="surrogateescape").read().split("\n"):
        m = re.match(r"^\s*(menuconfig|config)\s+(\w+)", line)
        if m:
            cur = m.group(2)
            opts.setdefault(cur, {"type": "bool", "dep": [], "def": [], "sel": []})
            order.append(cur)
            continue
        if cur is None:
            continue
        if re.match(r"^\s*(choice|endchoice|endmenu|source|comment|mainmenu)", line):
            cur = None
            continue
        if re.match(r"^\s*(tristate|bool|string|int|hex)\b", line):
            opts[cur]["type"] = re.match(r"^\s*(\w+)", line).group(1)
            continue
        m = re.match(r"^\s*depends on\s+(.*)", line)
        if m:
            opts[cur]["dep"].append(m.group(1).strip())
            continue
        m = re.match(r"^\s*default\s+(.*)", line)
        if m:
            opts[cur]["def"].append(m.group(1).strip())
            continue
        m = re.match(r"^\s*select\s+(.*)", line)
        if m:
            for sym in re.split(r"[\s&|]+", m.group(1)):
                if re.fullmatch(r"\w+", sym):
                    opts[cur]["sel"].append(sym)
    return opts, order

opts, order = {}, []
for kc in KCONFIGS:
    o, r = parse(kc)
    for name, val in o.items():
        if name in opts:
            for key in ("dep", "def", "sel"):
                opts[name][key] += val[key]
        else:
            opts[name] = val
    order += r

def norm(expr):
    e = expr.replace("&&", " and ").replace("||", " or ").replace("!", " not ")
    return re.sub(r"(\w+)=([ynm])", r"('\2' == '\2')", e)

def satisfied(name):
    o = opts[name]
    for dep in o["dep"]:
        expr = norm(dep)
        expr = re.sub(r"\b(\w+)\b", lambda m: "True" if (
            m.group(1) in env and not (m.group(1) == name)) else "False", expr) if False else expr
        # evaluate symbols against current env
        def sub(m):
            s = m.group(1)
            return "True" if s in env else "False"
        expr = re.sub(r"\b([A-Za-z_]\w*)\b", sub, expr)
        try:
            if not eval(expr):
                return False
        except Exception:
            return False
    return True

env = set(SEED)
changed = True
while changed:
    changed = False
    for name in order:
        if name in env or name in BLOCK or name not in opts:
            continue
        o = opts[name]
        if o["type"] != "bool":
            continue
        if not any(d.strip() in ("y", '"y"') for d in o["def"]):
            continue
        if satisfied(name):
            env.add(name)
            changed = True
    # propagate select
    for name in list(env):
        for s in opts.get(name, {}).get("sel", []):
            if s not in env and s not in BLOCK:
                env.add(s)
                changed = True

env -= BLOCK
for n in sorted(env):
    print("CONFIG_%s=y" % n)
print(
    "\n# --- selected %d options; Kconfig exposes %d ---" % (len(env), len(opts)),
    file=sys.stderr,
)
