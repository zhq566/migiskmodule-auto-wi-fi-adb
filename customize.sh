SKIPUNZIP=0

if [ "$MAGISK_VER_CODE" -lt 30000 ]; then
  abort "! 需要 Magisk 30.0 或更高版本"
fi

ui_print "- 无线 ADB 端口: 5555"
ui_print "- 投屏分辨率/DPI 请在 service.sh 顶部修改"
ui_print "- 运行日志: /data/adb/modules/cloud_phone_auto/run.log"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
