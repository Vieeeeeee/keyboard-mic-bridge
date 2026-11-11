# 参考项目与许可

以下为前期调查留给接手者的入口，**本次打包未重新检查远端最新状态，不列易变的 stars 数量**。某平台、某型号的能力不代表本机可用。

| 项目 | 参考用途与限制 |
|---|---|
| [SayAll / remote-mic-app](https://github.com/HD838A/remote-mic-app) | 本机现用 1.9.21；[音频输出](https://github.com/HD838A/remote-mic-app/blob/v1.9.21/Sources/RemoteMic/AudioOutput.swift)、[小米蓝牙链路](https://github.com/HD838A/remote-mic-app/blob/v1.9.21/Sources/RemoteMic/XiaomiBluetoothBridge.swift)、[延长录音研究](https://github.com/HD838A/remote-mic-app/blob/main/Testing/ExtendedVoiceRecording.md)、[TODO](https://github.com/HD838A/remote-mic-app/blob/main/TODO.md) |
| [Open Voice Bridge](https://github.com/nijez/open-voice-bridge) | 调查资料描述 Fn 时转发电脑麦克风，可比较生命周期；本机没有验证完整替代、点按与稳定性 |
| [VoiceHub](https://github.com/techdou/VoiceHub) | Windows 项目，实验性重连延长会话可作思路；不能视为 macOS 方案 |
| [ATVVoice](https://github.com/b0o/ATVVoice) | Linux／其他型号协议参考，不是 RC003 在 Mac 上的已验证方案 |
| [remote-buddy G9N9N 兼容说明](https://github.com/zfdang/remote-buddy/blob/main/docs/g9n9n-compatibility.md) | 评估其他遥控器兼容性；未验证可替代现有整套交互 |
| [MI-RC003-ESP32-Bridge](https://github.com/ncmro7/MI-RC003-ESP32-Bridge)、[RemoteMapper-ESP32](https://github.com/cuicui-V5/RemoteMapper-ESP32) | 硬件桥接参考，不能据此断言解除长按／一分钟限制 |

## 许可状态

本项目当前未指定开源许可证，未随包附上其他项目源码、标志、驱动或安装器。发布者应在上传 GitHub 前决定本项目的授权方式。

本工具以 Apple 平台 API 单独实现；前期阅读了 SayAll 源码作为参考，没有在本包中直接分发其文件。这不是已完成的法律或代码来源审计。若下一位 Agent 复制、移植或链接其他项目实现，应先检查对应版本的许可证，并保留要求的版权、源码与许可文本。

前期记录：SayAll 代码声明 GPL-3.0-only，品牌图形另有边界；Open Voice Bridge 采用 GPL-3.0。应直接复核各仓库的 LICENSE／COPYRIGHT 等当前声明，不能用本项目尚未选许可来免除第三方义务。

项目不包含私人音频、转写文本、完整运行日志、API key、蓝牙地址或用户账号配置。日志位置只描述标准相对用户目录路径，不携带本机日志内容。
