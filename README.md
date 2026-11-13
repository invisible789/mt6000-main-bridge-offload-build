# GL-MT6000 build: OpenWrt main + PR #24038 (L2 bridge offload) + vsftpd + temp-status

Sysupgrade image for the GL-MT6000 built from **current OpenWrt main (pinned: `e2ed57b`, 2026-11-13, kernel 6.18.60)** with
**OpenWrt PR #24038** (bridge-aware flow offload for a dumb AP) applied on top. It replaces `bridger` (do not install it).
The PR is still **not merged**, so this is a snapshot-style build, not a stable release.

Extras on top of the offload build:
- **vsftpd** (packages feed, the no-TLS variant). See the security note below before using it.
- **luci-app-temp-status** (`gSpotx2f/luci-app-temp-status`, MIT, pinned commit `6d12781`). It is not in any OpenWrt feed, so the
  workflow clones it into `package/` at that commit and builds it from source.

## What the patch series is
`bridge-offload-on-main-e2ed57b.mbox` holds the **10 current commits of PR #24038, unmodified** (cherry-picked onto main
`e2ed57b`; the tree is identical to what `git am` produces). Nothing in it is mine any more:
- 6 kernel/netfilter commits: the `nft_flow_offload` bridge offload series (`675-xx`), `hw_ifidx`, removal of the `WARN_ON`,
  the `DEV_PATH_BR_VLAN_KEEP_HW` case in `xt_FLOWOFFLOAD`, the airoha `915-01` fix and a refresh of the kernel patches.
- firewall4 `001` (bridge flowtable) and `002` ("harden bridge offload lifecycle"): hardware offload is probed for the bridge and
  falls back to a software flowtable with a warning, bridge members behind VLAN devices are resolved, the bridge table is
  removed on `fw4 stop`, and **fw4 now ships the `50-fw4-bridge-reload` hotplug script itself** (waits for the port to join its
  bridge, queues events instead of dropping them, reloads for any bridge port).
- `kmod-nft-bridge` is now the default package that carries `nf_conntrack_bridge` (`kmod-nf-conntrack-bridge` is gone).

Earlier builds of this repo carried three commits of mine on top of the PR: a port of `675-06`/`675-11` to main's ctx-based
`dev_fill_forward_path()` API, a context fix for kernel 6.18.60, and a replacement hotplug script. The PR author's version of
the port is equivalent, and the hotplug script is now upstream, so all three were dropped.

## Build on GitHub (free machines)
Actions -> "Build GL-MT6000 (main + bridge offload)" -> Run workflow.
1. Tick **dry_run** first (about 30-60 min): sources, patches, feeds, `make defconfig`, pre-checks, then host tools and the
   firewall4 + kernel `prepare` steps, which apply every package and kernel patch for real. No compile of the kernel.
2. Untick it for the full build (about 1-4 h): full build, post-checks, image uploaded as an artifact.

Or locally on Linux/WSL (normal user, ~25 GB free): `DRY_RUN=1 VALIDATE_PATCHES=1 bash build-mt6000.sh`, then `bash build-mt6000.sh`.
`MODE=pr` builds the PR head commit `5df179e` as posted (older base `706052b`).

## What check.sh verifies for you
- **Before the long build:** kernel 6.18; the PR's kernel patches, both firewall4 patches (including the hotplug script and the
  hardware-offload probe) and `kmod-nft-bridge` are in the tree; no per-target copy of the hotplug script exists (it would
  collide with fw4's); main's WED/PPE fixes are present; the MT6000 profile and WED firmware exist; feeds provide `vsftpd`; the
  temp-status package is in `package/`; `.config` selects the MT6000, luci, chrony, iperf3, ethtool, `kmod-nft-bridge`,
  `kmod-nft-offload`, nftables-json, firewall4, vsftpd, luci-app-temp-status and NOT bridger.
- **After the build:** image exists and is >8 MB (+ SHA256); the manifest lists the above and kernel 6.18; the rootfs has fw4's
  hotplug script (queued version), fw4 with bridge flowtable support and the lifecycle hardening, `nf_conntrack_bridge.ko`,
  `/usr/sbin/vsftpd` and the temp-status rpcd script.
- Any failure prints `CHECKS FAILED - do not flash` and exits non-zero.

## What no automated check can tell you
Whether the image **boots and offloads on your router.** Before flashing:
1. Copy the image to `/tmp` and run `sysupgrade -T <file>` (validates format and device match, does not flash).
2. Keep the working image you run now and a config backup (`sysupgrade -b /tmp/b.tar.gz`) off the router.
3. Recovery (OpenWrt wiki, this device): U-Boot web UI works even with bricked firmware: unplug power, hold Reset, plug in,
   release after the LED stabilises (~10 s), browse to `192.168.1.1`, upload a sysupgrade image.

## Flash
Only the `*-sysupgrade.bin`, never a factory image. Keep your settings with `sysupgrade /tmp/<file>`, or start clean with
`sysupgrade -n /tmp/<file>`.

## vsftpd: lock it down first
The package's defaults: `anonymous_enable=NO`, but `local_enable=YES` and `write_enable=YES` with `check_shell=NO`, no chroot and
no TLS. The init script enables it at boot, so after flashing **any local account, including root, can log in over plain FTP and
write anywhere**, from anything that can reach port 21 (your LAN zone accepts input). Before relying on it either
`service vsftpd stop; service vsftpd disable`, or create a non-root user, set `local_root`/`chroot_local_user`, and keep root
out of the FTP login list. The `vsftpd-tls` variant (+libopenssl) can encrypt logins if you need that; it conflicts with the
plain package, so only one can be installed.

## luci-app-temp-status
Adds a temperature block to the LuCI Status -> Overview page (it reads `/sys/class/hwmon` and `/sys/class/thermal` through an
rpcd ucode script; dependencies are `ucode` and `ucode-mod-fs`). After the first boot run `service rpcd restart` if the block
does not appear.

## Dumb-AP configuration (unchanged)
- LAN: DHCP client (or static); no `wan`/`wan6`; `dnsmasq` and `odhcpd` disabled; chrony only; Wi-Fi country first.
- **Firewall must be ON** (fw4 builds the bridge flowtable): `flow_offloading '1'` and `flow_offloading_hw '1'` in `defaults`,
  one minimal `lan` zone with input/output/forward ACCEPT, then `service firewall enable; service firewall restart`.
- WED: `sed -i '$a options mt7915e wed_enable=Y' /etc/modules.conf; reboot`, then
  `cat /sys/module/mt7915e/parameters/wed_enable` -> `Y`.

## Verify
```
nft list flowtable bridge fw4 fb          # devices: your wired lan ports AND phy0-ap0 / phy1-ap0, and "flags offload"
logread | grep -i 'hardware bridge offloading'   # must print nothing: that message means fw4's probe failed and
                                          # it fell back to a software flowtable (no "flags offload")
grep ' BND ' /sys/kernel/debug/ppe0/entries      # during a transfer: your flow; ib2 dest port 8 = WDMA0 (WED)
dmesg | grep -iE 'mtk_wed|wed|mt76|dma|oops|bug'
```
Success = a bound flow for your transfer, `flags offload` present, CPU near idle. Run it for a day watching `logread` for
Wi-Fi/WED restarts.

## Roll back
Flash the previous sysupgrade image (`sysupgrade -n <old.bin>`), or use the recovery methods above, then restore the config backup.
