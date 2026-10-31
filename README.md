# GL-MT6000 build: OpenWrt main + PR #24038 (L2 bridge offload)

Sysupgrade image for the GL-MT6000 built from **current OpenWrt main (pinned: `7eb9f10`, kernel 6.18)** with
**OpenWrt PR #24038** (bridge-aware flow offload for a dumb AP) applied on top. It replaces `bridger` (do not install it).
The PR is still a **draft** and is not merged, so this is a snapshot-style build, not a stable release.

Compared with a build from the PR head alone (`db25d82`, 2026-09-18), this one also carries everything main gained
since, including the mtk_wed fixes (ring free on detach, `dma_unmap_single` size, WED v2 `RESV_BUFF`), the mtk_eth_soc
PPE flow-priority change, the flowtable roaming/VLAN-ID fixes, and newer mt76/mac80211.

## How it was rebased
The 12 PR commits are in `bridge-offload-on-main-7eb9f10.mbox` and apply with plain `git am` on main `7eb9f10`.
Differences from the PR as posted:
- Patch 6 (`DEV_PATH_BR_VLAN_KEEP_HW` in `xt_FLOWOFFLOAD`): main changed `hack-6.18/650-...` since the PR was written, so the
  two-line `case DEV_PATH_BR_VLAN_KEEP_HW:` addition was re-applied on main's version of the file (hunk count 734 -> 736).
- Patch 7 (firewall4): main moved firewall4 to `e6f600c` (2026-10-29). The PR's patch still applies (offsets only);
  `PKG_RELEASE` is 2 instead of 3 because main's package release was reset by the version bump.
- Patch 12 (refresh): only the PR's own `675-xx` refreshes were kept. Refreshes of files main maintains itself
  (`650`, `721`, `731`, `915-01`) were dropped, and `699` stays deleted because main folded it into an upstream backport.

## Build on GitHub (free machines)
Actions -> "Build GL-MT6000 (main + bridge offload)" -> Run workflow.
1. Tick **dry_run** first (about 30-60 min): sources, patches, feeds, `make defconfig`, pre-checks, then host tools and the
   firewall4 + kernel `prepare` steps, which apply every package and kernel patch for real. No compile of the kernel.
2. Untick it for the full build (about 2-4 h, an estimate): full build, post-checks, image uploaded as an artifact.

Or locally on Linux/WSL (normal user, ~25 GB free): `DRY_RUN=1 VALIDATE_PATCHES=1 bash build-mt6000.sh`, then `bash build-mt6000.sh`.
`MODE=pr` builds the PR head `db25d82` as before.

## What check.sh verifies for you
- **Before the long build:** kernel 6.18; the 12 PR patches, firewall4 patch, hotplug script and new kmod are in the tree; the
  main-side WED/PPE fixes are present; the MT6000 profile and WED firmware exist; `.config` selects the MT6000, luci, chrony,
  iperf3, ethtool, kmod-nf-conntrack-bridge, kmod-nft-offload, nftables-json, firewall4 and NOT bridger.
- **After the build:** image exists and is >8 MB (+ SHA256), manifest lists firewall4, the new kmod, mt7915e and the WED
  firmware, no bridger, kernel 6.18; the rootfs has the hotplug script, fw4 with bridge-flowtable support and `nf_conntrack_bridge.ko`.
- Any failure prints `CHECKS FAILED - do not flash` and exits non-zero.

## What no automated check can tell you
Whether the image **boots and offloads on your router.** Before flashing:
1. Copy the image to `/tmp` and run `sysupgrade -T <file>` (validates format and device match, does not flash).
2. Keep the working image you run now and a config backup (`sysupgrade -b /tmp/b.tar.gz`) off the router.
3. Recovery (OpenWrt wiki, this device): U-Boot web UI works even with bricked firmware: unplug power, hold Reset, plug in,
   release after the LED stabilises (~10 s), browse to `192.168.1.1`, upload a sysupgrade image.

## Flash
Only the `*-sysupgrade.bin`, never a factory image. Keep your settings with `sysupgrade /tmp/<file>`, or start clean with
`sysupgrade -n /tmp/<file>`. This is a new kernel and a new PPE/WED code path, so a clean start is the safer first test.

## Dumb-AP configuration (unchanged from the PR-head build)
- LAN: DHCP client (or static); no `wan`/`wan6`; `dnsmasq` and `odhcpd` disabled; chrony only; Wi-Fi country first.
- **Firewall must be ON** (fw4 builds the bridge flowtable): `flow_offloading '1'` and `flow_offloading_hw '1'` in `defaults`,
  one minimal `lan` zone with input/output/forward ACCEPT, then `service firewall enable; service firewall restart`.
- WED: `sed -i '$a options mt7915e wed_enable=Y' /etc/modules.conf; reboot`, then
  `cat /sys/module/mt7915e/parameters/wed_enable` -> `Y`.

## Verify (during a long FTP/iperf3 transfer)
```
nft list flowtable bridge fw4 fb          # must list your wired lan port AND phy0-ap0 / phy1-ap0
grep -c ' BND ' /sys/kernel/debug/ppe0/entries
grep -h 'WED_TX_MIB(1)' /sys/kernel/debug/wed0/*info
dmesg | grep -iE 'mtk_wed|wed|mt76|dma|oops|bug'
```
Success = `BND` > 0 under load, WED_TX rising, CPU near idle. Then compare speed, loaded ping and CPU against the PR-head build,
and run it for a day watching `logread` for Wi-Fi/WED restarts.

## Roll back
Flash the previous sysupgrade image (`sysupgrade -n <old.bin>`), or use the recovery methods above, then restore the config backup.
