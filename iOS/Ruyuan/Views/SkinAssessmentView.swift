import SwiftUI

struct SkinAssessmentView: View {
    let onContinue: (SkinSelfAssessment?) -> Void
    var onCancel: () -> Void = {}
    @State private var dryness: Int?
    @State private var oiliness: Int?
    @State private var reactivity: Int?
    @State private var age = ""
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    Text("再了解一点你的日常肤感")
                        .font(.title2.bold()).foregroundStyle(RuyuanStyle.ink)
                    Text("3 个简单问题，帮助区分照片外观与真实使用感受。回答只保存在本机报告里。")
                        .font(.subheadline).foregroundStyle(RuyuanStyle.muted)
                    question("洗脸后，皮肤紧绷或干燥吗？", selection: $dryness, identifier: "dryness")
                    question("洗脸约两小时后，T 区明显出油吗？", selection: $oiliness, identifier: "oiliness")
                    question("日常护肤后，会刺痛或泛红吗？", selection: $reactivity, identifier: "reactivity")
                    HStack {
                        Text("实际年龄（可不填）").font(.subheadline)
                        Spacer()
                        TextField("12–100", text: $age).keyboardType(.numberPad).multilineTextAlignment(.trailing).frame(width: 95)
                    }.padding(16).background(.white,in:RoundedRectangle(cornerRadius:16))
                    Text("实际年龄是你填写的资料，不会改写为算法肤龄，也不生成无依据的同龄排名。")
                        .font(.caption).foregroundStyle(RuyuanStyle.muted)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    Button("开始检测") {
                        guard let dryness, let oiliness, let reactivity else { return }
                        let text = age.trimmingCharacters(in: .whitespaces)
                        let value = text.isEmpty ? nil : Int(text)
                        if !text.isEmpty && (value == nil || !(12...100).contains(value!)) { error = "年龄请填写 12–100 之间的整数，或留空。"; return }
                        onContinue(SkinSelfAssessment(dryness:dryness,oiliness:oiliness,reactivity:reactivity,age:value))
                    }.buttonStyle(RuyuanPrimaryButtonStyle()).disabled(dryness == nil || oiliness == nil || reactivity == nil)
                        .accessibilityIdentifier("assessmentContinue")
                    Button("跳过，只分析照片外观") { onContinue(nil) }
                        .font(.subheadline).foregroundStyle(RuyuanStyle.purple).frame(maxWidth:.infinity)
                }.padding(24)
            }.background(RuyuanStyle.background).navigationTitle("日常肤感").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.cancellationAction) { Button("取消",action:onCancel) } }
        }.interactiveDismissDisabled()
    }
    private func question(_ title:String, selection:Binding<Int?>, identifier:String) -> some View {
        VStack(alignment:.leading,spacing:12) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(RuyuanStyle.ink)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:9) {
                ForEach(0..<4) { index in
                    Button { selection.wrappedValue = index } label: {
                        Text(SkinSelfAssessment.frequency[index]).font(.subheadline)
                            .frame(maxWidth:.infinity).padding(.vertical,12)
                            .foregroundStyle(selection.wrappedValue == index ? .white:RuyuanStyle.purple)
                            .background(selection.wrappedValue == index ? RuyuanStyle.purple:.white,in:RoundedRectangle(cornerRadius:12))
                    }.buttonStyle(.plain).accessibilityIdentifier("assessment-\(identifier)-\(index)")
                }
            }
        }
    }
}
