import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var onSaved: () -> Void
    @State private var installed = HookInstaller.isInstalled()
    @State private var preview: String?
    @State private var hookStatus = ""
    @State private var server = BarkConfig.load().server
    @State private var deviceKey = BarkConfig.load().deviceKey
    @State private var encKey = BarkConfig.load().encryptionKey
    @State private var iv = BarkConfig.load().iv
    @State private var away = BarkConfig.load().awayThreshold
    @State private var barkStatus = ""
    @State private var chime = DeskChime.enabled
    @State private var feishu = CCConnectIndex.enabled
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Claude Code Hooks") {
                HStack {
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

    private func save() {
        BarkConfig(server: server, deviceKey: deviceKey.trimmingCharacters(in: .whitespaces), encryptionKey: encKey, iv: iv, awayThreshold: away).save()
        onSaved()
    }

    private func run(_ f: () throws -> Void) {
        do { try f() } catch { hookStatus = "失败：\(error.localizedDescription)" }
        installed = HookInstaller.isInstalled()
    }
}
