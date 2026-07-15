import assert from "node:assert/strict"
import {
  buildDevelopmentContext,
  createCompletionGateServer,
  isClearlyReadOnlyShell,
  isPotentiallyMutatingTool,
} from "../../.agents/skills/1c-workflow/kilo-plugin/itl-completion-gate.js"

const paths = { exportPath: "src/cf", extensionsPath: "src/cfe", testsPath: "tests/features" }
const dev = (fingerprint, freshPassed = false, status = freshPassed ? "passed" : "stale") => ({
  branch: "itldev/demo", isDevelopmentBranch: true, currentFingerprint: fingerprint,
  freshPassed, status, paths,
})
const master = (fingerprint) => ({
  branch: "master", isDevelopmentBranch: false, currentFingerprint: fingerprint,
  freshPassed: false, status: "missing", paths,
})

function createHarness(statuses, branch = "itldev/demo") {
  let statusCalls = 0
  const prompts = []
  const logs = []
  const readStatus = async () => {
    const value = statuses[Math.min(statusCalls, statuses.length - 1)]
    statusCalls += 1
    if (value instanceof Error) throw value
    return value
  }
  readStatus.projectPaths = paths
  const hooks = createCompletionGateServer({
    readBranch: async () => branch,
    readStatus,
    sendPrompt: async (sessionID, text) => prompts.push({ sessionID, text }),
    log: async (level, message, extra) => logs.push({ level, message, extra }),
  })
  return { hooks, prompts, logs, get statusCalls() { return statusCalls } }
}

async function userTurn(harness, sessionID = "s1") {
  const output = { parts: [] }
  await harness.hooks["chat.message"]({ sessionID }, output)
  return output
}

async function idle(harness, sessionID = "s1") {
  await harness.hooks.event({ event: { type: "session.idle", properties: { sessionID } } })
}

assert.equal(isClearlyReadOnlyShell("rg -n gate ."), true)
assert.equal(isClearlyReadOnlyShell("git status --short"), true)
assert.equal(isClearlyReadOnlyShell("Set-Content src/cf/a.xml x"), false)
assert.equal(isPotentiallyMutatingTool("read", {}), false)
assert.equal(isPotentiallyMutatingTool("bash", { command: "rg -n gate ." }), false)
assert.equal(isPotentiallyMutatingTool("apply_patch", {}), true)

{
  const harness = createHarness([dev("A")])
  const output = await userTurn(harness)
  assert.equal(harness.statusCalls, 0, "chat context must not calculate a fingerprint")
  assert.match(output.parts[0].text, /Git branch name, not a directory/)
  assert.ok(Math.ceil(Buffer.byteLength(output.parts[0].text, "utf8") / 4) <= 80)
  await harness.hooks["tool.execute.before"]({ tool: "bash", sessionID: "s1" }, { args: { command: "rg -n gate ." } })
  await idle(harness)
  assert.equal(harness.statusCalls, 0, "read-only turns must not calculate a fingerprint")
}

{
  const harness = createHarness([dev("A"), dev("A")])
  await userTurn(harness)
  await harness.hooks["tool.execute.before"]({ tool: "apply_patch", sessionID: "s1" }, { args: {} })
  await idle(harness)
  assert.equal(harness.statusCalls, 2)
  assert.equal(harness.prompts.length, 0, "pre-existing dirty state without a new content delta must not recover")
}

{
  const harness = createHarness([dev("A"), dev("B", true, "passed")])
  await userTurn(harness)
  await harness.hooks["tool.execute.before"]({ tool: "write", sessionID: "s1" }, { args: {} })
  await idle(harness)
  assert.equal(harness.prompts.length, 0, "fresh passed verification must close the gate")
}

{
  const harness = createHarness([dev("A"), dev("B"), dev("B"), dev("B")])
  await userTurn(harness)
  await harness.hooks["tool.execute.before"]({ tool: "edit", sessionID: "s1" }, { args: {} })
  await idle(harness)
  assert.equal(harness.prompts.length, 1)
  assert.match(harness.prompts[0].text, /Add\/update the relevant scenario/)
  await userTurn(harness) // synthetic recovery prompt; must preserve the original baseline
  await idle(harness)
  assert.equal(harness.prompts.length, 2)
  assert.match(harness.prompts[1].text, /blocker diagnostics now/)
  await userTurn(harness)
  await idle(harness)
  assert.equal(harness.prompts.length, 2, "recovery must be bounded to two turns")
}

{
  const harness = createHarness([master("A"), master("B")], "master")
  const output = await userTurn(harness)
  assert.equal(output.parts.length, 0, "master must not receive runtime prompt tokens")
  await harness.hooks["tool.execute.before"]({ tool: "write", sessionID: "s1" }, { args: {} })
  await idle(harness)
  assert.match(harness.prompts[0].text, /outside itldev/)
}

{
  const harness = createHarness([new Error("status unavailable")])
  await userTurn(harness)
  await assert.rejects(
    harness.hooks["tool.execute.before"]({ tool: "write", sessionID: "s1" }, { args: {} }),
    /ITL_COMPLETION_GATE_STATUS_FAILED/,
  )
}

const context = buildDevelopmentContext({ branch: "itldev/demo", paths })
assert.ok(Math.ceil(Buffer.byteLength(context, "utf8") / 4) <= 80)
console.log("kilo completion gate harness passed")
