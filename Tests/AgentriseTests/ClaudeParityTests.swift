import Foundation
import Testing
import TowerKit
@testable import Agentrise

/// A golden recording of how Claude Code events drive `TowerStore`. Recorded on the code before the
/// multi-agent adapter refactor; the refactor must keep reproducing it byte for byte.
/// Never re-record: `RECORD_PARITY=1` exists only for the very first recording.
enum ClaudeParity {
    enum Step {
        case event(SlimEvent, SessionContext)
        case tick(Date)
        case markRead(String, Date)
        case seed(String, SessionContext, busy: Bool, lastActive: Date, now: Date)
        case registryStatus(String, busy: Bool, now: Date)
        case touchRegistry(String, Date)
        case remove(String)
    }

    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// Scenarios that run with the Feishu bridge switched on; every other one runs with it off,
    /// so the recording never depends on the machine's own setting.
    static let bridgeOn: Set<String> = ["cc-connect-send"]

    /// Builds a scenario one second at a time: every event, tick or markRead moves the clock on by
    /// one second; `wait` jumps further.
    private struct Script {
        var sid: String
        var ctx: SessionContext
        var t: TimeInterval = 0
        var steps: [Step] = []

        init(_ sid: String, title: String = "主会话", source: SessionSource? = .desktop(hostSessionId: nil),
             model: String? = "claude-opus-5-5") {
            self.sid = sid
            self.ctx = SessionContext(title: title, source: source, model: model)
        }

        var now: Date { ClaudeParity.base + t }

        mutating func switchTo(_ sid: String, title: String, model: String?) {
            self.sid = sid
            ctx = SessionContext(title: title, source: .desktop(hostSessionId: nil), model: model)
        }

        mutating func wait(_ seconds: TimeInterval) { t += seconds }

        mutating func ev(_ name: HookEventName, agent: String? = nil, _ f: (inout SlimEvent) -> Void = { _ in }) {
            t += 1
            var e = SlimEvent(event: name, sessionId: sid, receivedAt: now)
            e.agentId = agent
            f(&e)
            steps.append(.event(e, ctx))
        }

        mutating func tick(after seconds: TimeInterval = 1) {
            t += seconds
            steps.append(.tick(now))
        }

        mutating func markRead() {
            t += 1
            steps.append(.markRead(sid, now))
        }

        /// `lastActive` is an offset from the step's own time (negative = in the past).
        mutating func seed(_ id: String, title: String = "种子", model: String? = nil, busy: Bool, lastActive: TimeInterval) {
            t += 1
            let c = SessionContext(title: title, source: .terminal(bundleId: nil), model: model)
            steps.append(.seed(id, c, busy: busy, lastActive: now + lastActive, now: now))
        }

        mutating func registryStatus(_ id: String, busy: Bool) {
            t += 1
            steps.append(.registryStatus(id, busy: busy, now: now))
        }

        mutating func touchRegistry(_ id: String) {
            t += 1
            steps.append(.touchRegistry(id, now))
        }

        mutating func remove(_ id: String) {
            t += 1
            steps.append(.remove(id))
        }
    }

    static let scenarios: [(name: String, steps: [Step])] = {
        var out: [(name: String, steps: [Step])] = []

        // An ordinary turn.
        var s = Script("cc-plain-turn")
        s.ev(.sessionStart) { $0.source = "startup"; $0.model = "claude-opus-5-5"; $0.cwd = "/work/demo" }
        s.ev(.userPromptSubmit) { $0.sessionTitle = "修一个 bug" }
        s.ev(.preToolUse) { $0.toolName = "Read"; $0.toolUseId = "t1" }
        s.ev(.postToolUse) { $0.toolName = "Read"; $0.toolUseId = "t1" }
        s.ev(.preToolUse) { $0.toolName = "Edit"; $0.toolUseId = "t2" }
        s.ev(.postToolUse) { $0.toolName = "Edit"; $0.toolUseId = "t2" }
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "swift test"; $0.toolUseId = "t3" }
        s.ev(.postToolUse) { $0.toolName = "Bash"; $0.toolUseId = "t3" }
        s.ev(.stop) { $0.lastAssistantMessage = "已完成" }
        out.append(("plain-turn", s.steps))

        // The agent asks through AskUserQuestion; the CEO answers.
        s = Script("cc-ask-user-question", model: "claude-haiku-4-5")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "AskUserQuestion"; $0.question = "用哪个方案？"; $0.toolUseId = "q1" }
        s.ev(.postToolUse) { $0.toolName = "AskUserQuestion"; $0.toolUseId = "q1" }
        s.ev(.stop) { $0.lastAssistantMessage = "按你选的方案改好了。" }
        out.append(("ask-user-question", s.steps))

        // A permission prompt, and a notification that is not a call for the CEO.
        s = Script("cc-notification-permission", source: .terminal(bundleId: "com.apple.Terminal"))
        s.ev(.userPromptSubmit)
        s.ev(.notification) { $0.notificationType = "idle_prompt" }
        s.ev(.notification) { $0.notificationType = "permission_prompt" }
        s.ev(.postToolUse) { $0.toolName = "Bash" }
        s.ev(.stop) { $0.lastAssistantMessage = "搞定了。" }
        out.append(("notification-permission", s.steps))

        // A turn whose last words ask the CEO something.
        s = Script("cc-stop-asks-question", model: "claude-fable-1")
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "两种做法都可行。\n\n要不要我先改接口层？" }
        s.markRead()
        out.append(("stop-asks-question", s.steps))

        // A background Bash, then a Stop with a snapshot: one running, one completed, one missing.
        s = Script("cc-background-bash")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "npm run dev -- --host 0.0.0.0 --port 5173 --open"; $0.runInBackground = true; $0.toolUseId = "b1" }
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "swift build"; $0.runInBackground = true; $0.toolUseId = "b2" }
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.toolDescription = "tail the log"; $0.runInBackground = true; $0.toolUseId = "b3" }
        s.ev(.stop) {
            $0.lastAssistantMessage = "几个后台任务在跑。"
            $0.backgroundTasks = [
                BackgroundTaskInfo(id: "b1", type: "shell", status: "running", description: "dev server"),
                BackgroundTaskInfo(id: "b2", type: "shell", status: "completed", description: "build"),
            ]
        }
        s.tick()
        out.append(("background-bash", s.steps))

        // Subagents: one succeeds, one comes back empty, one reports an error.
        s = Script("cc-subagents")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1") { $0.agentType = "general-purpose" }
        s.ev(.preToolUse, agent: "a1") { $0.toolName = "Grep"; $0.agentType = "general-purpose" }
        s.ev(.postToolUse, agent: "a1") { $0.toolName = "Grep" }
        s.ev(.subagentStart, agent: "a2") { $0.agentType = "Explore" }
        s.ev(.preToolUse, agent: "a3") { $0.toolName = "Read"; $0.agentType = "Explore" }   // never announced
        s.ev(.subagentStop, agent: "a1") { $0.lastAssistantMessage = "找到了三处调用。" }
        s.ev(.subagentStop, agent: "a2") { $0.lastAssistantMessage = "" }
        s.ev(.subagentStop, agent: "a3") { $0.lastAssistantMessage = "Error: could not read the file" }
        s.ev(.subagentStop, agent: "ghost") { $0.lastAssistantMessage = "unknown sub" }
        s.ev(.stop) { $0.lastAssistantMessage = "小弟们都回来了。" }
        out.append(("subagents", s.steps))

        // A stop with a live sub waits; the sub reports back and the boss settles.
        s = Script("cc-stop-with-live-sub")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1") { $0.agentType = "general-purpose" }
        s.ev(.preToolUse, agent: "a1") { $0.toolName = "Grep" }
        s.ev(.stop) { $0.lastAssistantMessage = "统计交给后台的小弟了。" }
        s.tick(after: 5)
        s.wait(20)
        s.ev(.subagentStop, agent: "a1") { $0.lastAssistantMessage = "统计完了" }
        s.tick(after: TowerStore.subsSettle - 1)
        s.tick(after: 2)
        out.append(("stop-with-live-sub", s.steps))

        // The sub never reports: the boss gives up after subsGiveUp.
        s = Script("cc-sub-never-reports")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1")
        s.ev(.stop) { $0.lastAssistantMessage = "交给小弟了。" }
        s.tick(after: TowerStore.subsGiveUp - 10)
        s.tick(after: 20)
        out.append(("sub-never-reports", s.steps))

        // The main wakes on the sub's notice before the settle time runs out.
        s = Script("cc-main-resumes-after-sub")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1")
        s.ev(.stop) { $0.lastAssistantMessage = "后台跑着。" }
        s.ev(.subagentStop, agent: "a1") { $0.lastAssistantMessage = "done" }
        s.ev(.preToolUse) { $0.toolName = "Read" }
        s.tick(after: TowerStore.subsSettle + 1)
        s.ev(.stop) { $0.lastAssistantMessage = "汇总好了。" }
        out.append(("main-resumes-after-sub", s.steps))

        // Tool failures: an interrupt, then a real failure that clears three seconds later.
        s = Script("cc-tool-failure")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "make" }
        s.ev(.postToolUseFailure) { $0.toolName = "Bash"; $0.isInterrupt = true; $0.error = "interrupted" }
        s.tick(after: 4)
        s.ev(.postToolUseFailure) { $0.toolName = "Bash"; $0.isInterrupt = false; $0.error = "exit 2" }
        s.tick(after: 2)
        s.tick(after: 2)
        out.append(("tool-failure", s.steps))

        // The turn dies with an API error.
        s = Script("cc-stop-failure")
        s.ev(.userPromptSubmit)
        s.ev(.stopFailure) { $0.error = "rate_limit" }
        s.markRead()
        out.append(("stop-failure", s.steps))

        // Compaction.
        s = Script("cc-pre-compact")
        s.ev(.userPromptSubmit)
        s.ev(.preCompact)
        s.ev(.postToolUse) { $0.toolName = "Read" }
        s.ev(.stop) { $0.lastAssistantMessage = "整理完了。" }
        out.append(("pre-compact", s.steps))

        // SessionStart with source startup, resume, and clear.
        s = Script("cc-session-start", model: nil)
        s.ev(.sessionStart) { $0.source = "startup" }
        s.ev(.userPromptSubmit)
        s.ev(.sessionStart) { $0.source = "resume"; $0.model = "claude-opus-5-5" }
        s.ev(.sessionStart) { $0.source = "clear" }
        out.append(("session-start", s.steps))

        // Headless runs stay hidden.
        s = Script("cc-headless", title: "headless", source: nil)
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "ok" }
        out.append(("headless", s.steps))

        // cc-connect send, Feishu bridge on.
        s = Script("cc-connect-send", title: "飞书会话 1", source: .lark)
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "cc-connect send -m 'hello'"; $0.toolUseId = "l1" }
        s.ev(.postToolUse) { $0.toolName = "Bash"; $0.toolUseId = "l1" }
        s.ev(.stop) { $0.lastAssistantMessage = "已发飞书。" }
        s.markRead()
        s.ev(.userPromptSubmit)
        out.append(("cc-connect-send", s.steps))

        // The same command with the bridge off is just a command.
        s = Script("cc-connect-off")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "cc-connect send -m 'hello'" }
        s.ev(.stop) { $0.lastAssistantMessage = "好了。" }
        out.append(("cc-connect-off", s.steps))

        // The CEO reads a finished turn.
        s = Script("cc-mark-read")
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "完成。" }
        s.markRead()
        s.markRead()
        out.append(("mark-read", s.steps))

        // A day of silence puts a finished session to sleep.
        s = Script("cc-sleep")
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "完成。" }
        s.tick(after: TowerStore.sleepAfter - 10)
        s.tick(after: 20)
        s.ev(.userPromptSubmit)
        out.append(("sleep", s.steps))

        // Two sessions in one store take team indices in creation order.
        s = Script("cc-team-a", title: "甲")
        s.ev(.userPromptSubmit)
        s.switchTo("cc-team-b", title: "乙", model: "claude-haiku-4-5")
        s.ev(.userPromptSubmit)
        s.switchTo("cc-team-a", title: "甲", model: "claude-opus-5-5")
        s.ev(.stop) { $0.lastAssistantMessage = "完成。" }
        s.switchTo("cc-team-b", title: "乙", model: "claude-haiku-4-5")
        s.ev(.stop) { $0.lastAssistantMessage = "要不要继续？" }
        out.append(("two-teams", s.steps))

        // cwd and transcriptPath: cwd is first-wins, transcriptPath is last-wins; nil never clears.
        s = Script("cc-cwd-transcript")
        s.ev(.userPromptSubmit) { $0.cwd = "/work/first"; $0.transcriptPath = "/t/one.jsonl" }
        s.ev(.preToolUse) { $0.toolName = "Read"; $0.cwd = "/work/second"; $0.transcriptPath = "/t/two.jsonl" }
        s.ev(.postToolUse) { $0.toolName = "Read" }
        s.ev(.stop) { $0.lastAssistantMessage = "好了。"; $0.cwd = "/work/third" }
        out.append(("cwd-transcript", s.steps))

        // The context handed in with each event updates title, source, model and visibility.
        s = Script("cc-context-updates", title: "原标题", source: .desktop(hostSessionId: "host-1"), model: nil)
        s.ev(.userPromptSubmit)
        s.ctx = SessionContext(title: "", source: .terminal(bundleId: "com.apple.Terminal"), model: "claude-fable-1")
        s.ev(.preToolUse) { $0.toolName = "Read" }
        s.ctx = SessionContext(title: "新标题", source: nil, model: nil)
        s.ev(.postToolUse) { $0.toolName = "Read" }
        s.ctx = SessionContext(title: nil, source: .lark, model: "claude-haiku-4-5")
        s.ev(.stop) { $0.lastAssistantMessage = "完成。" }
        s.ctx = SessionContext(title: "回桌面", source: .desktop(hostSessionId: nil), model: "claude-sonnet-4-5")
        s.ev(.userPromptSubmit)
        out.append(("context-updates", s.steps))

        // A live background command is expired by tick after contractorTimeout.
        s = Script("cc-contractor-timeout")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "tail -f /var/log/system.log"; $0.runInBackground = true; $0.toolUseId = "b1" }
        s.tick(after: TowerStore.contractorTimeout - 1)
        s.tick(after: 2)
        out.append(("contractor-timeout", s.steps))

        // The boss stopped while the command ran; the timeout lets it settle to done.
        s = Script("cc-contractor-timeout-waiting")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "sleep 99999"; $0.runInBackground = true; $0.toolUseId = "b1" }
        s.ev(.stop) { $0.lastAssistantMessage = "命令在后台跑。" }
        s.tick(after: TowerStore.contractorTimeout - 5)
        s.tick(after: 10)
        out.append(("contractor-timeout-waiting", s.steps))

        // A Stop snapshot adds contractors never seen through PreToolUse, then retires them by status.
        s = Script("cc-snapshot-adds-contractors")
        s.ev(.userPromptSubmit)
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "make watch"; $0.runInBackground = true; $0.toolUseId = "b9" }
        s.ev(.stop) {
            $0.lastAssistantMessage = "后台有几个任务。"
            $0.backgroundTasks = [
                BackgroundTaskInfo(id: "c1", type: "shell", status: "running", description: "tail the production log and grep for errors forever"),
                BackgroundTaskInfo(id: "c2", type: "monitor", status: "running", description: "monitor the deploy"),
                BackgroundTaskInfo(id: "c3", type: "workflow", status: "running", description: "nightly workflow"),
                BackgroundTaskInfo(id: "c4", type: "agent", status: "running", description: "an agent task is not a contractor"),
                BackgroundTaskInfo(id: "b9", type: "agent", status: "completed", description: "same id, ignored type"),
            ]
        }
        s.ev(.userPromptSubmit)
        s.ev(.stop) {
            $0.lastAssistantMessage = "再看一眼。"
            $0.backgroundTasks = [
                BackgroundTaskInfo(id: "c1", type: "shell", status: "failed", description: "tail"),
                BackgroundTaskInfo(id: "c2", type: "monitor", status: "killed", description: "monitor"),
                BackgroundTaskInfo(id: "c3", type: "workflow", status: "completed", description: "workflow"),
                BackgroundTaskInfo(id: "c4", type: "agent", status: "running", description: "agent"),
            ]
        }
        out.append(("snapshot-adds-contractors", s.steps))

        // A question wins over live subs and contractors.
        s = Script("cc-question-with-live-subs")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1") { $0.agentType = "general-purpose" }
        s.ev(.preToolUse) { $0.toolName = "Bash"; $0.command = "npm run watch"; $0.runInBackground = true; $0.toolUseId = "b1" }
        s.ev(.stop) { $0.lastAssistantMessage = "小弟在查。你希望我先出方案吗？" }
        s.ev(.subagentStop, agent: "a1") { $0.lastAssistantMessage = "查完了" }
        s.tick(after: TowerStore.subsSettle + 5)
        s.markRead()
        out.append(("question-with-live-subs", s.steps))

        // Sleep guards in tick: working and waiting sessions never sleep.
        s = Script("cc-sleep-guard-working")
        s.ev(.userPromptSubmit)
        s.tick(after: TowerStore.sleepAfter + 10)
        out.append(("sleep-guard-working", s.steps))

        s = Script("cc-sleep-guard-waiting")
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "要不要继续？" }
        s.tick(after: TowerStore.sleepAfter + 10)
        out.append(("sleep-guard-waiting", s.steps))

        // ...but standby and error sessions do.
        s = Script("cc-sleep-standby")
        s.ev(.sessionStart) { $0.source = "startup" }
        s.tick(after: TowerStore.sleepAfter - 10)
        s.tick(after: 20)
        out.append(("sleep-standby", s.steps))

        s = Script("cc-sleep-error")
        s.ev(.userPromptSubmit)
        s.ev(.stopFailure) { $0.error = "overloaded" }
        s.tick(after: TowerStore.sleepAfter - 10)
        s.tick(after: 20)
        out.append(("sleep-error", s.steps))

        // A stop that waits for a sub forever: give-up and sleep happen in the same tick.
        s = Script("cc-sleep-after-give-up")
        s.ev(.userPromptSubmit)
        s.ev(.subagentStart, agent: "a1")
        s.ev(.stop) { $0.lastAssistantMessage = "交给小弟。" }
        s.tick(after: TowerStore.sleepAfter + 10)
        out.append(("sleep-after-give-up", s.steps))

        // Every notification type that calls for the CEO, and two that do not.
        s = Script("cc-notification-types")
        s.ev(.userPromptSubmit)
        s.ev(.notification) { $0.notificationType = "permission_prompt" }
        s.ev(.userPromptSubmit)
        s.ev(.notification) { $0.notificationType = "elicitation_dialog" }
        s.ev(.userPromptSubmit)
        s.ev(.notification) { $0.notificationType = "agent_needs_input" }
        s.ev(.userPromptSubmit)
        s.ev(.notification) { $0.notificationType = "idle_prompt" }
        s.ev(.notification) { $0.notificationType = "auth_success" }
        s.ev(.notification)
        out.append(("notification-types", s.steps))

        // SubagentStart while the boss is not working leaves the boss's activity alone.
        s = Script("cc-sub-start-not-working")
        s.ev(.sessionStart) { $0.source = "startup" }
        s.ev(.subagentStart, agent: "a1") { $0.agentType = "general-purpose" }
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "要不要先看看？" }
        s.ev(.subagentStart, agent: "a2") { $0.agentType = "Explore" }
        out.append(("sub-start-not-working", s.steps))

        // seed, touchRegistry, setStatusFromRegistry and remove.
        s = Script("cc-registry")
        s.seed("cc-seed-busy", title: "忙", model: "claude-opus-5-5", busy: true, lastActive: -200)
        s.seed("cc-seed-busy-fresh", title: "刚忙", busy: true, lastActive: -60)
        s.seed("cc-seed-idle", title: "闲", model: "claude-haiku-4-5", busy: false, lastActive: -100)
        s.seed("cc-seed-asleep", title: "睡", busy: false, lastActive: -(TowerStore.sleepAfter + 5))
        s.seed("cc-seed-asleep-busy", title: "睡但忙", busy: true, lastActive: -(TowerStore.sleepAfter + 5))
        s.ev(.userPromptSubmit)   // cc-registry itself, working
        s.seed("cc-registry", title: "已存在", busy: false, lastActive: -1)   // no-op: already there
        s.touchRegistry("cc-seed-idle")
        s.touchRegistry("cc-nobody")
        s.registryStatus("cc-seed-busy-fresh", busy: false)   // within 120s: stays
        s.registryStatus("cc-seed-busy", busy: true)          // still busy: stays
        s.registryStatus("cc-seed-idle", busy: false)         // not working: stays
        s.registryStatus("cc-nobody", busy: false)
        s.registryStatus("cc-seed-busy", busy: false)         // idle >120s: flips to standby
        s.remove("cc-nobody")
        s.remove("cc-seed-idle")
        out.append(("registry", s.steps))

        // The session ends.
        s = Script("cc-session-end")
        s.ev(.userPromptSubmit)
        s.ev(.stop) { $0.lastAssistantMessage = "完成。" }
        s.ev(.sessionEnd)
        s.ev(.sessionEnd)
        out.append(("session-end", s.steps))

        return out
    }()

    // MARK: Rendering

    private static func stamp(_ d: Date) -> String { String(Int(d.timeIntervalSince1970)) }
    private static func opt(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "nil" }

    private static func describe(source: SessionSource) -> String {
        switch source {
        case .desktop(let host): return "desktop(host=\(opt(host)))"
        case .lark: return "lark"
        case .terminal(let bundle): return "terminal(bundle=\(opt(bundle)))"
        }
    }

    private static func describe(_ step: Step) -> String {
        switch step {
        case .event(let e, let ctx):
            var parts = ["event", e.event.rawValue, "session=\(e.sessionId)", "t=\(stamp(e.receivedAt))"]
            if let v = e.agentId { parts.append("agentId=\(v)") }
            if let v = e.agentType { parts.append("agentType=\(v)") }
            if let v = e.toolName { parts.append("tool=\(v)") }
            if let v = e.toolUseId { parts.append("toolUseId=\(v)") }
            if let v = e.command { parts.append("command=\(opt(v))") }
            if let v = e.runInBackground { parts.append("runInBackground=\(v)") }
            if let v = e.toolDescription { parts.append("toolDescription=\(opt(v))") }
            if let v = e.question { parts.append("question=\(opt(v))") }
            if let v = e.lastAssistantMessage { parts.append("lastAssistantMessage=\(opt(v))") }
            if let v = e.backgroundTasks {
                parts.append("backgroundTasks=[" + v.map { "\($0.id):\($0.type):\($0.status):\(opt($0.description))" }.joined(separator: ";") + "]")
            }
            if let v = e.notificationType { parts.append("notificationType=\(v)") }
            if let v = e.error { parts.append("error=\(opt(v))") }
            if let v = e.isInterrupt { parts.append("isInterrupt=\(v)") }
            if let v = e.model { parts.append("model=\(v)") }
            if let v = e.source { parts.append("source=\(v)") }
            if let v = e.cwd { parts.append("cwd=\(opt(v))") }
            if let v = e.transcriptPath { parts.append("transcriptPath=\(opt(v))") }
            let src = ctx.source.map { describe(source: $0) } ?? "nil"
            parts.append("ctx(title=\(opt(ctx.title)) source=\(src) model=\(opt(ctx.model)))")
            return parts.joined(separator: " ")
        case .tick(let d): return "tick t=\(stamp(d))"
        case .markRead(let id, let d): return "markRead session=\(id) t=\(stamp(d))"
        case .seed(let id, let ctx, let busy, let lastActive, let now):
            let src = ctx.source.map { describe(source: $0) } ?? "nil"
            return "seed session=\(id) busy=\(busy) lastActive=\(stamp(lastActive)) t=\(stamp(now)) ctx(title=\(opt(ctx.title)) source=\(src) model=\(opt(ctx.model)))"
        case .registryStatus(let id, let busy, let now): return "setStatusFromRegistry session=\(id) busy=\(busy) t=\(stamp(now))"
        case .touchRegistry(let id, let now): return "touchRegistry session=\(id) t=\(stamp(now))"
        case .remove(let id): return "remove session=\(id)"
        }
    }

    static func render(_ store: TowerStore, _ effects: [TowerEffect]) -> String {
        var lines = ["effects: " + String(describing: effects)]
        let c = store.counts
        lines.append("counts working=\(c.working) waiting=\(c.waiting) done=\(c.done) subs=\(c.subs) contractors=\(c.contractors) sleeping=\(c.sleeping) standby=\(c.standby)")
        for id in store.sessions.keys.sorted() {
            let s = store.sessions[id]!
            let subs = s.subs.keys.sorted().map {
                let x = s.subs[$0]!
                return "\($0):\(x.activity.rawValue)@\(stamp(x.startedAt))/type=\(opt(x.type))"
            }.joined(separator: ";")
            let contractors = s.contractors.keys.sorted().map {
                let x = s.contractors[$0]!
                return "\($0):\(x.description)@\(stamp(x.startedAt))"
            }.joined(separator: ";")
            lines.append([
                "session \(s.id)",
                "status=\(s.status.rawValue)",
                "activity=\(s.activity.rawValue)",
                "title=\(s.title)",
                "rank=\(s.rank.rawValue)",
                "subs=[\(subs)]",
                "contractors=[\(contractors)]",
                "delivered=\(s.delivered)",
                "failedSubs=\(s.failedSubs)",
                "contractorsDone=\(s.contractorsDone)",
                "larkSent=\(s.larkSent)",
                "waitingSummary=\(s.waitingSummary ?? "nil")",
                "statusSince=\(stamp(s.statusSince))",
                "lastActivityAt=\(stamp(s.lastActivityAt))",
                "teamIndex=\(s.teamIndex)",
                "isHidden=\(s.isHidden)",
                "source=\(describe(source: s.source))",
                "modelKnown=\(s.modelKnown)",
                "cwd=\(opt(s.cwd))",
                "transcriptPath=\(opt(s.transcriptPath))",
                "transientErrorAt=\(s.transientErrorAt.map(stamp) ?? "nil")",
                "lastSeenInRegistry=\(s.lastSeenInRegistry.map(stamp) ?? "nil")",
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    /// Runs every scenario on a fresh store and concatenates the renderings.
    static func runAll() -> String {
        let saved = CCConnectIndex.enabled
        defer { CCConnectIndex.enabled = saved }
        var out = ""
        for (name, steps) in scenarios {
            CCConnectIndex.enabled = bridgeOn.contains(name)
            var store = TowerStore()
            out += "== \(name) ==\n"
            for (i, step) in steps.enumerated() {
                let effects: [TowerEffect]
                switch step {
                case .event(let e, let ctx): effects = store.apply(e, context: ctx)
                case .tick(let now): effects = store.tick(now: now)
                case .markRead(let id, let now): effects = store.markRead(id, now: now)
                case .seed(let id, let ctx, let busy, let lastActive, let now):
                    store.seed(id: id, context: ctx, busy: busy, lastActive: lastActive, now: now); effects = []
                case .registryStatus(let id, let busy, let now): effects = store.setStatusFromRegistry(id, busy: busy, now: now)
                case .touchRegistry(let id, let now): store.touchRegistry(id, now: now); effects = []
                case .remove(let id): effects = store.remove(id)
                }
                out += "-- \(i + 1) \(describe(step))\n" + render(store, effects) + "\n"
            }
            out += "\n"
        }
        return out
    }
}

@Suite struct ClaudeParityTests {
    @Test func claudeBehaviourMatchesRecording() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/claude-parity.txt")
        let actual = ClaudeParity.runAll()
        if ProcessInfo.processInfo.environment["RECORD_PARITY"] == "1" {
            try actual.write(to: url, atomically: true, encoding: .utf8); return
        }
        #expect(actual == (try String(contentsOf: url, encoding: .utf8)))
    }
}
