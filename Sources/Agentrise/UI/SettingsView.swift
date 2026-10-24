import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var onSaved: () -> Void
    var onRanksSaved: () -> Void = {}
    @State private var installed = HookInstaller.isInstalled()
    @State private var preview: String?
    @State private var hookStatus = ""
    private let codexPresent = FileManager.default.fileExists(atPath: HookInstaller.codexHome().path)
    @AppStorage(HookInstaller.codexSeenKey) private var codexSeen = false
    @State private var codexInstalled = HookInstaller.codex.isInstalled()
    @State private var codexPreview: String?
    @State private var codexStatus = ""
    @State private var codexBusy = false
    @State private var askCodexTrust = false
    @State private var server = BarkConfig.load().server
    @State private var deviceKey = BarkConfig.load().deviceKey
    @State private var encKey = BarkConfig.load().encryptionKey
    @State private var iv = BarkConfig.load().iv
    @State private var away = BarkConfig.load().awayThreshold
    @State private var barkStatus = ""
    @State private var chime = DeskChime.enabled
    @State private var feishu = CCConnectIndex.enabled
    @State private var rankNames: [Rank: String] = Dictionary(uniqueKeysWithValues: Rank.ranksTopDown.map { ($0, RankBook.current.title($0)) })
    @State private var rankKeywords: [Rank: String] = Dictionary(uniqueKeysWithValues: Rank.ranksTopDown.map { ($0, RankBook.current.keywordText($0)) })
    @State private var rankStatus = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Agent 接入") {
                HStack {
                    Text("Claude Code")
                    Text(installed ? "✓ Hooks 已安装" : "Hooks 未安装").foregroundColor(installed ? .green : .orange)
                    Spacer()
                    if installed {
                        Button("卸载 Hooks") { run { try HookInstaller.uninstall(); hookStatus = "已卸载" } }
                    } else {
                        Button("安装 Hooks") { run { preview = try HookInstaller.preview() } }
                    }
                }
                if let p = preview {
                    Text("确认前请检查写入后的 settings.json：").font(.caption)
                    ScrollView { Text(p).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 180).border(.gray.opacity(0.3))
                    HStack {
                        Button("确认并写入") { run { let b = try HookInstaller.install(); hookStatus = "已安装" + (b.map { "，备份在 \($0.lastPathComponent)" } ?? ""); preview = nil } }
                        Button("取消") { preview = nil }
                    }
                }
                if !hookStatus.isEmpty { Text(hookStatus).font(.caption).foregroundColor(.secondary) }
                if codexPresent { codexRows }
            }
            .alert("Codex 要求信任这个 hook 才会运行。要我替你确认吗？", isPresented: $askCodexTrust) {
                Button("替我确认") { trustCodex() }
                Button("我自己来", role: .cancel) { codexStatus = Self.codexManualHint }
            }
            Section("iPhone 推送（Bark）") {
                TextField("服务器", text: $server)
                TextField("设备 Key（api.day.app/ 后面那段）", text: $deviceKey)
                TextField("加密 Key（与 Bark 加密设置里的 Key 相同，32 位）", text: $encKey)
                Stepper("离开判定：\(Int(away)) 秒无操作", value: $away, in: 30...1800, step: 30)
                HStack {
                    Button("保存") { save() }
                    Button("发送测试推送") {
                        save()
                        let cfg = BarkConfig.load()
                        barkStatus = "发送中…"
                        Task {
                            do { try await BarkClient.send(BarkMessage(body: "测试推送：Agentrise 已连上你的 iPhone"), config: cfg); barkStatus = "✓ 已发送，看看手机" }
                            catch { barkStatus = "发送失败：\(error.localizedDescription)" }
                        }
                    }
                    Text(barkStatus).font(.caption).foregroundColor(.secondary)
                }
            }
            Section("电脑提示音") {
                Toggle("会话做完了 / 等你回复 / 出错时，在电脑上响一声", isOn: $chime).onChange(of: chime) { _, on in DeskChime.enabled = on }
                HStack {
                    Text("试听：").foregroundColor(.secondary)
                    Button("做完了") { DeskChime.play(.done) }
                    Button("等你回复") { DeskChime.play(.waiting) }
                    Button("出错了") { DeskChime.play(.error) }
                }
            }
            Section("飞书（cc-connect）") {
                Toggle("识别 cc-connect 转发的飞书会话", isOn: $feishu).onChange(of: feishu) { _, on in CCConnectIndex.enabled = on }
            }
            ranksSection
            Section("其他") {
                Toggle("开机自动启动", isOn: $launchAtLogin).onChange(of: launchAtLogin) { _, on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }

    private static let newSessionNote = "新开一个 Codex 会话才会带上这个 hook，已经开着的会话不会。"
    private static let codexManualHint = "请在 Codex 里输入 /hooks，确认 Agentrise 的 hook。" + newSessionNote

    private var codexState: (text: String, color: Color) {
        if !codexInstalled { return ("未安装", .orange) }
        return codexSeen ? ("✓ 已生效", .green) : ("已安装待信任", .orange)
    }

    @ViewBuilder private var codexRows: some View {
        HStack {
            Text("Codex")
            Text(codexState.text).foregroundColor(codexState.color)
            Spacer()
            if codexInstalled {
                Button("卸载 Hook") { uninstallCodex() }.disabled(codexBusy)
            } else {
                Button("安装 Hook") { runCodex { codexPreview = try HookInstaller.previewCodex() } }.disabled(codexBusy)
            }
        }
        if let p = codexPreview {
            Text("确认前请检查写入后的 hooks.json：").font(.caption)
            ScrollView { Text(p).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 180).border(.gray.opacity(0.3))
            HStack {
                Button("确认并写入") {
                    runCodex {
                        let b = try HookInstaller.installCodex()
                        codexStatus = "已安装" + (b.map { "，备份在 \($0.lastPathComponent)" } ?? "")
                        codexPreview = nil
                        askCodexTrust = true
                    }
                }
                Button("取消") { codexPreview = nil }
            }
        }
        if !codexStatus.isEmpty { Text(codexStatus).font(.caption).foregroundColor(.secondary) }
    }

    /// Off the main thread: Codex's app-server can take a few seconds to start.
    private func trustCodex() {
        codexBusy = true
        codexStatus = "正在请 Codex 确认…"
        CodexAppServer.inBackground({ try $0.trustAgentriseHooks() }) { r in
            codexBusy = false
            switch r {
            case .success(let n): codexStatus = (n > 0 ? "✓ 已替你确认 \(n) 条 hook。" : "✓ Agentrise 的 hook 已经被信任。") + Self.newSessionNote
            case .failure: codexStatus = Self.codexManualHint
            }
        }
    }

    private func uninstallCodex() {
        guard runCodex({ try HookInstaller.codex.uninstall() }) else { return }
        codexSeen = false
        codexBusy = true
        codexStatus = "hook 已删除，正在清理信任记录…"
        CodexAppServer.inBackground({ try $0.untrustAgentriseHooks() }) { r in
            codexBusy = false
            switch r {
            case .success(let n): codexStatus = n > 0 ? "已卸载" : "hook 已删除。"
            case .failure(let error):
                if case CodexRPCError.binaryNotFound = error {
                    codexStatus = "hook 已删除；找不到 codex，信任记录留在 Codex 里，它们不再起作用。"
                } else {
                    codexStatus = "hook 已删除；信任记录没能清掉，它们不再起作用。"
                }
            }
        }
    }

    @discardableResult
    private func runCodex(_ f: () throws -> Void) -> Bool {
        defer { codexInstalled = HookInstaller.codex.isInstalled() }
        do { try f(); return true } catch { codexStatus = "失败：\(error.localizedDescription)"; return false }
    }

    private func save() {
        BarkConfig(server: server, deviceKey: deviceKey.trimmingCharacters(in: .whitespaces), encryptionKey: encKey, iv: iv, awayThreshold: away).save()
        onSaved()
    }

    private func keywordPrompt(_ r: Rank) -> String {
        r == .seniorEngineer ? "关键词（其余模型都算这档）" : "模型名包含的关键词，逗号分隔"
    }

    private func rankRow(_ r: Rank) -> some View {
        let name: Binding<String> = Binding(get: { rankNames[r] ?? "" }, set: { rankNames[r] = $0 })
        let words: Binding<String> = Binding(get: { rankKeywords[r] ?? "" }, set: { rankKeywords[r] = $0 })
        return HStack {
            TextField("名称", text: name).frame(width: 110)
            TextField(keywordPrompt(r), text: words).disabled(r == .seniorEngineer)
        }
    }

    private var ranksSection: some View {
        Section("模型职级") {
            ForEach(Rank.ranksTopDown, id: \.self) { r in rankRow(r) }
            Text("关键词不区分大小写；匹配顺序：资深总监、高级专家、校招生，都没匹配上的算高级工程师。").font(.caption).foregroundColor(.secondary)
            HStack {
                Button("保存") { saveRanks() }
                Text(rankStatus).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func saveRanks() {
        var book = RankBook.current
        for r in Rank.ranksTopDown { book.set(r, name: rankNames[r] ?? "", keywordText: rankKeywords[r] ?? "") }
        do {
            try book.save()
            RankBook.current = book
            for r in Rank.ranksTopDown { rankNames[r] = book.title(r); rankKeywords[r] = book.keywordText(r) }
            onRanksSaved()
            rankStatus = "✓ 已保存"
        } catch { rankStatus = "保存失败：\(error.localizedDescription)" }
    }

    private func run(_ f: () throws -> Void) {
        do { try f() } catch { hookStatus = "失败：\(error.localizedDescription)" }
        installed = HookInstaller.isInstalled()
    }
}
