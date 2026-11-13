#!/usr/bin/env bash
# Build a GL-MT6000 sysupgrade image: current OpenWrt main + OpenWrt PR #24038 (L2 bridge offload).
# Run on Linux/WSL as a NORMAL user (not root). Needs ~25 GB free disk and a few hours.
#
# Ubuntu/Debian build dependencies (from the OpenWrt build docs):
#   sudo apt install build-essential clang flex bison g++ gawk gcc-multilib g++-multilib \
#     gettext git libncurses-dev libssl-dev python3-setuptools rsync swig unzip \
#     zlib1g-dev file wget
#
# Environment options:
#   MODE=rebased   (default) apply bridge-offload-on-main-e2ed57b.mbox (the 10 current PR commits, unmodified) on top of main commit e2ed57b
#   MODE=pr        exactly the PR head commit 5df179e (PR branch, older base 706052b)
#   DRY_RUN=1      get sources, apply patches, fetch feeds, run the pre-checks, then STOP
#                  (no compile; takes minutes; safe to run first)
#   VALIDATE_PATCHES=1  with DRY_RUN=1: also build host tools and run the firewall4 and kernel
#                  "prepare" steps, which applies every package/kernel patch (the real patch test)
#   FEEDS_GITHUB=1 use the GitHub mirrors for feeds instead of git.openwrt.org
#   SKIP_DEPS_CHECK=1  skip the build-tool check (only for partial tests)
#   WORKDIR=...    where to clone (default ./openwrt-bridge-offload)
#   JOBS=N         parallel make jobs (default: all cores)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="${WORKDIR:-$PWD/openwrt-bridge-offload}"
JOBS="${JOBS:-$(nproc)}"
MODE="${MODE:-rebased}"
DRY_RUN="${DRY_RUN:-0}"
OPENWRT_REPO="${OPENWRT_REPO:-https://github.com/openwrt/openwrt}"
PR_SHA=5df179eee9f194350924eaded9c625b10f2e3ff4
BASE_SHA=e2ed57b957dc983fae535ca14a0969711537d752
MBOX="$HERE/bridge-offload-on-main-e2ed57b.mbox"
TEMP_STATUS_REPO=https://github.com/gSpotx2f/luci-app-temp-status
TEMP_STATUS_SHA=6d127817d92d758e35617620f9567a1336f5f8a5

if [ "$DRY_RUN" != "1" ] && [ "$(id -u)" -eq 0 ]; then
    echo "Do not run the real build as root (OpenWrt refuses). DRY_RUN=1 is allowed."
    exit 1
fi

step() { printf '\n==> %s\n' "$*"; }

if [ "${SKIP_DEPS_CHECK:-0}" != "1" ]; then
    missing=""
    for t in gcc g++ make git gawk rsync swig flex bison unzip wget file python3 perl; do
        command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
    done
    if [ -n "$missing" ]; then
        echo "Missing build tools:$missing"
        echo "Ubuntu/Debian: sudo apt install build-essential clang flex bison g++ gawk gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev python3-setuptools rsync swig unzip zlib1g-dev file wget"
        exit 1
    fi
fi

step "Getting sources"
if [ ! -d "$WORKDIR/.git" ]; then
    git clone "$OPENWRT_REPO" "$WORKDIR"
fi
cd "$WORKDIR"

step "Selecting patch set (MODE=$MODE)"
case "$MODE" in
pr)
    git cat-file -e "$PR_SHA^{commit}" 2>/dev/null || git fetch origin pull/24038/head
    git checkout -q "$PR_SHA"
    ;;
rebased)
    git cat-file -e "$BASE_SHA^{commit}" 2>/dev/null || git fetch origin "$BASE_SHA"
    git checkout -q "$BASE_SHA"
    git checkout -q -B mt6000-bridge-offload
    git -c user.name="${GIT_AUTHOR_NAME:-builder}" -c user.email="${GIT_AUTHOR_EMAIL:-builder@example.com}" \
        am --3way "$MBOX"
    ;;
*)
    echo "MODE must be rebased or pr"; exit 1 ;;
esac
git log -1 --format='source commit: %H %s'

step "Feeds"
if [ "${FEEDS_GITHUB:-0}" = "1" ]; then
    cat > feeds.conf <<'EOF'
src-git packages https://github.com/openwrt/packages.git
src-git luci https://github.com/openwrt/luci.git
src-git routing https://github.com/openwrt/routing.git
src-git telephony https://github.com/openwrt/telephony.git
src-git video https://github.com/openwrt/video.git
EOF
fi
if [ "$DRY_RUN" = "1" ] && [ "${VALIDATE_PATCHES:-0}" != "1" ]; then
    ./scripts/feeds update packages luci
    ./scripts/feeds install luci chrony iperf3 vsftpd
else
    ./scripts/feeds update -a
    ./scripts/feeds install -a
fi

step "Extra package: luci-app-temp-status (not in any OpenWrt feed; pinned commit)"
rm -rf package/luci-app-temp-status
git clone -q "$TEMP_STATUS_REPO" package/luci-app-temp-status
git -C package/luci-app-temp-status checkout -q "$TEMP_STATUS_SHA"
rm -rf package/luci-app-temp-status/.git

step "Pre-build checks"
bash "$HERE/check.sh" pre "$PWD"

if [ "$DRY_RUN" = "1" ]; then
    if [ "${VALIDATE_PATCHES:-0}" = "1" ]; then
        step "Configuring"
        cp "$HERE/mt6000.diffconfig" .config
        make defconfig
        bash "$HERE/check.sh" pre "$PWD"
        step "Patch validation: host tools, firewall4 and kernel prepare"
        make tools/install -j"$JOBS"
        make package/network/config/firewall4/download package/network/config/firewall4/prepare V=s 2>&1 | tee "$HERE/fw4-prepare.log" | tail -n 20
        make target/linux/download target/linux/prepare V=s 2>&1 | tee "$HERE/kernel-prepare.log" | tail -n 30
        if grep -E 'Hunk #[0-9]+ FAILED|can.t find file to patch|Patch failed|saving rejects' "$HERE/fw4-prepare.log" "$HERE/kernel-prepare.log"; then
            echo "PATCH FAILURES - do not build"; exit 1
        fi
        echo "Patch validation passed."
    fi
    echo
    echo "DRY RUN finished. No compile was done."
    exit 0
fi

step "Configuring"
cp "$HERE/mt6000.diffconfig" .config
make defconfig
bash "$HERE/check.sh" pre "$PWD"

step "Downloading sources"
make download -j8

step "Building (this is the long part)"
make -j"$JOBS" || make -j1 V=s

step "Post-build checks"
bash "$HERE/check.sh" post "$PWD"

echo
echo "Done. Image(s):"
ls -l bin/targets/mediatek/filogic/*gl-mt6000*sysupgrade.bin
echo "Flash only the *-sysupgrade.bin. Never a factory image. Test it first on the router with: sysupgrade -T <file>"
