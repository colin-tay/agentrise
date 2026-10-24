import Foundation
import TowerKit

/// What happened in a session, in Agentrise's own words. Every agent's adapter translates its hook
/// events into these; `TowerStore` never sees an agent's tool or event names.
struct TowerEvent: Equatable {
    var sessionId: String
    var at: Date
    var cwd: String?
    var transcriptPath: String?
    var kind: Kind

    enum Kind: Equatable {
        case sessionStarted(fresh: Bool)
        case sessionEnded
        case promptSubmitted
        /// `background` already carries its id, description (≤40) and start time.
        case toolStarted(activity: Activity, background: Contractor?)
        case toolFinished
        case toolFailed(interrupted: Bool)
        /// Sets waitingSummary to `question`.
        case askedUser(question: String?)
        /// Waiting at the door without touching waitingSummary (Claude Code's Notification).
        case needsAttention
        /// Back to thinking while working; back to working from waiting.
        case answeredUser
        case turnEnded(lastMessage: String?, backgroundSnapshot: [BackgroundTaskInfo]?)
        case turnFailed(error: String?)
        /// Stands the session down (Claude Code never sends this).
        case interrupted
        case subStarted(id: String, type: String)
        case subFinished(id: String, lastMessage: String?)
        case subActivity(id: String, type: String, activity: Activity)
        case subIdle(id: String)
        case compacting
        /// Only the common prelude: create the session, refresh its context, bump lastActivityAt.
        case keepAlive
    }
}
