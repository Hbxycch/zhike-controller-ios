# 智科控制器 iOS 监控端（ZhikeMonitor）

一个 SwiftUI + CoreBluetooth 的 iOS App，通过蓝牙（BLE）连接智科（GEKOO）控制器，实时显示运行数据，并把 **所有 BLE 收发与逐帧解码结果** 落盘，日志可直接导出用于问题核查。

## 需要什么

- 一台 Mac（macOS 13+ 建议），Xcode 15 或更新
- 一部 iPhone（iOS 16+）
- Apple ID（免费账号即可，App 装到手机上 7 天有效，重新连接 Xcode 再跑一次即可续期）
- 控制器已上电，且型号带蓝牙（GK 系列默认不带蓝牙，需向卖家确认；蓝牙密码默认 `8888`）

## 打开与运行

1. 双击 `ZhikeMonitor.xcodeproj`
2. 左侧选中 `ZhikeMonitor` target → **Signing & Capabilities**
   - Team 选择你的 Apple ID
   - Bundle Identifier 改成一个唯一值，例如 `com.你的名字.zhikemonitor`（也可以直接在 `project.pbxproj` 里改 `com.zhike.monitor`）
3. iPhone 用数据线连 Mac，顶部设备选你的 iPhone，点 ▶️ Run
4. 首次运行会弹蓝牙权限，选择 **允许**

> 如果 Xcode 提示 "Untrusted Developer"，在 iPhone 的 设置 → 通用 → VPN与设备管理 里信任你的开发者证书。

## 方式二：用 GitHub Actions 编译（没有 Mac 也行）

仓库里已带 `.github/workflows/ios-build.yml`，推到 GitHub 后自动执行：

1. 模拟器 Debug 编译 —— 纯粹的编译校验，Swift 有错会在这里红
2. 真机 Release 编译（不签名）
3. 打包成 `ZhikeMonitor-unsigned.ipa` 并作为 Artifact 上传（保留 7 天）

用法：

1. 把本仓库推到 GitHub（public 仓库的 macOS runner 免费）
2. 打开仓库 **Actions → iOS Build**，等 3~6 分钟
3. 页面底部 **Artifacts → ZhikeMonitor-unsigned-ipa** 下载
4. 用 [Sideloadly](https://sideloadly.io) 或 AltStore，以你自己的 Apple ID 对这个 ipa 重签名后装到 iPhone

> 未签名 ipa 不能直接安装，必须本机重签名 —— 这是苹果的限制，不是工程问题。

## 使用流程

1. 车辆上电（控制器"滴"一声）
2. App 首页点 **扫描设备**（12 秒自动停止，可再点）
3. 在列表里点你的控制器（默认显示全部设备；可打开"只显示 GEKOO/智科设备"过滤）
4. 连接成功后 App 自动：订阅通知 → 发开启帧 `01 02` → 每 200ms 发轮询帧 `AA 13 FF 01 AA 13 00 01`
5. **监控**页看实时数据；**原始帧**页看 32 个数据字、变化的字会标红；**日志**页看事件流

没有控制器在身边时，首页点 **演示模式**，会用合成数据跑通界面和日志格式。

## 界面显示的内容

| 位置 | 内容 |
| --- | --- |
| 监控页 | 母线电压 V、母线电流 A、功率 W、转速 rpm、控制器温度 ℃、挡位、转把原始值 w2、故障码、故障位、当前帧 HEX、帧率、校验失败数、RSSI、GATT 服务数 |
| 原始帧页 | 当前帧 32 个字（w0…w31）+ 相比上一帧变化的字标红 + 最近 400 帧的 HEX 与摘要 |
| 日志页 | 实时事件流（可暂停滚动）、一键导出、清空 |
| 设置页 | 自动重连、设备过滤、演示模式、GATT 特征清单、日志路径 |

## 日志在哪、怎么给我

日志按会话分目录，路径形如：

```
我的 iPhone/智科监控/ZhikeLogs/20261116-190512/
├── frames.csv   每个校验通过的帧一行（含 32 个原始字 + 解码值）
└── events.log   事件流：连接、服务/特征发现、每次 TX/RX 原始字节、错误
```

三种取法：

1. **App 内**：日志页右上角分享图标 → 存到"文件"/发微信/发邮件
2. **文件 App**：浏览 → 我的 iPhone → 智科监控 → ZhikeLogs
3. **Finder**：iPhone 连 Mac → Finder → 设备 → 文件 → 智科监控

`frames.csv` 的列：

```
iso_time, seq, checksum_ok, hex, w0..w31, voltage_v, current_a, power_w, rpm, temp_c, gear, fault, throttle_raw
```

## 关于相线电流（重要）

智科的 BLE 实时帧（67 字节）里 **只有母线电流（w9）**，没有相线电流和电机温度字段 —— 官方 APP 的相电流来自参数页的另一种读取方式。所以：

- 相电流目前只能：① 用官方 GEKOO APP 看；② 用本 App 记录原始 32 个字，再反推
- 反推思路：让车在 **空载匀速** 和 **爬坡/大电流** 两种工况各跑 20 秒，把两次的 `frames.csv` 给我，对比哪些 `w` 值随负载明显变化而 w9 同步变化 —— 相电流通常与母线电流成 1.2~1.5 倍关系，很容易定位
- 如果你能提供控制器的 CAN/485 协议文档（CP 系列支持 CAN），我可以直接加一路相电流解析

## 协议实现说明（供核查）

依据 Motexa 2.7.0 反编译基线，实现位于 `ZhikeProtocol.swift`：

```
帧长 67 字节：[0..2] AA 13 00 帧头 + 31 个小端字 + [65..66] 校验字
校验：sum(w0..w31) & 0xFFFF == 0xFFFF
w6 转速 = int16 / 5.46
w8 母线电压 = raw × 150 / 4096 / 10 V
w9 母线电流 = int16 A
w18 控制器温度 = raw / 100 ℃
w21 高字节=1 表示驾驶模式有效，bit4-5 挡位（1 高 / 2 低 / 其他中）
w22 故障位图
```

**这套偏移来自 APK 静态分析，没有实车抓包验证。** 上机时如果电压/电流/温度出现 10 倍或 100 倍偏差，先看 `frames.csv` 的原始字，再调 `ZhikeProtocol.swift` 里的换算系数即可 —— 拆包、校验、日志都不用动。

## 文件结构

```
ZhikeMonitor.xcodeproj/
ZhikeMonitor/
├── ZhikeMonitorApp.swift   入口
├── ContentView.swift       监控面板 + 指标卡
├── DetailViews.swift       原始帧 / 日志 / 设备列表 / 设置
├── ZhikeProtocol.swift     帧解析、校验、拆包重同步、CSV 格式、演示数据
├── ZhikeBLEClient.swift    CoreBluetooth 扫描/连接/GATT/轮询/重连
├── LogStore.swift          日志落盘（events.log + frames.csv）
└── Info.plist              蓝牙权限、文件共享
project.yml                 XcodeGen 备用工程描述（没装 XcodeGen 可忽略）
```

## 备选：没有 Mac 的情况

iOS App 必须有 Mac + Xcode 才能编译安装（iOS 的 Safari 也不支持 Web Bluetooth）。如果没有 Mac，可行的替代是做一个 **Android / 桌面 Chrome 的 Web Bluetooth 网页版**，同一套协议解析可以直接复用，说一声我就写。
