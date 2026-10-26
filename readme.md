# 🌐 Auto VPN Hotspot & ADB Helper

这是一个功能强大的 Magisk / KernelSU / APatch 模块。它能在后台静默运行，实现 **全自动 VPN 热点共享（包含 USB 共享网络）**、**智能开启无线 ADB**，以及针对 **scrcpy 投屏的自动化显示优化**。

## ✨ 核心功能

*   🚀 **全自动 VPN 流量接管 (热点 & USB 共享)**
    *   **无感切换**：开启热点或 USB 共享时，自动将连接设备的流量通过策略路由转发至本机的 VPN 通道（`tun` 网卡）。
    *   **高度兼容**：自动识别软 AP（`ap0`, `wlan1`）和 USB 共享网卡（`rndis0`, `usb0`），严格过滤蜂窝网卡（如联发科 `ccmni`）防误判。
    *   **防断流设计**：内置 TCP MSS 钳制（解决大包丢包）与 `rp_filter` 动态调整，自动处理防火墙锁竞争（`iptables -w`）。
    *   **防 IPv6 泄漏**：默认阻断热点入口的 IPv6 流量，强制客户端回落至 IPv4，避免真实 IP 泄漏。
*   🔌 **智能无线 ADB 控制**
    *   当手机连接 Wi-Fi 或开启热点时，自动打开无线 ADB 调试（默认端口 5555）。
    *   网络断开且无 scrcpy 投屏时，自动关闭无线 ADB，保障设备安全。
*   📱 **Scrcpy 投屏深度优化**
    *   **画质修改**：检测到 `scrcpy` 进程连入时，自动修改系统显示分辨率和 DPI（支持自定义）。
    *   **省电防烧屏**：投屏期间自动将屏幕亮度压至最低，断开投屏后瞬间自动恢复原有亮度和分辨率。

## 📦 安装与运行

1. python ./build.py;会自动打包成zip模块文件。
2. 打开 Magisk Manager (或 KernelSU / APatch)。
3. 选择“从本地安装”，选中压缩包并刷入。
4. 重启手机。
5. 脚本将作为 `late_start service` 在后台自动静默运行。

## ⚙️ 自定义配置

你可以通过修改模块目录下的 `service.sh` 文件来定制各项参数。默认路径通常为 `/data/adb/modules/你的模块名/service.sh`。

### 核心参数说明：

| 参数 | 默认值 | 作用说明 |
| :--- | :--- | :--- |
| `ADB_PORT` | `5555` | 无线 ADB 监听端口 |
| `TARGET_SIZE` | `1080x2400` | scrcpy 投屏时的强制分辨率 |
| `TARGET_DENSITY` | `400` | scrcpy 投屏时的强制 DPI |
| `BRIGHTNESS_OFF` | `1` | 投屏时的背光亮度。建议设为 `1`（最暗）。**注意：** 部分 OLED 屏幕设为 `0` 会导致触摸 IC 睡眠而死机，确认安全后方可改为 `0` |
| `VPN_BLOCK_IPV6` | `1` | `1`=阻断热点 IPv6 防止 IP 泄露，`0`=不干预 |
| `VPNTB` | `20000` | 策略路由表编号，通常无需修改 |

## 🛠️ 排错与日志 (Troubleshooting)

如果你发现模块似乎没有生效，可以通过查看运行日志来排查原因：

日志文件路径：`/data/adb/modules/你的模块名/run.log`
（上一轮运行的备份日志为 `run.log.1`）

**常见问题：**
*   **VPN 共享未生效**：请检查你的代理软件是否创建了 `tun` 接口（通常需要在代理软件中开启“TUN 模式”或“真 VPN 模式”）。
*   **无限提示 "retry in 10s"**：这通常是因为你的系统精简了原生 `ip` 或 `iptables` 工具，或者内核不支持相关的网络模块。脚本会把报错细节（`dump_vpn_state`）输出在日志中。

## 📜 依赖与兼容性

*   **环境**：Magisk / KernelSU / APatch (具备 root 权限执行 `service.sh` 的环境)。
*   **系统**：Android 10+ 测试通过，兼容原生 Android、MIUI/HyperOS、ColorOS、OriginOS 等定制系统。
*   **组件**：依赖 Android 系统原生自带的 `iproute2` 和 `iptables`。

## 📝 声明

本模块基于个人需求编写，使用请自行承担风险。若导致系统无响应或网络异常，请在 Magisk/KSU 模块管理器中禁用或卸载本模块并重启即可恢复。