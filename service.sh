#!/system/bin/sh
# 运行于 late_start service 阶段（root 权限）

MODDIR=${0%/*}

# ===== 可修改参数 =====
ADB_PORT=5555
# 投屏时使用的分辨率和 DPI（按投屏端屏幕修改）
TARGET_SIZE=1080x2400
TARGET_DENSITY=400
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
log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }
: > "$LOG"
now() { date +%s; }

# 1. 等待系统完全引导启动
until [ "$(getprop sys.boot_completed)" = "1" ]; do
  sleep 3
done
sleep 5

# 2. 查找物理背光节点
BACKLIGHT_DIR=$(ls -d /sys/class/backlight/* 2>/dev/null | head -n 1)
BACKLIGHT_NODE="$BACKLIGHT_DIR/brightness"
MAX_BRIGHT=$(cat "$BACKLIGHT_DIR/max_brightness" 2>/dev/null)
[ -z "$MAX_BRIGHT" ] && MAX_BRIGHT=255
[ -f "$BACKLIGHT_NODE" ] || BACKLIGHT_NODE=""
log "backlight=$BACKLIGHT_NODE max=$MAX_BRIGHT"

# 网卡的第一个 IPv4 地址（形如 192.168.43.1/24），没有则输出空
ifaddr_of() {
  ip -4 -o addr show dev "$1" 2>/dev/null \
    | awk '{ for (i = 1; i < NF; i++) if ($i == "inet") { print $(i + 1); exit } }'
}

# 3. 查找热点网卡：优先 vlan 子接口（热点在 wlan 上开了 VLAN 时，
#    该 veth 上挂着热点地址 192.168.43.x/24）；回退到 ap0 / softap0。
HOTIF=""
scan_hotspot() {
  HOTIF=""
  if [ -n "$HOTSPOT_IF" ]; then
    [ -n "$(ifaddr_of "$HOTSPOT_IF")" ] && HOTIF="$HOTSPOT_IF"
    return
  fi
  for veth in $(ls /sys/class/net 2>/dev/null | grep -E '^veth[0-9]+$'); do
    [ -n "$(ifaddr_of "$veth")" ] && { HOTIF="$veth"; break; }
  done
  if [ -z "$HOTIF" ]; then
    for cand in ap0 softap0 wlan1 swlan0 ap_br_wlan0 br0; do
      [ -n "$(ifaddr_of "$cand")" ] && { HOTIF="$cand"; break; }
    done
  fi
  # 部分机型直接用 wlan0/swlan0 当热点：看无线网卡是不是 AP 模式
  if [ -z "$HOTIF" ] && command -v iw > /dev/null 2>&1; then
    for ifc in $(ls /sys/class/net 2>/dev/null | grep -E '^(wlan|swlan|wifi|wl)'); do
      [ -n "$(ifaddr_of "$ifc")" ] || continue
      iw dev "$ifc" info 2>/dev/null | grep -q 'type AP' && { HOTIF="$ifc"; break; }
    done
  fi
}
scan_hotspot
log "hotspot if=${HOTIF:-未找到}"

# Wi-Fi 已连接（对应网卡上有 IPv4 地址）
wifi_up() {
  ip -4 -o addr show 2>/dev/null | grep -qE "$WIFI_IF_REGEX"
}

# 热点已开启：热点网卡上确实有 IPv4 地址才算
hotspot_up() {
  [ -n "$HOTIF" ] && [ -n "$(ifaddr_of "$HOTIF")" ]
}

scrcpy_running() {
  pgrep -f "com.genymobile.scrcpy.Server" > /dev/null 2>&1
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
    function and8(a, b,   r, s) {
      r = 0; s = 1
      while (a > 0 && b > 0) { if (a % 2 == 1 && b % 2 == 1) r += s; a = int(a / 2); b = int(b / 2); s *= 2 }
      return r
    }
    {
      split($1, i, "/"); m = i[2] + 0; if (m < 8 || m > 32) exit 1
      split(i[1], o, ".")
      split("", mk)
      for (n = 1; n <= m; n++) mk[int((n - 1) / 8) + 1] += 2 ^ (7 - (n - 1) % 8)
      printf "%d.%d.%d.%d/%d", and8(o[1], mk[1]), and8(o[2], mk[2]), and8(o[3], mk[3]), and8(o[4], mk[4]), m
    }'
}

# 候选 ip rule 优先级，按顺序尝试，第一个没被占用的会被采用。
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

# 扫掉所有指向本脚本策略表的 ip rule（不管优先级、选择器、来自哪个热点网段）。
# 上次运行、旧版本、热点换网卡都可能留下规则，不清干净会串到下一次。
flush_vpn_rules() {
  ip rule show 2>/dev/null \
    | awk -v t="$VPNTB" '$0 ~ ("lookup " t "$") { p = $1; sub(/:$/, "", p); print p }' \
    | while read -r p; do ip rule del priority "$p" 2>/dev/null; done
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
      while iptables -t nat -D POSTROUTING -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; do :; done
    fi
    if [ -n "$hotif" ]; then
      while iptables -D FORWARD -i "$hotif" -o "$tun" -j ACCEPT 2>/dev/null; do :; done
      while iptables -D FORWARD -i "$tun" -o "$hotif" \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do :; done
      # enable 时 conntrack 不可用会退化成无状态放行，这条也要清
      while iptables -D FORWARD -i "$tun" -o "$hotif" -j ACCEPT 2>/dev/null; do :; done
    fi
    while iptables -t mangle -D FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    if [ -n "$VPN_RPF" ]; then
      echo "$VPN_RPF" > "/proc/sys/net/ipv4/conf/$tun/rp_filter" 2>/dev/null
    fi
  fi
  if [ "$VPN_V6BLOCK" = "1" ] && [ -n "$hotif" ]; then
    while ip6tables -D FORWARD -i "$hotif" -j REJECT 2>/dev/null; do :; done
  fi
  VPN_V6BLOCK=0
  VPN_RPF=""
}

enable_vpn_hotspot() {
  local tun hotif addr subnet pri rpf cand

  hotspot_up || return 1
  hotif="$HOTIF"
  command -v iptables > /dev/null 2>&1 || { log "no iptables, skip vpn hotspot"; return 1; }

  addr=$(ifaddr_of "$hotif")
  subnet=$(subnet_of "$addr")
  [ -n "$subnet" ] || return 1

  tun=$(find_tun) || return 1
  [ "$tun" != "$hotif" ] || return 1

  VPN_RPF=""
  # 转发开关（开热点时系统本就为 1，这里兜底）
  echo 1 > /proc/sys/net/ipv4/ip_forward 2>/dev/null

  # 1. 独立策略路由表：热点网段留在热点网卡（客户端互访、访问网关），
  #    其余全部进 tun。不动 main 表，因此不会顶掉系统默认路由，always-on VPN /
  #    移动数据与 Wi-Fi 切换都不受影响。
  #    先清空：热点网段换过（veth1 -> ap0）时，旧网段路由可能还指着已消失的网卡。
  ip route flush table "$VPNTB" 2>/dev/null
  ip route replace "$subnet" dev "$hotif" table "$VPNTB" 2>/dev/null
  if ! ip route replace default dev "$tun" table "$VPNTB" 2>/dev/null; then
    log "vpn hotspot: route via $tun failed, abort"
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
      if ip rule add from "$subnet" table "$VPNTB" priority "$cand" 2>/dev/null; then
        pri="$cand"
        break
      fi
    done
  elif ip rule add from "$subnet" table "$VPNTB" priority "$VPNPRI" 2>/dev/null; then
    pri="$VPNPRI"
  fi
  if [ -z "$pri" ]; then
    log "vpn hotspot: ip rule add failed, abort"
    remove_rules "$tun" "$hotif" "$subnet"
    return 1
  fi

  # 2. 源地址伪装成 tun 地址；不 NAT 的话 VPN 服务器收到 192.168.43.x 会直接丢包。
  #    插到链首，避免被系统/netd 的既有规则先截走。
  if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; then
    if ! iptables -t nat -I POSTROUTING 1 -s "$subnet" -o "$tun" -j MASQUERADE 2>/dev/null; then
      log "vpn hotspot: nat rule failed, abort"
      remove_rules "$tun" "$hotif" "$subnet"
      return 1
    fi
  fi

  # 3. 放行转发：系统的 FORWARD 只给「热点 -> 移动数据」开了口子，
  #    走 tun 的这条路径没有规则，会被直接 DROP
  iptables -C FORWARD -i "$hotif" -o "$tun" -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD 1 -i "$hotif" -o "$tun" -j ACCEPT 2>/dev/null
  if ! iptables -C FORWARD -i "$tun" -o "$hotif" \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
    iptables -I FORWARD 1 -i "$tun" -o "$hotif" \
      -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD 1 -i "$tun" -o "$hotif" -j ACCEPT 2>/dev/null
  fi

  # 4. 隧道 MTU 比热点小，客户端发的大包会在 VPN 里被丢：钳制 TCP MSS
  iptables -t mangle -C FORWARD -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -I FORWARD 1 -o "$tun" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null

  # 5. 回包从 tun 进来、源地址却是公网地址，严格 rp_filter 会当非法包丢掉
  rpf="/proc/sys/net/ipv4/conf/$tun/rp_filter"
  if [ -r "$rpf" ]; then
    VPN_RPF=$(cat "$rpf" 2>/dev/null)
    [ "$VPN_RPF" = "1" ] && echo 0 > "$rpf" 2>/dev/null
  fi

  # 6. IPv6 旁路：策略路由和 NAT 只覆盖 IPv4，热点客户端的 IPv6 会绕过 VPN
  #    直接走运营商。默认在热点网卡入口 REJECT，客户端会自己回落到 IPv4。
  if [ "$VPN_BLOCK_IPV6" = "1" ] && command -v ip6tables > /dev/null 2>&1; then
    if ip6tables -C FORWARD -i "$hotif" -j REJECT 2>/dev/null \
      || ip6tables -I FORWARD 1 -i "$hotif" -j REJECT 2>/dev/null; then
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
vpn_rules_alive() {
  local rules
  rules=$(ip rule show 2>/dev/null)
  echo "$rules" | grep -q "from $VPN_SUBNET" || return 1
  echo "$rules" | grep -q "lookup $VPNTB" || return 1
  ip route show table "$VPNTB" 2>/dev/null | grep -q '^default' || return 1
  iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$VPN_TUN" -j MASQUERADE 2>/dev/null || return 1
  iptables -C FORWARD -i "$VPN_HOTIF" -o "$VPN_TUN" -j ACCEPT 2>/dev/null || return 1
  return 0
}

adb_on=0
is_connected=0
SAVED_BRIGHT=0
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
    if [ "$adb_on" -eq 0 ]; then
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
      wm size "$TARGET_SIZE"
      wm density "$TARGET_DENSITY"
      is_connected=1
      log "scrcpy connected, saved brightness=$SAVED_BRIGHT"
    fi
    # 每轮都强制置 0，防止系统/自动亮度把背光改回来
    if [ -n "$BACKLIGHT_NODE" ] && [ "$(cat "$BACKLIGHT_NODE")" != "0" ]; then
      echo 0 > "$BACKLIGHT_NODE"
    fi
  elif [ "$is_connected" -eq 1 ]; then
    wm size reset
    wm density reset
    if [ -n "$BACKLIGHT_NODE" ]; then
      # 保底亮度：原值无效时用最大值的一半，避免黑屏无法操作
      if [ -z "$SAVED_BRIGHT" ] || [ "$SAVED_BRIGHT" -le 0 ] 2>/dev/null; then
        SAVED_BRIGHT=$((MAX_BRIGHT / 2))
      fi
      echo "$SAVED_BRIGHT" > "$BACKLIGHT_NODE"
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
      fi
    fi
  else
    [ "$VPN_HOTSPOT" -eq 1 ] && disable_vpn_hotspot
    # VPN 还没就绪（或已断开）时不进入退避，等它一连上就立即生效
    VPN_FAIL_UNTIL=0
  fi

  sleep 2
done
