# IPRC1000 Classic F7 语音协议

本文记录本项目实测到的格式与当前解析规则，不把参考协议、离线测试或字段名称当作完整逆向结论。
依据：2026-10-30 外部协议交接中的目标抓包、用户试听确认，以及 2026-10-31 至 11-03 的应用实时输入验证。
原始抓包包含其他设备流量，未随源码发布；下面的测试地址均为示例，运行时从系统配对信息取得真实地址。

## 身份、传输与键盘

- 产品名 `IPRC1000`，VID `0x0A5C`、PID `0x8502`，Bluetooth Classic HID。
- 型号不能唯一识别实物：应用要求唯一同名已配对设备，并将 HID SerialNumber 规范化后与其地址比较。
- HID Control PSM 为 `0x0011`，Interrupt PSM 为 `0x0013`；CID 和 ACL handle 动态分配，不能硬编码。
- Report ID `1` 是键盘。含 Report ID 时共 9 字节：`01 modifier reserved usage[6]`；不含 ID 时为 8 字节。
  麦克风 usage 为 `0x10`（系统解释为 M），松键后会出现短暂 `0x0C`（I）。必须隔离原始设备事件，
  在应用内按映射转发；仅识别语音不等于阻止 M/I 进入系统。
- Usage `1/2/3` 是 HID 的错误状态（rollover/POSTFail/undefined）；它们不是新的按键状态，不能据此释放已按住的麦克风。
- 本机描述符只声明 ID 1、最大输入 9 字节。实际 IOHID 独占可读键盘，但未交付 F7；扩展用户态缓冲不能代替缺失的报告交付。

## F7 完整负载

下表偏移从完整 L2CAP payload 开始，不含 HCI ACL 和 L2CAP 基础头。完整长度固定 653 字节。

| 偏移 | 字节数 | 格式/意义 | 证据边界 |
| --- | ---: | --- | --- |
| 0 | 1 | `A1`，HIDP DATA/Input | 传输封装 |
| 1 | 1 | `F7`，Report ID | 目标实测 |
| 2 | 1 | `01`，format | 仅实现已观察格式 1 |
| 3–4 | 2 | sequence，UInt16LE | 按模 65536 比较 |
| 5–6 | 2 | deviceTime，UInt16LE | 单位/时钟语义未确认 |
| 7–8 | 2 | bufferState，UInt16LE | 运行语义未确认 |
| 9–10 | 2 | reserved，UInt16LE | 真实帧允许非零，不能要求等于 0 |
| 11–12 | 2 | count=`0x0140`=320，UInt16LE | 样本数，不是字节数 |
| 13–652 | 640 | 320 个 signed Int16LE PCM | 导出后用户确认本人声音 |

`653 = 1(HIDP) + 1(ID) + 1(format) + 10(五个 UInt16) + 640(PCM)`。

16 kHz 单声道由约 50 帧/秒、每帧 320 样本推算，并用于已试听及成功转写的音频；
尚无采样率协商消息证据。每帧按 20 ms 播放，PCM 净速率 32,000 字节/秒。
Float 转换为 `Float(Int16(bitPattern: littleEndianWord)) / 32768`，不默认增益、滤波或当作无符号 PCM。

`ClassicVoiceFrame.parse` 还兼容去掉 HIDP 头后的两种布局：

| 输入 | 总长度 | count 偏移 | PCM 偏移 |
| --- | ---: | --- | ---: |
| `F7 01 …`，包含 ID | 652 | 10–11 | 12 |
| `01 …`，不含 ID | 651 | 9–10 | 11 |

这两种是解析兼容布局，不意味着本机 IOHID 已交付隐藏 F7。当前生产入口使用 Apple 工具转换后完整 ACL 行，去掉 `A1` 后传递 652 字节报告。

## HCI 行筛选

固定调用已验证 Apple 签名的 PacketLogger：

```text
/Applications/PacketLogger.app/Contents/Resources/packetlogger convert -s -f itpanhsr
```

stdout 为按 tab 分隔的 `ISO time / packet type / address / name / handle / summary / raw`。
解析器允许 Apple 输出的尾部 tab；要求 `HID Interrupt Receive`、目标地址和十六进制 handle。
显示名称可能与系统配对名称不同，所以不能将该列当作逐帧身份条件。

对原始字段进一步检查：

1. ACL handle 与行中 handle 一致；广播位为 0，PB 为当前支持的 0 或 2。
2. ACL 长度、L2CAP 长度与实际完整数据一致；CID 必须是动态通道（≥`0x0040`）。
3. HIDP 是 `A1`，音频为 `F7 01`，样本计数 320，总长度 661（4 字节 ACL 头 + 4 字节 L2CAP 头 + 653 负载）。
4. 通道归属依赖 Apple 的 HID Interrupt 分类；不自行扫描任意字节找 F7，不接受尚未重组的分片或任意 CID 上的相同字节。
5. 根捕获进程只向前台转发目标 F7；键盘另由目标 IOHID 独占入口交付。HCI 解析器支持键盘格式仅用于回放校验。

首次实时捕获不用 `-b`。音频子进程重启且已有实时帧水位时才加 `-b`，按 Apple 行时间、handle/sequence 去重，
拒绝已转发时间之前的音频。只比较捕获时间的相对先后，不将其与系统墙钟硬比较；历史 Apple 转换存在时区显示差异。

## 连续音频与停止判定

`ClassicVoiceStream` 处理 sequence 回绕、重复与旧帧。小缺口最多补 5 帧零样本，超过该范围重同步，避免累积大延迟。
超过 500 ms 无有效新帧或新段 sequence 重置时重同步。补零不是恢复缺失语音，也不证明丢失一定发生在无线链路。

停止依靠松键和有效 F7 停止后的 500 ms 超时，并等待已排队音频送完；不是识别到了私有 STOP 消息。
本路径不扫描 BLE、不发送 F8、GET_REPORT/SET_REPORT 语音启动命令，不要求 mSBC/ADPCM 解码。
历史解码器仍保留于源码和自测中，但不参与此遥控器当前 PCM 路径。

## 尚未确认

- deviceTime、bufferState、reserved 的确切语义与丢序号来源。
- 采样率协商、完整私有控制协议和其他固件格式。
- Intel 真机上的蓝牙、权限与语音行为；交叉构建不能代替真机。
- 不同系统/PacketLogger 版本对行格式和隐藏报告的兼容性。

实现入口见 [VOICE_IMPLEMENTATION.md](VOICE_IMPLEMENTATION.md)，实际验证见 [REVIEW_20261103.md](REVIEW_20261103.md)。
