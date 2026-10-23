#!/system/bin/sh
# 运行于 late_start service 阶段（root 权限）

MODDIR=${0%/*}

# ===== 可修改参数 =====
ADB_PORT=5555
# 投屏时使用的分辨率和 DPI（按投屏端屏幕修改）
TARGET_SIZE=1080x2400
TARGET_DENSITY=400
# Wi-Fi / 热点网卡名匹配（wlan0/wlan1/swlan0/ap0/softap0 等）
WIFI_IF_REGEX='^[0-9]+: (wlan|swlan|ap|softap|wifi)[0-9]+'
# =====================

LOG="$MODDIR/run.log"
log() { echo "$(date '+%m-%d %H:%M:%S') $1" >> "$LOG"; }
: > "$LOG"

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

# Wi-Fi 已连接或热点已开启（对应网卡上有 IPv4 地址）
wifi_up() {
  ip -4 -o addr show 2>/dev/null | grep -qE "$WIFI_IF_REGEX"
}

# scrcpy 服务端进程：app_process / com.genymobile.scrcpy.Server ...
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

adb_on=0
is_connected=0
SAVED_BRIGHT=0

while true; do
  # 3. 根据 Wi-Fi/热点状态开关无线 ADB
  # 有 scrcpy 连着时不重启 adbd，避免断开会话
  if wifi_up; then
    if [ "$adb_on" -eq 0 ]; then
      adb_tcp_on
      adb_on=1
    fi
  elif [ "$adb_on" -eq 1 ] && [ "$is_connected" -eq 0 ]; then
    adb_tcp_off
    adb_on=0
  fi

  # 4. 监测 scrcpy 连入/断开
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

  sleep 2
done
