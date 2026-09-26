---
name: grilling
description: Grill the user relentlessly about a plan, decision, or idea. Use when the user wants to stress-test their thinking, or uses any 'grill' trigger phrases.
---

Adapted from [`mattpocock/skills`](https://github.com/mattpocock/skills/tree/0ab1b63a410a03d3627979a109c8695de27af954/skills/productivity/grilling) (MIT).

Interview the user relentlessly until you reach a shared understanding. Map this as a **design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose prerequisites are already settled: the questions you can ask _now_ without guessing at answers you haven't heard yet. Ask the whole frontier in one round: number each question and give your recommended answer. Then wait for the user's answers before the next round.

Format a round like so:

```
❓ **Q1** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>

---

❓ **Q2** - **<question title>**: <question body, might be multiple paragraphs, including multiple choices>

➡️ <your recommended answer>
```

Each round the user answers reshapes the tree: settled decisions push the frontier outward and unblock questions that depended on them. Recompute the frontier and ask the next round. A question whose answer depends on another question still open in this round belongs to a _later_ round, not this one.

Finding _facts_ is your job, never the user's. Follow the project's existing fact-routing instructions and use the minimum relevant documentation, MCP, code, filesystem, or runtime evidence. In an installed ITL project, honor required project skills such as product documentation routing before broad repository traversal. When delegation is available and useful, dispatch the project-specific read-only explorer; otherwise find the fact in the parent. Never ask the user for something you can look up yourself. A running exploration is an unsettled prerequisite, so only its downstream questions wait; ask the rest of the frontier now.

The _decisions_ are the user's: put each to them and wait. The session is done when the frontier is empty: every branch of the design tree visited, nothing left silently assumed. Do not act on the result until the user confirms you have reached a shared understanding.

If the user says to stop, including `достаточно`, stop questioning immediately. Summarize settled decisions, evidence-backed facts, unresolved branches, and your recommendation without implementing anything.

After confirmation, summarize the same handoff and offer the project's existing next routes. Do not implicitly select `planningMode=OpenSpec`, promote `executionPath` to `full-cycle`, implement, or change verification depth. If the user chooses OpenSpec, carry the handoff into the available explore or propose entrypoint instead of creating a parallel specification format.
