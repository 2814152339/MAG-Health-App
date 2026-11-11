import SwiftUI

@MainActor
struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverEnabled = false
    @State private var serverURL = ""
    @State private var serverToken = ""
    @State private var showPrivacy = false
    @State private var showDelete = false
    @State private var saved = false
    @State private var validationMessage: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "sparkle")
                        .font(.title2.weight(.light)).foregroundStyle(RuyuanStyle.purple)
                        .frame(width: 52, height: 52)
                        .background(RuyuanStyle.lilac, in: RoundedRectangle(cornerRadius: 17))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("如愿美学").font(.headline).foregroundStyle(RuyuanStyle.ink)
                        Text("尊重真实，也尊重你的选择。")
                            .font(.caption).foregroundStyle(RuyuanStyle.muted)
                    }
                }
                .padding(.vertical, 5)
            }

            Section("隐私与照片") {
                Label("默认在本机进行面部几何分析", systemImage: "iphone")
                Label(store.hasConsent ? "已同意分析使用说明" : "首次分析前需阅读并同意使用说明",
                      systemImage: store.hasConsent ? "checkmark.shield" : "hand.raised")
                Button { showPrivacy = true } label: {
                    HStack { Text("查看隐私与使用说明"); Spacer(); Image(systemName: "chevron.right") }
                }
            }
            .foregroundStyle(RuyuanStyle.ink)

            Section {
                Toggle("启用服务端分析", isOn: $serverEnabled)
                    .tint(RuyuanStyle.purple)
                if serverEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("服务地址").font(.caption).foregroundStyle(RuyuanStyle.muted)
                        TextField("https://your-server.example", text: $serverURL)
                            .keyboardType(.URL).textContentType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.subheadline)
                            .accessibilityLabel("分析服务器地址")
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("访问令牌").font(.caption).foregroundStyle(RuyuanStyle.muted)
                        SecureField("由你的服务端提供", text: $serverToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("服务器访问令牌，保存在钥匙串")
                    }
                    Label("照片将上传到你指定的服务器，请先确认其可信与隐私政策。", systemImage: "arrow.up.doc")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted)
                }
                Button(action: saveSettings) {
                    HStack {
                        Text("保存设置").fontWeight(.semibold)
                        Spacer()
                        if saved { Label("已保存", systemImage: "checkmark").font(.caption) }
                    }
                }
                .foregroundStyle(RuyuanStyle.purple)
            } header: {
                Text("可选的服务端模型")
            } footer: {
                Text("默认关闭。仅接受 HTTPS 或本地网络地址；本地 HTTP 不加密。令牌保存在设备钥匙串，不写入报告。更改后请保存。")
            }

            Section {
                modelRow("面部轮廓与比例", detail: "本机 Apple Vision · 依据真实特征点计算", symbol: "face.dashed")
                modelRow("皮肤五维与可视化", detail: "需接入适配的服务端模型；无有效输出时不评分", symbol: "square.3.layers.3d")
                modelRow("演示报告", detail: "固定示例数据与矢量插画 · 非你的检测结果", symbol: "doc.text.magnifyingglass")
            } header: {
                Text("分析能力与边界")
            } footer: {
                Text("照片中的光线、妆容和拍摄角度会影响观察。报告不作医学诊断，也不据此推荐治疗。")
            }

            Section {
                HStack {
                    Label("已保存的报告", systemImage: "rectangle.stack")
                    Spacer()
                    Text("\(store.reports.count) 份").foregroundStyle(RuyuanStyle.muted)
                }
                Button(role: .destructive) { showDelete = true } label: {
                    Label("删除全部报告与关联照片", systemImage: "trash")
                }
            } header: {
                Text("数据管理")
            } footer: {
                Text("删除不可撤销。服务端报告也会请求删除对应的远端记录；失败时保留未删除的报告并提示。")
            }

            Section {
                HStack {
                    Text("版本")
                    Spacer()
                    Text(appVersion).foregroundStyle(RuyuanStyle.muted)
                }
                Text("以观察理解美，不以数字定义你。")
                    .font(.footnote).foregroundStyle(RuyuanStyle.muted)
            }
        }
        .scrollContentBackground(.hidden)
        .background(RuyuanStyle.background)
        .navigationTitle("我的与设置")
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            serverEnabled = store.serverEnabled
            serverURL = store.serverURL
            serverToken = store.serverToken
        }
        .onChange(of: serverEnabled) { _, _ in saved = false }
        .onChange(of: serverURL) { _, _ in saved = false }
        .onChange(of: serverToken) { _, _ in saved = false }
        .sheet(isPresented: $showPrivacy) { privacySheet }
        .confirmationDialog("删除全部报告？", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除全部报告与照片", role: .destructive) { store.deleteAll() }
            Button("保留数据", role: .cancel) {}
        } message: {
            Text("本机的分析记录和关联照片将被删除，无法恢复。不会删除系统相册中的原照片。")
        }
        .alert("请检查服务端设置", isPresented: validationPresented) {
            Button("知道了", role: .cancel) { validationMessage = nil }
        } message: { Text(validationMessage ?? "") }
    }

    private func modelRow(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(RuyuanStyle.purple).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(RuyuanStyle.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var privacySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "hand.raised.square")
                        .font(.largeTitle.weight(.light)).foregroundStyle(RuyuanStyle.purple)
                    Text("你的面容，\n由你掌握。")
                        .font(.largeTitle.weight(.medium)).foregroundStyle(RuyuanStyle.ink)
                    privacyParagraph("你选择什么，我们才处理什么", "相机仅用于本次拍摄；相册选择器只将你主动选中的照片交给应用。不会扫描你的相册。")
                    privacyParagraph("默认本机处理", "本机分析使用 Apple Vision 获取面部特征与比例。报告及关联照片保存在应用的数据目录中。请妥善保护设备。")
                    privacyParagraph("上传需要你的选择", "只有开启并保存服务端设置后，照片才会用于指定服务器的分析。请核对服务地址、数据保留规则和访问权限；本地 HTTP 传输不加密。")
                    privacyParagraph("随时删除记录", "可单独删除报告，或在设置中删除全部报告与关联照片。服务端数据的删除以服务器实际处理结果为准；失败时请根据提示重试或联系服务管理者。")
                    privacyParagraph("理解能力的边界", "外观指标不是健康诊断，也不能确认皮肤疾病、年龄或治疗效果。演示分数仅说明界面如何工作；真实报告没有数据时保持为空。")
                }
                .padding(26)
            }
            .background(RuyuanStyle.background)
            .navigationTitle("隐私与使用说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showPrivacy = false } } }
        }
        .tint(RuyuanStyle.purple)
    }

    private func privacyParagraph(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline).foregroundStyle(RuyuanStyle.ink)
            Text(text).font(.subheadline).lineSpacing(5).foregroundStyle(RuyuanStyle.muted)
        }
    }

    private func saveSettings() {
        let trimmedURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if serverEnabled && !Self.isAllowedURL(trimmedURL) {
            validationMessage = "请输入有效的 HTTPS 地址，或你信任的本地网络 HTTP 地址（例如 http://192.168.1.10:8000）。"
            return
        }
        if serverEnabled && serverToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            validationMessage = "启用服务端分析需要填写访问令牌。请向服务管理者获取令牌后再保存。"
            return
        }
        store.serverEnabled = serverEnabled
        store.serverURL = trimmedURL
        store.serverToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = store.persistSettings()
    }

    private static func isAllowedURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        if url.scheme?.lowercased() == "https" { return !host.isEmpty }
        guard url.scheme?.lowercased() == "http" else { return false }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".local") { return true }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count == 4, labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return false }
        let parts = labels.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1])) || parts[0] == 127
    }

    private var validationPresented: Binding<Bool> {
        Binding(get: { validationMessage != nil }, set: { if !$0 { validationMessage = nil } })
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}
