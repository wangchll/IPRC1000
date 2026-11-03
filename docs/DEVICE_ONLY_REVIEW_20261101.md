# 单设备语音适配 review（2026-11-01）

状态：未达到可交付或再次邀请用户测试的条件。本次只改源码、构建和运行无设备输入的回归测试，未安装新版，未安装后台服务，未运行全机 HCI 或全局按键监听。

## 已修正并覆盖自动测试

- HIDController 在没有目标设备时原先返回过滤准备成功。现在返回失败；测试覆盖 prepare 和 maintain 两条路径。
- CoreHID 订阅创建成功不再等同音频可用。独立记录当前连接实例和有效 F7 证据；只有目标实例的合法帧可以允许启用输入。
- 目标断开、报告任务退出、被其他客户端独占、停止监听会撤销音频可用状态并结束当前输入；任务退出使用 defer 清理，防止早退留下任务登记。
- 回归用例覆盖未连接、仅键盘报告、F7 截断、其他实例、无关设备移除、目标断开、旧实例迟到数据、新实例重新验证。
- 外部输入入口在切换输入源、麦克风或启动辅助程序之前检查通道；延迟发出自定义快捷键前再次检查。测试覆盖 Fn / 自定义快捷键与长按 / 切换两种模式的拒绝路径。
- 按键回调在原主 runloop 同步处理，避免异步任务跨断连继续发键；过滤失效、设备移除和退出时释放已处理的按住状态。这一部分完成代码 review 和编译，未声称真实 Fn/麦克风恢复已复验。
- 映射成功提示改为“系统按键映射已回读”；删除把属性读回当作“原始按键已屏蔽”的断言。

## 尚未解决的交付阻断

1. **UserKeyMapping 不是原始 HID 客户端隔离。** 本次本机注册表快照中，IPRC1000 下同时存在适配器和 WeType 的 IOHIDLibUserClient，均为非独占打开。系统事件映射即使成功，也不能证明另一个直接读 HID 的客户端不接收 M/I。不能再通过调整 Fn 延时来回避该问题。
2. **冷连接首包竞态依然存在。** 设备匹配后再写服务属性、每 10 ms 重试，无法证明匹配回调之前的首个 M 已被阻止。单纯增加重试次数不是修复。
3. **单设备 F7 尚未接通。** 历史 `.29` 正确说话测试只收到了 ID 1、长度 9。用户文档证明了原始 Bluetooth HID Interrupt 上的 F7，不等于 macOS CoreHID 会交付。新的状态测试只证明严格解析和隔离逻辑，不证明实时接口能接收。
4. **设备独占需要与音频入口一起设计。** Apple CoreHID `seizeDevice` 文档明确要求在订阅等调用前执行，成功后只有该客户端收通知。因此不能把 seize 加到音频监听旁边、同时继续依赖另一个 HIDController 的原始报告回调；必须单入口处理键盘及音频，并验证授权、释放和首包问题。旧管理员探针已有首个 M 漏出，不能把独占调用返回成功当作完整验收。
5. **L2CAP 是待验证路线，不是已实现的解决方案。** 已检查本机 IOBluetooth SDK 的通道/委托接口；没有证据证明可以对系统拥有的 HID 通道无损附加只读订阅。未盲目替换系统 delegate、打开重复 HID 通道或发送未知控制命令。

## 验证记录和边界

本机没有 AGENTS.md 指定的 MacOSX15.4.sdk，使用已安装的 MacOSX26.5.sdk，保留 Release 与隔离 module-cache 配置；未用 plain swift build 判断。

```sh
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
CLANG_MODULE_CACHE_PATH=/private/tmp/iprc1000-module-cache \
SWIFT_MODULECACHE_PATH=/private/tmp/iprc1000-module-cache \
swift build --disable-sandbox -c release \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
.build/out/Products/Release/IPRC1000Adapter --self-test
git diff --check
```

自动测试没有打开遥控器、录音、调用微信或发送测试按键。协议 fixture 为合成数据。此前 PacketLogger 链路成功的中文输入不能计作当前单设备实现的验收。未重新打包，因此不产生新的双签名制品。

官方接口依据：
- https://developer.apple.com/documentation/corehid/hiddeviceclient/seizedevice()
- https://developer.apple.com/documentation/corehid/hiddeviceclient/notification/deviceseized
- https://raw.githubusercontent.com/apple-oss-distributions/IOHIDFamily/main/IOHIDEventSystemPlugIns/IOHIDKeyboardFilter.mm

再次安排用户测试前，至少必须解决原始报告的单设备隔离与 F7 实时入口；之后才可做冷启动首按、连续按压、真实光标转写、退出恢复的端到端验收。

## 单设备 L2CAP 接管实测补充

用户按方向键唤醒后，`--inspect` 确认目标 connected=1，缓存 PnP VID/PID=2652/34050。探针在连接前已经调用公开的 IOBluetoothIgnoreHIDDevice，并注册 HID Control/Interrupt incoming 通道通知；没有收到通道回调。同期 hidutil 仍列出目标 IOHIDUserDevice 和 AppleUserHIDEventService。因此本机该调用未实现预期的默认 HID 隔离，不能作为有效接管方案集成到应用。探针已结束，恢复接口已调用；没有要求用户再次说话。

探针现在每 250 ms 在目标已连接时检查目标 HID 是否仍暴露；发现即失败退出并恢复，避免只有未交付的 L2CAP 回调才触发隔离失败。协议边界测试在 ASan/UBSan 下通过，包括非目标、错误 PSM、全部短帧长度、错误头字段和允许非零 reserved。这些结果不代表产品语音或按键拦截已通过。

## 同客户端独占接收修复（尚未安装）

应用源码已改为在 CoreHID 同一客户端上先执行 seizeDevice，再订阅报告。键盘 ID 1 直接交给原配置转发逻辑；F7 交给现有音频解析。语音监听启动前停止普通 HIDController 读设备，停止后恢复普通按键适配。失去独占、移除和停止时撤销输入许可并释放按住状态；独占失败没有非独占降级。修复重复点击启动导致已有接管状态被清空的问题。

新增实际 HIDController 回归：未拥有设备时拒绝报告、同一按下报告不重复转发、非法报告不能改变按键状态、断连恰好释放一次、旧报告被拒绝。Release 构建、自测和 diff 检查通过。

新增 --diagnose-exclusive 为120秒有界、不发系统按键、不路由或保存音频的本机验证入口。第一轮30秒未匹配到在线目标，keyboard=0/F7=0，不构成独占失败或成功证据。正在等待下一轮目标上线以核对真实权限。尚未解决/验证普通用户键盘独占权限、冷连接首包与隐藏 F7 交付，不作为可用版本安装。

## 2026-11-02 测试窗口修复

用户反馈已唤醒时，旧120秒诊断已退出且目标当前在线，故旧 keyboard=0/F7=0 无法判断独占成功或失败。诊断现分为最长900秒等待与首次独占成功后120秒接收，重连不会续期。两阶段使用 systemUptime；新增晚唤醒、等待超时及重连不无限续期回归用例，Release 构建、自测和 diff 检查通过。接收阶段即时打印目标按键报告和F7计数；不保存报告正文或音频、不发系统按键。

旧 CoreHID 管理员版本已经明确返回 notPermitted；已切换低层 IOHIDDeviceOpen(SeizeDevice)。低层版本尚未在有效在线窗口内完成本次真机验证。新临时诊断日志为 /private/tmp/iprc-exclusive-iohid-rendezvous.log，启动时仍需系统认证。不得把程序签名、认证或等待状态算作实际接管成功。

## 输入监控授权定位与修正

有效唤醒窗口内，低层 IOHID 独占打开返回 0xE00002E2 (NotPermitted)。tccd 日志明确显示请求来自 UID 0 的独立诊断路径，缺少 ListenEvent 授权且不能向 root 弹出提示。普通用户调用 IOHIDRequestAccess 返回 granted 不能证明管理员侧独立程序条目已授权；系统设置当时只有微信输入法及 IPRC1000 Adapter。

用户已明确允许临时诊断获取系统“输入监控”权限，并亲自解锁设置。通过系统设置标准添加界面选中 /private/tmp/iprc-device-capture-diagnostic；界面已回读该条目且开关 on。未修改 TCC 数据库。该权限保留至用户撤销；诊断代码仅匹配目标遥控器，无全局事件钩子。正在重新启动同一路径、同一签名文件验证管理员预检，尚不代表独占或F7接收已成功。

## 已授权低层独占结果与音频窗口边界

2026-11-02，输入监控条目显式添加后，管理员进程75123通过预检，日志出现 EXCLUSIVE:true 和“目标 IOHID 独占打开成功”，累计142条目标键盘报告，并在目标重连后再次独占成功。此结果证明该身份及权限条件下能独占打开并读取键盘；尚未独立证明冷启动首键不漏或系统M/I完全不出现。

上轮说话的麦克风按下 ID1 usage0x10 记录于08:43:20.034，紧接着原测试窗口结束，没有覆盖完整说话过程。F7=0不应视为音频接口的有效反证。已保留原日志 /private/tmp/iprc-device-capture-first-window.log。

诊断窗口再次修正：最多等15分钟至实际麦克风按下，方向键或独占就绪不启动短窗口；麦克风按下后最多120秒，松开后留2秒尾包退出；再次按下不会无限延长总窗口。新增方向键不消耗音频窗口、松开尾包及晚按下边界回归，通过Release构建和自测。未再次安装应用，未声称语音修复完成。

## 完整麦克风操作的有效IOHID独占测试

进程75898在目标上线后 EXCLUSIVE:true；08:54:06.319收到麦克风 usage0x10按下，08:54:12.834收到释放，随后还接收0x0C与空报告。此次按住约6.515秒，窗口含完整按住、松开及尾包。最终 keyboard=24/F7=0，进程已退出释放。回调只出现ID1/9字节，描述符maxInput=9。此为当前IOHID独占条件不交付F7的有效证据，不证明底层无线没有F7（本轮未使用全机HCI对照）。不得再把独占成功当作音频路径成功。

补充工具 --existing 验证公开SDK的旧 openL2CAPChannel:findExisting:newChannel: 接口，固定目标HID Interrupt PSM 0x13，校验返回channel设备地址和PSM，仅当无已有delegate时附加自己的delegate。停止时解除自己的delegate，不关闭查找到的系统通道；不设置忽略HID、不改配对、不监听其他设备数据。该API本身可能在找不到既有通道时尝试打开，不能描述为保证纯只读。协议测试ASan/UBSan通过，正在等目标上线核对实际返回值，尚未接入产品。

## L2CAP现有通道接口实测

用户唤醒后，立即重新启动 --existing，唯一配对目标 connected=1、PnP型号匹配，旧 openL2CAPChannel:findExisting:newChannel: 返回0xE00002BC，channel=nil。未附加delegate、未取得数据。不能将其归为未唤醒或无音频。

新增 --interrupt 仅针对该目标，使用当前公开 openL2CAPChannelAsync:withPSM:delegate: (PSM0x13)，保留目标地址/PSM验证及有界退出，不改配对或全机抓包。它是主动通道打开请求，不保证纯被动查找。程序已编译及协议自测通过，现等目标上线以检查实际返回。该试验尚未成为产品音频后端。

## 异步L2CAP请求成功不等于通道打开

2026-11-02进程17655在目标connected=1时，异步Interrupt请求返回0并给出对象，setDelegate也返回0。用户说话时该进程仍运行、目标在线，但没有打开完成或任何数据回调。进程自身系统日志明确出现 setupL2CAPChannelForDevice: No channel，随后 xpc_fd_dup failed: errno 22、WARNING: Unknown error:454、Failed to open L2CAP channel (CBErrorDomain Code0)。因此此轮不是F7解析拒收，而是底层通道没有打开；不能将API返回0报告为可用音频入口。

工具已新增：异步请求对象不得视为ready；10秒内必须收到打开完成或真实数据，否则标记失败；所有严格目标的数据回调先打印长度元数据，再做协议分类，避免误把未知封装静默拒绝当作没有回调。ASan/UBSan协议测试通过。当前公开异步路径仍未解决，不再要求用户重复说话验证同一失败条件。

## 2026-11-02 继续排查结果

当前主机 macOS 26.6.2 (25G83)。公开 CBManager.authorization 查询返回3 (allowedAlways)，未申请额外蓝牙权限、未扫描设备。因此普通用户蓝牙授权缺失不能解释这次底层fd创建失败。SDK公开配置仅列出 MaxAllowedIncomingMTU / DesiredOutgoingMTU；暂无证据支持通过随意调整MTU解决 xpc_fd_dup errno22，不将其作为修复。

工具进一步修正异步完成可能早于out-parameter赋值的回调处理：先校验目标地址和PSM再绑定通道；委托注册成功提示明确不等于channel ready。ASan/UBSan协议测试和diff检查通过。此修改消除调用方可能漏处理早期完成的风险，不能声称修复已观测的系统通道打开错误。

当前边界：已验证目标独占键盘报告可读；完整按住松开时IOHID不交付F7；旧L2CAP查询返回错误无对象；现代异步API给出对象但底层创建失败且无完成/数据回调。未恢复全机HCI或全局按键钩子，未发布/安装这轮实验代码。继续纯单设备音频需要新的可验证传输入口，尚无端到端交付。

## 用户重新授权临时HCI后的组合实现

用户已明确允许临时HCI音频捕获、仅解析目标F7。本轮恢复历史已成功的AuthorizationExecuteWithPrivileges临时启动机制（不安装服务），独占键盘仍用单目标IOHID。管理员自身运行DeviceVoiceInput，并运行经Apple签名校验的PacketLogger stdout捕获；仅在独占目标后，才将严格身份/方向/通道/封装校验后的F7及目标IOHID键盘报告送到前台。原始HCI行留在管理员进程内、丢弃其他流量、不写抓包文件。

新增过滤后通信协议和拒收回归测试；Release、自测、diff检查通过。保持原输入配置，增加重连后的启用意图保留。已制作20261102.30 Local和GitHub AdHoc两个独立签名制品，分别codesign校验通过；安装Local版，旧版完整备份至/private/tmp/IPRC1000-before-20261102.30.app。新版UI已实际启动，外部微信模式设置保留。当前正在等待实际软件启动管理员认证，组合路径启动/停止清理及真实微信输入尚未验收，不能标完成。

## .30冷重连失败与.31恢复修复

用户冷唤醒+两句快速测试失败。浏览器回读出现连续m及末尾mi。23:19:38管理员20330重新匹配设备并记录描述符，紧接着23:19:38.492正常退出；前台20286仍在，管理员和PacketLogger均已消失，界面捕获已停止。旧实现会在音频子进程退出、音频管道EOF/错误或超长未完成行时退出整个管理员会话并释放键盘。旧实现没有退出原因日志，不能仅据此唯一确定是子进程EOF还是其他退出分支。

.31将键盘接管生命周期与音频子进程分开：保持DeviceVoiceInput，在音频EOF/错误时独立清理并退避重启PacketLogger；只在前台控制管道结束或安全校验失败时结束整体会话。异常长HCI行丢弃至下一换行并继续，新增CaptureLifecycle状态日志。不增加全局键盘监听。

恢复时使用最后已转发目标帧的时间与句柄/序号水位拒收旧帧；只有已有实时水位时才使用PacketLogger缓冲包恢复。相同时间的不同序号保留，新句柄旧时间帧拒绝；不按系统墙钟猜测PacketLogger时区。前台收到音频重置后结束旧Fn会话、保留输入意图，恢复时仅重送仍按住的目标麦克风报告。该路径仍需实际验证缓冲恢复及冷首键行为。

新增“重试音频接收”只发送固定R控制字，不执行任意命令。可由代理在界面触发恢复，以比较管理员PID保持、PacketLogger PID更换。管道关闭使用F_SETNOSIGPIPE避免前台在重试时被SIGPIPE终止；新增真实断管写入返回EPIPE测试。超长行恢复、分包、多行、防重放、同时间戳和重连帧测试均通过。

.31 Release构建、自测、diff检查通过。20261102.31 Local / GitHub AdHoc分别生成且签名校验通过；已安装Local版，.30完整备份位于/private/tmp/IPRC1000-before-20261102.31.app。实际软件已启动，等待管理员认证后先验证音频重试；尚未通过冷重连复验，不能声称漏键修复已验收。

## .31实际音频重试验证

2026-11-03实际运行.31。代理点击“重试音频接收”，CaptureLifecycle日志07:45:27.806记录固定R请求。管理员PID28091不变；PacketLogger从56375更换至56487，无额外认证。UI仍显示目标独占；只读精确目标的注册表检查得到该管理员客户端ClientOpened=1、ClientOptions=1、Privileged=1。ClientSeized=0不代表未持有独占，它表示本客户端是否被另一个独占者阻塞；对照Apple IOHIDLibUserClient源码的open/messageGated/serializeDebugState确认。默认输入仍为MacBook Air麦克风(ID99)。

只读检查程序最初因CF匹配字典所有权处理错误退出，已改用bridge_retained向消耗引用的IOServiceGetMatchingServices传参后成功；Tools/TargetBluetoothProbe相同模式亦修正，产品捕获未受该临时工具影响。

已启用微信输入，当前目标休眠，空测试框由代理聚焦，等待冷唤醒+两句快速输入反馈。R验证发生在本会话尚无F7水位时，因此尚不能代替“已有F7水位后缓冲重启不重放”的实际验收。


## .31冷重连漏键纠正与.32键盘修复

用户明确确认原始M/I出现后被自己删除；浏览器空输入框绝不能作为没有漏键的证据。.31冷测试失败。07:53:39.089管理员匹配目标，07:53:39.190记录旧的“parent closed”退出原因；该旧标签无法区分控制EOF和输出写失败，不能声称已唯一定位退出根因。

静态复核发现确定的错误：临时进程对非阻塞通信端直接write，并把EAGAIN当致命失败，随后释放HID独占。新增有界输出队列，在EAGAIN保留待发送按键并稍后重试；仅真实断连/硬错误退出。音频积压到256KiB时丢弃新增音频，给按键/状态留出空间，总队列最多1MiB。真实非阻塞pipe填满到EAGAIN的回归已通过：不退出，排空后精确按序交付I及K按下/松开；真实EPIPE仍正确识别。

独占匹配提前到IOHIDManagerOpen(seize)，通过VendorID、ProductID、Product、Bluetooth及精确SerialNumber限定同一只遥控器；重连继续使用已打开的独占manager，不等匹配回调才第一次请求独占。保留回调中的身份校验与设备打开返回值检查。没有注册全局键盘钩子，没有增加其他设备输入访问。增加管理器打开、目标设备打开、断开及关闭日志，区分前台EOF与写失败。匹配与故障回归通过不等于真实冷首键已验收。

最终Release构建使用本机已安装MacOSX26.5 SDK（AGENTS指定15.4未安装），最终自测通过；目前仍需真实独占/冷重连验证，不声明微信全链路已修复。


## .32真实键盘拦截复验及首键缺失

测试页面只监听自身textarea的keydown/beforeinput，不注册系统钩子。代理先发送m/i，计数正确变为1/1、输入2，再刷新归零。用户实际操作后，页面M=0、I=0、输入=0；设备08:21:31.990重连独占成功，08:21:35.021和08:21:40.747收到M按下，分别08:21:39.304及08:21:45.076松开并收到I；根进程58529和PacketLogger58854未退出。这一轮有真实报告对应的零漏键计数，拦截通过本轮观察；尚不能替代后续长期/所有冷启动验收。

首次重连后仅08:21:33.797出现松开和I，未见首次M按下，提示冷唤醒按下可能早于报告注册。该观察不足以唯一归因于应用或遥控器，不能声称已确认硬件/系统根因。

.33将目标专属manager报告回调注册提前到设置匹配与打开之前，独占设备不再在匹配回调覆盖报告回调；仍为同一精确地址范围。参考Apple公开IOKitUser/hid.subproj/IOHIDManager.c（https://raw.githubusercontent.com/apple-oss-distributions/IOKitUser/main/hid.subproj/IOHIDManager.c）中的设备枚举/回调安装顺序。

接管完成后仅一次读取该设备键盘页麦克风元素的缓存值（IOHIDDeviceGetValueWithOptions withoutUpdate，SDK明确为get last value，不发送GetReport），仅缓存明确按住才补交初始M；后续实时同状态由既有pressed集合去重，正常松开仍照常处理。不轮询其他设备、不猜测语音意图。Release构建、完整自测和diff检查通过；真实冷首键恢复仍需验证。


## .33冷首键真实端到端通过（单次观察）

2026-11-03用户反馈“一次按住出现浮窗和文字”。Edge回读“第一次按住就开始微信语音输入 12345。”，页面M=0、I=0、字母输入=0。08:44:15.186目标独占打开；15.190实际读到目标缓存麦克风仍按住并补交M，15.199前台收到；15.212送音助手启动；17.306 Fn按下；21.751遥控器松开；26.529助手code0退出且Fn释放。默认麦克风恢复MacBook Air(ID99)，输入源仍WeType；管理员60291、PacketLogger60965均保持。44:42.997目标自行休眠断开，管理器保持预先独占。

本轮证明首键恢复实际触发、真实文字落入光标、未见M/I漏键且现场恢复。不能据单轮声称全部连续/长期场景通过。助手启动至Fn仍2.094秒；恢复拦截不等于初始化延迟已消除。保留此可用版本进行独立初始化性能检查，暂不重装。


## .33连续两句真实验证与当前交付状态

用户反馈“两句都出现，响应正常”。Edge回读两行“第一句连续输入测试。\n第二句连续输入测试。”；测试页M=0、I=0、字母输入=0。08:54:19.369再次冷重连，19.372补交目标缓存的按住；19.388启动助手62201，19.547 Fn按下（设备枚举后178ms，不含蓝牙无线唤醒之前的耗时）。25.048助手62201正常退出，25.059接续助手62209，30.986第二助手code0退出并释放Fn。默认麦克风恢复MacBook Air(ID99)，输入源WeType，无送音助手残留；管理员60291与PacketLogger60965均保持。目标49.087正常休眠，独占manager保持预先打开，待下次连接。

独立静音音频组件计时：实际安装组件两次从启动到READY为0.158/0.150秒，未发送Fn、未切默认输入、未采集音频。此前首次真实助手启动2.094秒未稳定复现；不能声称所有首次初始化延迟已永久消除。当前.33通过本轮冷首键及快速接续实际验证，保留本机可用版本，不再为重复测试重装。免重复认证仍未实现/启用，遵照用户选择不安装常驻服务。

结构化证据：dist/combined-20261103.33-verification.json；本机安装版本20261103.33；独立Local证书签名和GitHub AdHoc签名制品均已核验，未发布GitHub。
