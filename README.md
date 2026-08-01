# IPRC1000 Adapter for macOS

本机菜单栏适配软件，目标设备为 Broadcom/Cypress `0A5C:8502` 的 IPRC1000
蓝牙语音遥控器。

功能：

- 使用统一的“遥控器＋麦克风声波”App 图标和原生模板状态栏图标常驻；首次启动显示设置窗口，关闭窗口后适配继续运行。
- 仅接管产品名为 `IPRC1000` 且 VID/PID 为 `0A5C:8502` 的 HID 设备；不保存 MAC、序列号或 CoreBluetooth UUID，换用另一只同型号遥控器无需重新配置。
- 共享读取仅属于该型号遥控器的 HID 值，并按硬件时间戳过滤其原始事件，包括松键时错误发出的 `0x0C`（字母 i）；其他输入设备的事件不会匹配该时间戳。
- 提供默认按键映射，并在设置中逐键自定义；包括麦克风键在内的全部按键均支持单键、组合键和媒体键。
- 优先使用 CYW20734 官方 Android TV Voice 服务，完成能力协商、按键握手与 ADPCM 语音接收。
- 同时保留 F7/F8 HOGP + mSBC 兼容路径，并将 16 kHz 单声道音频写入 `BlackHole 2ch`。

## 构建

```sh
chmod +x scripts/build-libsbc.sh scripts/package-app.sh
scripts/build-libsbc.sh
scripts/package-app.sh
```

开发构建默认使用本机固定签名身份。正式发布时可通过
`IPRC1000_CODE_SIGN_IDENTITY` 指定 Developer ID Application 身份；私钥仅保存在钥匙串中，
不要导出或提交到仓库。

生成物位于 `dist/IPRC1000 Adapter.app`（需要 macOS 14 或更高版本）。首次运行需允许“蓝牙”、
“输入监控”和“辅助功能”。在需要语音的 App 中选择 `BlackHole 2ch` 作为麦克风。

## 重要限制

实测这批 IPRC1000 的工厂固件只发布 Bluetooth Classic SDP、PnP 和键盘 HID 三条服务：
HID Control/Interrupt PSM 为 `0x0011`/`0x0013`，报告描述符只有 Report ID 1，最大
Input/Output/Feature 分别为 9/1/1 字节。它没有发布 BLE GATT、Android TV Voice、
F7/F8 HID Audio、RFCOMM 或其他音频数据通道；对隐藏 F8 Feature 的只读请求也返回
`kIOReturnUnsupported`。因此按键适配可正常使用，但 BlackHole 无法替代遥控器到 Mac 之间
并不存在的音频传输通道，设置页会明确显示该固件限制。

App 仍保留官方 Android TV Voice（ADPCM）和 F7/F8 HOGP（mSBC）接收实现；换成公开这些
服务的兼容固件即可复用。要让当前工厂固件的麦克风工作，需要先取得原配机顶盒的蓝牙抓包并
还原其未公开协议，或通过主板触点进行有线固件读取/刷写。当前固件没有 BLE OTA 服务，不能
直接通过 macOS 无线刷入；有线刷写需要匹配 CYW20734 的镜像、引脚和工具，并存在变砖风险。
