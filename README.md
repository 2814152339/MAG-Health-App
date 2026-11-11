# 如愿美学 · 原生 iOS App

基于《如愿美学 iOS 测肤 App 技术方案（2026-11-10）》生成的**首版可开发工程**。SwiftUI 原生界面，最低 iOS 17，仅 iPhone 竖屏；不是网页套壳。工程独立保存在本目录。

## Windows 电脑 + 自己的 iPhone（主路径）

1. 在 [iPhone 真机云端构建](https://github.com/2814152339/ruyuan-aesthetics-ios/actions/workflows/ios-device.yml) 下载成功运行中的 `Ruyuan-iPhone-Unsigned-运行编号-尝试编号` 产物，解压外层 ZIP 取出 `.ipa`。
2. 用 Windows 本地签名工具和你自己的 Apple ID 签名，通过 USB 安装到 iOS 17 及以上的 iPhone；无需先购买开发者会员。
3. 按 [iPhone 安装指南](docs/iPhone安装.md) 完成电脑信任、本人账号信任及开发者模式。账号密码只在你自己的电脑输入，不提供给助理或仓库。

**未签名 IPA 不能直接点击安装。** 云端只负责真机程序编译与打包，不会替你连接手机或完成签名。[本次真机云编译成功运行](https://github.com/2814152339/ruyuan-aesthetics-ios/actions/runs/43052667325)；签名安装及真实手机测试仍未执行。

## 有 Mac 时打开工程（可选）

1. 将整个文件夹复制到 Mac。安装并打开完整 Xcode 16 或更新版本，完成首次组件安装。
2. 双击 **`iOS/Ruyuan.xcodeproj`**。
3. 选择一个已安装的 iPhone 模拟器，按 **⌘R**。首页「先看一份示例报告」可直接体验报告、雷达图、图层与 PDF 导出。
4. 真机拍照：连接 iPhone，在 **Signing & Capabilities → Team** 选择你的开发团队；根据团队需要更改 Bundle Identifier，然后运行。相机需真机验证；模拟器可导入照片。

不需要 CocoaPods、付费 API、云端 Key 或后端，默认本机流程即可使用。`.command` 是辅助入口，直接打开 `.xcodeproj` 更简单。

## 本版已经写入工程

- 三个原生主 Tab：首页、历史报告、我的与设置。
- 使用说明与授权、前后摄像头、拍照、重拍、确认、系统相册单图选择。
- 统一照片方向、缩图、去除来源元数据，后续分析与存储采用同一张图片。
- Apple Vision 真实人脸/五官点位、单人/姿态/曝光/尺寸检查、19 项二维几何条目。
- 面颊区域真实 RGB 采样，生成高亮/相对偏红图层、亮度与均匀度参考；每项注明算法来源和含义。
- 五维报告页面、分项切换、几何点位、图层放大、缩放拖动、原图/覆盖层切换。
- 历史记录落盘、单份删除、全部清除、PDF 导出和 iOS 系统分享。
- 可选自托管后端连接、Keychain 令牌、持久任务键与任务 ID、前台恢复、取消与重复请求处理。
- 独立的演示报告：固定演示分数与矢量插画，不保存为用户检测记录。

## 当前算法输出

真实照片的本机输出是 **五官几何＋RGB 外观基线**。高亮不命名为皮脂量，偏红不命名为敏感诊断。五项皮肤评分为缺省值，报告显示「未评分」，不生成假的综合分或肤龄。

计划中的痘/黑头/毛孔/皱纹/眼周专项模型、含水/屏障预测、三庭发际线、标定毫米、人群常模和专业评分，分别保留接入位置与功能清单，见 `docs/功能对照.md`。目前没有捆绑训练完成的专项测肤模型。

## 可选后端

见 `docs/backend.md`。附带 FastAPI、持久 SQLite 任务账本、私有本地图片、单进程 worker、同意记录、幂等上传、按操作键取消与完整报告契约。

默认不上传照片。启用服务器前，在「我的」填写服务器地址与令牌并保存。服务端的 MediaPipe 模型按文档配置；未配置时明确返回失败。后端是开发联调实现，计划中的 PostgreSQL/Celery/S3、多账户和运营后台列入下一阶段。

## 构建与测试

GitHub 私有仓库：[2814152339/ruyuan-aesthetics-ios](https://github.com/2814152339/ruyuan-aesthetics-ios)。推送 `main` 且改动 iOS 源码、真机构建脚本或真机工作流时，自动构建 **iPhone 未签名 IPA**，也可手动运行。模拟器 XCTest 保留为手动运行，不再随 push 自动触发；见 [云端构建说明](docs/云端构建.md)。

Mac 终端可在本目录复现：

```bash
bash scripts/ci-ios-device.sh      # 真机 Release 未签名 IPA，仍需本地签名安装
bash scripts/build-mac.sh          # 无签名模拟器构建
bash scripts/build-mac.sh --test   # 自动选择已安装的 iPhone 模拟器运行 XCTest
```

工程已包含 11 个单元测试与 1 个 UI 测试。修改 Swift 文件列表后，使用 `python3 scripts/generate_xcode_project.py` 重新生成工程。

**验证结果：**[真机未签名 IPA 云编译成功](https://github.com/2814152339/ruyuan-aesthetics-ios/actions/runs/43052667325)，commit `a85391f374935bcba5058eebceae4632b7ebff09`，含编译、二进制/包校验及产物上传。Windows 后端 27 项测试通过；既有云端 Xcode 16.4 / iOS 18.5 模拟器编译及 11 单元＋1 UI 测试全部通过，[原成功记录保留](https://github.com/2814152339/ruyuan-aesthetics-ios/actions/runs/43048093223)。签名安装、真实手机/相机验收及 TestFlight 尚未执行。`docs/验证记录.md` 记录具体范围；发布前执行 `docs/发布检查.md`。

## 工程目录

```text
iOS/Ruyuan.xcodeproj       直接打开的 Xcode 工程（共享 Scheme）
iOS/Ruyuan/               SwiftUI、相机、Vision、本地存储、API、PDF
iOS/RuyuanTests/          算法坐标与报告契约单元测试
iOS/RuyuanUITests/        首页 → 演示报告 → 历史的 UI 冒烟测试
backend/                  可选 Python 后端与测试
docs/                     计划对照、后端启动、验证及发布清单
scripts/                  Mac 构建、工程再生成和结构检查
```

## 技术依据

使用 Apple 官方 [Vision 人脸关键点](https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest)、[AVFoundation 相机会话](https://developer.apple.com/documentation/avfoundation/setting-up-a-capture-session) 和 PhotosUI 的系统照片选择器。服务端 MediaPipe 的来源、模型与授权检查路径列在后端说明中。没有接入商业测肤 API，没有复制参考产品的私有代码或真人样本到交付包。
