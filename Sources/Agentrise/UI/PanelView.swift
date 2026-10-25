// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import SwiftUI

private let amber = Color(red: 1, green: 0.79, blue: 0.36)
private let green = Color(red: 0.44, green: 0.94, blue: 0.66)
private let ink = Color(red: 0.87, green: 0.9, blue: 1)
private let sub = Color(red: 0.56, green: 0.61, blue: 0.88)

/// "待处理 / 组织架构": a column in landscape, a strip in portrait.
struct PanelView: View {
    @ObservedObject var vm: TowerViewModel
    var onOpen: (String) -> Void
    var onHover: (String?) -> Void
    @State private var showSleepers = false

    var waiting: [Session] { vm.sessions.filter { $0.status == .waiting || $0.status == .error }.sorted { $0.statusSince < $1.statusSince } }
    var done: [Session] { vm.sessions.filter { $0.status == .done }.sorted { $0.statusSince > $1.statusSince } }
    var working: [Session] { vm.sessions.filter { $0.status == .working || $0.status == .standby } }
    var sleeping: [Session] { vm.sessions.filter { $0.status == .sleeping } }

    var body: some View {
        Group {
            if vm.orientation == .landscape { column } else { strip }
        }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Text(t).font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color(red: 0.2, green: 0.44, blue: 1)))
                    .padding(8)
            }
        }
    }

    private var column: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("待处理 / 组织架构").font(.system(size: 12, weight: .bold)).foregroundColor(.white).padding(.bottom, 2)
                if waiting.isEmpty && done.isEmpty {
                    Text("没有需要你处理的").font(.system(size: 11)).foregroundColor(sub)
                }
                ForEach(waiting, id: \.id) { s in card(s, color: s.status == .error ? .red : amber, icon: s.status == .error ? "⚠️" : "🙋",
                                                       detail: (s.waitingSummary ?? (s.status == .error ? "出错了" : "在等你回复")) + " · \(minutes(s))") }
                ForEach(done, id: \.id) { s in card(s, color: green, icon: "✓", detail: "做完了 · \(minutes(s))") }
                Text("干活中").font(.system(size: 10.5)).foregroundColor(sub).padding(.top, 6)
                ForEach(working, id: \.id) { s in row(s) }
                Button { showSleepers.toggle() } label: {
                    Text("🌙 睡眠舱 \(sleeping.count) \(showSleepers ? "▾" : "▸")").font(.system(size: 11)).foregroundColor(Color(red: 0.72, green: 0.69, blue: 1))
                }.buttonStyle(.plain).padding(.top, 6)
                if showSleepers { ForEach(sleeping, id: \.id) { s in row(s) } }
            }.padding(10)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.04, green: 0.055, blue: 0.15).opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(red: 0.23, green: 0.27, blue: 0.59)))
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if waiting.isEmpty && done.isEmpty {
                    Text("没有需要你处理的").font(.system(size: 11)).foregroundColor(sub).padding(.horizontal, 8)
                }
                ForEach(waiting, id: \.id) { s in card(s, color: s.status == .error ? .red : amber, icon: "🙋", detail: minutes(s)).frame(maxWidth: 220) }
                ForEach(done, id: \.id) { s in card(s, color: green, icon: "✓", detail: "做完了").frame(maxWidth: 200) }
            }.padding(6)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.04, green: 0.055, blue: 0.15).opacity(0.9)))
    }

    private func card(_ s: Session, color: Color, icon: String, detail: String) -> some View {
        Button { onOpen(s.id) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(icon)
                    Text(s.title).font(.system(size: 11.5, weight: .bold)).foregroundColor(ink).lineLimit(1)
                    if s.larkSent || s.isLark { lark }
                }
                Text(detail).font(.system(size: 10.5)).foregroundColor(sub).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { onHover($0 ? s.id : nil) }
    }

    private func row(_ s: Session) -> some View {
        Button { onOpen(s.id) } label: {
            HStack(spacing: 5) {
                Text(Team.glyph(s.teamIndex)).font(.system(size: 9, weight: .black)).foregroundColor(Color(red: 0.04, green: 0.06, blue: 0.15))
                    .frame(width: 14, height: 14).background(Circle().fill(Color(nsColor: Team.color(s.teamIndex))))
                Text(s.title).font(.system(size: 11, weight: .semibold)).foregroundColor(ink).lineLimit(1)
                if s.isLark || s.larkSent { lark }
                Spacer(minLength: 4)
                Text(Self.countsText(for: s))
                    .font(.system(size: 9.5)).foregroundColor(sub)
            }
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(vm.hovered == s.id ? Color(nsColor: Team.color(s.teamIndex)).opacity(0.2) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { onHover($0 ? s.id : nil) }
    }

    /// Right-hand text of a row; agents that cannot report contractors show no contractor count.
    static func countsText(for s: Session) -> String {
        if s.status == .standby { return "待命" }
        if s.status == .sleeping { return "睡觉" }
        let subs = "小弟 \(s.subs.count)"
        return s.capabilities.contains(.contractors) ? "\(subs) · 外包 \(s.contractors.count)" : subs
    }

    private var lark: some View {
        Text("飞").font(.system(size: 8.5, weight: .bold)).foregroundColor(.white).padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.2, green: 0.44, blue: 1)))
    }

    private func minutes(_ s: Session) -> String {
        let m = Int(Date().timeIntervalSince(s.statusSince) / 60)
        return m < 1 ? "刚刚" : m < 60 ? "\(m) 分钟" : "\(m / 60) 小时"
    }
}
