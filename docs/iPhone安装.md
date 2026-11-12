# 在自己的 iPhone 安装如愿美学

你不需要 Mac 或先购买开发者会员。云端负责生成 **iPhone 真机 arm64 的未签名 IPA**；Windows 负责用你自己的 Apple ID 签名并通过 USB 安装。未签名 IPA **不能直接在微信、Safari 或「文件」里点开安装**，也不是 App Store / TestFlight 包。

## 1. 下载本次真机包

1. 打开私有仓库的 [GitHub Actions](https://github.com/2814152339/ruyuan-aesthetics-ios/actions/workflows/ios-device.yml)，选择 **iPhone Unsigned IPA Build**。
2. 等待本次运行成功，下载底部 `Ruyuan-iPhone-Unsigned-运行编号-重试编号` 产物 ZIP。
3. 在 Windows 解压外层 ZIP，取出 `Ruyuan-iPhone-Unsigned.ipa`；不要再解压或改动 IPA 本身。

`status.txt`、`binary-architecture.log`、`binary-platform.log` 记录真实编译与架构检查。失败运行也会尽量上传日志和已有的 `Build.xcresult.zip`，但不会伪造成功 IPA。产物仅保留 7 天，过期可手动重新运行。本工作流使用已安装的 Xcode 16.4 / iphoneos SDK，Release、`generic/platform=iOS`，关闭签名；检查 Mach-O 为 `arm64` / `IOS` 后才打包 `Payload/Ruyuan.app`。

原来的模拟器构建与测试保留为手动运行；模拟器 `.app.zip` **不能安装到真实 iPhone**。此前成功的模拟器测试记录仍有效，不代表本次真机安装已成功。

## 2. Windows 本地签名安装（Sideloadly）

需要：iOS **17 或以上**的 iPhone、可传数据的 USB 线、Windows 电脑及你自己的 Apple ID。以下是第三方签名工具流程，不是 Apple 官方安装器；由你决定是否信任并安装。

1. 只从 [Sideloadly 官网](https://sideloadly.io/) 下载 Windows 版本。官网要求 Windows 使用相应 Apple iTunes / iCloud 组件；先读官网当前兼容说明。**不要为了安装本 App 随意卸载现有软件**；遇到版本冲突先停下核对，不自动更改你的系统。
2. USB 连接 iPhone，解锁，并在手机上确认「信任此电脑」。工具中选中你自己的手机。
3. 将 `Ruyuan-iPhone-Unsigned.ipa` 拖入工具。只在你本机的工具窗口输入自己的 Apple ID、密码及按提示需要的验证码，不发给聊天助理，不写入仓库、GitHub Secrets、截图或日志。
4. 以普通 Apple ID 签名安装模式开始，等待工具报告安装成功。不要启用注入插件、降低 iOS 限制等与本 App 无关的选项。
5. 按设备提示，在「设置 → 通用 → VPN 与设备管理」信任**你自己的开发者账号**；不要信任不认识的企业证书或商家账号。
6. iOS 16 及以上的开发安装需要「设置 → 隐私与安全性 → 开发者模式」，按系统提示重启并确认。我们的 App 最低 iOS 17，所以同样适用。若看不到该开关，先完成本机工具与手机的配对/安装流程，再查对应官方排错说明。
7. 手机上打开「如愿美学」，先点「先看一份示例报告」，再在你同意后试拍照。首次相机权限由你确认；默认照片只在本机处理，不要求填写云端地址或密钥。

免费 Apple ID 的开发签名通常 **7 天有效**，需要到期前重新签名/刷新；无需先付费加入 Apple Developer Program。Sideloadly 可提供刷新功能，但不要假定电脑关闭时仍能刷新，也不要把签名失效误认为 App 数据已丢失。[Sideloadly 官方说明](https://sideloadly.io/)

另一条可选 Windows 路径是 [AltStore Classic 官方安装说明](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows)：先安装 AltServer / AltStore，再导入此 IPA，同样需要自己的 Apple ID、设备信任及开发者模式。选择一种路径即可，无须同时安装两套工具。[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)

## 3. 如果失败

- 没有 `.ipa`：确认下载的是 **iPhone Unsigned IPA Build** 的成功产物，不是模拟器产物；检查 `status.txt`。
- 手机未出现：换确认可传数据的线、解锁手机并确认电脑信任，按工具官方说明检查 Apple 驱动组件。
- 安装后打不开：查看本机工具的具体签名错误，以及手机上的账号信任、开发者模式和 7 天有效期。只分享去除账号、设备标识等隐私后的错误文字。
- 不要越狱、关闭安全软件或系统安全机制，也不要购买来源不明的「企业签」「永久证书」。我们不会自动安装/卸载 Windows 软件，也不会索要你的账号密码。

付费 Apple Developer / TestFlight 是以后多人分发的独立可选流程，需正式证书、描述文件与相应 Apple 审核/上传要求；本仓库未配置这些凭据，本次未执行该流程。

## 验证边界

云端构建只验证 Release 真机编译、arm64 / iOS 平台与 IPA 结构；没有连接你的手机，不声称已经安装、相机已正常或真机测试已通过。安装签名留在你自己的电脑与账号内完成；CI 按固定哈希下载并随 App 打包公开模型和开源 MediaPipe SDK；手机端不临时下载模型，不上传真实照片，不加入商业测肤 API 或签名注入插件。
