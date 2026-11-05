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

这两种是解析兼容布局，不意味着本机 IOHID 已交付隐藏 F7。当前生产入口直接读取系统原生捕获封装，重组目标 ACL/L2CAP 后去掉 `A1`，传递 652 字节报告。

## 原生捕获与目标筛选

生产入口为 `NativeCapture.m`，直接连接 `com.apple.bluetooth.BTPacketLogger`。先以空请求接收 `RequiresAuth`，再发送正常系统授权的 `Authentication` 外部形式；不期待此认证消息的单独回复，不修改系统授权规则。

`packet` 数据使用12字节长度/时间头、1字节记录类型及HCI负载；过滤器验证完整封装长度并兼容头部大小端。类型1为HCI事件、2为发出ACL、3为接收ACL。

1. 只从目标地址的成功 Classic Connection Complete 学习handle；断连与handle复用会清除原链路状态。
2. 从双向L2CAP信令中的PSM `0x13`连接请求及成功响应学习入站Interrupt CID；不依赖设备名称列或固定CID。
3. 仅重组已确认handle/CID上的入站ACL：PB 0/2开始，PB 1续包。固定657字节缓冲包含4字节L2CAP头及653字节HID负载。
4. 完成后验证 `A1 F7 01`、长度与320样本；不扫描PCM中的F7字节。溢出、新PDU、通道变化或断连丢弃不完整帧。
5. 目标队列最多64帧，溢出丢最旧帧并计数；等目标键盘独占就绪后再交付前台，避免冷连接早期音频被消费后丢弃。

接收前需要观察完整连接及通道协商。中途开始捕获已建立的连接时不能凭空获知CID，等待下次设备重连；这也是音频计数为零不能单独证明设备未发送语音的原因。

历史文本行解析器保留用于旧抓包离线回归，不参与当前实时接收，不要求安装PacketLogger。

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
- 不同macOS版本的私有捕获服务和隐藏报告交付兼容性。

实现入口见 [VOICE_IMPLEMENTATION.md](VOICE_IMPLEMENTATION.md)，构建与验证入口见 [DEVELOPMENT.md](DEVELOPMENT.md)。
