#!/bin/sh
# ============================================================
# quarantine-setup.sh - all-in-one installer for Asuswrt-Merlin routers (tested on RT-AX88U)
#   1. checks permissions
#   2. makes a full backup (live files + old install set) incl. restore.sh
#   3. removes the old install set (it is safe in the backup)
#   4. writes the new set + SHA256SUMS to /tmp/mnt/sda1/quarantine_install
#   5. runs install.sh (integrity, installation, self-test)
#   6. on a failed self-test: automatic rollback via restore.sh
# Usage: sh /tmp/mnt/sda1/quarantine-setup.sh
# ============================================================
umask 077
SET="/tmp/mnt/sda1/quarantine_install"
QD="/jffs/addons/quarantine.d"
SC="/jffs/scripts"
TS=$(date +%Y%m%d%H%M%S)
BK="$SET/backup-$TS"
SCRIPTS="dnsmasq.postconf firewall-start init-start services-start service-event post-mount"

abort() { echo "[setup] ABORTED: $*"; exit 1; }
say()   { echo "[setup] $*"; }

qt_hash() {
    # note: the router shell has no builtin 'command' - hence explicit paths
    for _h in /bin/sha256sum /usr/bin/sha256sum /opt/bin/sha256sum; do
        if [ -x "$_h" ]; then
            "$_h" "$1" | cut -d' ' -f1
            return 0
        fi
    done
    if [ -x /usr/sbin/openssl ]; then
        /usr/sbin/openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

# ---- 1. permissions and sources ----
for d in "$SC" /jffs/addons /tmp/mnt/sda1 /www; do
    [ -w "$d" ] || abort "no write permission on $d"
done
[ -r /usr/sbin/helper.sh ] || abort "/usr/sbin/helper.sh missing"
qt_hash /usr/sbin/helper.sh >/dev/null || abort "no sha256 tool (sha256sum or openssl) available"
same() { [ "$(qt_hash "$1")" = "$(qt_hash "$2")" ]; }
mkdir -p "$SET"

# ---- 2. backup ----
mkdir -p "$BK/jffs-scripts" "$BK/quarantine.d" "$BK/old-set"
for f in $SCRIPTS; do
    if [ -f "$SC/$f" ]; then
        cp -p "$SC/$f" "$BK/jffs-scripts/$f"
        same "$SC/$f" "$BK/jffs-scripts/$f" || abort "backup of $SC/$f failed"
    else
        : > "$BK/jffs-scripts/$f.absent"
    fi
done
for f in "$QD"/*; do
    [ -f "$f" ] || continue
    cp -p "$f" "$BK/quarantine.d/"
    same "$f" "$BK/quarantine.d/$(basename "$f")" || abort "backup of $f failed"
done
[ -f /jffs/addons/custom_settings.txt ] && cp -p /jffs/addons/custom_settings.txt "$BK/custom_settings.txt"
iptables-save > "$BK/iptables-save.txt" 2>/dev/null
for f in "$SET"/*; do
    [ -f "$f" ] && mv "$f" "$BK/old-set/"
done

cat > "$BK/restore.sh" << 'QT_PAYLOAD_RESTORE'
#!/bin/sh
# Restore the situation right before quarantine-setup.sh
B=$(cd "$(dirname "$0")" && pwd)
SC="/jffs/scripts"
QD="/jffs/addons/quarantine.d"
for f in dnsmasq.postconf firewall-start init-start services-start service-event post-mount; do
    if [ -f "$B/jffs-scripts/$f" ]; then
        cp -p "$B/jffs-scripts/$f" "$SC/$f"
    elif [ -f "$B/jffs-scripts/$f.absent" ]; then
        rm -f "$SC/$f"
    fi
done
for f in "$B"/quarantine.d/*; do
    [ -f "$f" ] && cp -p "$f" "$QD/$(basename "$f")"
done
# files that did not exist before this run (new add-on files) are removed again
for f in lib.sh fw.sh postconf.sh webui.sh selftest.sh cli.sh applied.prefix; do
    [ -f "$B/quarantine.d/$f" ] || rm -f "$QD/$f"
done
service restart_dnsmasq
logger -t quarantine "restore: state from $B restored"
echo "[restore] done - state from $B restored"
QT_PAYLOAD_RESTORE
chmod 700 "$BK/restore.sh"
say "backup saved in $BK (old install set is in $BK/old-set)"

# ---- 3. write the new set ----
cat > "$SET/lib.sh" << 'QT_PAYLOAD_LIB'
#!/bin/sh
# ============================================================
# Quarantine - shared functions (sourced, never executed directly)
# ============================================================

# Hook scripts run with a short PATH (wl/iptables live in /usr/sbin): put the system dirs first
PATH="/bin:/usr/bin:/sbin:/usr/sbin:$PATH"
export PATH

# shellcheck disable=SC1091
[ -r /usr/sbin/helper.sh ] && . /usr/sbin/helper.sh

QT_VERSION="0.18"
QT_DIR="/jffs/addons/quarantine.d"
QT_APPLIED="$QT_DIR/applied.prefix"
QT_BANFILE="/tmp/quarantine.banned"
QT_BAN_SECS=10
QT_BUSYFILE="/tmp/quarantine.busy"
QT_MSGFILE="/tmp/quarantine.msg"
QT_MSG_TTL=90
QT_STATIC="/jffs/addons/YazDHCP.d/.staticlist"
QT_YAZ_DIR="/jffs/addons/YazDHCP.d"
QT_RFC1918="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
QT_BLOCKFILE="$QT_DIR/blocked.list"

# ---- debug logging (quarantine only) ----
# On/off via setting qt_debug (1 = on, default on while commissioning; off: am_settings_set qt_debug 0)
# File on sda1 (600, dir 700), rotated at > 1 MB to .1; without writable sda1 it goes to /tmp.
QT_DBGDIR="/tmp/mnt/sda1/quarantine_debug"
qt_dbg() {
    [ "$(qt_get qt_debug 1)" = "1" ] || return 0
    _df="$QT_DBGDIR/quarantine-debug.log"
    if [ -d /tmp/mnt/sda1 ] && [ -w /tmp/mnt/sda1 ]; then
        [ -d "$QT_DBGDIR" ] || { mkdir -p "$QT_DBGDIR" 2>/dev/null && chmod 700 "$QT_DBGDIR"; }
    else
        _df="/tmp/quarantine-debug.log"
    fi
    if [ -f "$_df" ] && [ "$(wc -c < "$_df")" -gt 1048576 ]; then
        mv -f "$_df" "$_df.1"
    fi
    printf '%s [%s %s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${QT_CTX:-lib}" "$$" "$*" >> "$_df" 2>/dev/null
    chmod 600 "$_df" 2>/dev/null
    return 0
}

qt_log() { logger -t "quarantine" "$*"; qt_dbg "LOG $*"; }

# Read a setting with a default: qt_get <key> <default>
qt_get() {
    _v=$(am_settings_get "$1")
    [ -z "$_v" ] && _v="$2"
    echo "$_v"
}

# Status: only an explicit 0 means off. Anything else (also unreadable/empty) = on (fail-closed).
qt_status() {
    _s=$(am_settings_get qt_status)
    case "$_s" in
        0) echo 0 ;;
        *) echo 1 ;;
    esac
}

# Valid unicast IPv4 address (octets 0-255, not 0.x, 127.x or >=224)
qt_is_ipv4() {
    echo "$1" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || return 1
    echo "$1" | awk -F. '{ if ($1 < 1 || $1 == 127 || $1 >= 224) bad = 1; for (i = 1; i <= 4; i++) if ($i > 255) bad = 1 } END { exit bad + 0 }'
}

# Valid MAC address (lower case, as in dnsmasq.leases)
qt_is_mac() {
    echo "$1" | grep -Eq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

# Only safe characters in displayed/mailed names
qt_clean_name() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._*-' | cut -c1-63
}

# Name for DHCP reservations (no '*')
qt_host_name() {
    printf '%s' "$1" | tr -cd 'A-Za-z0-9._-' | cut -c1-30
}

qt_ssh_port() {
    _p=$(nvram get sshd_port)
    case "$_p" in
        ''|*[!0-9]*) _p=22 ;;
    esac
    echo "$_p"
}

# ============================================================
# Network detection (nothing is hardcoded)
# ============================================================
# Quarantine always uses a /24. The LAN must be a /24 too (checked in qt_net_check).

qt_pfx_of() { echo "$1" | cut -d. -f1-3; }

# 3-octet prefix that is a valid private /24 candidate (RFC1918 only)
qt_prefix_syntax() {
    echo "$1" | grep -Eq '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$' || return 1
    echo "$1" | awk -F. '{
        for (i = 1; i <= 3; i++) if ($i > 255) bad = 1
        ok = 0
        if ($1 == 10) ok = 1
        if ($1 == 172 && $2 >= 16 && $2 <= 31) ok = 1
        if ($1 == 192 && $2 == 168) ok = 1
        if (!ok) bad = 1 } END { exit bad + 0 }'
}

# 0 when the candidate prefix collides with an existing network (LAN, guest, WAN, VPN, ...)
qt_prefix_conflict() {
    [ "$1" = "$QT_LANPFX" ] && return 0
    ip -4 -o addr show 2>/dev/null | awk -v c="$1" -v br="$QT_BR" '
        { split($4, a, "/"); n = split(a[1], o, "."); if (n != 4) next
          if (o[1] "." o[2] "." o[3] == c && !($2 == br && a[1] == c ".1")) found = 1 }
        END { exit found ? 0 : 1 }' && return 0
    # ranges of other networks (our own quarantine range, tagged "tag:!<name>", does not count)
    grep -v '^dhcp-range=tag:!' /etc/dnsmasq.conf 2>/dev/null | grep -Eq "^dhcp-range=[^,]*,${1}\." && return 0
    return 1
}

# Validate a quarantine prefix; sets QT_PFX_ERR on failure
qt_valid_prefix() {
    QT_PFX_ERR=""
    if ! qt_prefix_syntax "$1"; then QT_PFX_ERR="not a private /24 (use 10.x.y, 172.16-31.x.y or 192.168.x)"; return 1; fi
    if [ "$1" = "$QT_LANPFX" ]; then QT_PFX_ERR="same as the LAN subnet"; return 1; fi
    if qt_prefix_conflict "$1"; then QT_PFX_ERR="overlaps with an existing network on this router"; return 1; fi
    return 0
}

# Suggestion: third octet of the LAN + 1 (or -1 at the top); next free one if that is taken
qt_suggest_prefix() {
    _a=$(echo "$QT_LANPFX" | cut -d. -f1-2)
    _c=$(echo "$QT_LANPFX" | cut -d. -f3)
    _try=$((_c + 1))
    _n=0
    while [ "$_n" -lt 60 ]; do
        [ "$_try" -gt 254 ] && _try=$((_c - 1 - _n))
        [ "$_try" -lt 1 ] && break
        if qt_valid_prefix "${_a}.${_try}"; then
            echo "${_a}.${_try}"
            return 0
        fi
        _try=$((_try + 1)); _n=$((_n + 1))
    done
    echo ""
    return 1
}

# Loads QT_LANIP QT_LANMASK QT_LANPFX QT_BR QT_QPFX QT_NET QT_GWIP. Returns 1 when the LAN cannot be determined.
qt_load_net() {
    QT_LANIP=$(nvram get lan_ipaddr)
    QT_LANMASK=$(nvram get lan_netmask)
    QT_BR=$(nvram get lan_ifname)
    [ -n "$QT_BR" ] || QT_BR=br0
    QT_QPFX=""; QT_NET=""; QT_GWIP=""; QT_LANPFX=""
    qt_is_ipv4 "$QT_LANIP" || return 1
    QT_LANPFX=$(qt_pfx_of "$QT_LANIP")
    _s=$(am_settings_get qt_subnet)
    if [ -n "$_s" ] && qt_valid_prefix "$_s"; then
        QT_QPFX="$_s"
    else
        QT_QPFX=$(qt_suggest_prefix)
    fi
    [ -n "$QT_QPFX" ] || return 1
    QT_NET="${QT_QPFX}.0/24"
    QT_GWIP="${QT_QPFX}.1"
    return 0
}

# Preconditions for turning quarantine on; message in QT_NET_ERR
qt_net_check() {
    QT_NET_ERR=""
    if ! qt_load_net; then QT_NET_ERR="Cannot determine the LAN network or a free quarantine subnet"; return 1; fi
    if [ "$QT_LANMASK" != "255.255.255.0" ]; then QT_NET_ERR="LAN netmask is $QT_LANMASK - only a /24 LAN is supported"; return 1; fi
    if [ -z "$(qt_lan_tag /etc/dnsmasq.conf)" ]; then QT_NET_ERR="Cannot find the LAN DHCP range for ${QT_LANPFX}.x in dnsmasq.conf"; return 1; fi
    return 0
}

# Name of the dnsmasq tag/label of the main LAN range (from the given dnsmasq.conf), e.g. "lan"
qt_lan_tag() {
    [ -r "$1" ] || return 1
    awk -F, -v p="${QT_LANPFX}." '
        /^dhcp-range=/ {
            t = $1; sub(/^dhcp-range=/, "", t); sub(/^tag:/, "", t)
            if (t ~ /^[A-Za-z][A-Za-z0-9_-]*$/ && index($2, p) == 1) { print t; exit }
        }' "$1"
}

# Prefix of the subnet that is currently configured on the bridge (so it can be removed again)
qt_applied_prefix() {
    [ -r "$QT_APPLIED" ] && head -n 1 "$QT_APPLIED"
}

# ============================================================
# Known devices (the only devices allowed on the LAN)
# ============================================================
# Source: YazDHCP when present and filled, otherwise the native ASUS DHCP reservation list.

qt_yaz_macs() {
    [ -r "$QT_STATIC" ] || return 1
    _sm=$(awk -F, 'toupper($2) ~ /^([0-9A-F][0-9A-F]:)+[0-9A-F][0-9A-F]$/ {print toupper($2)}' "$QT_STATIC")
    [ -n "$_sm" ] || return 1
    echo "$_sm"
}

# native list format (from nvram dhcp_staticlist): <MAC>IP>DNS>HOSTNAME<MAC>...
qt_native_macs() {
    _nm=$(nvram get dhcp_staticlist | tr '<' '\n' | awk -F'>' 'toupper($1) ~ /^([0-9A-F][0-9A-F]:)+[0-9A-F][0-9A-F]$/ {print toupper($1)}')
    [ -n "$_nm" ] || return 1
    echo "$_nm"
}

qt_known_src() {
    if qt_yaz_macs >/dev/null; then echo yazdhcp
    elif qt_native_macs >/dev/null; then echo native
    else echo none
    fi
}

# Known MACs (upper case). Fails when there are none: then nothing may be cleaned up or kicked.
qt_known_macs() {
    qt_yaz_macs || qt_native_macs
}

# ============================================================
# Access policy for quarantine devices (allowed outgoing ports)
# ============================================================
# Mode (setting qt_access): A = 53, 80, 443; B = A + NTP (123/udp) + QUIC (443/udp) (default); C = B + your own port list (setting qt_ports),
# O = open (no port restriction: every port to the Internet; private ranges and the router stay blocked).
# In the restricted modes port 53 (tcp+udp) is always allowed. Custom port list is stored as tokens joined by '-':
#   "443-8883-123u-80t"  (no suffix = tcp and udp, t = tcp only, u = udp only)
qt_access_mode() {
    case "$(qt_get qt_access B)" in
        A) echo A ;;
        C) echo C ;;
        O) echo O ;;
        *) echo B ;;
    esac
}

# 0 when the token string is valid (1-20 ports, 1-65535)
qt_ports_valid() {
    [ -n "$1" ] || return 1
    echo "$1" | grep -Eq '^[1-9][0-9]{0,4}[tu]?(-[1-9][0-9]{0,4}[tu]?){0,19}$' || return 1
    for _t in $(echo "$1" | tr '-' ' '); do
        _n=${_t%[tu]}
        [ "$_n" -le 65535 ] || return 1
    done
    return 0
}

# Allowed outgoing ports for the current mode, one "proto port" per line (empty in open mode: no restriction)
qt_access_list() {
    [ "$(qt_access_mode)" = "O" ] && return 0
    {
        echo "tcp 53"
        echo "udp 53"
        case "$(qt_access_mode)" in
            A) echo "tcp 80"; echo "tcp 443" ;;
            B) echo "tcp 80"; echo "tcp 443"; echo "udp 123"; echo "udp 443" ;;
            C)
                echo "tcp 80"; echo "tcp 443"; echo "udp 123"; echo "udp 443"
                _pt=$(qt_get qt_ports "")
                if qt_ports_valid "$_pt"; then
                    for _t in $(echo "$_pt" | tr '-' ' '); do
                        _n=${_t%[tu]}
                        case "$_t" in
                            *t) echo "tcp $_n" ;;
                            *u) echo "udp $_n" ;;
                            *) echo "tcp $_n"; echo "udp $_n" ;;
                        esac
                    done
                fi
                ;;
        esac
    } | awk '!seen[$0]++'
}

# Readable form: "tcp/53, udp/53, ..."
qt_access_text() {
    [ "$(qt_access_mode)" = "O" ] && { echo "all ports (no port restriction)"; return 0; }
    qt_access_list | tr ' ' '/' | tr '\n' ',' | sed 's/,$//; s/,/, /g'
}

# ============================================================
# Blocked devices (list of MACs without any network access)
# ============================================================
# File format: mac(lower case)|epoch|name. A block works on the MAC address, also while quarantine is Off.
qt_blocked_macs() {
    [ -r "$QT_BLOCKFILE" ] || return 0
    awk -F'|' '$1 ~ /^([0-9a-f][0-9a-f]:)+[0-9a-f][0-9a-f]$/ {print $1}' "$QT_BLOCKFILE"
}

qt_is_blocked() {
    qt_blocked_macs | grep -qix "$1"
}

qt_block_backup() {
    [ -f "$QT_BLOCKFILE" ] || return 0
    mkdir -p "$QT_DIR/backups"; chmod 700 "$QT_DIR/backups"
    cp -p "$QT_BLOCKFILE" "$QT_DIR/backups/blocked.list.$(date +%Y%m%d%H%M%S)"
}

# qt_block_add <mac lower case> <name>
qt_block_add() {
    qt_is_mac "$1" || return 1
    qt_is_blocked "$1" && return 0
    qt_block_backup
    _bn=$(qt_clean_name "$2")
    [ -n "$_bn" ] || _bn="-"
    printf '%s|%s|%s\n' "$1" "$(date +%s)" "$_bn" >> "$QT_BLOCKFILE"
    chmod 600 "$QT_BLOCKFILE"
    return 0
}

qt_block_del() {
    [ -f "$QT_BLOCKFILE" ] || return 0
    qt_block_backup
    grep -v -i "^$1|" "$QT_BLOCKFILE" > "$QT_BLOCKFILE.tmp"
    cat "$QT_BLOCKFILE.tmp" > "$QT_BLOCKFILE"
    rm -f "$QT_BLOCKFILE.tmp"
    chmod 600 "$QT_BLOCKFILE"
    return 0
}

# ============================================================
# Firewall (own chains, fully rebuilt on every apply)
# ============================================================
ipt_add() { iptables -C "$@" 2>/dev/null || iptables -I "$@"; }
ipt_del() { while iptables -D "$@" 2>/dev/null; do :; done; }

# Remove jump rules + chains created by this add-on (QT_BLK is referenced twice: the second pass removes the chain)
qt_fw_clear() {
    for _pc in FORWARD:QT_FWD INPUT:QT_IN FORWARD:QT_BLK INPUT:QT_BLK; do
        _p=${_pc%%:*}; _n=${_pc##*:}
        iptables -S "$_p" 2>/dev/null | grep -- "-j $_n\$" | sed 's/^-A/-D/' | while read -r _r; do
            # shellcheck disable=SC2086
            iptables $_r 2>/dev/null
        done
        iptables -F "$_n" 2>/dev/null
        iptables -X "$_n" 2>/dev/null
    done
    return 0
}

# Rules left behind by an earlier applied quarantine prefix
qt_fw_legacy_cleanup() {
    for _lp in "$(qt_applied_prefix)"; do
        [ -n "$_lp" ] || continue
        for _p in 80 443 8443 "$(qt_ssh_port)"; do
            ipt_del INPUT -s "${_lp}.0/24" -p tcp --dport "$_p" -j DROP
            ipt_del INPUT -s "${_lp}.0/24" -d "$QT_LANIP" -p tcp --dport "$_p" -j DROP
        done
    done
}

qt_fw_apply() {
    qt_load_net
    qt_fw_legacy_cleanup
    qt_fw_clear
    _fwrc=0
    if [ "$(qt_status)" = "1" ]; then
        qt_fw_quarantine || _fwrc=1
    fi
    qt_fw_blocks
    return "$_fwrc"
}

# Blocked devices: everything from the MAC is dropped except DHCP (so the device keeps its lease and stays visible)
qt_fw_blocks() {
    _bl=$(qt_blocked_macs)
    [ -n "$_bl" ] || return 0
    iptables -N QT_BLK
    for _bm in $_bl; do
        iptables -A QT_BLK -m mac --mac-source "$_bm" -p udp --dport 67 -j RETURN
        iptables -A QT_BLK -m mac --mac-source "$_bm" -j DROP
    done
    iptables -I FORWARD 1 -j QT_BLK
    iptables -I INPUT 1 -j QT_BLK
    qt_dbg "firewall: $(echo "$_bl" | grep -c .) blocked device(s) applied"
}

# Chains for the quarantine subnet (only while quarantine is on)
qt_fw_quarantine() {
    [ -n "$QT_NET" ] || { qt_log "WARNING: no quarantine subnet - firewall rules not applied"; return 1; }
    # quarantine -> everything private is blocked (only the Internet is reachable); replies to LAN-initiated sessions stay allowed
    iptables -N QT_FWD
    iptables -A QT_FWD -d "$QT_NET" -j RETURN
    iptables -A QT_FWD -m state --state RELATED,ESTABLISHED -j RETURN
    for _r in $QT_RFC1918; do iptables -A QT_FWD -d "$_r" -j DROP; done
    # restricted access: only the allowed ports may leave the quarantine, everything else is dropped
    # (open mode: no port rules and no default drop - everything that is not private is allowed)
    if [ "$(qt_access_mode)" != "O" ]; then
        qt_access_list > "/tmp/qt-acc.$$"
        while read -r _pr _po; do
            iptables -A QT_FWD -p "$_pr" --dport "$_po" -j RETURN
        done < "/tmp/qt-acc.$$"
        rm -f "/tmp/qt-acc.$$"
        iptables -A QT_FWD -j DROP
    fi
    iptables -I FORWARD 1 -s "$QT_NET" -j QT_FWD
    # quarantine -> router itself: default deny except DHCP and ping
    iptables -N QT_IN
    iptables -A QT_IN -m state --state RELATED,ESTABLISHED -j RETURN
    iptables -A QT_IN -p udp --dport 67 -j RETURN
    iptables -A QT_IN -p icmp --icmp-type echo-request -j RETURN
    iptables -A QT_IN -j DROP
    iptables -I INPUT 1 -s "$QT_NET" -j QT_IN
    qt_dbg "firewall applied for $QT_NET"
}

# ---- busy marker for the GUI (epoch in file; older than 90 s = expired) ----
qt_busy_set() { QT_BUSY_OWNER=1; date +%s > "$QT_BUSYFILE" 2>/dev/null; }
qt_busy_clear() { rm -f "$QT_BUSYFILE"; }
qt_busy_get() {
    [ -f "$QT_BUSYFILE" ] || { echo 0; return; }
    _t=$(cat "$QT_BUSYFILE" 2>/dev/null); _n=$(date +%s)
    case "$_t" in ''|*[!0-9]*) echo 0; return ;; esac
    if [ $((_n - _t)) -lt 90 ]; then echo 1; else echo 0; fi
}

# ---- message for the GUI (cleared at the start of every action) ----
# File format: "<epoch>|<message>". The GUI only shows a message for QT_MSG_TTL seconds (see generate-data.sh).
qt_msg_set() { printf '%s|%s\n' "$(date +%s)" "$1" > "$QT_MSGFILE" 2>/dev/null; qt_log "NOTICE: $1"; }
qt_msg_clear() { rm -f "$QT_MSGFILE"; }

# ---- remove the quarantine gateway address from the bridge (when quarantine is off or the subnet changes) ----
qt_gw_addr_del() {
    _ap=$(qt_applied_prefix)
    [ -n "$_ap" ] || _ap="${1:-}"
    [ -n "$_ap" ] || return 0
    if ip addr show "$QT_BR" 2>/dev/null | grep -q "${_ap}.1/24"; then
        if ip addr del "${_ap}.1/24" dev "$QT_BR" 2>/dev/null; then
            qt_log "removed ${_ap}.1/24 from $QT_BR (quarantine subnet no longer exists)"
        else
            qt_log "WARNING: could not remove ${_ap}.1/24 from $QT_BR"
        fi
    fi
    rm -f "$QT_APPLIED"
}

# ============================================================
# Leases
# ============================================================
qt_leases() {
    if [ -f /var/lib/misc/dnsmasq.leases ]; then
        echo /var/lib/misc/dnsmasq.leases
    else
        echo /tmp/dnsmasq.leases
    fi
}

# Remove leases in the given prefix (default: current quarantine prefix)
qt_clear_leases() {
    _lf=$(qt_leases)
    [ -f "$_lf" ] || return 0
    _pf="${1:-$QT_QPFX}."
    _n=$(awk -v p="$_pf" 'index($3, p) == 1' "$_lf" | grep -c .)
    awk -v p="$_pf" 'index($3, p) != 1' "$_lf" > "$_lf.qt.tmp"
    cat "$_lf.qt.tmp" > "$_lf"
    rm -f "$_lf.qt.tmp"
    qt_log "${_n:-0} quarantine lease(s) removed from $_lf"
}

# MACs with a lease in the given prefix (default: quarantine prefix)
qt_lease_macs_q() {
    _lf=$(qt_leases)
    [ -f "$_lf" ] || return 0
    awk -v p="${1:-$QT_QPFX}." 'index($3, p) == 1 {print toupper($2)}' "$_lf"
}

# MACs with a LAN lease that are NOT in the known list
qt_unknown_lan_macs() {
    _lf=$(qt_leases)
    [ -f "$_lf" ] || return 0
    _st=$(qt_known_macs) || return 1
    printf '%s\n' "$_st" > "/tmp/qt-static.$$"
    awk -v p="${QT_LANPFX}." 'NR==FNR {k[$1]=1; next} index($3, p) == 1 && !(toupper($2) in k) {print toupper($2)}' "/tmp/qt-static.$$" "$_lf"
    rm -f "/tmp/qt-static.$$"
}

# Remove the leases of the given MACs (one per line); the lease file stays untouched if awk fails
qt_drop_leases_for() {
    _lf=$(qt_leases)
    [ -f "$_lf" ] || return 0
    [ -n "$1" ] || return 0
    printf '%s\n' "$1" > "/tmp/qt-drop.$$"
    qt_dbg "dropping leases for: $(echo $1) (before: $(wc -l < "$_lf") lines)"
    if awk 'NR==FNR {k[$1]=1; next} !(toupper($2) in k)' "/tmp/qt-drop.$$" "$_lf" > "$_lf.qt.tmp"; then
        cat "$_lf.qt.tmp" > "$_lf"
    fi
    rm -f "$_lf.qt.tmp" "/tmp/qt-drop.$$"
    qt_dbg "dropping leases done (after: $(wc -l < "$_lf") lines)"
}

# Find an executable on explicit paths (the router shell has no 'command' and hooks run with a short PATH)
qt_find() {
    for _d in /usr/sbin /bin /sbin /usr/bin; do
        if [ -x "$_d/$1" ]; then
            echo "$_d/$1"
            return 0
        fi
    done
    return 1
}

# Deauthenticate the given MACs (one per line) from wifi; only devices that are connected right now
qt_kick_macs() {
    [ -n "$1" ] || return 0
    _wl=$(qt_find wl) || { qt_log "wl not found (PATH=$PATH) - no deauth"; return 0; }
    _nv=$(qt_find nvram) || { qt_log "nvram not found (PATH=$PATH) - no deauth"; return 0; }
    qt_dbg "kick list: $(echo $1) (wl=$_wl nvram=$_nv)"
    _all=""
    for _i in 0 1 2; do
        _if=$("$_nv" get "wl${_i}_ifname")
        [ -n "$_if" ] || continue
        _assoc=$("$_wl" -i "$_if" assoclist 2>/dev/null | tr 'a-f' 'A-F')
        _all="$_all $_assoc"
        qt_dbg "kick: $_if has $(echo "$_assoc" | grep -c .) associated station(s)"
        for _mac in $1; do
            qt_is_mac "$(printf '%s' "$_mac" | tr 'A-F' 'a-f')" || continue
            case "$_assoc" in
                *"$_mac"*)
                    if "$_wl" -i "$_if" deauthenticate "$_mac" >/dev/null 2>&1; then
                        qt_log "deauth $_mac on $_if"
                    else
                        qt_log "deauth $_mac on $_if FAILED"
                    fi
                    ;;
            esac
        done
    done
    for _mac in $1; do
        case "$_all" in
            *"$_mac"*) : ;;
            *) qt_dbg "kick: $_mac is not on wifi (wired, already gone or other interface)" ;;
        esac
    done
}

# ---- temporary wifi deny-list so a kicked device does NOT come straight back ----
# Only on radios with macmode=1 (deny) and an empty list (not used by you/ASUS).
# Registered in $QT_BANFILE (epoch + interfaces) so cleanup also works after a crash.
qt_ban_release() {
    [ -f "$QT_BANFILE" ] || return 0
    _wl=$(qt_find wl) || return 0
    _ifs=$(sed -n '2p' "$QT_BANFILE" 2>/dev/null)
    for _if in $_ifs; do
        "$_wl" -i "$_if" mac none >/dev/null 2>&1
        _left=$("$_wl" -i "$_if" mac 2>/dev/null | tr -d ' \n')
        if [ -n "$_left" ]; then
            "$_wl" -i "$_if" mac none >/dev/null 2>&1
            _left=$("$_wl" -i "$_if" mac 2>/dev/null | tr -d ' \n')
        fi
        if [ -z "$_left" ]; then
            qt_log "wifi deny-list released on $_if"
        else
            qt_log "WARNING: wifi deny-list on $_if NOT released (list: $_left) - manually: wl -i $_if mac none"
        fi
    done
    rm -f "$QT_BANFILE"
}

# safety net (cron): release a deny-list older than 60 s
qt_ban_stale() {
    [ -f "$QT_BANFILE" ] || return 0
    _t=$(sed -n '1p' "$QT_BANFILE" 2>/dev/null); _n=$(date +%s)
    case "$_t" in ''|*[!0-9]*) qt_ban_release; return 0 ;; esac
    [ $((_n - _t)) -gt 60 ] && qt_ban_release
    return 0
}

# Kick MACs (one per line) with a short deny-list; falls back to a plain deauth
qt_ban_kick() {
    [ -n "$1" ] || return 0
    _wl=$(qt_find wl) || { qt_log "wl not found (PATH=$PATH) - no deauth"; return 0; }
    _nv=$(qt_find nvram) || { qt_log "nvram not found (PATH=$PATH) - no deauth"; return 0; }
    _macs=""
    for _mac in $1; do
        _m=$(printf '%s' "$_mac" | tr 'A-F' 'a-f')
        qt_is_mac "$_m" && _macs="$_macs $_m"
    done
    [ -n "$_macs" ] || return 0
    QT_BAN_OWNER=1
    _ok=""
    for _i in 0 1 2; do
        _if=$("$_nv" get "wl${_i}_ifname")
        [ -n "$_if" ] || continue
        _mm=$("$_wl" -i "$_if" macmode 2>/dev/null | tr -d ' \n')
        _ml=$("$_wl" -i "$_if" mac 2>/dev/null | tr -d ' \n')
        if [ "$_mm" = "1" ] && [ -z "$_ml" ]; then
            _ok="$_ok $_if"
        else
            qt_log "wifi deny-list skipped on $_if (macmode=[$_mm] list=[$_ml]) - plain deauth only"
        fi
    done
    if [ -n "$_ok" ]; then
        printf '%s\n%s\n' "$(date +%s)" "$(echo $_ok)" > "$QT_BANFILE"
        for _if in $_ok; do
            # shellcheck disable=SC2086
            if "$_wl" -i "$_if" mac $_macs >/dev/null 2>&1; then
                qt_log "wifi deny-list on $_if for:$_macs"
            else
                qt_log "setting wifi deny-list on $_if FAILED"
            fi
        done
    fi
    qt_kick_macs "$1"
    if [ -n "$_ok" ]; then
        sleep "$QT_BAN_SECS"
        qt_ban_release
    fi
}

# Stop dnsmasq (waits max 10 s). dnsmasq writes its in-memory lease table back to the lease file when it
# stops: leases must therefore be edited while dnsmasq is NOT running.
qt_stop_dnsmasq() {
    service stop_dnsmasq >/dev/null 2>&1
    _w=0
    while pidof dnsmasq >/dev/null 2>&1 && [ "$_w" -lt 10 ]; do
        sleep 1
        _w=$((_w + 1))
    done
    if pidof dnsmasq >/dev/null 2>&1; then
        qt_log "WARNING: dnsmasq does not stop - leases may come back"
        return 1
    fi
    qt_dbg "dnsmasq stopped after ${_w}s"
    return 0
}

# ============================================================
# Free IP addresses (for the Trust dropdown)
# ============================================================
# Free = LAN addresses .2-.254 outside the dynamic pool and not used by any reservation, lease, ARP entry or the router
qt_free_ips() {
    _tag=$(qt_lan_tag /etc/dnsmasq.conf)
    [ -n "$_tag" ] || return 1
    _pool=$(awk -F, -v t="$_tag" -v p="${QT_LANPFX}." '
        /^dhcp-range=/ { x = $1; sub(/^dhcp-range=/, "", x); sub(/^tag:/, "", x)
            if (x == t && index($2, p) == 1) { s = $2; e = $3; sub(/.*\./, "", s); sub(/.*\./, "", e); print s, e; exit } }' /etc/dnsmasq.conf)
    _ps=${_pool%% *}; _pe=${_pool##* }
    case "$_ps" in ''|*[!0-9]*) _ps=1; _pe=0 ;; esac
    case "$_pe" in ''|*[!0-9]*) _pe=0 ;; esac
    {
        echo "$QT_LANIP"
        [ -r "$QT_STATIC" ] && awk -F, '{print $4}' "$QT_STATIC"
        nvram get dhcp_staticlist | tr '<' '\n' | awk -F'>' '{print $2}'
        grep '^dhcp-host=' /etc/dnsmasq.conf 2>/dev/null | tr ',=' '\n\n'
        awk '{print $3}' "$(qt_leases)" 2>/dev/null
        ip -4 neigh show 2>/dev/null | awk '{print $1}'
    } | grep -E "^${QT_LANPFX}\.[0-9]+$" | sort -u > "/tmp/qt-used.$$"
    _i=2
    while [ "$_i" -le 254 ]; do
        if [ "$_i" -lt "$_ps" ] || [ "$_i" -gt "$_pe" ]; then
            grep -qx "${QT_LANPFX}.${_i}" "/tmp/qt-used.$$" || echo "${QT_LANPFX}.${_i}"
        fi
        _i=$((_i + 1))
    done
    rm -f "/tmp/qt-used.$$"
}

# ============================================================
# Trust: make a quarantine device a known device (permanent DHCP reservation)
# ============================================================
# qt_trust <mac lower case> <ip> <name>. Writes to YazDHCP (when in use) or the native ASUS list.
# Backups go to $QT_DIR/backups. Returns 1 with a message (qt_msg_set) on a problem.
qt_trust() {
    _m=$1; _ip=$2; _n=$(qt_host_name "$3")
    qt_is_mac "$_m" || { qt_msg_set "Trust failed: invalid MAC address"; return 1; }
    qt_is_ipv4 "$_ip" || { qt_msg_set "Trust failed: invalid IP address"; return 1; }
    qt_is_blocked "$_m" && { qt_msg_set "Trust failed: $_m is blocked - unblock it first"; return 1; }
    case "$_ip" in "${QT_LANPFX}".*) ;; *) qt_msg_set "Trust failed: $_ip is not in the LAN ${QT_LANPFX}.0/24"; return 1 ;; esac
    qt_free_ips | grep -qx "$_ip" || { qt_msg_set "Trust failed: $_ip is in use, reserved or inside the dynamic DHCP pool"; return 1; }
    _M=$(printf '%s' "$_m" | tr 'a-f' 'A-F')
    qt_known_macs | grep -qx "$_M" && { qt_msg_set "Trust failed: $_M is already a known device"; return 1; }
    [ -n "$_n" ] || _n="Trusted-$(printf '%s' "$_m" | tr -d ':' | cut -c9-12)"
    _ts=$(date +%Y%m%d%H%M%S)
    mkdir -p "$QT_DIR/backups"; chmod 700 "$QT_DIR/backups"
    _tag=$(qt_lan_tag /etc/dnsmasq.conf)
    case "$(qt_known_src)" in
        yazdhcp)
            _conf="$QT_YAZ_DIR/DHCP_clients"
            [ -w "$_conf" ] || { qt_msg_set "Trust failed: $_conf is not writable"; return 1; }
            cp -p "$_conf" "$QT_DIR/backups/DHCP_clients.$_ts" || { qt_msg_set "Trust failed: backup of DHCP_clients failed"; return 1; }
            cp -p "$QT_STATIC" "$QT_DIR/backups/staticlist.$_ts" 2>/dev/null
            cp -p "$QT_YAZ_DIR/.hostnames" "$QT_DIR/backups/hostnames.$_ts" 2>/dev/null
            [ -n "$(tail -c 1 "$_conf")" ] && printf '\n' >> "$_conf"
            printf '%s,%s,%s,\n' "$_M" "$_ip" "$_n" >> "$_conf"
            [ -n "$(tail -c 1 "$QT_STATIC")" ] && printf '\n' >> "$QT_STATIC"
            printf 'set:%s,%s,set:%s,%s,%s\n' "$_tag" "$_M" "$_M" "$_ip" "$_n" >> "$QT_STATIC"
            if [ -f "$QT_YAZ_DIR/.hostnames" ]; then
                [ -n "$(tail -c 1 "$QT_YAZ_DIR/.hostnames")" ] && printf '\n' >> "$QT_YAZ_DIR/.hostnames"
                printf '%s %s  #%s#\n' "$_ip" "$_n" "$_M" >> "$QT_YAZ_DIR/.hostnames"
            fi
            qt_log "trust: $_M -> $_ip ($_n) added to YazDHCP (backup $_ts)"
            ;;
        native|none)
            nvram get dhcp_staticlist > "$QT_DIR/backups/dhcp_staticlist.$_ts"
            _cur=$(nvram get dhcp_staticlist)
            nvram set dhcp_staticlist="${_cur}<${_M}>${_ip}>>${_n}"
            nvram commit
            qt_log "trust: $_M -> $_ip ($_n) added to the native DHCP reservation list (backup $_ts)"
            ;;
    esac
    return 0
}

# ============================================================
# Diagnostics: lines "name|OK/WARN/FAIL|detail"
# ============================================================
qt_diag() {
    if qt_load_net; then
        echo "LAN|OK|${QT_LANIP} on ${QT_BR}, netmask ${QT_LANMASK}"
        [ "$QT_LANMASK" = "255.255.255.0" ] || echo "LAN netmask|FAIL|only a /24 LAN is supported"
        echo "Quarantine subnet|OK|${QT_NET}, gateway ${QT_GWIP}"
    else
        echo "LAN|FAIL|cannot determine LAN network or a free quarantine subnet"
    fi
    _t=$(qt_lan_tag /etc/dnsmasq.conf)
    if [ -n "$_t" ]; then echo "DHCP tag|OK|LAN range tag is '${_t}'"; else echo "DHCP tag|FAIL|no LAN dhcp-range found for ${QT_LANPFX}.x"; fi
    _k=$(qt_known_macs | grep -c .)
    if [ "$_k" -gt 0 ]; then echo "Known devices|OK|source $(qt_known_src), ${_k} device(s)"; else echo "Known devices|FAIL|no YazDHCP or native DHCP reservations - quarantine cannot be enabled"; fi
    if [ "$(qt_status)" = "1" ]; then
        grep -q "^dhcp-range=tag:!${_t}," /etc/dnsmasq.conf 2>/dev/null && echo "dnsmasq range|OK|quarantine DHCP range active" || echo "dnsmasq range|FAIL|quarantine DHCP range missing in dnsmasq.conf"
        ip addr show "$QT_BR" 2>/dev/null | grep -q "${QT_GWIP}/24" && echo "Gateway address|OK|${QT_GWIP}/24 on ${QT_BR}" || echo "Gateway address|FAIL|${QT_GWIP}/24 missing on ${QT_BR}"
        iptables -S FORWARD 2>/dev/null | grep -q -- '-j QT_FWD' && echo "Firewall FORWARD|OK|chain QT_FWD active" || echo "Firewall FORWARD|FAIL|chain QT_FWD missing"
        iptables -S INPUT 2>/dev/null | grep -q -- '-j QT_IN' && echo "Firewall INPUT|OK|chain QT_IN active" || echo "Firewall INPUT|FAIL|chain QT_IN missing"
        echo "Allowed ports|OK|mode $(qt_access_mode): $(qt_access_text)"
    else
        echo "Quarantine|OK|off - normal network"
    fi
    _nb=$(qt_blocked_macs | grep -c .)
    if [ "$_nb" -gt 0 ]; then
        iptables -S QT_BLK >/dev/null 2>&1 && echo "Blocked devices|OK|${_nb} device(s), chain QT_BLK active" || echo "Blocked devices|FAIL|${_nb} device(s) listed but chain QT_BLK missing"
    else
        echo "Blocked devices|OK|none"
    fi
    if [ -f "$QT_DIR/notify_enabled" ]; then
        if qt_mail_decrypt >/dev/null; then echo "Mail|OK|notifications on, amtm mail password readable"; else echo "Mail|WARN|notifications on but the amtm mail setup cannot be read (configure mail in amtm first)"; fi
    else
        echo "Mail|OK|notifications off"
    fi
    _w=$(qt_find wl) && echo "wl|OK|$_w" || echo "wl|WARN|wl not found - devices cannot be kicked from wifi"
    echo "Version|OK|${QT_VERSION}"
}

# ---- mail: read the amtm mail password (no credentials of our own) ----
# amtm stores the SMTP password encrypted in <amtm>/mail/emailpw.enc. The decrypt command (with its passphrase)
# is part of amtm itself (email.mod), so it is read from the installed amtm at run time and handed to openssl
# via stdin. Nothing is stored or created by this add-on. Prints the password; returns 1 when that is not possible.
QT_AMTM_DIR="/jffs/addons/amtm"
qt_mail_decrypt() {
    [ -r "$QT_AMTM_DIR/mail/emailpw.enc" ] && [ -r "$QT_AMTM_DIR/email.mod" ] && [ -r "$QT_AMTM_DIR/mail/email.conf" ] || return 1
    _mp=$(grep -F -- '-pass pass:' "$QT_AMTM_DIR/email.mod" | grep -F -- ' -d -in' | sed -n 's/.*-pass pass:\([^ ")]*\).*/\1/p' | head -n 1)
    [ -n "$_mp" ] || return 1
    _mo=$( . "$QT_AMTM_DIR/mail/email.conf" >/dev/null 2>&1; printf '%s' "$emailPwEnc" )
    case "$_mo" in *[!-A-Za-z0-9\ ]*) return 1 ;; esac
    # shellcheck disable=SC2086
    _mw=$(printf '%s' "$_mp" | /usr/sbin/openssl aes-256-cbc $_mo -d -in "$QT_AMTM_DIR/mail/emailpw.enc" -pass stdin 2>/dev/null) || { _mp=""; return 1; }
    _mp=""
    [ -n "$_mw" ] || return 1
    printf '%s' "$_mw"
    _mw=""
}

# Momentary state snapshot (debug only)
qt_dbg_state() {
    [ "$(qt_get qt_debug 1)" = "1" ] || return 0
    _lf=$(qt_leases)
    qt_dbg "STATE[$1] status=$(qt_status) net=${QT_NET} dnsmasq_pids=$(pidof dnsmasq | tr ' ' ',') bridge_has_gw=$(ip addr show "$QT_BR" 2>/dev/null | grep -c "${QT_GWIP}/24") leases_total=$(wc -l < "$_lf" 2>/dev/null) leases_q=$(awk -v p="${QT_QPFX}." 'index($3,p)==1' "$_lf" 2>/dev/null | grep -c .)"
    awk -v p="${QT_QPFX}." 'index($3,p)==1' "$_lf" 2>/dev/null | while read -r _e _m _i _n _r; do
        qt_dbg "STATE[$1] quarantine lease mac=$_m ip=$_i name=$(qt_clean_name "$_n")"
    done
    grep -E '^dhcp-range=|^dhcp-option=tag:!' /etc/dnsmasq.conf 2>/dev/null | while read -r _l; do
        qt_dbg "STATE[$1] dnsmasq.conf: $_l"
    done
}

# Diagnostics after a kick (debug only): wait 20 s and log per MAC the lease, whether the device is back on wifi
# and all hostapd/wlceventd/DHCP lines from the system log.
qt_dbg_dhcp() {
    [ "$(qt_get qt_debug 1)" = "1" ] || return 0
    [ -n "$1" ] || return 0
    sleep 20
    _wl=$(qt_find wl)
    _nv=$(qt_find nvram)
    for _m in $1; do
        _lm=$(printf '%s' "$_m" | tr 'A-F' 'a-f')
        qt_dbg "AFTER-KICK $_m lease: $(grep -iF "$_lm" "$(qt_leases)" 2>/dev/null | tr '\n' ' ')"
        if [ -n "$_wl" ] && [ -n "$_nv" ]; then
            for _i in 0 1 2; do
                _if=$("$_nv" get "wl${_i}_ifname")
                [ -n "$_if" ] || continue
                "$_wl" -i "$_if" assoclist 2>/dev/null | grep -qiF "$_m" && qt_dbg "AFTER-KICK $_m is connected again on $_if"
            done
        fi
        grep -iF "$_lm" /tmp/syslog.log 2>/dev/null | grep -iE "dnsmasq-dhcp|hostapd|wlceventd" | tail -10 | while read -r _x; do
            qt_dbg "SYSLOG $_x"
        done
    done
}

# Load the network variables for every script that sources this file
qt_load_net
QT_PAYLOAD_LIB
cat > "$SET/fw.sh" << 'QT_PAYLOAD_FW'
#!/bin/sh
# Quarantine firewall - called from firewall-start and install.sh
umask 077
[ -r /jffs/addons/quarantine.d/lib.sh ] || { logger -t quarantine "ERROR: lib.sh missing"; exit 1; }
# shellcheck disable=SC1091
. /jffs/addons/quarantine.d/lib.sh
case "$1" in
    apply)
        qt_fw_apply
        qt_log "firewall: rules applied"
        ;;
    *)
        echo "usage: fw.sh apply"
        exit 1
        ;;
esac
QT_PAYLOAD_FW
cat > "$SET/postconf.sh" << 'QT_PAYLOAD_POSTCONF'
#!/bin/sh
# Quarantine dnsmasq adjustment - called from /jffs/scripts/dnsmasq.postconf with $1 = /etc/dnsmasq.conf
CONF="$1"
[ -f "$CONF" ] || exit 0
[ -r /jffs/addons/quarantine.d/lib.sh ] || { logger -t quarantine "ERROR: lib.sh missing, dnsmasq left unchanged"; exit 0; }
# shellcheck disable=SC1091
. /jffs/addons/quarantine.d/lib.sh
QT_CTX="postconf"
qt_dbg "postconf started for $CONF status=$(qt_status) net=${QT_NET}"

if [ "$(qt_status)" != "1" ]; then
    qt_log "postconf: quarantine off - normal network"
    exit 0
fi
if ! qt_net_check; then
    qt_log "postconf: NOT applying quarantine - $QT_NET_ERR"
    exit 0
fi
TAG=$(qt_lan_tag "$CONF")
[ -n "$TAG" ] || { qt_log "postconf: LAN DHCP tag not found - dnsmasq left unchanged"; exit 0; }

ip addr add "${QT_GWIP}/24" dev "$QT_BR" 2>/dev/null || true
echo "$QT_QPFX" > "$QT_APPLIED"

DNS=$(qt_get qt_dns 9.9.9.9)
if ! qt_is_ipv4 "$DNS"; then
    qt_log "postconf: invalid DNS in settings, falling back to 9.9.9.9"
    DNS=9.9.9.9
fi

# LAN range from interface/label match to tag match: only known devices get the LAN
LANPFX_RE=$(echo "$QT_LANPFX" | sed 's/\./\\./g')
sed -i "s/^dhcp-range=${TAG},\(${LANPFX_RE}\.\)/dhcp-range=tag:${TAG},\1/" "$CONF"
grep -q "^dhcp-range=tag:${TAG}," "$CONF" || qt_log "WARNING: LAN dhcp-range not converted to tag:${TAG}"

# Native ASUS reservations carry no tag: add one per known MAC (YazDHCP lines already have set:<tag>)
if [ "$(qt_known_src)" = "native" ]; then
    for m in $(qt_native_macs); do
        printf 'dhcp-mac=set:%s,%s\n' "$TAG" "$m" >> "$CONF"
    done
fi

printf 'dhcp-range=tag:!%s,%s.100,%s.200,255.255.255.0,1h\ndhcp-option=tag:!%s,option:router,%s\ndhcp-option=tag:!%s,option:dns-server,%s\n' \
    "$TAG" "$QT_QPFX" "$QT_QPFX" "$TAG" "$QT_GWIP" "$TAG" "$DNS" >> "$CONF"
qt_dbg "postconf: after change $(grep -c "^dhcp-range=tag:${TAG}," "$CONF") tag:${TAG}, $(grep -c "tag:!${TAG}" "$CONF") tag:!${TAG} lines"
qt_log "postconf: quarantine active (net=${QT_NET} dns=$DNS tag=$TAG)"
QT_PAYLOAD_POSTCONF
cat > "$SET/webui.sh" << 'QT_PAYLOAD_WEBUI'
#!/bin/sh
# Quarantine WebUI - called from post-mount and install.sh
umask 022
ASP="/jffs/addons/quarantine.d/quarantine.asp"
[ -r "$ASP" ] || { logger -t quarantine "ERROR: quarantine.asp missing"; exit 1; }
# shellcheck disable=SC1091
. /usr/sbin/helper.sh
am_get_webui_page "$ASP"
if [ -z "$am_webui_page" ] || [ "$am_webui_page" = "none" ]; then
    logger -t quarantine "ERROR: no free WebUI user slot"
    exit 1
fi
mkdir -p /www/ext/quarantine
cp "$ASP" "/www/user/$am_webui_page"
[ -f /tmp/menuTree.js ] || cp /www/require/modules/menuTree.js /tmp/
sed -i '/tabName: "Quarantaine"/d;/tabName: "Quarantine"/d' /tmp/menuTree.js
sed -i "s|{url: \"DNSDirector.asp\", tabName: \"DNS Director\"},|{url: \"DNSDirector.asp\", tabName: \"DNS Director\"},\n{url: \"$am_webui_page\", tabName: \"Quarantine\"},|" /tmp/menuTree.js
umount /www/require/modules/menuTree.js 2>/dev/null
mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js
logger -t quarantine "webui: restored as $am_webui_page"
QT_PAYLOAD_WEBUI
cat > "$SET/generate-data.sh" << 'QT_PAYLOAD_GEN'
#!/bin/sh
# Quarantine data generator - writes /www/ext/quarantine/data.htm and sends mail notifications
# Runs via cron (*/2) and after every GUI action
umask 077
QD="/jffs/addons/quarantine.d"
[ -r "$QD/lib.sh" ] || exit 1
# shellcheck disable=SC1091
. "$QD/lib.sh"
QT_CTX="generate"
VERBOSE="$1"

# ---- lock: prevent concurrent runs (cron + service handler) ----
LOCK="/tmp/qt-generate.lock"
CURL_CFG="/tmp/qt-curl.cfg"
BODY_FILE="/tmp/qt-mail-body"
OUT_DIR="/www/ext/quarantine"
OUT="$OUT_DIR/data.htm"
TMP_OUT="$OUT_DIR/.data.htm.tmp"

cleanup() { rm -rf "$LOCK" "$CURL_CFG" "$BODY_FILE" "$TMP_OUT"; }

tries=0
until mkdir "$LOCK" 2>/dev/null; do
    OLD=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$OLD" ] && ! kill -0 "$OLD" 2>/dev/null; then
        rm -rf "$LOCK"
        continue
    fi
    tries=$((tries + 1))
    if [ "$tries" -ge 10 ]; then
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || exit 0
        break
    fi
    sleep 1
done
echo $$ > "$LOCK/pid"
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

LEASES=$(qt_leases)
mkdir -p "$OUT_DIR"

qt_ban_stale
QT_STATUS=$(qt_status)
QT_DNS=$(qt_get qt_dns 9.9.9.9)
qt_is_ipv4 "$QT_DNS" || QT_DNS="9.9.9.9"
# Gateway: WAN only (VPN routing not implemented yet)
QT_GW="WAN"
QT_NOTIFY=0
[ -f "$QD/notify_enabled" ] && QT_NOTIFY=1
QT_MSG=""
# GUI message: only shown for QT_MSG_TTL seconds after the action that produced it, then removed
if [ -f "$QT_MSGFILE" ]; then
    _ml=$(head -n 1 "$QT_MSGFILE" | tr -d '\r')
    _mt=${_ml%%|*}
    case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
    if [ $(( $(date +%s) - _mt )) -le "$QT_MSG_TTL" ]; then
        QT_MSG=$(printf '%s' "${_ml#*|}" | cut -c1-200)
    else
        rm -f "$QT_MSGFILE"
    fi
fi

{
    echo "qt_version=${QT_VERSION}"
    echo "qt_status=${QT_STATUS}"
    echo "qt_dns=${QT_DNS}"
    echo "qt_gateway=${QT_GW}"
    echo "qt_notify=${QT_NOTIFY}"
    echo "qt_busy=$(qt_busy_get)"
    echo "qt_msg=${QT_MSG}"
    echo "qt_lan=${QT_LANIP}|${QT_LANMASK}|${QT_LANPFX}.0/24"
    echo "qt_access=$(qt_access_mode)"
    echo "qt_ports=$(qt_get qt_ports "")"
    echo "qt_allowed=$(qt_access_text)"
    echo "qt_subnet=${QT_QPFX}"
    echo "qt_applied=$(qt_applied_prefix)"
    echo "qt_known=$(qt_known_src)|$(qt_known_macs 2>/dev/null | grep -c .)"
    for _i in 1 2 3 4 5; do
        echo "qt_vpn=${_i}|$(nvram get "vpn_client${_i}_state")|$(qt_clean_name "$(nvram get "vpn_client${_i}_desc")")"
    done
    if [ "$QT_STATUS" = "1" ]; then
        echo "qt_free=$(qt_free_ips 2>/dev/null | tr '\n' ',' | sed 's/,$//')"
    fi
    qt_diag | while IFS='|' read -r _n _s _d; do
        echo "qt_diag=${_n}|${_s}|$(printf '%s' "$_d" | tr -d '|')"
    done
    if [ -f "$LEASES" ]; then
        awk -v p="${QT_QPFX}." 'index($3, p) == 1' "$LEASES" 2>/dev/null | while read -r _exp mac ip name _rest; do
            qt_is_mac "$mac" || continue
            qt_is_blocked "$mac" && continue
            echo "qt_device=${mac}|${ip}|$(qt_clean_name "$name")"
        done
    fi
    # blocked devices come from the block list (not from leases): they stay visible while offline
    if [ -r "$QT_BLOCKFILE" ]; then
        while IFS='|' read -r _bm _bt _bn; do
            qt_is_mac "$_bm" || continue
            case "$_bt" in ''|*[!0-9]*) _bt=0 ;; esac
            _bip=$(awk -v m="$_bm" 'tolower($2) == m {print $3; exit}' "$LEASES" 2>/dev/null)
            echo "qt_blocked=${_bm}|${_bip:--}|${_bn:--}|${_bt}"
        done < "$QT_BLOCKFILE"
    fi
} > "$TMP_OUT"
chmod 644 "$TMP_OUT"
mv "$TMP_OUT" "$OUT"
# debug: only on change (cron runs every 2 min) or when called from the handler
_nd=$(grep -c '^qt_device=' "$OUT")
if [ "$VERBOSE" = "verbose" ] || [ "$(cat /tmp/qt-dbg-last 2>/dev/null)" != "${QT_STATUS}:${_nd}" ]; then
    qt_dbg "data.htm: status=${QT_STATUS} dns=${QT_DNS} devices=${_nd}"
    echo "${QT_STATUS}:${_nd}" > /tmp/qt-dbg-last
fi

# quick mode (called by the handler right after a status change): only update data.htm
[ "$VERBOSE" = "quick" ] && exit 0

# ---- Notification (max once per 6 hours per MAC) ----
# When off the normal network is active: no quarantine mails
if [ "$QT_STATUS" != "1" ]; then
    [ "$VERBOSE" = "verbose" ] && qt_dbg "notify: skipped, quarantine is off"
    exit 0
fi
[ -f "$QD/notify_enabled" ] || { [ "$VERBOSE" = "verbose" ] && qt_dbg "notify: disabled"; exit 0; }
NOTIFY_DB="$QD/notified.db"
touch "$NOTIFY_DB"
chmod 600 "$NOTIFY_DB"
EMAIL_DIR="/jffs/addons/amtm/mail"
[ -f "${EMAIL_DIR}/email.conf" ] || { qt_dbg "notify: ${EMAIL_DIR}/email.conf missing"; exit 0; }
# shellcheck disable=SC1091
. "${EMAIL_DIR}/email.conf"
qt_mail_decrypt >/dev/null || { qt_dbg "notify: amtm mail password not readable"; exit 0; }
NOW=$(date +%s)
SIX_HOURS=21600

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

send_mail() {
    _mac=$1; _ip=$2; _name=$3
    # Never put the password on the curl command line: temporary config file (600, via umask)
    # The password comes from the amtm mail setup (see qt_mail_decrypt in lib.sh)
    _pw=$(qt_mail_decrypt) || return 1
    [ -n "$_pw" ] || return 1
    rm -f "$CURL_CFG" "$BODY_FILE"
    printf 'user = "%s:%s"\n' "$(esc "$USERNAME")" "$(esc "$_pw")" > "$CURL_CFG"
    _pw=""
    {
        echo "Subject: [Quarantine] New device on ${FRIENDLY_ROUTER_NAME}"
        echo "From: \"Quarantine\" <${FROM_ADDRESS}>"
        echo "Date: $(date -R)"
        echo "To: \"${TO_NAME}\" <${TO_ADDRESS}>"
        echo ""
        echo "Unknown device detected in the quarantine subnet."
        echo ""
        echo "MAC:      ${_mac}"
        echo "IP:       ${_ip}"
        echo "Hostname: ${_name:-unknown}"
        echo "Time:     $(date)"
        echo ""
        echo "Router: ${FRIENDLY_ROUTER_NAME}"
    } > "$BODY_FILE"
    /usr/sbin/curl --silent --show-error -K "$CURL_CFG" \
        --url "${PROTOCOL}://${SMTP}:${PORT}/${SMTP}" \
        --mail-from "${FROM_ADDRESS}" \
        --mail-rcpt "${TO_ADDRESS}" \
        --upload-file "$BODY_FILE" \
        --ssl-reqd --crlf
    _rc=$?
    rm -f "$CURL_CFG" "$BODY_FILE"
    return $_rc
}

if [ -f "$LEASES" ]; then
    awk -v p="${QT_QPFX}." 'index($3, p) == 1' "$LEASES" 2>/dev/null | while read -r _exp mac ip name _rest; do
        qt_is_mac "$mac" || continue
        qt_is_blocked "$mac" && continue
        LAST=$(grep "^${mac}|" "$NOTIFY_DB" 2>/dev/null | cut -d'|' -f2)
        case "$LAST" in ''|*[!0-9]*) LAST=0 ;; esac
        if [ $((NOW - LAST)) -le "$SIX_HOURS" ]; then
            [ "$VERBOSE" = "verbose" ] && qt_dbg "notify: $mac skipped (cooldown, last mail $((NOW - LAST))s ago)"
            continue
        fi
        cname=$(qt_clean_name "$name")
        qt_dbg "notify: sending mail for $mac ip=$ip name=$cname (last mail: ${LAST})"
        if send_mail "$mac" "$ip" "$cname"; then
            sed -i "/^${mac}|/d" "$NOTIFY_DB"
            echo "${mac}|${NOW}" >> "$NOTIFY_DB"
            qt_log "Notification sent: mac=${mac} ip=${ip} name=${cname}"
        else
            qt_log "Notification FAILED: mac=${mac} ip=${ip} (retry on next run)"
        fi
    done
fi
QT_PAYLOAD_GEN
cat > "$SET/service-handler.sh" << 'QT_PAYLOAD_HANDLER'
#!/bin/sh
# Quarantine service handler - called from service-event ($1=type $2=event)
umask 077
EVENT=$2
QD="/jffs/addons/quarantine.d"
[ -r "$QD/lib.sh" ] || { logger -t quarantine "ERROR: lib.sh missing"; exit 1; }
# shellcheck disable=SC1091
. "$QD/lib.sh"
GEN="$QD/generate-data.sh"
QT_CTX="handler"
qt_cleanup() {
    if [ "$QT_BAN_OWNER" = 1 ]; then qt_ban_release; fi
    if [ "$QT_BUSY_OWNER" = 1 ]; then qt_busy_clear; fi
}
trap qt_cleanup EXIT
trap 'exit 1' INT TERM HUP
qt_dbg "=== EVENT=$EVENT version=$QT_VERSION shell=$0 PATH=$PATH net=$QT_NET"

# Turn quarantine on (also used after a subnet change). $1 = extra MACs (one per line) to kick
apply_on() {
    qt_net_check || { qt_msg_set "Cannot enable quarantine: $QT_NET_ERR"; am_settings_set qt_status "0"; return 1; }
    qt_known_macs >/dev/null || { qt_msg_set "Cannot enable quarantine: no known devices found (add DHCP reservations in YazDHCP or in LAN > DHCP Server first)"; am_settings_set qt_status "0"; return 1; }
    am_settings_set qt_status "1"
    "$GEN" quick
    qt_dbg_state "enable-before"
    qt_fw_apply
    # Unknown devices with a normal LAN address (from the Off period) are cleaned up and disconnected
    KICK=$(qt_unknown_lan_macs) || { qt_log "known-device list unreadable or empty - unknown devices NOT cleaned up"; KICK=""; }
    KICK=$(printf '%s\n%s\n' "$KICK" "$1" | grep . | sort -u)
    qt_stop_dnsmasq
    qt_drop_leases_for "$KICK"
    service restart_dnsmasq
    sleep 3
    qt_ban_kick "$KICK"
    return 0
}

case "$EVENT" in
    quarantinesave*)
        qt_busy_set; qt_msg_clear
        DNS=$(echo "$EVENT" | cut -d'_' -f2)
        GW=$(echo "$EVENT" | cut -d'_' -f3)
        PFX=$(echo "$EVENT" | cut -d'_' -f4)
        MODE=$(echo "$EVENT" | cut -d'_' -f5)
        PORTS=$(echo "$EVENT" | cut -d'_' -f6)
        OLDPFX="$QT_QPFX"
        # allowed ports (mode A/B/C + custom list); an invalid custom list leaves the setting unchanged
        if [ -n "$MODE" ]; then
            qt_ports_valid "$PORTS" && am_settings_set qt_ports "$PORTS"
            case "$MODE" in
                A|B|O) am_settings_set qt_access "$MODE" ;;
                C)
                    if qt_ports_valid "$PORTS"; then
                        am_settings_set qt_access "C"
                    else
                        qt_msg_set "Custom ports rejected (use for example: 443, 8883, 123/udp - max 20 ports) - access setting unchanged"
                    fi
                    ;;
                *) qt_msg_set "Unknown access mode '$(qt_clean_name "$MODE")' rejected - setting unchanged" ;;
            esac
            qt_log "Access mode now $(qt_access_mode): $(qt_access_text)"
        fi
        if qt_is_ipv4 "$DNS"; then
            am_settings_set qt_dns "$DNS"
        else
            qt_msg_set "Invalid DNS server '$(qt_clean_name "$DNS")' rejected - setting unchanged"
        fi
        # VPN routing is not implemented yet: only WAN is accepted
        [ -z "$GW" ] && GW="WAN"
        [ "$GW" != "WAN" ] && qt_log "gateway '$(qt_clean_name "$GW")' not supported yet (no VPN routing) - stays WAN"
        am_settings_set qt_gateway "WAN"
        CHANGED=0
        if [ -n "$PFX" ] && [ "$PFX" != "$OLDPFX" ]; then
            if qt_valid_prefix "$PFX"; then
                am_settings_set qt_subnet "$PFX"; CHANGED=1
            else
                qt_msg_set "Quarantine subnet '$PFX' rejected: $QT_PFX_ERR - setting unchanged"
            fi
        fi
        if [ "$CHANGED" = 1 ] && [ "$(qt_status)" = "1" ]; then
            # subnet change while on: kick everything in the old subnet, remove the old gateway, build the new one
            OLDKICK=$(qt_lease_macs_q "$OLDPFX")
            qt_stop_dnsmasq
            qt_clear_leases "$OLDPFX"
            qt_gw_addr_del "$OLDPFX"
            qt_load_net
            apply_on "$OLDKICK"
            qt_log "Settings saved: dns=$(qt_get qt_dns 9.9.9.9) subnet $OLDPFX -> $QT_QPFX"
        else
            service restart_dnsmasq
            qt_load_net
            qt_fw_apply
            qt_log "Settings saved: dns=$(qt_get qt_dns 9.9.9.9) gw=WAN subnet=$QT_QPFX"
        fi
        qt_busy_clear
        "$GEN" verbose
        ;;
    quarantineenable)
        qt_busy_set; qt_msg_clear
        if apply_on ""; then
            qt_busy_clear
            "$GEN" verbose
            qt_dbg_state "enable-after"
            qt_log "Enabled (net=$QT_NET)"
            qt_dbg_dhcp "$KICK"
        else
            qt_busy_clear
            "$GEN" verbose
        fi
        ;;
    quarantinedisable)
        # Off = normal network: quarantine DHCP gone, quarantine leases and bookkeeping wiped (clean slate)
        # so devices get a normal LAN address on their next request.
        qt_busy_set; qt_msg_clear
        am_settings_set qt_status "0"
        "$GEN" quick
        qt_dbg_state "disable-before"
        KICK=$(qt_lease_macs_q)
        qt_stop_dnsmasq
        qt_clear_leases
        rm -f "$QD/known_quarantine.db" "$QD/notified.db"
        service restart_dnsmasq
        # the quarantine subnet no longer exists: remove the gateway address BEFORE disconnecting, so a device
        # that comes straight back cannot reach its gateway and does DHCP again
        qt_gw_addr_del
        qt_fw_apply
        sleep 3
        qt_kick_macs "$KICK"
        qt_busy_clear
        "$GEN" verbose
        qt_dbg_state "disable-after"
        qt_log "Disabled"
        qt_dbg_dhcp "$KICK"
        ;;
    quarantinetrust*)
        # quarantinetrust_<MAC with dashes>_<IP>_<NAME>
        qt_busy_set; qt_msg_clear
        TM=$(echo "$EVENT" | cut -d'_' -f2 | tr '-' ':' | tr 'A-F' 'a-f')
        TI=$(echo "$EVENT" | cut -d'_' -f3)
        TN=$(echo "$EVENT" | cut -d'_' -f4)
        if [ "$(qt_status)" != "1" ]; then
            qt_msg_set "Trust ignored: quarantine is off"
        elif qt_trust "$TM" "$TI" "$TN"; then
            TMU=$(printf '%s' "$TM" | tr 'a-f' 'A-F')
            qt_stop_dnsmasq
            qt_drop_leases_for "$TMU"
            [ -f "$QD/notified.db" ] && sed -i "/^${TM}|/d" "$QD/notified.db"
            service restart_dnsmasq
            sleep 3
            qt_ban_kick "$TMU"
            qt_msg_set "Device $TMU is now trusted with fixed address $TI"
        fi
        qt_busy_clear
        "$GEN" verbose
        ;;
    quarantineblock*)
        # quarantineblock_<MAC with dashes>
        qt_busy_set; qt_msg_clear
        BM=$(echo "$EVENT" | cut -d'_' -f2 | tr '-' ':' | tr 'A-F' 'a-f')
        if ! qt_is_mac "$BM"; then
            qt_msg_set "Block failed: invalid MAC address"
        elif qt_is_blocked "$BM"; then
            qt_msg_set "Device $BM is already blocked"
        else
            BN=$(awk -v m="$BM" 'tolower($2) == m {print $4; exit}' "$(qt_leases)" 2>/dev/null)
            if qt_block_add "$BM" "$BN"; then
                qt_fw_apply
                qt_log "Blocked $BM (name=$(qt_clean_name "$BN"))"
                qt_msg_set "Device $BM is blocked: no network access (DHCP only)"
            else
                qt_msg_set "Block failed: could not write the block list"
            fi
        fi
        qt_busy_clear
        "$GEN" verbose
        ;;
    quarantineunblock*)
        # quarantineunblock_<MAC with dashes>
        qt_busy_set; qt_msg_clear
        BM=$(echo "$EVENT" | cut -d'_' -f2 | tr '-' ':' | tr 'A-F' 'a-f')
        if ! qt_is_mac "$BM"; then
            qt_msg_set "Unblock failed: invalid MAC address"
        elif ! qt_is_blocked "$BM"; then
            qt_msg_set "Device $BM was not blocked"
        else
            qt_block_del "$BM"
            qt_fw_apply
            qt_log "Unblocked $BM"
            qt_msg_set "Device $BM is unblocked"
        fi
        qt_busy_clear
        "$GEN" verbose
        ;;
    quarantinenotifyon)
        touch "$QD/notify_enabled"
        "$GEN"
        qt_log "Notifications enabled"
        ;;
    quarantinenotifyoff)
        rm -f "$QD/notify_enabled"
        "$GEN"
        qt_log "Notifications disabled"
        ;;
    quarantineclear)
        qt_busy_set; qt_msg_clear
        qt_dbg_state "clear-before"
        KICK=$(qt_lease_macs_q)
        qt_stop_dnsmasq
        qt_clear_leases
        rm -f "$QD/known_quarantine.db" "$QD/notified.db"
        "$GEN" quick
        service restart_dnsmasq
        sleep 3
        qt_kick_macs "$KICK"
        sleep 2
        qt_busy_clear
        "$GEN" verbose
        qt_dbg_state "clear-after"
        qt_log "Quarantine cleared"
        qt_dbg_dhcp "$KICK"
        ;;
esac
QT_PAYLOAD_HANDLER
cat > "$SET/selftest.sh" << 'QT_PAYLOAD_SELFTEST'
#!/bin/sh
# Quarantine self-test - generic (no fixed subnets). Exit code = number of failures.
# Usage: sh /jffs/addons/quarantine.d/selftest.sh
QD="/jffs/addons/quarantine.d"
SC="/jffs/scripts"
# shellcheck disable=SC1091
. /usr/sbin/helper.sh
# shellcheck disable=SC1091
. "$QD/lib.sh"
QT_CTX="selftest"
FAILS=0
fail() { echo "[quarantine] FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "[quarantine] ok: $*"; }
cnt() { grep -c -E "$2" "$1" 2>/dev/null; }

QSTAT=$(am_settings_get qt_status)
qt_load_net || fail "cannot determine LAN network / quarantine subnet"
[ "$QT_LANMASK" = "255.255.255.0" ] || fail "LAN netmask is $QT_LANMASK (only /24 supported)"
TAG=$(qt_lan_tag /etc/dnsmasq.conf)
[ -n "$TAG" ] || fail "no LAN dhcp-range found for ${QT_LANPFX}.x in dnsmasq.conf"

for f in lib.sh fw.sh postconf.sh webui.sh generate-data.sh service-handler.sh selftest.sh cli.sh install.sh; do
    [ -x "$QD/$f" ] || fail "$QD/$f not executable"
done
find "$QD" "$SC/dnsmasq.postconf" -perm -0002 2>/dev/null | grep -q . && fail "world-writable files in $QD"
if [ "$(am_settings_get qt_debug)" = "1" ]; then
    qt_dbg "selftest: write test"
    if [ -f "$QT_DBGDIR/quarantine-debug.log" ]; then
        find "$QT_DBGDIR" -perm -0004 2>/dev/null | grep -q . && fail "debug log or directory is world-readable"
    elif [ ! -f /tmp/quarantine-debug.log ]; then
        fail "debug log not created"
    fi
fi

[ "$(cnt "$SC/dnsmasq.postconf" '# Quarantine$')" = "1" ]  || fail "dnsmasq.postconf hook is not exactly 1x"
[ "$(cnt "$SC/firewall-start" '# Quarantine$')" = "1" ]    || fail "firewall-start hook is not exactly 1x"
[ "$(cnt "$SC/post-mount" '# Quarantine$')" = "1" ]        || fail "post-mount hook is not exactly 1x"
[ "$(cnt "$SC/service-event" '# Quarantine$')" = "1" ]     || fail "service-event hook is not exactly 1x"
[ "$(cnt "$SC/services-start" 'quarantine_data')" = "1" ]  || fail "services-start cron is not exactly 1x"

if [ "$QSTAT" = "0" ]; then
    # Off: remove a leftover gateway address, then verify the normal network
    qt_gw_addr_del
    [ -n "$QT_GWIP" ] && ip addr show "$QT_BR" 2>/dev/null | grep -q "${QT_GWIP}/24" && fail "status off but ${QT_GWIP}/24 is still on $QT_BR"
    grep -q "^dhcp-range=${TAG}," /etc/dnsmasq.conf || fail "status off but the LAN dhcp-range is not the default (${TAG},...)"
    grep -q 'tag:!' /etc/dnsmasq.conf && fail "status off but a quarantine range is still in dnsmasq.conf"
    iptables -S FORWARD 2>/dev/null | grep -q -- '-j QT_FWD' && fail "status off but QT_FWD is still active"
    iptables -S INPUT 2>/dev/null | grep -q -- '-j QT_IN' && fail "status off but QT_IN is still active"
else
    n=$(iptables -S FORWARD 2>/dev/null | grep -c -- "-s ${QT_NET} -j QT_FWD")
    [ "$n" = "1" ] || fail "FORWARD jump to QT_FWD: $n rule(s), expected 1"
    n=$(iptables -S INPUT 2>/dev/null | grep -c -- "-s ${QT_NET} -j QT_IN")
    [ "$n" = "1" ] || fail "INPUT jump to QT_IN: $n rule(s), expected 1"
    for r in $QT_RFC1918; do
        iptables -S QT_FWD 2>/dev/null | grep -q -- "-d $r -j DROP" || fail "QT_FWD does not block $r"
    done
    iptables -S QT_IN 2>/dev/null | grep -q -- "-j DROP" || fail "QT_IN has no default drop"
    if [ "$(qt_access_mode)" = "O" ]; then
        iptables -S QT_FWD 2>/dev/null | grep -q -- "--dport" && fail "open mode but QT_FWD still has port rules"
        [ "$(iptables -S QT_FWD 2>/dev/null | tail -n 1)" = "-A QT_FWD -j DROP" ] && fail "open mode but QT_FWD still ends with a default drop"
    else
        qt_access_list | while read -r pr po; do
            iptables -S QT_FWD 2>/dev/null | grep -Eq -- "-p $pr .*--dport $po -j RETURN" || echo "MISSING $pr $po"
        done | grep -q . && fail "QT_FWD misses an allowed port of mode $(qt_access_mode)"
        [ "$(iptables -S QT_FWD 2>/dev/null | tail -n 1)" = "-A QT_FWD -j DROP" ] || fail "QT_FWD does not end with a default drop"
    fi
    grep -q "^dhcp-range=tag:${TAG}," /etc/dnsmasq.conf || fail "LAN dhcp-range not converted to tag:${TAG}"
    grep -q "^dhcp-range=tag:!${TAG},${QT_QPFX}.100,${QT_QPFX}.200,255.255.255.0,1h" /etc/dnsmasq.conf || fail "quarantine dhcp-range missing"
    grep -q "^dhcp-option=tag:!${TAG},option:router,${QT_GWIP}\$" /etc/dnsmasq.conf || fail "quarantine router option missing"
    grep -q "^dhcp-option=tag:!${TAG},option:dns-server," /etc/dnsmasq.conf || fail "quarantine dns option missing"
    ip addr show "$QT_BR" 2>/dev/null | grep -q "${QT_GWIP}/24" || fail "${QT_GWIP}/24 missing on $QT_BR"
    qt_known_macs >/dev/null || fail "no known devices (YazDHCP / DHCP reservations) while quarantine is on"
fi
# blocked devices (apply in both states)
NB=$(qt_blocked_macs | grep -c .)
if [ "$NB" -gt 0 ]; then
    [ "$(iptables -S FORWARD 2>/dev/null | grep -c -- '-j QT_BLK')" = "1" ] || fail "FORWARD jump to QT_BLK missing or duplicated"
    [ "$(iptables -S INPUT 2>/dev/null | grep -c -- '-j QT_BLK')" = "1" ] || fail "INPUT jump to QT_BLK missing or duplicated"
    for m in $(qt_blocked_macs); do
        iptables -S QT_BLK 2>/dev/null | grep -qi -- "--mac-source $m -j DROP" || fail "QT_BLK does not drop $m"
    done
else
    iptables -S FORWARD 2>/dev/null | grep -q -- '-j QT_BLK' && fail "no blocked devices but QT_BLK is still active"
fi
if [ "$(qt_known_src)" = "yazdhcp" ]; then
    grep -q 'dhcp-hostsfile=/jffs/addons/YazDHCP.d/.staticlist' /etc/dnsmasq.conf || fail "YazDHCP hostsfile line missing in dnsmasq.conf"
fi
grep -q '^qt_status=' /www/ext/quarantine/data.htm 2>/dev/null || fail "data.htm not generated"
grep -q '"Quarantine"' /tmp/menuTree.js 2>/dev/null || fail "Quarantine menu item missing"

if [ "$FAILS" -eq 0 ]; then
    echo "[quarantine] SELFTEST PASSED (qt_status=$QSTAT net=$QT_NET)"
    logger -t quarantine "selftest: passed (qt_status=$QSTAT)"
else
    echo "[quarantine] SELFTEST FAILED: $FAILS problem(s)"
    logger -t quarantine "selftest: FAILED ($FAILS problems)"
fi
exit "$FAILS"
QT_PAYLOAD_SELFTEST
cat > "$SET/cli.sh" << 'QT_PAYLOAD_CLI'
#!/bin/sh
# Quarantine command line: sh /jffs/addons/quarantine.d/cli.sh status | selftest | diag | uninstall
QD="/jffs/addons/quarantine.d"
SC="/jffs/scripts"
[ -w "$SC" ] || { echo "ERROR: no write permission on $SC (run as the router admin user)"; exit 1; }
# shellcheck disable=SC1091
. /usr/sbin/helper.sh
# shellcheck disable=SC1091
. "$QD/lib.sh"
QT_CTX="cli"
case "$1" in
    status)
        echo "Quarantine $QT_VERSION - status: $([ "$(qt_status)" = "1" ] && echo ON || echo OFF)"
        echo "LAN:               ${QT_LANIP} (${QT_LANPFX}.0/24) on ${QT_BR}"
        echo "Quarantine subnet: ${QT_NET} (gateway ${QT_GWIP})"
        echo "Known devices:     $(qt_known_src), $(qt_known_macs | grep -c .) device(s)"
        echo "Quarantine devices:"
        _lf=$(qt_leases)
        awk -v p="${QT_QPFX}." 'index($3, p) == 1 {print "  " $2 "  " $3 "  " $4}' "$_lf" 2>/dev/null
        ;;
    selftest)
        sh "$QD/selftest.sh"
        ;;
    diag)
        qt_diag | while IFS='|' read -r _n _s _d; do printf '%-18s %-5s %s\n' "$_n" "$_s" "$_d"; done
        ;;
    uninstall)
        echo "This removes Quarantine completely and returns the router to its normal network:"
        echo "  - hooks, cron job, menu tab, GUI page, firewall chains, quarantine gateway address"
        echo "  - all Quarantine settings, the block list (blocked devices become unblocked), logs and install backups"
        echo "Not removed: DHCP reservations (they are normal reservations) and your own copy of the setup script."
        printf 'Type YES to continue: '
        read -r _a
        [ "$_a" = "YES" ] || { echo "Aborted."; exit 1; }
        # safety copy in RAM only (/tmp): gone after a reboot, no trace on flash or USB
        _bk="/tmp/quarantine-uninstall-backup-$(date +%Y%m%d%H%M%S)"
        mkdir -p "$_bk" && chmod 700 "$_bk" || exit 1
        for f in dnsmasq.postconf firewall-start init-start services-start service-event post-mount; do
            [ -f "$SC/$f" ] && cp -p "$SC/$f" "$_bk/$f"
        done
        cp -p /jffs/addons/custom_settings.txt "$_bk/" 2>/dev/null
        cp -p "$QD/blocked.list" "$_bk/" 2>/dev/null
        # normal network again: all chains (incl. the block chain), gateway address
        qt_fw_clear
        qt_gw_addr_del
        # hooks: remove only our own lines; a hook file that only has a shebang left is removed
        for f in dnsmasq.postconf firewall-start init-start services-start service-event post-mount; do
            [ -f "$SC/$f" ] || continue
            grep -v -E '# Quarantine( data)?$|quarantine_data' "$SC/$f" > "$SC/$f.qt.tmp" && cat "$SC/$f.qt.tmp" > "$SC/$f"
            rm -f "$SC/$f.qt.tmp"
            if [ -z "$(grep -v -E '^#!|^[[:space:]]*$' "$SC/$f")" ]; then rm -f "$SC/$f"; fi
        done
        cru d quarantine_data 2>/dev/null
        # GUI: menu entry, user page, data
        sed -i '/tabName: "Quarantine"/d' /tmp/menuTree.js 2>/dev/null
        umount /www/require/modules/menuTree.js 2>/dev/null
        mount -o bind /tmp/menuTree.js /www/require/modules/menuTree.js 2>/dev/null
        grep -l 'qt_devices_tbody' /www/user/user*.asp 2>/dev/null | while read -r _p; do rm -f "$_p"; done
        rm -rf /www/ext/quarantine
        # settings: every qt_* line (backup is in the safety copy above)
        if [ -f /jffs/addons/custom_settings.txt ]; then
            grep -v '^qt_' /jffs/addons/custom_settings.txt > /jffs/addons/custom_settings.txt.qt.tmp
            cat /jffs/addons/custom_settings.txt.qt.tmp > /jffs/addons/custom_settings.txt
            rm -f /jffs/addons/custom_settings.txt.qt.tmp
        fi
        # add-on files, logs, install backups, temporary files
        service restart_dnsmasq
        rm -rf "$QD" /tmp/mnt/sda1/quarantine_debug /tmp/mnt/sda1/quarantine_install
        rm -rf /tmp/qt-* /tmp/quarantine.busy /tmp/quarantine.msg /tmp/quarantine.banned /tmp/quarantine-debug.log /tmp/quarantine-debug.log.1
        logger -t quarantine "uninstall: done"
        echo "Quarantine removed. Safety copy of the old hook files and settings (RAM only): $_bk"
        ;;
    *)
        echo "usage: cli.sh status | selftest | diag | uninstall"
        exit 1
        ;;
esac
QT_PAYLOAD_CLI
cat > "$SET/install.sh" << 'QT_PAYLOAD_INSTALL'
#!/bin/sh
# ============================================================
# Quarantine installer (Asuswrt-Merlin) - idempotent
# Run from the install directory: sh install.sh
# Verifies SHA256SUMS first, installs, edits hooks idempotently,
# runs its own self-test and returns an error code on any problem.
# ============================================================
umask 077
SETDIR=$(cd "$(dirname "$0")" && pwd)
QD="/jffs/addons/quarantine.d"
SC="/jffs/scripts"
FILES="lib.sh fw.sh postconf.sh webui.sh generate-data.sh service-handler.sh selftest.sh cli.sh install.sh quarantine.asp"
FAILS=0

say()  { echo "[quarantine] $*"; }
fail() { echo "[quarantine] ERROR: $*"; FAILS=$((FAILS + 1)); }

qt_hash() {
    # note: the router shell has no 'command' builtin, so explicit paths are used
    for _h in /bin/sha256sum /usr/bin/sha256sum /opt/bin/sha256sum; do
        if [ -x "$_h" ]; then
            "$_h" "$1" | cut -d' ' -f1
            return 0
        fi
    done
    if [ -x /usr/sbin/openssl ]; then
        /usr/sbin/openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        return 1
    fi
}

# ---- 0. permissions ----
for d in "$SC" /jffs/addons /www; do
    [ -w "$d" ] || { echo "[quarantine] ERROR: no write permission on $d"; exit 1; }
done
[ -r /usr/sbin/helper.sh ] || { echo "[quarantine] ERROR: /usr/sbin/helper.sh missing"; exit 1; }
# shellcheck disable=SC1091
. /usr/sbin/helper.sh

# ---- 1. integrity ----
if [ -f "$SETDIR/SHA256SUMS" ]; then
    while read -r h f; do
        [ -n "$f" ] || continue
        cur=$(qt_hash "$SETDIR/$f") || { echo "[quarantine] ERROR: no sha256 tool available"; exit 1; }
        if [ "$cur" != "$h" ]; then
            echo "[quarantine] ERROR: integrity check failed for $f - installation aborted"
            exit 1
        fi
    done < "$SETDIR/SHA256SUMS"
    say "integrity OK (SHA256SUMS)"
else
    echo "[quarantine] ERROR: SHA256SUMS missing in $SETDIR - installation aborted"
    exit 1
fi

# ---- 2. install files ----
mkdir -p "$QD" "$QD/backups"
chmod 700 "$QD" "$QD/backups"
for f in $FILES; do
    [ "$SETDIR" = "$QD" ] && continue
    if ! { cp "$SETDIR/$f" "$QD/$f.new" && mv "$QD/$f.new" "$QD/$f"; }; then
        echo "[quarantine] ERROR: copying $f failed"
        exit 1
    fi
done
for f in lib.sh fw.sh postconf.sh webui.sh generate-data.sh service-handler.sh selftest.sh cli.sh install.sh; do chmod 700 "$QD/$f"; done
chmod 600 "$QD/quarantine.asp"
[ -f "$QD/notified.db" ] && chmod 600 "$QD/notified.db"
[ -f "$QD/notify_enabled" ] && chmod 600 "$QD/notify_enabled"
[ -f "$QD/known_quarantine.db" ] && chmod 600 "$QD/known_quarantine.db"
# tighten permissions of existing files/dirs (incl. old backups)
find "$QD/backups" -type d -exec chmod 700 {} + 2>/dev/null
find "$QD/backups" -type f -exec chmod 600 {} + 2>/dev/null
say "files installed in $QD"

# ---- 3. edit hooks idempotently ----
strip_lines() { # file, regex
    [ -f "$1" ] || return 0
    grep -v -E "$2" "$1" > "$1.qt.tmp"
    cat "$1.qt.tmp" > "$1"
    rm -f "$1.qt.tmp"
}
ensure_shebang() {
    if [ ! -f "$1" ]; then
        printf '#!/bin/sh\n' > "$1"
    elif ! head -n 1 "$1" | grep -q '^#!'; then
        { printf '#!/bin/sh\n'; cat "$1"; } > "$1.qt.tmp"
        cat "$1.qt.tmp" > "$1"
        rm -f "$1.qt.tmp"
    fi
}
add_line() { # file, line (makes sure the file ends with a newline)
    [ -n "$(tail -c 1 "$1" 2>/dev/null)" ] && printf '\n' >> "$1"
    printf '%s\n' "$2" >> "$1"
}

# dnsmasq.postconf: remove old own lines, add 1 hook line
ensure_shebang "$SC/dnsmasq.postconf"
strip_lines "$SC/dnsmasq.postconf" '# Quarantine$'
# shellcheck disable=SC2016
add_line "$SC/dnsmasq.postconf" '[ -r /jffs/addons/quarantine.d/postconf.sh ] && sh /jffs/addons/quarantine.d/postconf.sh "$1" # Quarantine'
chmod 700 "$SC/dnsmasq.postconf"

# firewall-start: remove marker lines and add the hook
ensure_shebang "$SC/firewall-start"
strip_lines "$SC/firewall-start" '# Quarantine$'
add_line "$SC/firewall-start" 'sh /jffs/addons/quarantine.d/fw.sh apply # Quarantine'
chmod 755 "$SC/firewall-start"

# services-start: cron for data refresh
ensure_shebang "$SC/services-start"
strip_lines "$SC/services-start" 'quarantine_data'
add_line "$SC/services-start" 'cru a quarantine_data "*/2 * * * * /jffs/addons/quarantine.d/generate-data.sh" # Quarantine data'
chmod 755 "$SC/services-start"

# service-event: handler
ensure_shebang "$SC/service-event"
strip_lines "$SC/service-event" '# Quarantine$'
# shellcheck disable=SC2016
add_line "$SC/service-event" 'if echo "$2" | grep -q "quarantine"; then { /jffs/addons/quarantine.d/service-handler.sh "$@" & }; fi # Quarantine'
chmod 755 "$SC/service-event"

# post-mount: marker lines and hook
ensure_shebang "$SC/post-mount"
strip_lines "$SC/post-mount" '# Quarantine$'
add_line "$SC/post-mount" 'sh /jffs/addons/quarantine.d/webui.sh # Quarantine'
chmod 755 "$SC/post-mount"
say "hooks updated"

# ---- 4. default settings (only when empty) ----
[ -z "$(am_settings_get qt_status)" ]     && am_settings_set qt_status "0"
[ -z "$(am_settings_get qt_dns)" ]        && am_settings_set qt_dns "9.9.9.9"
[ -z "$(am_settings_get qt_debug)" ]      && am_settings_set qt_debug "1"
[ -z "$(am_settings_get qt_access)" ]     && am_settings_set qt_access "B"
am_settings_set qt_gateway "WAN"
# load the installed lib.sh for debug logging
# shellcheck disable=SC1091
. "$QD/lib.sh"
QT_CTX="install"
qt_dbg "=== INSTALL version=$QT_VERSION lib.sh=$(qt_hash "$QD/lib.sh") handler=$(qt_hash "$QD/service-handler.sh") qt_status=$(am_settings_get qt_status)"

# ---- 5. activate ----
cru d quarantine_data 2>/dev/null
cru a quarantine_data "*/2 * * * * /jffs/addons/quarantine.d/generate-data.sh"
sh "$QD/fw.sh" apply
sh "$QD/webui.sh" || fail "webui.sh reported an error"
sh "$QD/generate-data.sh"
service restart_dnsmasq
sleep 3
say "activated"

# ---- 6. self-test ----
sh "$QD/selftest.sh" || FAILS=$((FAILS + 1))
QSTAT=$(am_settings_get qt_status)

if [ "$FAILS" -eq 0 ]; then
    say "INSTALL OK (qt_status=$QSTAT)"
    logger -t quarantine "install: self-test passed (qt_status=$QSTAT)"
    exit 0
fi
say "SELF-TEST FAILED"
logger -t quarantine "install: self-test FAILED"
exit 1
QT_PAYLOAD_INSTALL
cat > "$SET/quarantine.asp" << 'QT_PAYLOAD_ASP'
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge" />
<meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
<meta http-equiv="Pragma" content="no-cache" />
<meta http-equiv="Expires" content="-1" />
<link rel="shortcut icon" href="images/favicon.png" />
<link rel="icon" href="images/favicon.png" />
<title>Quarantine</title>
<link rel="stylesheet" type="text/css" href="index_style.css" />
<link rel="stylesheet" type="text/css" href="form_style.css" />
<style>
.qt_input{background:#32434A;color:#CCC;border:1px solid #6b8fa3;padding:4px 8px;font-size:13px;width:200px}
.qt_select{background:#32434A;color:#CCC;border:1px solid #6b8fa3;padding:4px 8px;font-size:13px}
.tabledata{font-size:12px;padding:5px 8px;border-bottom:1px solid #243B40}
.tabledata_odd{background-color:#2F3A3E}
.tabledata_even{background-color:#3A474C}
th.col_hdr{background:#243B40;color:#CCC;font-size:12px;padding:6px 10px;text-align:left;font-weight:normal;border-bottom:1px solid #1A1A1A}
.button_clear{background-color:#4D5960;color:#CCC;border:1px solid #6b8fa3;padding:4px 14px;cursor:pointer;font-size:12px}
.button_clear:hover{background-color:#5a6b70}
.qt_msg{background:#4a3b1f;color:#ffd27a;border:1px solid #8a6d2a;padding:6px 10px;margin:6px 0;font-size:12px}
.qt_badge{background:#5a4a2a;color:#ffd27a;border-radius:3px;padding:0 5px;font-size:10px;margin-left:6px}
.qt_ok{color:#7fd67f}.qt_warn{color:#ffd27a}.qt_fail{color:#ff8a8a}
.button_gen_inv{background:#4B5A61 !important;background-image:none !important;color:#F4F7F8 !important;border:1px solid #7F929B !important;text-shadow:none !important;font-weight:normal !important;cursor:pointer;width:auto !important;padding-left:14px;padding-right:14px}
.button_gen_inv:hover{background:#5C6D75 !important;color:#FFFFFF !important}
.qt_small{font-size:11px;color:#9ab}
</style>
<script language="JavaScript" type="text/javascript" src="/js/jquery.js"></script>
<script language="JavaScript" type="text/javascript" src="/js/httpApi.js"></script>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/client_function.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script language="JavaScript" type="text/javascript" src="/detect.js"></script>
<script language="JavaScript" type="text/javascript" src="/validator.js"></script>
<script type="text/javascript">
var custom_settings = <% get_custom_settings(); %>;
var qt = {version:"",status:0,dns:"9.9.9.9",gateway:"WAN",notify:0,busy:0,msg:"",lan:["","",""],subnet:"",applied:"",known:["none",0],vpn:[],free:[],diag:[],devices:[],blocked:[],access:"B",ports:"",allowed:""};
var qt_working=false, qt_timer=null, qt_eta=0, qt_elapsed=0, qt_seen_busy=false, qt_trust_open="";
function SetCurrentPage(){
    document.form.next_page.value=window.location.pathname.substring(1);
    document.form.current_page.value=window.location.pathname.substring(1);
    document.formScriptActions.current_page.value=window.location.pathname.substring(1);
    document.formScriptActions.next_page.value=window.location.pathname.substring(1);
}
function initial(){
    SetCurrentPage();
    show_menu();
    load_data();
}
function esc(t){return String(t).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function load_data(cb){
    $.ajax({
        url:"/ext/quarantine/data.htm?_="+Date.now(),
        dataType:"text",
        cache:false,
        success:function(data){ parse_data(data); render_all(); if(cb) cb(true); },
        error:function(){ $("#qt_status_text").text("Error"); if(cb) cb(false); }
    });
}
// Start a router action. eta = expected duration in seconds. Counts down, then reloads the page once the router reports it is done.
function start_action(script, eta){
    if(qt_working) return;
    qt_working=true; qt_eta=eta; qt_elapsed=0; qt_seen_busy=false;
    document.formScriptActions.action_script.value=script;
    document.formScriptActions.submit();
    show_working();
    qt_timer=setInterval(function(){
        qt_elapsed++;
        if(qt_eta>0) qt_eta--;
        show_working();
        if(qt_elapsed%2==0){
            load_data(function(ok){
                if(!ok) return;
                if(qt.busy==1) qt_seen_busy=true;
                var done=(qt.busy==0 && (qt_seen_busy || qt_elapsed>=8));
                if((qt_eta<=0 && done) || qt_elapsed>=150){
                    clearInterval(qt_timer); qt_timer=null;
                    window.location.reload();
                }
            });
        }
    },1000);
}
function show_working(){
    $("#qt_status_text").text(qt_eta>0?("Working\u2026 ETA "+qt_eta+" sec"):"Finishing\u2026");
}
function parse_data(raw){
    qt.devices=[]; qt.vpn=[]; qt.diag=[]; qt.free=[]; qt.blocked=[];
    var lines=raw.split("\n");
    for(var i=0;i<lines.length;i++){
        var l=lines[i].trim(); if(!l) continue;
        var eq=l.indexOf("="); if(eq<0) continue;
        var k=l.substring(0,eq), v=l.substring(eq+1), p=v.split("|");
        if(k=="qt_version") qt.version=v;
        else if(k=="qt_status") qt.status=parseInt(v);
        else if(k=="qt_dns") qt.dns=v;
        else if(k=="qt_gateway") qt.gateway=v;
        else if(k=="qt_notify") qt.notify=parseInt(v);
        else if(k=="qt_busy") qt.busy=parseInt(v);
        else if(k=="qt_msg") qt.msg=v;
        else if(k=="qt_lan") qt.lan=p;
        else if(k=="qt_subnet") qt.subnet=v;
        else if(k=="qt_applied") qt.applied=v;
        else if(k=="qt_known") qt.known=p;
        else if(k=="qt_vpn") qt.vpn.push({n:p[0],state:p[1],desc:p[2]});
        else if(k=="qt_free") qt.free=v?v.split(","):[];
        else if(k=="qt_diag") qt.diag.push({n:p[0],s:p[1],d:p[2]});
        else if(k=="qt_device") qt.devices.push({mac:p[0],ip:p[1],name:p[2]||"-"});
        else if(k=="qt_blocked") qt.blocked.push({mac:p[0],ip:p[1]||"-",name:p[2]||"-",since:parseInt(p[3])||0});
        else if(k=="qt_access") qt.access=v;
        else if(k=="qt_ports") qt.ports=v;
        else if(k=="qt_allowed") qt.allowed=v;
    }
}
// "443, 8883, 123/udp" -> "443-8883-123u" (null when invalid)
function ports_to_tokens(txt){
    var parts=txt.split(","), out=[];
    for(var i=0;i<parts.length;i++){
        var t=parts[i].replace(/\s/g,""); if(!t) continue;
        var m=/^([1-9][0-9]{0,4})(\/(tcp|udp))?$/i.exec(t);
        if(!m || parseInt(m[1])>65535) return null;
        out.push(m[1]+(m[3]?(m[3].toLowerCase()=="tcp"?"t":"u"):""));
    }
    if(out.length<1 || out.length>20) return null;
    return out.join("-");
}
// "443-8883-123u" -> "443, 8883, 123/udp"
function tokens_to_ports(tok){
    if(!tok || tok=="0") return "";
    var parts=tok.split("-"), out=[];
    for(var i=0;i<parts.length;i++){
        var m=/^([0-9]+)([tu]?)$/.exec(parts[i]); if(!m) continue;
        out.push(m[1]+(m[2]=="t"?"/tcp":(m[2]=="u"?"/udp":"")));
    }
    return out.join(", ");
}
function access_changed(){
    $("#qt_access_select").data("dirty",1);
    $("#qt_ports_row").toggle($("#qt_access_select").val()=="C");
}
function is_random_mac(mac){
    var c=mac.charAt(1).toLowerCase();
    return (c=="2"||c=="6"||c=="a"||c=="e");
}
function render_all(){
    if(!qt_working) $("#qt_status_text").text(qt.busy==1?"Working\u2026":(qt.status==1?"Active":"Disabled"));
    $("#qt_device_count").text(qt.devices.length);
    $("#qt_version").text(qt.version);
    if(qt.msg){ $("#qt_msg").text(qt.msg).show(); } else { $("#qt_msg").hide(); }
    $("#qt_lan_info").text(qt.lan[2]+" (router "+qt.lan[0]+", netmask "+qt.lan[1]+")");
    var ksrc={yazdhcp:"YazDHCP",native:"ASUS DHCP reservations",none:"none found"}[qt.known[0]]||qt.known[0];
    $("#qt_known_info").text(ksrc+" \u2014 "+qt.known[1]+" known device(s)");
    if(!qt_working){
        document.getElementById("qt_enable_on").checked=(qt.status==1);
        document.getElementById("qt_enable_off").checked=(qt.status==0);
        document.getElementById("qt_notify_on").checked=(qt.notify==1);
        document.getElementById("qt_notify_off").checked=(qt.notify==0);
    }
    if(!$("#qt_dns_input").data("dirty")) $("#qt_dns_input").val(qt.dns);
    if(!$("#qt_subnet_input").data("dirty")) $("#qt_subnet_input").val(qt.subnet);
    if(!$("#qt_access_select").data("dirty")){
        $("#qt_access_select").val(qt.access);
        $("#qt_ports_row").toggle(qt.access=="C");
    }
    if(!$("#qt_ports_input").data("dirty")) $("#qt_ports_input").val(tokens_to_ports(qt.ports));
    $("#qt_allowed_info").text(qt.allowed);
    // gateway dropdown: WAN + VPN clients (not supported yet)
    if(!$("#qt_gw_select").data("built")){
        var o='<option value="WAN">WAN (direct)</option>';
        for(var i=1;i<=5;i++){
            var v=qt.vpn[i-1]||{state:"0",desc:""};
            o+='<option value="VPN'+i+'" disabled>VPN Client '+i+(v.state=="2"?" (connected)":" (not configured)")+" \u2014 not supported yet</option>";
        }
        $("#qt_gw_select").html(o).data("built",1);
    }
    $("#qt_gw_select").val("WAN");
    // diagnostics
    var d="";
    for(var j=0;j<qt.diag.length;j++){
        var x=qt.diag[j];
        d+='<tr><td class="tabledata">'+esc(x.n)+'</td><td class="tabledata qt_'+esc(x.s).toLowerCase()+'">'+esc(x.s)+'</td><td class="tabledata">'+esc(x.d)+'</td></tr>';
    }
    $("#qt_diag_tbody").html(d);
    // devices
    var h="";
    if(qt.devices.length==0){
        h='<tr><td colspan="4" class="tabledata" style="text-align:center;color:#777;padding:14px">No quarantine devices</td></tr>';
    } else {
        for(var i=0;i<qt.devices.length;i++){
            var dv=qt.devices[i];
            var cls=i%2==0?"tabledata_odd":"tabledata_even";
            h+='<tr class="'+cls+'">';
            h+='<td class="tabledata" style="font-family:monospace;font-size:12px">'+esc(dv.mac)+(is_random_mac(dv.mac)?'<span class="qt_badge" title="Locally administered (private/random) MAC address">random MAC</span>':'')+'</td>';
            h+='<td class="tabledata">'+esc(dv.ip)+'</td>';
            h+='<td class="tabledata">'+esc(dv.name)+'</td>';
            h+='<td class="tabledata" style="white-space:nowrap"><input type="button" class="button_clear" value="Trust\u2026" onclick="trust_open(\''+esc(dv.mac)+'\')" /> <input type="button" class="button_clear" value="Block" onclick="block_device(\''+esc(dv.mac)+'\')" /></td>';
            h+='</tr>';
            if(qt_trust_open==dv.mac){
                var opts="";
                for(var k=0;k<qt.free.length;k++) opts+='<option value="'+esc(qt.free[k])+'">'+esc(qt.free[k])+'</option>';
                h+='<tr class="'+cls+'"><td class="tabledata" colspan="4">Make <b>'+esc(dv.mac)+'</b> a known device with a permanent DHCP reservation: '
                 +'IP <select id="qt_trust_ip" class="qt_select">'+opts+'</select> '
                 +'Name <input type="text" id="qt_trust_name" class="qt_input" style="width:140px" value="'+esc(dv.name=="-"?"":dv.name)+'" maxlength="30" /> '
                 +'<input type="button" class="button_clear" value="Confirm" onclick="trust_confirm()" /> '
                 +'<input type="button" class="button_clear" value="Cancel" onclick="trust_open(\'\')" />'
                 +'<div class="qt_small">Saved in '+(qt.known[0]=="yazdhcp"?"YazDHCP (DHCP_clients)":"the ASUS DHCP reservation list")+'. The device is disconnected once and rejoins the normal LAN with this address. Reload the YazDHCP page before editing it there.</div></td></tr>';
            }
        }
    }
    $("#qt_devices_tbody").html(h);
    // blocked devices
    var b="";
    $("#qt_blocked_count").text(qt.blocked.length);
    if(qt.blocked.length==0){
        b='<tr><td colspan="5" class="tabledata" style="text-align:center;color:#777;padding:14px">No blocked devices</td></tr>';
    } else {
        for(var n=0;n<qt.blocked.length;n++){
            var bd=qt.blocked[n];
            var bcls=n%2==0?"tabledata_odd":"tabledata_even";
            var since=bd.since>0?new Date(bd.since*1000).toLocaleString():"-";
            b+='<tr class="'+bcls+'">';
            b+='<td class="tabledata" style="font-family:monospace;font-size:12px">'+esc(bd.mac)+(is_random_mac(bd.mac)?'<span class="qt_badge" title="Locally administered (private/random) MAC address">random MAC</span>':'')+'</td>';
            b+='<td class="tabledata">'+esc(bd.ip)+'</td>';
            b+='<td class="tabledata">'+esc(bd.name)+'</td>';
            b+='<td class="tabledata">'+esc(since)+'</td>';
            b+='<td class="tabledata"><input type="button" class="button_clear" value="Unblock" onclick="unblock_device(\''+esc(bd.mac)+'\')" /></td>';
            b+='</tr>';
        }
    }
    $("#qt_blocked_tbody").html(b);
}
function block_device(mac){
    if(qt_working) return;
    if(!confirm("Block "+mac+"?\nThe device keeps its address (DHCP only) but has no network access at all, also not the Internet. It stays blocked until you unblock it.")) return;
    start_action("start_quarantineblock_"+mac.replace(/:/g,"-"), 8);
}
function unblock_device(mac){
    if(qt_working) return;
    if(!confirm("Unblock "+mac+"?\nThe device returns to the quarantine (or the LAN when it is a known device).")) return;
    start_action("start_quarantineunblock_"+mac.replace(/:/g,"-"), 8);
}
function trust_open(mac){ qt_trust_open=mac; render_all(); }
function trust_confirm(){
    var ip=$("#qt_trust_ip").val();
    var name=($("#qt_trust_name").val()||"").replace(/[^A-Za-z0-9.-]/g,"");
    if(!ip){alert("No free IP address available.");return;}
    if(!confirm("Trust "+qt_trust_open+" as "+ip+"?")) return;
    var mac=qt_trust_open.replace(/:/g,"-");
    start_action("start_quarantinetrust_"+mac+"_"+ip+"_"+name, 35);
}
function toggle_quarantine(enable){
    if(qt_working) return;
    var msg=enable?"Enable quarantine?\nUnknown devices will be moved to the quarantine network.":"Disable quarantine?\nAll devices will return to the normal LAN.";
    if(!confirm(msg)){
        document.getElementById("qt_enable_on").checked=(qt.status==1);
        document.getElementById("qt_enable_off").checked=(qt.status==0);
        return;
    }
    start_action(enable?"start_quarantineenable":"start_quarantinedisable", enable?30:18);
}
function toggle_notify(enable){
    if(qt_working) return;
    start_action(enable?"start_quarantinenotifyon":"start_quarantinenotifyoff", 3);
}
function save_settings(){
    var dns=$("#qt_dns_input").val();
    var sn=$("#qt_subnet_input").val().replace(/\s/g,"");
    if(!dns){alert("DNS cannot be empty.");return;}
    if(!/^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$/.test(sn)){alert("Quarantine subnet must look like 192.168.2");return;}
    var mode=$("#qt_access_select").val();
    var tok=ports_to_tokens($("#qt_ports_input").val()||"");
    if(mode=="C" && !tok){alert("Custom ports: enter 1 to 20 ports separated by commas, for example: 443, 8883, 123/udp");return;}
    if(!tok) tok="0";
    var chg=(sn!=qt.subnet && qt.status==1);
    if(chg && !confirm("Changing the quarantine subnet while quarantine is on disconnects all quarantine devices. Continue?")) return;
    start_action("start_quarantinesave_"+dns+"_WAN_"+sn+"_"+mode+"_"+tok, chg?35:12);
}
function clear_quarantine(){
    if(qt.devices.length==0){alert("No quarantine devices to clear.");return;}
    if(!confirm("Clear all "+qt.devices.length+" quarantine device(s)?\nThey will rejoin the network as unknown devices.")) return;
    start_action("start_quarantineclear", 18);
}
</script>
</head>
<body onload="initial();">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="about:blank" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" id="ruleForm" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="action_script" value="" />
<input type="hidden" name="current_page" id="current_page" value="" />
<input type="hidden" name="next_page" id="next_page" value="" />
<input type="hidden" name="modified" value="0" />
<input type="hidden" name="action_mode" value="apply" />
<input type="hidden" name="action_wait" value="3" />
<input type="hidden" name="first_time" value="" />
<input type="hidden" name="SystemCmd" value="" />
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>" />
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>" />
<input type="hidden" name="amng_custom" id="amng_custom" value="" />
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
<td width="17">&nbsp;</td>
<td valign="top" width="202">
<div id="mainMenu"></div>
<div id="subMenu"></div>
</td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
<tr><td valign="top">
<table width="760px" border="0" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
<tbody><tr bgcolor="#4D595D"><td valign="top">
<div style="line-height:10px;">&nbsp;</div>
<div class="formfonttitle">Quarantine <span id="qt_version" class="qt_small"></span></div>
<div id="qt_msg" class="qt_msg" style="display:none"></div>
<div style="margin:4px 0 8px 0;border-bottom:1px solid #6b8fa3"></div>
<table width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<thead><tr><td colspan="2" class="FormTitle_table_thead">Settings</td></tr></thead>
<tr>
    <td class="FormTitle_table_td">Status</td>
    <td><span id="qt_status_text" style="color:#CCC">...</span> &nbsp;|&nbsp; Quarantine devices: <span id="qt_device_count" style="color:#CCC">&#x2014;</span></td>
</tr>
<tr>
    <td class="FormTitle_table_td">Quarantine</td>
    <td>
        <input type="radio" name="qt_enable" id="qt_enable_on" value="1" onclick="toggle_quarantine(1)" /><label for="qt_enable_on"> On</label>
        &nbsp;&nbsp;
        <input type="radio" name="qt_enable" id="qt_enable_off" value="0" onclick="toggle_quarantine(0)" /><label for="qt_enable_off"> Off</label>
    </td>
</tr>
<tr>
    <td class="FormTitle_table_td">Email notifications</td>
    <td>
        <input type="radio" name="qt_notify" id="qt_notify_on" value="1" onclick="toggle_notify(1)" /><label for="qt_notify_on"> On</label>
        &nbsp;&nbsp;
        <input type="radio" name="qt_notify" id="qt_notify_off" value="0" onclick="toggle_notify(0)" /><label for="qt_notify_off"> Off</label>
    </td>
</tr>
<tr>
    <td class="FormTitle_table_td">Detected LAN</td>
    <td><span id="qt_lan_info" style="color:#CCC">...</span></td>
</tr>
<tr>
    <td class="FormTitle_table_td">Known devices</td>
    <td><span id="qt_known_info" style="color:#CCC">...</span><div class="qt_small">Only devices with a DHCP reservation are allowed on the LAN. Everything else goes to quarantine.</div></td>
</tr>
<tr>
    <td class="FormTitle_table_td">Quarantine subnet</td>
    <td><input type="text" id="qt_subnet_input" class="qt_input" style="width:110px" value="" onchange="$(this).data('dirty',1)" /> .0/24
    <div class="qt_small">Default: LAN third octet + 1. Must be a free private /24.</div></td>
</tr>
<tr>
    <td class="FormTitle_table_td">DNS Server</td>
    <td><input type="text" id="qt_dns_input" class="qt_input" value="9.9.9.9" onchange="$(this).data('dirty',1)" /></td>
</tr>
<tr>
    <td class="FormTitle_table_td">Allowed traffic</td>
    <td><select id="qt_access_select" class="qt_select" onchange="access_changed()">
        <option value="A">Basic: ports 53, 80, 443</option>
        <option value="B">Extended: Basic + 123/udp + 443/udp</option>
        <option value="C">Custom: Extended + your own ports</option>
        <option value="O">Open: no port restriction</option>
    </select>
    <div id="qt_ports_row" style="display:none;margin-top:6px"><input type="text" id="qt_ports_input" class="qt_input" style="width:300px" value="" placeholder="443, 8883, 123/udp" onchange="$(this).data('dirty',1)" />
    <div class="qt_small">Extra ports on top of Extended, separated by commas (max 20). No suffix = TCP and UDP; add /tcp or /udp to limit it.</div></div>
    <div class="qt_small">In Basic, Extended and Custom mode port 53 is always allowed and everything else leaving the quarantine is dropped. Open mode only keeps the private ranges and the router blocked. Currently allowed: <span id="qt_allowed_info"></span></div></td>
</tr>
<tr>
    <td class="FormTitle_table_td">Gateway</td>
    <td><select id="qt_gw_select" class="qt_select"><option value="WAN">WAN (direct)</option></select>
    <div class="qt_small">Quarantine devices can reach the Internet only, on the ports allowed above. All private ranges (10/8, 172.16/12, 192.168/16) and the router itself are blocked.</div></td>
</tr>
<tr>
    <td colspan="2" style="padding:8px;text-align:center"><input type="button" class="button_gen" value="Apply" onclick="save_settings()" />
    </td>
</tr>
</table>
<div style="line-height:10px;">&nbsp;</div>
<table width="100%" border="1" align="center" cellpadding="0" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<tr>
<th class="col_hdr" style="width:34%">MAC Address</th>
<th class="col_hdr" style="width:20%">IP Address</th>
<th class="col_hdr">Hostname</th>
<th class="col_hdr" style="width:150px">Action</th>
</tr>
<tbody id="qt_devices_tbody">
<tr><td colspan="4" class="tabledata" style="text-align:center;color:#777;padding:14px">Loading...</td></tr>
</tbody>
</table>
<div style="line-height:10px;">&nbsp;</div>
<div style="text-align:center;margin:10px 0">
<input type="button" class="button_gen button_gen_inv" value="Refresh" onclick="load_data()" />
&nbsp;<input type="button" class="button_gen button_gen_inv" value="Clear current quarantine devices" onclick="clear_quarantine()" />
</div>
<table width="100%" border="1" align="center" cellpadding="0" cellspacing="0" bordercolor="#6b8fa3" class="FormTable">
<thead><tr><td colspan="5" class="FormTitle_table_thead">Blocked devices (<span id="qt_blocked_count">0</span>)</td></tr></thead>
<tr>
<th class="col_hdr" style="width:30%">MAC Address</th>
<th class="col_hdr" style="width:16%">Last IP</th>
<th class="col_hdr">Hostname</th>
<th class="col_hdr" style="width:20%">Blocked since</th>
<th class="col_hdr" style="width:80px">Action</th>
</tr>
<tbody id="qt_blocked_tbody">
<tr><td colspan="5" class="tabledata" style="text-align:center;color:#777;padding:14px">Loading...</td></tr>
</tbody>
</table>
<div class="qt_small" style="margin:4px 0 10px 0">A blocked device has no network access at all (only DHCP, so it stays visible). The block works on the MAC address, is not removed by Clear and stays active while quarantine is Off.</div>
<details><summary style="cursor:pointer;color:#CCC;font-size:12px">Diagnostics</summary>
<table width="100%" border="1" cellpadding="0" cellspacing="0" bordercolor="#6b8fa3" class="FormTable" style="margin-top:6px">
<tr><th class="col_hdr" style="width:28%">Check</th><th class="col_hdr" style="width:10%">Result</th><th class="col_hdr">Detail</th></tr>
<tbody id="qt_diag_tbody"></tbody>
</table>
<div class="qt_small" style="margin-top:4px">Command line: sh /jffs/addons/quarantine.d/cli.sh status | selftest | diag | uninstall</div>
</details>
<div style="line-height:20px;">&nbsp;</div>
</td></tr></tbody>
</table>
</td></tr>
</table>
</td>
<td width="10" align="center" valign="top">&nbsp;</td>
</tr>
</table>
<div id="footer"></div>
</form>
<form method="post" name="formScriptActions" action="/start_apply.htm" target="hidden_frame">
<input type="hidden" name="action_script" value="" />
<input type="hidden" name="action_mode" value="apply" />
<input type="hidden" name="action_wait" value="3" />
<input type="hidden" name="current_page" value="" />
<input type="hidden" name="next_page" value="" />
</form>
</body>
</html>
QT_PAYLOAD_ASP
chmod 600 "$SET/quarantine.asp"
chmod 700 "$SET"/*.sh

: > "$SET/SHA256SUMS"
for f in lib.sh fw.sh postconf.sh webui.sh generate-data.sh service-handler.sh selftest.sh cli.sh install.sh quarantine.asp; do
    echo "$(qt_hash "$SET/$f")  $f" >> "$SET/SHA256SUMS"
done
say "new set written to $SET (SHA256SUMS created)"

# ---- 4. install and test ----
if sh "$SET/install.sh"; then
    say "DONE: installation and self-test passed"
    say "backup: $BK  (undo: sh $BK/restore.sh)"
    exit 0
fi
say "self-test/installation FAILED - restoring previous state"
sh "$BK/restore.sh"
abort "restored the state from before this run; see logs: grep quarantine /tmp/syslog.log | tail -30"
