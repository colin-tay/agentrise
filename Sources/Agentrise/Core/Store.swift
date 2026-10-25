// Copyright (c) 2026 Colin Tay
// SPDX-License-Identifier: MIT

import Foundation
import TowerKit

struct SessionContext {
    var title: String?
    var source: SessionSource?   // nil = hidden (headless run)
    var model: String?
    var agent: AgentKind = .claude
}

/// All of Agentrise's state rules. Pure: feed it events and the clock.
struct TowerStore {
    private(set) var sessions: [String: Session] = [:]
    private var nextTeam = 0

    static let sleepAfter: TimeInterval = 24 * 3600
    static let contractorTimeout: TimeInterval = 2 * 3600
    /// A stopped main whose background work has all finished is done if it stays quiet this long
    /// (it usually wakes up on the completion notice first and carries on).
    static let subsSettle: TimeInterval = 30
    /// Stop waiting for subs that never report back (a missed SubagentStop).
    static let subsGiveUp: TimeInterval = 2 * 3600
    /// A working or waiting session of an agent without a registry (and whose process we cannot watch)
    /// that sends nothing for this long has most likely died without a SessionEnd: stand it down.
    static let quietTimeout: TimeInterval = 60 * 60

    var counts: TowerCounts {
        var c = TowerCounts()
        for s in sessions.values where !s.isHidden {
            switch s.status {
            case .working, .error: c.working += 1
            case .waiting: c.waiting += 1
            case .done: c.done += 1
            case .sleeping: c.sleeping += 1
            case .standby: c.standby += 1
            }
            c.subs += s.subs.count
            c.contractors += s.contractors.count
        }
        return c
    }

    // MARK: Session creation and context

    @discardableResult
    mutating func ensure(_ id: String, context: SessionContext, now: Date,
                         status: SessionStatus = .standby, activity: Activity = .standby) -> Session {
        if let s = sessions[id] { return s }
        let s = Session(id: id, title: context.title ?? "会话", source: context.source ?? .terminal(bundleId: nil),
                        rank: Rank.from(model: context.model), status: status, activity: activity,
                        teamIndex: nextTeam, statusSince: now, lastActivityAt: now,
                        isHidden: context.source == nil, modelKnown: context.model != nil, model: context.model, agent: context.agent)
        nextTeam += 1
        sessions[id] = s
        return s
    }

    mutating func updateContext(_ id: String, context: SessionContext) {
        guard var s = sessions[id] else { return }
        if let t = context.title, !t.isEmpty { s.title = t }
        if let src = context.source { s.source = src; s.isHidden = false } else { s.isHidden = true }
        if let m = context.model { s.rank = Rank.from(model: m); s.modelKnown = true; s.model = m }
        sessions[id] = s
    }

    /// After the rank book changed: every session whose model we know gets its rank recomputed.
    mutating func rerank() {
        for (id, s) in sessions {
            guard let m = s.model else { continue }
            let r = Rank.from(model: m)
            if r != s.rank { sessions[id]?.rank = r }
        }
    }

    mutating func noteAgentPid(_ id: String, _ pid: Int32) { sessions[id]?.agentPid = pid }

    /// Sessions of agents without a registry leave the building once their own process has exited.
    mutating func removeExited(isRunning: (Int32) -> Bool) -> [TowerEffect] {
        var effects: [TowerEffect] = []
        for (id, s) in sessions where !s.capabilities.contains(.registry) {
            if let pid = s.agentPid, !isRunning(pid) { effects += remove(id) }
        }
        return effects
    }

    mutating func remove(_ id: String) -> [TowerEffect] {
        guard sessions.removeValue(forKey: id) != nil else { return [] }
        return [.sessionLeft(sessionId: id)]
    }

    // MARK: Events

    mutating func apply(_ e: TowerEvent, context: SessionContext) -> [TowerEffect] {
        let now = e.at
        if e.kind == .sessionEnded { return remove(e.sessionId) }
        ensure(e.sessionId, context: context, now: now, status: .working, activity: .thinking)
        updateContext(e.sessionId, context: context)
        guard var s = sessions[e.sessionId] else { return [] }
        if s.cwd == nil { s.cwd = e.cwd }
        if let t = e.transcriptPath { s.transcriptPath = t }
        s.lastActivityAt = now
        var effects: [TowerEffect] = []
        let before = s.status

        switch e.kind {
        // Something a subagent is doing: only that sub moves.
        case .subActivity(let id, let type, let activity):
            if var sub = s.subs[id] {
                sub.activity = activity
                s.subs[id] = sub
            } else {
                s.subs[id] = SubAgent(id: id, type: type, activity: activity, startedAt: now)
            }
            sessions[s.id] = s
            return effects
        case .subIdle(let id):
            s.subs[id]?.activity = .thinking
            sessions[s.id] = s
            return effects
        default:
            break
        }

        switch e.kind {
        case .sessionStarted(let fresh):
            if fresh { set(&s, .standby, .standby, now) }
        case .promptSubmitted:
            s.larkSent = false
            s.waitingSummary = nil
            set(&s, .working, .thinking, now)
        case .askedUser(let question):
            s.waitingSummary = question
            set(&s, .waiting, .waitingAtDoor, now)
        case .toolStarted(let act, let background):
            set(&s, .working, act, now)
            if act == .sendingLark { s.larkSent = true }
            if let c = background { s.contractors[c.id] = c }
        case .toolFinished:
            if s.status == .working { s.activity = .thinking }
        case .answeredUser:
            if s.status == .working { s.activity = .thinking }
            if s.status == .waiting { set(&s, .working, .thinking, now) }
        case .toolFailed(let interrupted):
            if !interrupted { s.transientErrorAt = now; s.activity = .commandFailed }
        case .turnEnded(let lastMessage, let backgroundSnapshot):
            if let snapshot = backgroundSnapshot {
                let live = Set(snapshot.filter { $0.status != "completed" && $0.status != "failed" && $0.status != "killed" }.map(\.id))
                for (id, _) in s.contractors where !live.contains(id) && !snapshot.contains(where: { $0.id == id }) {
                    // Not in the snapshot at all: assume finished.
                    s.contractors[id] = nil; s.contractorsDone += 1
                    effects.append(.contractorFinished(sessionId: s.id, contractorId: id))
                }
                for t in snapshot where t.type == "shell" || t.type == "monitor" || t.type == "workflow" {
                    if live.contains(t.id), s.contractors[t.id] == nil {
                        s.contractors[t.id] = Contractor(id: t.id, description: String(t.description.prefix(40)), startedAt: now)
                    } else if !live.contains(t.id), s.contractors[t.id] != nil {
                        s.contractors[t.id] = nil; s.contractorsDone += 1
                        effects.append(.contractorFinished(sessionId: s.id, contractorId: t.id))
                    }
                }
            }
            // Decided after the background snapshot, so the live subs and contractors are current.
            switch WaitingClassifier.classify(lastMessage) {
            case .waiting(let summary):
                s.waitingSummary = summary
                set(&s, .waiting, .waitingAtDoor, now)
            case .done:
                s.waitingSummary = nil
                // Background subs or commands still running: the turn ended, the work didn't.
                if s.subs.isEmpty && s.contractors.isEmpty { set(&s, .done, .resting, now) } else { set(&s, .working, .waitingForSubs, now) }
            }
        case .turnFailed(let error):
            s.waitingSummary = error.map { "出错：\($0)" }
            set(&s, .error, .commandFailed, now)
        case .needsAttention:
            set(&s, .waiting, .waitingAtDoor, now)
        case .interrupted:
            s.waitingSummary = nil
            // The turn is over; a sub that never reports back must not keep its robot or the "在岗" count.
            s.subs.removeAll()
            set(&s, .standby, .standby, now)
        case .subStarted(let id, let type):
            if let id { s.subs[id] = SubAgent(id: id, type: type, activity: .briefing, startedAt: now) }
            if s.status == .working { s.activity = .delegating }
        case .subFinished(let id, let lastMessage):
            if s.subs[id] != nil {
                s.subs[id] = nil
                let msg = (lastMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let ok = !msg.isEmpty && !msg.lowercased().hasPrefix("error")
                if ok { s.delivered += 1 } else { s.failedSubs += 1 }
                effects.append(.subFinished(sessionId: s.id, subId: id, success: ok))
            }
        case .compacting:
            s.activity = .compacting
        case .keepAlive, .sessionEnded, .subActivity, .subIdle:
            break
        }
        sessions[s.id] = s
        if before != s.status { effects.insert(.statusChanged(sessionId: s.id, from: before, to: s.status), at: 0) }
        return effects
    }

    private func set(_ s: inout Session, _ status: SessionStatus, _ activity: Activity, _ now: Date) {
        if s.status != status { s.statusSince = now }
        s.status = status
        s.activity = activity
    }

    // MARK: CEO actions and time

    mutating func markRead(_ id: String, now: Date) -> [TowerEffect] {
        guard var s = sessions[id] else { return [] }
        s.larkSent = false
        var effects: [TowerEffect] = []
        if s.status == .waiting || s.status == .done || s.status == .error || s.status == .sleeping {
            let from = s.status
            s.waitingSummary = nil
            set(&s, .standby, .standby, now)
            s.lastActivityAt = now
            effects.append(.statusChanged(sessionId: id, from: from, to: .standby))
        }
        sessions[id] = s
        return effects
    }

    mutating func tick(now: Date) -> [TowerEffect] {
        var effects: [TowerEffect] = []
        for (id, var s) in sessions {
            for (cid, c) in s.contractors where now.timeIntervalSince(c.startedAt) > Self.contractorTimeout {
                s.contractors[cid] = nil; s.contractorsDone += 1
                effects.append(.contractorFinished(sessionId: id, contractorId: cid))
            }
            if let t = s.transientErrorAt, now.timeIntervalSince(t) > 3 {
                s.transientErrorAt = nil
                if s.activity == .commandFailed, s.status == .working { s.activity = .thinking }
            }
            let idle = now.timeIntervalSince(s.lastActivityAt)
            if s.status == .working, s.activity == .waitingForSubs {
                let settled = s.subs.isEmpty && s.contractors.isEmpty && idle > Self.subsSettle
                if settled || idle > Self.subsGiveUp {
                    s.subs.removeAll(); s.contractors.removeAll()
                    set(&s, .done, .resting, now)
                    effects.append(.statusChanged(sessionId: id, from: .working, to: .done))
                }
            }
            if !s.capabilities.contains(.registry), s.agentPid == nil,
               s.status == .working || s.status == .waiting, idle > Self.quietTimeout {
                let from = s.status
                s.waitingSummary = nil
                s.subs.removeAll(); s.contractors.removeAll()
                set(&s, .standby, .standby, now)
                effects.append(.statusChanged(sessionId: id, from: from, to: .standby))
            }
            if s.status != .waiting, s.status != .sleeping, s.status != .working, idle > Self.sleepAfter {
                let from = s.status
                set(&s, .sleeping, .sleeping, now)
                effects.append(.statusChanged(sessionId: id, from: from, to: .sleeping))
            }
            sessions[id] = s
        }
        return effects
    }

    /// Seeds a session found in ~/.claude/sessions at launch, before any hook fired.
    mutating func seed(id: String, context: SessionContext, busy: Bool, lastActive: Date, now: Date) {
        guard sessions[id] == nil else { return }
        let asleep = now.timeIntervalSince(lastActive) > Self.sleepAfter
        let status: SessionStatus = busy ? .working : (asleep ? .sleeping : .standby)
        let act: Activity = busy ? .thinking : (asleep ? .sleeping : .standby)
        ensure(id, context: context, now: now, status: status, activity: act)
        sessions[id]?.lastActivityAt = lastActive
    }

    mutating func touchRegistry(_ id: String, now: Date) { sessions[id]?.lastSeenInRegistry = now }

    mutating func setStatusFromRegistry(_ id: String, busy: Bool, now: Date) -> [TowerEffect] {
        // The app was restarted mid-turn and missed the Stop: trust the registry's idle.
        guard var s = sessions[id], s.status == .working, !busy, now.timeIntervalSince(s.lastActivityAt) > 120 else { return [] }
        set(&s, .standby, .standby, now)
        sessions[id] = s
        return [.statusChanged(sessionId: id, from: .working, to: .standby)]
    }
}
