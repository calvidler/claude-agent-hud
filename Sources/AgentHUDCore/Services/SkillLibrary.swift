import AppKit
import Foundation

// MARK: - Skill library

/// A folder of skills the user can drop into any project from a session's
/// right-click menu. Seeded with a few on first use; anything added to the
/// folder (one subfolder per skill, holding SKILL.md) shows up alongside.
enum SkillLibrary {
    static let folder = NSHomeDirectory() + "/Library/Application Support/Claude Agent HUD/skills"

    /// Skill names in the library, seeding the starter set if the folder is new.
    static func names() -> [String] {
        seedIfMissing()
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        return entries.filter { FileManager.default.fileExists(atPath: "\(folder)/\($0)/SKILL.md") }.sorted()
    }

    static func isInstalled(_ name: String, in cwd: String) -> Bool {
        FileManager.default.fileExists(atPath: "\(cwd)/.claude/skills/\(name)/SKILL.md")
    }

    /// Copies the skill's folder into the project's `.claude/skills`.
    static func install(_ name: String, into cwd: String) {
        let target = "\(cwd)/.claude/skills/\(name)"
        do {
            try FileManager.default.createDirectory(atPath: "\(cwd)/.claude/skills", withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: "\(folder)/\(name)", toPath: target)
            Notifier.post("Added /\(name) to \((cwd as NSString).lastPathComponent)")
        } catch {
            Notifier.post("Couldn't add /\(name): \(error.localizedDescription)")
        }
    }

    static func reveal() {
        seedIfMissing()
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder)
    }

    private static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: folder) else { return }
        for (name, body) in starters {
            let dir = "\(folder)/\(name)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? body.write(toFile: "\(dir)/SKILL.md", atomically: true, encoding: .utf8)
        }
    }

    private static let starters: [String: String] = [
        "verify": """
        ---
        name: verify
        description: Run the project's own checks on the current changes and show the evidence
        disable-model-invocation: true
        ---
        Verify the current uncommitted changes against the project's own checks.

        1. Work out which checks this project has (lint, typecheck, unit tests, build) from its package manifest, Makefile, or CLAUDE.md. Prefer running only the tests that cover the changed files.
        2. Run them. Do not skip or weaken a failing check.
        3. Report the exact commands and their real output, pass or fail. If something fails, fix the root cause and rerun; if you can't, say so plainly.
        """,
        "interview": """
        ---
        name: interview
        description: Interview me about a feature before any code is written
        disable-model-invocation: true
        ---
        I want to build: $ARGUMENTS

        Interview me in detail using the AskUserQuestion tool before writing any code. Ask about the technical approach, UI and UX, edge cases, failure states, and tradeoffs. Skip obvious questions; dig into the parts I probably haven't considered. Keep going until the design is settled, then write the agreed spec back to me in the conversation: files and interfaces involved, what is out of scope, and how we'll verify it end to end.
        """,
        "grill": """
        ---
        name: grill
        description: Challenge the current changes hard before they are trusted
        disable-model-invocation: true
        ---
        Grill me on the current uncommitted changes. Read the diff, then push back: what assumptions are unproven, which edge cases are unhandled, what would break under bad input, concurrency, or a failed dependency, and what a sceptical reviewer would refuse to merge. Ask me pointed questions where the intent is unclear. Do not fix anything yet; the output is the list of concerns, most serious first.
        """,
        "fresh-review": """
        ---
        name: fresh-review
        description: Review the current diff in a fresh subagent that only sees the diff and the criteria
        disable-model-invocation: true
        ---
        Use a subagent with fresh context to review the current uncommitted diff. Give it only the diff and these criteria: $ARGUMENTS

        The subagent must report gaps that affect correctness or the stated requirements: missing cases, broken invariants, changes outside the task's scope. Style preferences are not findings. Relay its findings to me, then fix the real ones and re-review until it reports none.
        """,
        "handoff": """
        ---
        name: handoff
        description: Write a short recap so a fresh session can pick this work up
        disable-model-invocation: true
        ---
        Write a handoff for a fresh session with no memory of this one: the goal, what is done, what is not, the files touched, the commands that verify the work, and the next step. Keep it to what a new session needs to continue without rereading this conversation. Print it here; do not create a file.
        """,
    ]
}
