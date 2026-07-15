import { execFileSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { join } from "node:path"

const READ_ONLY_TOOL_NAMES = new Set([
  "read", "grep", "glob", "list", "ls", "find", "search", "webfetch", "websearch",
  "question", "todowrite", "todo", "view", "inspect", "fetch", "open",
])
const SHELL_TOOL_NAMES = new Set(["bash", "shell", "terminal", "run_command", "execute_command"])
const READ_ONLY_NAME_PREFIX = /^(read|get|list|search|find|query|status|inspect|fetch|open|view)(?:_|$)/i
const SHELL_MUTATION_MARKERS = />|(?:^|[\s|;&])(tee\b|set-content\b|add-content\b|out-file\b|remove-item\b|move-item\b|copy-item\b|new-item\b|apply_patch\b|git\s+(?:add|commit|checkout|switch|restore|reset|clean|rm|mv)\b|npm\s+(?:install|update|uninstall)\b)/i
const READ_ONLY_SHELL_COMMAND = /^(?:rg\b|grep\b|get-content\b|select-string\b|test-path\b|get-childitem\b|get-child-item\b|resolve-path\b|get-location\b|pwd\b|ls\b|dir\b|git\s+(?:status\b|diff\b|log\b|show\b|rev-parse\b|ls-files\b|branch\s+(?:--show-current|--list)\b)|node\s+--version\b|npm\s+view\b|kilo\s+debug\s+config\b)/i

export function isClearlyReadOnlyShell(command) {
  const text = String(command ?? "").trim()
  if (!text || SHELL_MUTATION_MARKERS.test(text)) return false
  const statements = text.split(/(?:\r?\n|;)/).map((item) => item.trim()).filter(Boolean)
  return statements.length > 0 && statements.every((item) => READ_ONLY_SHELL_COMMAND.test(item))
}

export function isPotentiallyMutatingTool(tool, args = {}) {
  const name = String(tool ?? "").toLowerCase()
  if (READ_ONLY_TOOL_NAMES.has(name) || READ_ONLY_NAME_PREFIX.test(name)) return false
  if (SHELL_TOOL_NAMES.has(name)) {
    return !isClearlyReadOnlyShell(args.command ?? args.cmd ?? args.script)
  }
  return true
}

export function buildDevelopmentContext(status) {
  const { branch, paths } = status
  return `ITL gate: ${branch} is the current Git branch name, not a directory. Changes under ${paths.exportPath} or ${paths.extensionsPath} require tests in ${paths.testsPath} and fresh passed /itl-check; quick-fix and XML-only are not exemptions.`
}

function readProjectPaths(root) {
  const defaults = { exportPath: "src/cf", extensionsPath: "src/cfe", testsPath: "tests/features" }
  try {
    const config = JSON.parse(readFileSync(join(root, ".agent-1c", "project.json"), "utf8").replace(/^\uFEFF/, ""))
    return {
      exportPath: String(config.exportPath || defaults.exportPath),
      extensionsPath: String(config.extensionsPath || defaults.extensionsPath),
      testsPath: String(config.testsPath || defaults.testsPath),
    }
  } catch {
    return defaults
  }
}

function readGitBranch(root) {
  return execFileSync("git", ["-C", root, "symbolic-ref", "--quiet", "--short", "HEAD"], {
    encoding: "utf8",
    windowsHide: true,
  }).trim()
}

function readCompletionStatus(root) {
  const powershell = process.platform === "win32" ? "powershell" : "pwsh"
  const helper = join(root, ".agents", "skills", "1c-workflow", "scripts", "agent-1c.ps1")
  const output = execFileSync(powershell, [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", helper,
    "-Action", "completion-gate-status", "-ProjectRoot", root,
  ], { encoding: "utf8", windowsHide: true, maxBuffer: 16 * 1024 * 1024 })
  return JSON.parse(output.trim().replace(/^\uFEFF/, ""))
}

export function createCompletionGateServer({ readBranch, readStatus, sendPrompt, log = async () => {} }) {
  const sessions = new Map()

  async function getSession(sessionID) {
    let state = sessions.get(sessionID)
    if (!state) {
      state = { branch: await readBranch(), armed: false, baseline: null, recoveryAttempts: 0, expectSynthetic: false }
      sessions.set(sessionID, state)
    }
    return state
  }

  async function recover(sessionID, state, current) {
    if (state.recoveryAttempts >= 2) {
      sessions.delete(sessionID)
      await log("error", "completion gate remained unresolved after two bounded recovery turns", { sessionID, branch: current.branch })
      return
    }

    const firstAttempt = state.recoveryAttempts === 0
    let prompt
    if (!current.isDevelopmentBranch) {
      prompt = firstAttempt
        ? `ITL_COMPLETION_GATE_BLOCKED: agent-made 1C source/test changes were detected on Git branch '${current.branch}', outside itldev/*. Do not report completion. Revert the changes or move the work to a proper development worktree; if that is impossible, report concise blocker diagnostics.`
        : `ITL_COMPLETION_GATE_BLOCKED: the branch-safety violation remains. Do not make more edits or claim completion; return concise blocker diagnostics now.`
    } else {
      prompt = firstAttempt
        ? `ITL_COMPLETION_GATE_BLOCKED: agent-made changes were detected after the baseline, but verification is ${current.status}. Add/update the relevant scenario in ${current.paths.testsPath}, run /itl-check after the final edits, and report the scenario plus Vanessa report path. If testing cannot be completed, report blocker diagnostics instead of ready/done/implemented.`
        : `ITL_COMPLETION_GATE_BLOCKED: verification is still ${current.status}. Do not claim completion. Return concise blocker diagnostics now, including why the required scenario or fresh passed /itl-check is unavailable.`
    }

    state.recoveryAttempts += 1
    state.expectSynthetic = true
    await sendPrompt(sessionID, prompt)
  }

  return {
    "chat.message": async (input, output) => {
      const existing = sessions.get(input.sessionID)
      if (existing?.expectSynthetic) {
        existing.expectSynthetic = false
        return
      }

      let branch = ""
      try {
        branch = await readBranch()
      } catch (error) {
        await log("error", "current Git branch could not be determined", { sessionID: input.sessionID, error: error.message })
      }
      const state = { branch, armed: false, baseline: null, recoveryAttempts: 0, expectSynthetic: false }
      sessions.set(input.sessionID, state)
      if (branch.startsWith("itldev/")) {
        const status = { branch, paths: readProjectPathsForContext() }
        const textPart = output.parts.find((part) => part.type === "text")
        if (textPart) {
          textPart.text = `${buildDevelopmentContext(status)}\n\n${textPart.text}`
        }
      }
    },

    "tool.execute.before": async (input, output) => {
      if (!isPotentiallyMutatingTool(input.tool, output.args)) return
      const state = await getSession(input.sessionID)
      if (!state.baseline) {
        try {
          state.baseline = await readStatus()
        } catch (error) {
          throw new Error(`ITL_COMPLETION_GATE_STATUS_FAILED: potential write blocked because baseline status is unavailable. ${error.message}`)
        }
      }
      state.armed = true
    },

    event: async ({ event }) => {
      if (event.type === "session.deleted") {
        sessions.delete(event.properties.sessionID)
        return
      }
      if (event.type !== "session.idle") return

      const sessionID = event.properties.sessionID
      const state = sessions.get(sessionID)
      if (!state?.armed || !state.baseline) return

      let current
      try {
        current = await readStatus()
      } catch (error) {
        current = {
          branch: state.branch,
          isDevelopmentBranch: state.branch.startsWith("itldev/"),
          status: "unavailable",
          paths: state.baseline.paths,
        }
        await log("error", "completion gate status failed at session idle", { sessionID, error: error.message })
      }

      if (current.currentFingerprint && current.currentFingerprint === state.baseline.currentFingerprint) {
        sessions.delete(sessionID)
        return
      }
      if (current.isDevelopmentBranch && current.freshPassed) {
        sessions.delete(sessionID)
        return
      }
      await recover(sessionID, state, current)
    },
  }

  function readProjectPathsForContext() {
    return readStatus.projectPaths ?? { exportPath: "src/cf", extensionsPath: "src/cfe", testsPath: "tests/features" }
  }
}

const server = async ({ client, worktree, directory }) => {
  const root = worktree || directory
  const projectPaths = readProjectPaths(root)
  const statusReader = () => readCompletionStatus(root)
  statusReader.projectPaths = projectPaths

  const log = async (level, message, extra = {}) => {
    try {
      await client.app.log({ body: { service: "itl-completion-gate", level, message, extra } })
    } catch {
      // Logging must never hide the gate result.
    }
  }
  const sendPrompt = async (sessionID, text) => {
    const result = await client.session.promptAsync({
      path: { id: sessionID },
      query: { directory: root },
      body: { parts: [{ type: "text", text }] },
    })
    if (result?.error) throw new Error(String(result.error))
  }

  return createCompletionGateServer({
    readBranch: () => readGitBranch(root),
    readStatus: statusReader,
    sendPrompt,
    log,
  })
}

export default { id: "itl-completion-gate", server }
