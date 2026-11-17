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

**已跑通**：仓库 <https://github.com/Hbxycch/zhike-controller-ios>，首次构建成功，产物约 190 KB（arm64，iOS 16.0+）。

用法：

1. 推送代码后打开仓库 **Actions → iOS Build**，等 3~6 分钟
2. 页面底部 **Artifacts → ZhikeMonitor-unsigned-ipa** 下载
3. 用 [Sideloadly](https://sideloadly.io) 或 AltStore，以你自己的 Apple ID 对这个 ipa 重签名后装到 iPhone

> 未签名 ipa 不能直接安装，必须本机重签名 —— 这是苹果的限制，不是工程问题。

### CI 踩过的坑（保留备查）

**`runs-on: macos-14` 会瞬间 cancelled**，且不分配 runner、连日志都没有。原因是该镜像已从 GitHub 托管 runner 下线（2026 年）。用 `macos-15` 或 `macos-latest` 即可。
判断方法：Linux 任务能正常跑、macOS 任务 1 秒内 cancelled 且 `runner_name` 为空 → 就是镜像标签问题，不是账户权限或额度问题。

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

日志**按天一个目录，同一天内多次启动会续写同一份文件**（1.1 起）。这样骑行途中 App 被 iOS 回收、回来重开，也不会把当天的记录变成一个新的空会话：

```
我的 iPhone/智科监控/ZhikeLogs/20261117/
├── frames.csv   每个校验通过的帧一行（含 32 个原始字 + 解码值）
└── events.log   事件流：连接、服务/特征发现、每次 TX/RX 原始字节、错误
```

写入策略：每 5 秒 fsync 一次，进入后台 / 退出前强制落盘；冷启动时若今天已有数据，会 `seek` 到文件末尾继续追加，`seq` 接着上次的序号。

三种取法：

1. **App 内**：日志页右上角分享图标（导出今天）；时钟图标进「历史会话」，可导出任意一天。导出时会复制成带时间戳的快照再分享，文件名形如 `zhike-20261117-221218-frames.csv` / `zhike-20261117-221218-events.log`，多次导出不会重名
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
.github/workflows/ios-build.yml   CI：编译校验 + 产出未签名 ipa
dist/ZhikeMonitor-unsigned.ipa    本次 CI 产出的可安装包（未签名）
```

## 没有 Mac 也能把它装到 iPhone 上

`macos-15` runner 编译出的 `ZhikeMonitor-unsigned.ipa` **可以在 Windows 上装**：

1. Windows 装 [Sideloadly](https://sideloadly.io) + iTunes（提供 Apple 驱动）
2. iPhone 连线，Sideloadly 里拖入 `dist/ZhikeMonitor-unsigned.ipa`
3. 填自己的 Apple ID → Start，自动用免费开发者证书重签名并安装
4. 首次运行前到 iPhone 的 设置 → 通用 → VPN与设备管理 里信任该证书

免费 Apple ID 签的 App 有效期 7 天，到期重签一次即可（数据不会丢，日志在文件 App 里）。

如果完全不想要签名这一套，替代方案是 **Android / 桌面 Chrome 的 Web Bluetooth 网页版**，同一套协议解析可以直接复用。

## GPS 车速写入日志（用于自动标定）

App 会同时开启定位，把 iPhone 的 GPS 车速写进每帧 `frames.csv`：

| 列 | 含义 |
| --- | --- |
| `gps_kmh` | 该帧时刻的车速真值（km/h） |
| `gps_acc_m` | 水平精度（米） |
| `gps_age_s` | GPS 点与该帧的时间差（秒） |
| `gps_valid` | 1=有效速度读数，0=无/无效 |

监控面板的「实测 K」卡片直接显示 `GPS 车速 ÷ 当前 w6`，可现场核对；
拿到日志后运行 `python zhike_protocol/analyze_gps_calib.py frames.csv 1529`，
脚本会算出 K（km/h 每 w6 单位）、反解等效除数、并分速度段检查线性度。

> 首次运行请允许定位权限（设置页可查看授权状态）。GPS 在隧道 / 高架下会丢点，属正常。
