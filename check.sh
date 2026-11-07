#!/usr/bin/env bash
# Automated pre/post-build checks for the GL-MT6000 main + bridge-offload build.
#   check.sh pre  <openwrt-dir>   run before the long build (source tree + .config)
#   check.sh post <openwrt-dir>   run after the build (image, package manifest, rootfs)
# Exit code 0 only if every check passed. "skip" lines are not failures.
set -u
STAGE="${1:?usage: check.sh pre|post <openwrt-dir>}"
DIR="${2:?usage: check.sh pre|post <openwrt-dir>}"
cd "$DIR" || { echo "no such dir: $DIR"; exit 2; }

fail=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=1; }
skip() { echo "  skip  $*"; }
chk()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
has_glob() { compgen -G "$1" >/dev/null; }

case "$STAGE" in
pre)
  echo "[pre] patch set is present in the source tree"
  chk "kernel 6.18 is the mediatek default" grep -q 'KERNEL_PATCHVER:=6.18' target/linux/mediatek/Makefile
  chk "kmod-nf-conntrack-bridge is defined" grep -q 'KernelPackage/nf-conntrack-bridge' package/kernel/linux/modules/netfilter.mk
  chk "filogic installs kmod-nf-conntrack-bridge by default" grep -q 'kmod-nf-conntrack-bridge' target/linux/mediatek/filogic/target.mk
  chk "firewall4 bridge flowtable patch" test -f package/network/config/firewall4/patches/001-add-bridge-flowtable-support.patch
  chk "filogic hotplug script (fw4 reload on bridge port add)" test -f target/linux/mediatek/filogic/base-files/etc/hotplug.d/net/50-fw4-bridge-reload
  chk "hotplug script matches any wireless netdev" grep -q '/wireless' target/linux/mediatek/filogic/base-files/etc/hotplug.d/net/50-fw4-bridge-reload
  chk "hotplug script waits for the lock instead of dropping the event" grep -q 'until flock -n 9' target/linux/mediatek/filogic/base-files/etc/hotplug.d/net/50-fw4-bridge-reload
  chk "kernel patch: nft_flow_offload bridgeflow" has_glob 'target/linux/generic/pending-6.18/*Add-bridgeflow-to-nft_flo*'
  chk "kernel patch: dev_fill_bridge_path" has_glob 'target/linux/generic/pending-6.18/*net-core-dev-Add-dev_fill_bridge_path*'
  chk "kernel patch: bridge conntrack double-vlan/pppoe" has_glob 'target/linux/generic/pending-6.18/*bridge-Add-conntrack-double-vlan-and-pppoe*'
  chk "xt_FLOWOFFLOAD handles DEV_PATH_BR_VLAN_KEEP_HW" grep -q 'case DEV_PATH_BR_VLAN_KEEP_HW' target/linux/generic/hack-6.18/650-netfilter-add-xt_FLOWOFFLOAD-target.patch
  echo "[pre] current-main fixes are in the tree"
  chk "mtk_wed: free rings during detach" has_glob 'target/linux/generic/pending-6.18/793-03-*mtk_wed-free-up-rings-during-detach*'
  chk "mtk_wed: dma_unmap_single size fix" has_glob 'target/linux/generic/backport-6.18/*mtk_wed-Fix-dma_unmap_single-size*'
  chk "mtk_wed: WED v2 WDMA RESV_BUFF increase" has_glob 'target/linux/generic/backport-6.18/*mtk_wed-increase-WED-v2-WDMA-RESV_BUFF*'
  chk "mtk_eth_soc: PPE queries wireless driver for flow TID" has_glob 'target/linux/generic/pending-6.18/797-01-*query-the-wireless-driver*'
  chk "device profile glinet_gl-mt6000 exists" grep -q 'Device/glinet_gl-mt6000' target/linux/mediatek/image/filogic.mk
  chk "mt7986 WED offload firmware is a device package" grep -q 'mt7986-wo-firmware' target/linux/mediatek/image/filogic.mk
  if [ -d feeds ]; then
    echo "[pre] feeds installed"
    chk "feed package luci" test -e package/feeds/luci/luci
    chk "feed package chrony" test -e package/feeds/packages/chrony
    chk "feed package iperf3" test -e package/feeds/packages/iperf3
  else
    skip "feeds not fetched yet"
  fi
  if [ -f .config ]; then
    echo "[pre] .config selects what we expect"
    chk "device glinet_gl-mt6000 selected" grep -q '^CONFIG_TARGET_mediatek_filogic_DEVICE_glinet_gl-mt6000=y' .config
    for p in luci chrony iperf3 ethtool kmod-nf-conntrack-bridge kmod-nft-offload nftables-json firewall4; do
      chk "package $p selected" grep -q "^CONFIG_PACKAGE_${p}=y" .config
    done
    chk "bridger is NOT selected" bash -c '! grep -q "^CONFIG_PACKAGE_bridger=y" .config'
  else
    skip ".config not generated yet (run make defconfig first)"
  fi
  ;;
post)
  echo "[post] build output"
  img=$(ls bin/targets/mediatek/filogic/*gl-mt6000*sysupgrade.bin 2>/dev/null | head -1)
  if [ -n "$img" ]; then
    ok "sysupgrade image: $img"
    chk "image is larger than 8 MB" test "$(stat -c %s "$img")" -gt 8000000
    (cd "$(dirname "$img")" && sha256sum "$(basename "$img")" > SHA256SUMS.mt6000 && echo "  info  $(cat SHA256SUMS.mt6000)")
  else
    bad "no *gl-mt6000*sysupgrade.bin in bin/targets/mediatek/filogic/"
  fi
  man=$(ls bin/targets/mediatek/filogic/*gl-mt6000*.manifest 2>/dev/null | head -1)
  if [ -n "$man" ]; then
    echo "[post] package manifest ($man)"
    for p in firewall4 kmod-nf-conntrack-bridge kmod-nft-offload nftables-json kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware chrony luci; do
      chk "manifest has $p" grep -q "^${p} - " "$man"
    done
    chk "manifest has no bridger" bash -c '! grep -q "^bridger - " "'"$man"'"'
    chk "kernel in manifest is 6.18" grep -q '^kernel - 6\.18' "$man"
  else
    bad "no manifest file found"
  fi
  root=$(ls -d build_dir/target-*/root-mediatek 2>/dev/null | head -1)
  if [ -n "$root" ]; then
    echo "[post] rootfs contents ($root)"
    chk "hotplug script installed" test -f "$root/etc/hotplug.d/net/50-fw4-bridge-reload"
    chk "installed hotplug script is the robust version" grep -q 'until flock -n 9' "$root/etc/hotplug.d/net/50-fw4-bridge-reload"
    chk "fw4 has bridge flowtable support" grep -q 'check_bridge_flowtable' "$root/usr/share/ucode/fw4.uc"
    chk "nf_conntrack_bridge.ko present" has_glob "$root/lib/modules/*/nf_conntrack_bridge.ko"
    chk "kernel modules are 6.18.x" has_glob "$root/lib/modules/6.18.*"
  else
    skip "rootfs dir not found (not fatal; manifest checks above still apply)"
  fi
  ;;
*)
  echo "usage: check.sh pre|post <openwrt-dir>"; exit 2 ;;
esac

echo
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED ($STAGE)"; else echo "CHECKS FAILED ($STAGE) - do not flash"; fi
exit "$fail"
