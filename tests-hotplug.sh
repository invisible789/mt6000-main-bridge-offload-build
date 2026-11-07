#!/bin/sh
# Logic test for 50-fw4-bridge-reload with mocked nft / sysfs / firewall reload.
#   test-hotplug.sh <script-under-test> <label>
# Paths and sleeps are rewritten mechanically (sed) into a test copy; the control flow is the real script's.
set -u
SRC="$1"; LABEL="$2"
BASE=$(mktemp -d /tmp/claude-0/-home-claude/bdf7bd01-375b-58ea-9571-16e0df7f1e04/scratchpad/hp.XXXXXX)
pass=0; fail=0

setup() { # $1 = scenario dir name
  T="$BASE/$1"; mkdir -p "$T/sys" "$T/lock" "$T/bin" "$T/bridge"
  : > "$T/state"; : > "$T/reloads"
  # mock nft: only 'list flowtable bridge fw4 fb' is used
  cat > "$T/bin/nft" <<EOF
#!/bin/sh
[ -s "$T/state" ] || exit 1
devs=\$(sed 's/.*/"&"/' "$T/state" | paste -sd, - | sed 's/,/, /g')
printf 'table bridge fw4 {\n\tflowtable fb {\n\t\thook ingress priority filter\n\t\tdevices = { %s }\n\t}\n}\n' "\$devs"
EOF
  # mock firewall reload: snapshot the bridged devices at START, publish them after 0.5 s
  cat > "$T/firewall" <<EOF
#!/bin/sh
echo "\$(date +%s.%N)" >> "$T/reloads"
snap=\$(ls "$T/bridge")
sleep 0.5
printf '%s\n' \$snap > "$T/state"
EOF
  chmod +x "$T/bin/nft" "$T/firewall"
  sed -e "s#/sys/class/net#$T/sys#g" -e "s#/var/lock#$T/lock#g" -e "s#/etc/init.d/firewall#$T/firewall#g" \
      -e 's/\bsleep 2\b/sleep 0.4/' -e 's/\bsleep 1\b/sleep 0.1/' "$SRC" > "$T/script.sh"
}
fire() { # $1=dev $2=action ; mimic hotplug-call: source in a subshell
  ( PATH="$T/bin:$PATH"; ACTION="$2"; DEVICENAME="$1"; export ACTION DEVICENAME PATH; . "$T/script.sh" )
}
mkwifi()   { mkdir -p "$T/sys/$1"; printf 'DEVTYPE=wlan\nINTERFACE=%s\n' "$1" > "$T/sys/$1/uevent"; }
mkbridged(){ : > "$T/bridge/$1"; mkdir -p "$T/sys/$1/brport"; }
count()    { wc -l < "$T/reloads" | tr -d ' '; }
state()    { sort "$T/state" | paste -sd, -; }
check()    { # $1=name $2=expected reloads $3=expected final state
  sleep 3
  got=$(count); st=$(state)
  if [ "$got" = "$2" ] && [ "$st" = "$3" ]; then pass=$((pass+1)); printf '  PASS  %-46s reloads=%s state=[%s]\n' "$1" "$got" "$st"
  else fail=$((fail+1)); printf '  FAIL  %-46s reloads=%s (want %s) state=[%s] (want [%s])\n' "$1" "$got" "$2" "$st" "$3"; fi
}

echo "== $LABEL"
setup s1; mkwifi phy0-ap0; mkbridged phy0-ap0; fire phy0-ap0 remove;   check "non-add action is ignored" 0 ""
setup s2; mkbridged eth9; printf 'DEVTYPE=bridge\n' > "$T/sys/eth9/uevent";                  fire eth9 add;          check "non-wireless netdev is ignored" 0 ""
setup s3; mkwifi guest; mkbridged guest;       fire guest add;         check "custom ifname with wireless dir is handled" 1 "guest"
setup s3b; mkbridged phy0-ap0;                 fire phy0-ap0 add;      check "stock phyN-apM name w/o sysfs still handled" 1 "phy0-ap0"
setup s4; mkwifi phy0-ap0; mkwifi phy1-ap0; mkbridged phy0-ap0; mkbridged phy1-ap0
          fire phy0-ap0 add; sleep 0.2; fire phy1-ap0 add;             check "boot burst: two ports, one reload" 1 "phy0-ap0,phy1-ap0"
setup s5; mkwifi phy0-ap0; mkwifi guest; mkbridged phy0-ap0
          fire phy0-ap0 add; sleep 0.1; fire guest add; sleep 0.6; mkbridged guest
                                                                       check "port bridged late during a reload is not lost" 2 "guest,phy0-ap0"
setup s6; mkwifi phy0-ap0; mkbridged phy0-ap0; echo phy0-ap0 > "$T/state"; fire phy0-ap0 add
                                                                       check "already in flowtable: no reload" 0 "phy0-ap0"
setup s7; mkwifi phy0-sta0;                    fire phy0-sta0 add;     check "wlan netdev that is not a bridge port: no reload" 0 ""
rm -rf "$BASE"
echo "   -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
