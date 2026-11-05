# 源码构建与验证

## Release 构建

需要 Apple Command Line Tools、Swift 6 和与编译器匹配的 macOS SDK。脚本默认 SDK 15.4；本次发布使用已安装的 26.5。不要用不指定 SDK 的开发构建替代 Release 检查。

```sh
export IPRC1000_SDK_PATH=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
export SDKROOT="$IPRC1000_SDK_PATH"
export CLANG_MODULE_CACHE_PATH=/private/tmp/iprc1000-module-cache
export SWIFT_MODULECACHE_PATH=/private/tmp/iprc1000-module-cache
swift build --disable-sandbox -c release --sdk "$SDKROOT"
```

## 分别打包与签名

```sh
IPRC1000_PACKAGE_VARIANT=GitHub-AdHoc IPRC1000_CODE_SIGN_IDENTITY=- scripts/package-app.sh
IPRC1000_PACKAGE_VARIANT=Local IPRC1000_CODE_SIGN_IDENTITY="本机签名身份" scripts/package-app.sh
```

两个变体分别输出到 `dist/IPRC1000 Adapter GitHub-AdHoc.app` 和 `dist/IPRC1000 Adapter Local.app`。脚本会覆盖各自输出目录，不修改 `/Applications` 中的安装。每个变体都执行严格签名校验。发布只分发 ad-hoc 变体，本机证书包保留用于本地验证。

Intel 使用独立架构与静态库，不替换 arm64 的默认路径：

```sh
scripts/build-libsbc-intel.sh
IPRC1000_PACKAGE_VARIANT=GitHub-AdHoc IPRC1000_CODE_SIGN_IDENTITY=- scripts/package-app-intel.sh
IPRC1000_PACKAGE_VARIANT=Local IPRC1000_CODE_SIGN_IDENTITY="本机签名身份" scripts/package-app-intel.sh
```

架构构建必须串行，避免 SwiftPM 共用中间目录时互相覆盖。Intel 自测可在 Rosetta 下运行，但不等同 Intel 蓝牙真机验收。libsbc 来源及重新链接说明见 [NOTICE](../NOTICE.md)。

## 回归检查

应用包内的 `Contents/MacOS/IPRC1000Adapter --self-test` 不提权、不打开设备、不触发输入法。它覆盖目标隔离、报告解析、映射、序号、首音缓冲和识别提交顺序。

独立回归入口：

- [原生捕获过滤器与生命周期](../Tools/NativeBluetoothCaptureProbe/README.md)：ASan/UBSan，模拟授权与传输，不访问设备。
- [配置租约与跨进程恢复](../Tools/HCITraceLeaseSelfTest/README.md)：唯一测试偏好域、并发锁、EOF/超时/拥有者死亡恢复。
- [实时 PCM 管道](../Tools/PCMStreamWriterSelfTest/README.md)：真实管道背压、取消、超时、EPIPE 与并发结束。
- `Tools/CaptureStartupSelfTest/main.c`：模拟系统认证，验证目标参数及无外部工具启动。

`--replay-wechat` / `--replay-wechat-rapid` 会实际切换输入源、默认麦克风和 Fn，必须安排独立测试输入框；不能混入无人值守的常规自测。`--diagnose-exclusive` 与 Debug 构建的五分钟诊断按钮只用于开发定位，不是用户安装和日常使用的前置步骤；Release 界面不显示五分钟入口。

协议和当前路径见 [VOICE_PROTOCOL](VOICE_PROTOCOL.md)、[VOICE_IMPLEMENTATION](VOICE_IMPLEMENTATION.md)。日期命名的实验记录保留历史证据，其旧依赖与结论不代表当前发布行为。
