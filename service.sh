#!/system/bin/sh
# 运行于 late_start service 阶段（root 权限）

MODDIR=${0%/*}

# ===== 可修改参数 =====
ADB_PORT=5555
# 投屏时使用的分辨率和 DPI（按投屏端屏幕修改）
TARGET_SIZE=1080x2460
TARGET_DENSITY=400
# 投屏时把背光写成的值。0=全黑，部分 OLED 机型写 0 会让面板/触控进入 deep sleep，
# 断开后写回原值也点不亮（只能重启）。稳妥起见默认 1（最暗），确认安全再改 0。
BRIGHTNESS_OFF=1
# Wi-Fi 网卡名匹配（wlan0/wlan1/swlan0 等；热点 ap0/softap0 单独检测）
WIFI_IF_REGEX='^[0-9]+: (wlan|swlan|wifi)[0-9]+'
# 热点网卡：留空=自动检测（先找 veth*，再 ap0/softap0，最后看无线网卡是否 AP 模式）
# 检测不准时手动填写，例如 HOTSPOT_IF=ap0
HOTSPOT_IF=""
# VPN 网卡名匹配；要求网卡上确实有 IPv4 地址，才算 VPN 已就绪。
# 不要加 ppp/pptp：部分机型的蜂窝数据就叫 ppp0，会被当成 VPN 误判。
VPN_IF_REGEX='^(tun|utun|wg|vpn)[0-9]*$'
# 热点客户端的 IPv6：1=阻断转发（默认）。本模块的转发与策略路由只覆盖 IPv4，
# IPv6 会绕过 VPN 直接走运营商（泄漏真实地址，客户端看着像「没走梯子」），所以默认
# 在热点入口掐掉，客户端会自动回落到 IPv4。填 0 则完全不碰 IPv6
# （仅当你的 VPN 自己也能接管 IPv6 时才这么改）。
VPN_BLOCK_IPV6=1
# 热点流量走 VPN 用的策略路由表号（自定义表，不用系统表，避免互相踩）
VPNTB=20000
# ip rule 优先级：auto=自动算（必须排在系统的 main 表规则之前）；也可填数字，越小越优先
VPNPRI=auto
# 启用失败后的重试间隔（秒），避免每轮刷日志
VPN_RETRY=10
# =====================

LOG="$MODDIR/run.log"
# 保留上一轮日志（run.log.1），排查「上次为什么没生效」时有用
[ -f "$LOG" ] && mv -f "$LOG" "$LOG.1"
log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }
now() { date +%s; }

# ===== 选一个支持自定义路由表的 ip =====
# Magisk 会在 PATH 前面放自带 BusyBox，其中的 ip applet 不支持 table N：
#   ip route add ... table 20000  ->  ip: invalid argument '20000' to 'table'
# 策略路由是这套方案的基础，必须换成系统自带的 ip（/system/bin/ip）。
# 不靠猜，直接往表里加一条再删掉，能成功才算可用。
IPBIN=""
pick_ip() {
  local cand
  for cand in /system/bin/ip /system/xbin/ip /vendor/bin/ip /sbin/ip; do
    [ -x "$cand" ] || continue
    "$cand" route add 192.0.2.0/24 dev lo table "$VPNTB" 2>/dev/null || continue
    "$cand" route del 192.0.2.0/24 dev lo table "$VPNTB" 2>/dev/null
    IPBIN="$cand"
    return 0
  done
  # 最后才试 PATH 里的 ip（个别 ROM 的 BusyBox 是带 table 支持的定制版）
  if command -v ip > /dev/null 2>&1 \
      && ip route add 192.0.2.0/24 dev lo table "$VPNTB" 2>/dev/null; then
    ip route del 192.0.2.0/24 dev lo table "$VPNTB" 2>/dev/null
    IPBIN=$(command -v ip)
    return 0
  fi
  return 1
}
if pick_ip; then
  ip() { "$IPBIN" "$@"; }
  log "ip=$IPBIN ok (table $VPNTB supported)"
else
  log "no ip with table support, vpn hotspot disabled"
fi

# 热点/VPN 切换时 netd 会密集操作 iptables，抢不到 xtables 锁就直接失败；
# 更糟的是 -C 抢不到锁返回非 0 会被当成「规则不存在」，导致每 20 秒无谓重建。
IPT_WAIT="-w 2"

# iptables：寻找可用文件，并动态测试其支持的锁参数
pick_ipt() {
  local cand
  # 1. 优先找系统自带的
  for cand in /system/bin/iptables /system/xbin/iptables /sbin/iptables; do
    if [ -x "$cand" ]; then
      IPTBIN="$cand"
      break
    fi
  done
  # 2. 回退到环境变量里的
  [ -z "$IPTBIN" ] && IPTBIN=$(command -v iptables 2>/dev/null)
  [ -z "$IPTBIN" ] && return 1

  # 3. 动态探测该版本支持哪种等待锁
  IPT_WAIT=""
  if "$IPTBIN" -w 2 -L -n >/dev/null 2>&1; then
    IPT_WAIT="-w 2"
  elif "$IPTBIN" -w -L -n >/dev/null 2>&1; then
    IPT_WAIT="-w"
  fi
  return 0
}
pick_ipt || log "no usable iptables"

# ip6tables 同理
pick_ip6t() {
  local cand
  for cand in /system/bin/ip6tables /system/xbin/ip6tables /sbin/ip6tables; do
    if [ -x "$cand" ]; then
      IPT6BIN="$cand"
      break
    fi
  done
  [ -z "$IPT6BIN" ] && IPT6BIN=$(command -v ip6tables 2>/dev/null)

  IPT6_WAIT=""
  if [ -n "$IPT6BIN" ]; then
    if "$IPT6BIN" -w 2 -L -n >/dev/null 2>&1; then
      IPT6_WAIT="-w 2"
    elif "$IPT6BIN" -w -L -n >/dev/null 2>&1; then
      IPT6_WAIT="-w"
    fi
  fi
}
pick_ip6t

ipt() { "$IPTBIN" $IPT_WAIT "$@"; }
ip6t() { "$IPT6BIN" $IPT6_WAIT "$@"; }

# 1. 等待系统完全引导启动
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 3
done
sleep 5

# 2. 查找物理背光节点
  BACKLIGHT_NODE=""
  BACKLIGHT_DIR=""
  
  # 遍历常见的背光节点可能所在的目录
  for dir in /sys/class/backlight/* /sys/class/leds/lcd-backlight; do
    if [ -f "$dir/brightness" ]; then
      BACKLIGHT_DIR="$dir"
      BACKLIGHT_NODE="$dir/brightness"
      MAX_BRIGHT=$(cat "$dir/max_brightness" 2>/dev/null)
      break # 找到了就立马跳出循环
    fi
  done

  # 兜底最大亮度
  [ -z "$MAX_BRIGHT" ] && MAX_BRIGHT=255
  
  log "backlight=$BACKLIGHT_NODE max=$MAX_BRIGHT"

# 网卡的第一个 IPv4 地址（形如 192.168.43.1/24），没有则输出空。
# 不用 ip 的 -o（单行）输出：不同实现（BusyBox / 系统 iproute2）的 -o 格式不一致，
# 统一按普通多行输出解析，"inet X" 这一行在所有实现里都一样。
ifaddr_of() {
  ip -4 addr show dev "$1" 2>/dev/null \
    | awk '$1 == "inet" { print $2; exit }'
}

# tun 的点对点对端地址（"inet 10.8.0.2 peer 10.8.0.1/32" 里的 10.8.0.1），没有则输出空
peer_of() {
  ip -4 addr show dev "$1" 2>/dev/null \
    | awk '$1 == "inet" { for (i = 2; i < NF; i++) if ($i == "peer") { p = $(i + 1); sub(/\/.*/, "", p); print p; exit } }'
}

# 3. 查找热点网卡
#    顺序：手动指定 > netd 的 tether 规则（最权威）> vlan 子接口 > ap0/softap0 > 无线网卡兜底
HOTIF=""

# 当前默认路由的上行网卡（有 VPN 时可能已经是 tun，只用来排除误判）
uplink_if() {
  ip route show default 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

# netd 开热点时会在 tetherctrl_FORWARD 里写双向规则
#   "-A tetherctrl_FORWARD -i <热点网卡> -o <上行> -j RETURN"
# 用它反查热点网卡比猜名字可靠，而且不依赖 iw（Android 原生镜像根本不带 iw）。
# 只取 -i 侧：-o 侧是上行网卡（rmnet/tun），把它当热点会直接写坏规则。
# 必须严格排除蜂窝数据网卡（如 ccmni, rmnet），防止被反向规则误导。
hotif_from_tether() {
  local cand
  local uplink=$(uplink_if)
  for cand in $(ipt -S tetherctrl_FORWARD 2>/dev/null \
      | awk -v up="$uplink" '{
          i = ""; o = ""; start = ""
          for (n = 1; n < NF; n++) {
            if ($n == "-i") i = $(n + 1)
            if ($n == "-o") o = $(n + 1)
          }
          # 跳过 lo、上行网卡、以及典型的蜂窝数据/隧道网卡
          if (i != "" && i != "lo" && i != o && i != up && i !~ /^(rmnet|ccmni|ppp|pdn|tun|tap|ipsec)/) print i
        }' | sort -u); do
    [ -n "$(ifaddr_of "$cand")" ] && { echo "$cand"; return 0; }
  done
  return 1
}

scan_hotspot() {
  local cand veth ifc addr uplink
  HOTIF=""
  if [ -n "$HOTSPOT_IF" ]; then
    [ -n "$(ifaddr_of "$HOTSPOT_IF")" ] && HOTIF="$HOTSPOT_IF"
    return
  fi

  # 1) netd 认为正在 tether 的网卡
  cand=$(hotif_from_tether)
  [ -n "$cand" ] && HOTIF="$cand"

  # 2) vlan 子接口（热点在 wlan 上开了 VLAN 时，该 veth 上挂着热点地址 192.168.43.x/24）
  if [ -z "$HOTIF" ]; then
    for veth in $(ls /sys/class/net 2>/dev/null | grep -E '^veth[0-9]+$'); do
      [ -n "$(ifaddr_of "$veth")" ] && { HOTIF="$veth"; break; }
    done
  fi

  # 3) 固定名字的软 AP 网卡
  if [ -z "$HOTIF" ]; then
    for cand in rndis0 usb0 ncm0 eth0 ap0 softap0 wlan1 swlan0 ap_br_wlan0 br0; do
      [ -n "$(ifaddr_of "$cand")" ] && { HOTIF="$cand"; break; }
    done
  fi

  # 4) 热点直接跑在 wlan0 上的机型
  if [ -z "$HOTIF" ]; then
    uplink=$(uplink_if)
    for ifc in $(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|swlan|wifi|wl)[0-9]+$'); do
      addr=$(ifaddr_of "$ifc")
      [ -n "$addr" ] || continue
      if command -v iw > /dev/null 2>&1; then
        iw dev "$ifc" info 2>/dev/null | grep -q 'type AP' && { HOTIF="$ifc"; break; }
      else
        # 没有 iw 时的兜底：热点网关地址主机位必为 .1，且它不会是默认路由的上行网卡。
        # （DHCP 客户端拿到 .1 基本不可能，所以误判风险很小）
        [ "$ifc" = "$uplink" ] && continue
        case "$addr" in
          192.168.43.1/*|192.168.49.1/*|192.168.*.1/*|10.*.*.1/*) HOTIF="$ifc"; break ;;
        esac
      fi
    done
  fi
}
scan_hotspot
log "hotspot if=${HOTIF:-未找到}"

# Wi-Fi 已连接（对应网卡上有 IPv4 地址）
# 不用 ip -o：不同实现的单行格式不一致，按普通输出逐行匹配更稳
wifi_up() {
  ip -4 addr show 2>/dev/null \
    | awk -v re="$WIFI_IF_REGEX" '
        /^[0-9]+: /{ ifc = $2; sub(/:$/, "", ifc); next }
        $1 == "inet" && ifc ~ re { found = 1; exit }
        END { exit !found }'
}

# 热点已开启：热点网卡上确实有 IPv4 地址才算
hotspot_up() {
  [ -n "$HOTIF" ] && [ -n "$(ifaddr_of "$HOTIF")" ]
}

scrcpy_running() {
  # 使用 -e 参数同时匹配原版的包名和第三方版的包名
  ps -ef 2>/dev/null | grep -e "com.genymobile.scrcpy.Server" -e "org.server.scrcpy.Server" | grep -v "grep" > /dev/null 2>&1
}

adb_tcp_on() {
  settings put global adb_enabled 1
  setprop service.adb.tcp.port "$ADB_PORT"
  stop adbd
  start adbd
  log "adb tcp on :$ADB_PORT"
}

adb_tcp_off() {
  setprop service.adb.tcp.port -1
  stop adbd
  start adbd
  log "adb tcp off"
}

# 找第一个带 IPv4 地址的 VPN 网卡（tun0/wg0/vpn0 ...），排除热点网卡本身。
# 只看设备名不够：VPN 断开后 tun0 的节点可能还留着，只是没有地址。
find_tun() {
  local ifc
  for ifc in $(ls /sys/class/net 2>/dev/null | grep -E "$VPN_IF_REGEX"); do
    [ "$ifc" = "$HOTIF" ] && continue
    [ -n "$(ifaddr_of "$ifc")" ] && { echo "$ifc"; return 0; }
  done
  return 1
}

# 从 ip/mask 推算网段（192.168.43.1/24 -> 192.168.43.0/24，保留真实前缀长度）。
# 地址非法或前缀过小时返回失败，避免算出 0.0.0.0/0 这种会把全部流量抓走的规则。
subnet_of() {
  case "$1" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*/*) ;;
    *) return 1 ;;
  esac
  echo "$1" | awk '
    # 不用 2^n：部分精简 awk（toybox）对幂运算符支持不一致，直接查 8 位掩码表
    BEGIN { split("0 128 192 224 240 248 252 254 255", mask8, " ") }
    function and8(a, b,   r, s) {
      r = 0; s = 1
      while (a > 0 && b > 0) { if (a % 2 == 1 && b % 2 == 1) r += s; a = int(a / 2); b = int(b / 2); s *= 2 }
      return r
    }
    # 第 k 个字节（k=1..4）在前缀 m 下还剩几位
    function octmask(m, k,   rem) {
      rem = m - (k - 1) * 8
      if (rem <= 0) return 0
      if (rem >= 8) return 255
      return mask8[rem + 1]
    }
    {
      split($1, i, "/"); m = i[2] + 0
      # /31、/32 是点对点或单主机，热点不会是这种，算出来的规则也永远不命中
      if (m < 16 || m > 30) exit 1
      split(i[1], o, ".")
      for (n = 1; n <= 4; n++) if (o[n] !~ /^[0-9]+$/ || o[n] + 0 > 255) exit 1
      printf "%d.%d.%d.%d/%d", \
        and8(o[1] + 0, octmask(m, 1)), and8(o[2] + 0, octmask(m, 2)), \
        and8(o[3] + 0, octmask(m, 3)), and8(o[4] + 0, octmask(m, 4)), m
    }'
}

# 候选 ip rule 优先级。
# Linux 的 ip rule 允许同一个 pref 有多条规则（按插入顺序排列），所以 ip rule add
# 只有在「选择器和表完全相同」时才会报 EEXIST。正常情况下第一条 1000 就会成功，
# 后面几个只是兜底（比如上次残留了一条一模一样的）。
# 必须尽量小：系统会为热点网卡和 fwmark 插入 1xxxx 的规则（iif ap0 / fwmark … lookup …），
# 它们会把热点流量直接送去默认网络；我们的规则排在后面就永远轮不到 VPN。
# 唯一必须排在它后面的是优先级 0 的 "lookup local"（本机地址判定），所以从 1000 起试。
rule_priority_candidates() {
  echo 1000
  echo 500
  echo 1500
  echo 2000
  echo 3000
  echo 5000
  echo 10000
  echo 15000
  echo 16990
  echo 19990
  echo 25000
}

# 不同 ROM 的 ip 实现里，优先级关键字有的只认 pref，有的只认 priority，两种都试
iprule_add_from() {
  ip rule add from "$1" table "$2" pref "$3" 2>/dev/null && return 0
  ip rule del from "$1" table "$2" pref "$3" 2>/dev/null
  ip rule add from "$1" table "$2" priority "$3" 2>/dev/null && return 0
  return 1
}

iprule_del_pref() {
  ip rule del pref "$1" 2>/dev/null && return 0
  ip rule del priority "$1" 2>/dev/null && return 0
  return 1
}

# 扫掉所有指向本脚本策略表的 ip rule（不管优先级、选择器、来自哪个热点网段）。
# 上次运行、旧版本、热点换网卡都可能留下规则，不清干净会串到下一次。
# 只删选择器是具体网段的（"from all ..." 是系统规则，即使表号撞上也不能碰）。
# 删除时先用 pref 定位，不认 pref 关键字的 ROM 回退到用整条选择器删除。
flush_vpn_rules() {
  ip rule show 2>/dev/null \
    | awk -v t="$VPNTB" '
        $0 !~ /from all/ && $0 ~ ("lookup " t "( |$)") {
          p = $1; sub(/:$/, "", p)
          sub(/^[^ \t]+[ \t]+/, "")   # 去掉 "1000:" 前缀，剩下选择器
          print p "|" $0
        }' \
    | while IFS= read -r line; do
        [ -n "$line" ] || continue
        p=${line%%|*}
        sel=${line#*|}
        iprule_del_pref "$p" && continue
        [ -n "$sel" ] && ip rule del $sel 2>/dev/null
      done
}

# VPN 热点共享开关（幂等，可反复调用）。
# enable 时把实际用到的值记下来：cleanup 时热点/VPN 可能已经消失、重查会查不到，
# 那样残留的 ip rule / iptables 规则会一直生效并污染后续连接。
VPN_HOTSPOT=0
VPN_TUN=""
VPN_HOTIF=""
VPN_SUBNET=""
VPN_ADDR=""
VPN_PRI=""
VPN_RPF=""
VPN_RPF_ALL=""
VPN_V6BLOCK=0

# 删规则（enable 中途失败与 disable 共用）。参数：tun hotif subnet
remove_rules() {
  local tun="$1" hotif="$2" subnet="$3"
  # 两种选择器都清：本版本用 "from subnet"，旧版本曾加过 iif 前缀，一并清掉
  if [ -n "$subnet" ] && [ -n "$hotif" ]; then
    while ip rule del iif "$hotif" from "$subnet" table "$VPNTB" 2>/dev/null; do :; done
  fi
  if [ -n "$subnet" ]; then
    while ip rule del from "$subnet" table "$VPNTB" 2>/dev/null; do :; done
  fi
  flush_vpn_rules
  ip route flush table "$VPNTB" 2>/dev/null
  if [ -n "$tun" ]; then
    if [ -n "$subnet" ]; then
      while ipt -t nat -D POSTROUTING -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; do :; done
    fi
    if [ -n "$hotif" ]; then
      # 新版本按源/目的网段放行
      if [ -n "$subnet" ]; then
        while ipt -D FORWARD -s "$subnet" -o "$tun" -j ACCEPT 2>/dev/null; do :; done
        while ipt -D FORWARD -i "$tun" -d "$subnet" \
          -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
        while ipt -D FORWARD -i "$tun" -d "$subnet" -j ACCEPT 2>/dev/null; do :; done
      fi
      # 旧版本按入接口放行，一并清掉
      while ipt -D FORWARD -i "$hotif" -o "$tun" -j ACCEPT 2>/dev/null; do :; done
      while ipt -D FORWARD -i "$tun" -o "$hotif" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
      # enable 时 conntrack 不可用会退化成无状态放行，这条也要清
      while ipt -D FORWARD -i "$tun" -o "$hotif" -j ACCEPT 2>/dev/null; do :; done
    fi
    while ipt -t mangle -D FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    # rp_filter 恢复到 enable 前的值（tun 与 all 两份都要还原，见 enable 里的说明）
    if [ -n "$VPN_RPF" ]; then
      echo "$VPN_RPF" > "/proc/sys/net/ipv4/conf/$tun/rp_filter" 2>/dev/null
    fi
    if [ -n "$VPN_RPF_ALL" ]; then
      echo "$VPN_RPF_ALL" > /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null
    fi
  fi
  if [ "$VPN_V6BLOCK" = "1" ] && [ -n "$hotif" ]; then
    while ip6t -D FORWARD -i "$hotif" -j REJECT 2>/dev/null; do :; done
  fi
  VPN_V6BLOCK=0
  VPN_RPF=""
  VPN_RPF_ALL=""
}

# 单次尝试：失败时把 ip 的报错记进 ROUTE_ERR，并清掉可能加了一半的路由。
# 参数：目标网段 dst、完整参数串
try_route() {
  local dst="$1"
  shift
  ROUTE_ERR=$(ip route "$@" 2>&1) && return 0
  ip route del "$dst" table "$VPNTB" 2>/dev/null
  return 1
}

# 往策略表里加一条路由，返回 0 表示加成功了。
# 不同 ROM 的 ip 实现（toybox / iproute2 / 精简版）支持度不一样，实测常见三种失败：
# 1. toybox 老版本没有 "ip route replace"，直接 unknown command；
# 2. 点对点 tun 要求写 "via <对端>"，只写 dev 报 Network is unreachable；
# 3. 部分实现的参数解析很死板，要求 "table N" 写在目的地址前面。
# 所以按组合依次尝试，每种写法前先删掉同名路由，避免 EEXIST 干扰。
# 调用方最后还会读回表内容确认，不只信退出码。
add_table_route() {
  local dst="$1" dev="$2" via="$3"

  if [ "$dst" = "default" ]; then
    ip route del default table "$VPNTB" 2>/dev/null
    try_route default add default dev "$dev" table "$VPNTB" && return 0
    try_route default add table "$VPNTB" default dev "$dev" && return 0

    if [ -n "$via" ]; then
      try_route default add default via "$via" dev "$dev" table "$VPNTB" && return 0
      try_route default add table "$VPNTB" default via "$via" dev "$dev" && return 0
    fi

    # onlink 跳过「网关不在直连网段」的检查
    try_route default add default dev "$dev" onlink table "$VPNTB" && return 0
    try_route default add table "$VPNTB" default dev "$dev" onlink && return 0

    try_route default replace default dev "$dev" table "$VPNTB" && return 0
    try_route default replace table "$VPNTB" default dev "$dev" && return 0
  else
    ip route del "$dst" table "$VPNTB" 2>/dev/null
    try_route "$dst" add "$dst" dev "$dev" table "$VPNTB" && return 0
    try_route "$dst" add table "$VPNTB" "$dst" dev "$dev" && return 0
    try_route "$dst" add "$dst" dev "$dev" scope link table "$VPNTB" && return 0
    try_route "$dst" replace "$dst" dev "$dev" table "$VPNTB" && return 0
  fi
  return 1
}

# 启用失败时把现场写进 run.log，方便贴出来定位（真机上能直接看到是哪一步不认）
dump_vpn_state() {
  log "---- vpn state dump ----"
  log "ip=$(command -v ip) version=[$(ip -V 2>&1 | head -n 1)]"
  log "hotif=$HOTIF addr=[$(ifaddr_of "$HOTIF")] tun=$1"
  log "tun addr=[$(ifaddr_of "$1")] peer=[$(peer_of "$1")]"
  log "rules=[$(ip rule show 2>/dev/null | tr '\n' ';')]"
  log "table $VPNTB=[$(ip route show table "$VPNTB" 2>/dev/null | tr '\n' ';')]"
  log "routes=[$(ip route show 2>/dev/null | tr '\n' ';')]"
  log "rp_filter all=[$(cat /proc/sys/net/ipv4/conf/all/rp_filter 2>/dev/null)]"
  log "nets=[$(ls /sys/class/net 2>/dev/null | tr '\n' ' ')]"
  log "------------------------"
}

enable_vpn_hotspot() {
  local tun hotif addr subnet pri rpf cand peer

  # 没有支持自定义表的 ip 就别再重试了，日志里已经说明原因
  [ -n "$IPBIN" ] || { log "no ip with table support, skip vpn hotspot"; return 1; }
  [ -n "$IPTBIN" ] || { log "no usable iptables, skip vpn hotspot"; return 1; }
  hotspot_up || return 1
  hotif="$HOTIF"
  command -v iptables > /dev/null 2>&1 || { log "no iptables, skip vpn hotspot"; return 1; }

  addr=$(ifaddr_of "$hotif")
  subnet=$(subnet_of "$addr")
  if [ -z "$subnet" ]; then
    log "vpn hotspot: bad hotspot addr [$addr] on $hotif, abort"
    return 1
  fi

  tun=$(find_tun) || return 1
  [ "$tun" != "$hotif" ] || return 1
  peer=$(peer_of "$tun")

  VPN_RPF=""
  # 转发开关（开热点时系统本就为 1，这里兜底）
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

  # 1. 独立策略路由表：热点网段留在热点网卡（客户端互访、访问网关），
  #    其余全部进 tun。不动 main 表，因此不会顶掉系统默认路由，always-on VPN /
  #    移动数据与 Wi-Fi 切换都不受影响。
  #    先清空：热点网段换过（veth1 -> ap0）时，旧网段路由可能还指着已消失的网卡。
  ip route flush table "$VPNTB" 2>/dev/null
  ROUTE_ERR=""
  if ! add_table_route "$subnet" "$hotif" ""; then
    log "vpn hotspot: route $subnet dev $hotif failed: $ROUTE_ERR"
  fi
  if ! add_table_route default "$tun" "$peer"; then
    log "vpn hotspot: default via $tun failed: $ROUTE_ERR"
    dump_vpn_state "$tun"
    remove_rules "$tun" "$hotif" "$subnet"
    return 1
  fi
  # 读回确认（有的 ip 实现退出码是 0 但实际没写进表）
  if ! ip route show table "$VPNTB" 2>/dev/null | grep -q '^default'; then
    log "vpn hotspot: default route missing after add, abort (table=$VPNTB)"
    dump_vpn_state "$tun"
    remove_rules "$tun" "$hotif" "$subnet"
    return 1
  fi

  # 清掉旧规则（可能来自上次运行、旧版本或不同优先级），先有路由再加规则，避免断流
  flush_vpn_rules
  pri=""
  # 选择器只用 "from 热点网段"：热点客户端的源地址落在这个网段里，一定能命中。
  # 不用 "iif 热点网卡" 是因为各家 ROM 的热点实现不同：地址可能挂在 veth0/ap0 上，
  # 而客户端流量实际从另一个网卡进（或反过来），一旦不匹配规则就永不生效。
  # 手机自身访问该网段的本机流量也会命中这条规则，但表里有热点网段的本机路由，
  # 仍然走热点网卡，不会被塞进 VPN。
  if [ "$VPNPRI" = "auto" ]; then
    for cand in $(rule_priority_candidates); do
      if iprule_add_from "$subnet" "$VPNTB" "$cand"; then
        pri="$cand"
        break
      fi
    done
  elif iprule_add_from "$subnet" "$VPNTB" "$VPNPRI"; then
    pri="$VPNPRI"
  fi
  if [ -z "$pri" ]; then
    log "vpn hotspot: ip rule add failed, abort"
    remove_rules "$tun" "$hotif" "$subnet"
    return 1
  fi

  # 2. 源地址伪装成 tun 地址；不 NAT 的话 VPN 服务器收到 192.168.43.x 会直接丢包。
  #    插到链首，避免被系统/netd 的既有规则先截走。
  if ! ipt -t nat -C POSTROUTING -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; then
    if ! ipt -t nat -I POSTROUTING 1 -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; then
      log "vpn hotspot: nat rule failed, abort"
      remove_rules "$tun" "$hotif" "$subnet"
      return 1
    fi
  fi

  # 3. 放行转发：系统的 FORWARD 只给「热点 -> 移动数据」开了口子，
  #    走 tun 的这条路径没有规则，会被 tetherctrl_FORWARD 链尾的 DROP 丢掉。
  #    按源/目的网段匹配，不按 -i $hotif：热点地址可能挂在 veth0/ap0 上，
  #    而客户端流量实际从另一个网卡进（每家 ROM 的热点实现都不一样），
  #    按入接口匹配很容易一条都不命中，表现就是「规则全在但客户端不通」。
  ipt -C FORWARD -s "$subnet" -o "$tun" -j ACCEPT 2>/dev/null \
    || ipt -I FORWARD 1 -s "$subnet" -o "$tun" -j ACCEPT 2>/dev/null \
    || log "vpn hotspot: forward out rule failed"
  if ! ipt -C FORWARD -i "$tun" -d "$subnet" \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    ipt -I FORWARD 1 -i "$tun" -d "$subnet" \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || ipt -I FORWARD 1 -i "$tun" -d "$subnet" -j ACCEPT 2>/dev/null \
      || log "vpn hotspot: forward in rule failed"
  fi

  # 4. 隧道 MTU 比热点小，客户端发的大包会在 VPN 里被丢：钳制 TCP MSS
  ipt -t mangle -C FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || ipt -t mangle -I FORWARD 1 -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || log "vpn hotspot: tcp mss clamp failed"

  # 5. 回包从 tun 进来、源地址却是公网地址，严格 rp_filter 会当非法包丢掉。
  #    内核实际取 max(conf/all/rp_filter, conf/<网卡>/rp_filter)，
  #    只改 tun 那一份而 all 是 1 时并不生效，两份都要记录 + 清零。
  VPN_RPF=""
  VPN_RPF_ALL=""
  for f in "/proc/sys/net/ipv4/conf/$tun/rp_filter" /proc/sys/net/ipv4/conf/all/rp_filter; do
    [ -r "$f" ] || continue
    v=$(cat "$f" 2>/dev/null)
    case "$f" in
      */all/*) VPN_RPF_ALL="$v" ;;
      *)       VPN_RPF="$v" ;;
    esac
    [ "$v" = "0" ] || echo 0 > "$f" 2>/dev/null
  done

  # 6. IPv6 旁路：策略路由和 NAT 只覆盖 IPv4，热点客户端的 IPv6 会绕过 VPN
  #    直接走运营商。默认在热点入口 REJECT，客户端会自己回落到 IPv4。
  if [ "$VPN_BLOCK_IPV6" = "1" ] && [ -n "$IPT6BIN" ] && [ -x "$IPT6BIN" ]; then
    if ip6t -C FORWARD -i "$hotif" -j REJECT 2>/dev/null \
      || ip6t -I FORWARD 1 -i "$hotif" -j REJECT 2>/dev/null; then
      VPN_V6BLOCK=1
      log "vpn hotspot: ipv6 from $hotif blocked"
    fi
  fi

  VPN_HOTSPOT=1
  VPN_TUN="$tun"
  VPN_HOTIF="$hotif"
  VPN_SUBNET="$subnet"
  VPN_ADDR="$addr"
  VPN_PRI="$pri"
  log "vpn hotspot on: tun=$tun hotif=$hotif subnet=$subnet pri=$pri"
  return 0
}

disable_vpn_hotspot() {
  local tun="$VPN_TUN" hotif="$VPN_HOTIF" subnet="$VPN_SUBNET"
  VPN_HOTSPOT=0
  remove_rules "$tun" "$hotif" "$subnet"
  VPN_TUN=""
  VPN_HOTIF=""
  VPN_SUBNET=""
  VPN_ADDR=""
  VPN_PRI=""
  log "vpn hotspot off (tun=${tun:-none} subnet=${subnet:-none})"
}

# 系统的路由/防火墙刷新（切网、VPN 重连、netd 重建链）可能把我们的规则冲掉，定期体检
# 注意：不能用两条独立的 grep。别的规则里出现 "from $VPN_SUBNET"、另一条无关规则里
# 出现 "lookup $VPNTB" 时会误判存活，结果规则实际没了却一直不重建。
vpn_rules_alive() {
  [ -n "$VPN_SUBNET" ] && [ -n "$VPN_TUN" ] || return 1
  ip rule show 2>/dev/null | grep -qE "from ${VPN_SUBNET}[^0-9].*lookup ${VPNTB}( |$)" || return 1
  ip route show table "$VPNTB" 2>/dev/null | grep -q '^default' || return 1
  ipt -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$VPN_TUN" -j MASQUERADE 2>/dev/null || return 1
  ipt -C FORWARD -s "$VPN_SUBNET" -o "$VPN_TUN" -j ACCEPT 2>/dev/null || return 1
  return 0
}

adb_on=0
is_connected=0
SAVED_BRIGHT=0
SAVED_SIZE=""
SAVED_DENSITY=""
ROUTE_ERR=""
tick=0
VPN_FAIL_UNTIL=0

# 开机先清一次：上次运行被强杀、或模块重装后 service 重启时，策略表和 ip rule
# 会残留并指向已不存在的 tun，导致热点客户端断网。只清自己的表号和指向它的规则。
flush_vpn_rules
ip route flush table "$VPNTB" 2>/dev/null

while true; do
  # 4. 根据 Wi-Fi / 热点状态开关无线 ADB
  # 有 scrcpy 连着时不重启 adbd，避免断开会话
  if wifi_up || hotspot_up; then
    if [ "$adb_on" -eq 0 ] && [ "$is_connected" -eq 0 ]; then
      adb_tcp_on
      adb_on=1
    fi
  elif [ "$adb_on" -eq 1 ] && [ "$is_connected" -eq 0 ]; then
    adb_tcp_off
    adb_on=0
  fi

# 5. 监测 scrcpy 连入/断开
  if scrcpy_running; then
    if [ "$is_connected" -eq 0 ]; then
      if [ -n "$BACKLIGHT_NODE" ]; then
        SAVED_BRIGHT=$(cat "$BACKLIGHT_NODE")
      fi
      # 记下用户原来的 size/density
      SAVED_SIZE=$(wm size 2>/dev/null | sed -n 's/.*Override size: *//p' | head -n 1)
      SAVED_DENSITY=$(wm density 2>/dev/null | sed -n 's/.*Override density: *//p' | head -n 1)
      
      wm size "$TARGET_SIZE"
      wm density "$TARGET_DENSITY"
      is_connected=1
      log "scrcpy connected, saved brightness=$SAVED_BRIGHT size=${SAVED_SIZE:-default} density=${SAVED_DENSITY:-default}"
    fi
    
    # 每轮都强制写入 0，防止系统/自动亮度把背光改回来
    if [ -n "$BACKLIGHT_NODE" ] && [ "$(cat "$BACKLIGHT_NODE" 2>/dev/null)" != "0" ]; then
      echo 0 > "$BACKLIGHT_NODE" 2>/dev/null
    fi

  elif [ "$is_connected" -eq 1 ]; then
    # 恢复原状
    if [ -n "$SAVED_SIZE" ]; then
      wm size "$SAVED_SIZE"
    else
      wm size reset
    fi
    
    if [ -n "$SAVED_DENSITY" ]; then
      wm density "$SAVED_DENSITY"
    else
      wm density reset
    fi
    
    if [ -n "$BACKLIGHT_NODE" ]; then
      # 保底亮度：原值无效时用最大值的一半，避免黑屏无法操作
      if [ -z "$SAVED_BRIGHT" ] || [ "$SAVED_BRIGHT" -le 0 ] 2>/dev/null; then
        SAVED_BRIGHT=$((MAX_BRIGHT / 2))
        # 兜底中的兜底
        [ "$SAVED_BRIGHT" -eq 0 ] && SAVED_BRIGHT=128 
      fi
      echo "$SAVED_BRIGHT" > "$BACKLIGHT_NODE" 2>/dev/null
    fi
    
    is_connected=0
    log "scrcpy disconnected, restored brightness=$SAVED_BRIGHT"
  fi

  # 6. VPN 热点共享：热点与 TUN 同时就绪才启用，任一消失即清理
  # 热点关闭或换了网卡（veth0 -> veth1）时清空重扫，否则会一直拿旧名字判断
  if ! hotspot_up; then
    HOTIF=""
    scan_hotspot
  fi

  TUN_NOW=""
  if hotspot_up; then
    TUN_NOW=$(find_tun)
  fi

  if [ -n "$TUN_NOW" ]; then
    if [ "$VPN_HOTSPOT" -eq 1 ]; then
      rebuild=0
      [ "$TUN_NOW" = "$VPN_TUN" ] || rebuild=1
      [ "$HOTIF" = "$VPN_HOTIF" ] || rebuild=1
      [ "$(ifaddr_of "$HOTIF")" = "$VPN_ADDR" ] || rebuild=1
      if [ "$rebuild" -eq 0 ]; then
        tick=$((tick + 1))
        if [ "$tick" -ge 10 ]; then
          tick=0
          vpn_rules_alive || rebuild=1
        fi
      fi
      # VPN 换网卡 / 热点换网卡 / 地址变了 / 规则被冲掉：先拆再建
      if [ "$rebuild" -eq 1 ]; then
        disable_vpn_hotspot
        tick=0
      fi
    fi
    if [ "$VPN_HOTSPOT" -eq 0 ] && [ "$(now)" -ge "$VPN_FAIL_UNTIL" ]; then
      if enable_vpn_hotspot; then
        VPN_FAIL_UNTIL=0
      else
        VPN_FAIL_UNTIL=$(( $(now) + VPN_RETRY ))
        log "vpn hotspot enable failed, retry in ${VPN_RETRY}s"
        HOTIF=""
      fi
    fi
  else
    [ "$VPN_HOTSPOT" -eq 1 ] && disable_vpn_hotspot
    # VPN 还没就绪（或已断开）时不进入退避，等它一连上就立即生效
    VPN_FAIL_UNTIL=0
  fi

  sleep 2
done
