# Agentic Framework for Claude

*A configuration framework that turns Claude Code CLI into a disciplined, 21-agent engineering team — with real, tested enforcement.*

---

## 1. Agentic vs. Chatbot

| | Chatbot | Agent |
|---|---|---|
| Interaction | One question → one answer | One **goal** → a finished **outcome** |
| Who executes | You (copy/paste, run, verify) | The agent (edits files, runs commands, reads results) |
| **Context** | Only what you paste; lost when the window overflows | Gathers its own: reads the repo, greps code, checks git history, fetches live docs |
| Memory & state | Forgets everything between chats | Persistent: project rules (`CLAUDE.md`), memory files, session state |
| Tool use | None (text in, text out) | Full toolbelt: filesystem, shell, git, web, MCP servers |
| Planning | Single-shot best guess | Decomposes the goal, tracks tasks, replans when a step fails |
| Feedback loop | None — it can't see what happened | Observes tool output, self-corrects, iterates |
| Autonomy | Human drives every step | Works unattended for minutes to hours; escalates only real decisions |
| Verification | You must check every claim | Runs the tests, validators, and review agents itself |
| Collaboration | One generalist model | A routed team of specialists + independent reviewers |
| Guardrails | Content filtering only | Permissions, hooks, and blocking quality gates |
| Failure mode | Confidently wrong text | Caught by tests, CI, and the review chain before it ships |

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "primaryColor": "#cde2fb", "primaryBorderColor": "#2a78d6", "primaryTextColor": "#0b0b0b", "lineColor": "#898781", "textColor": "#898781", "titleColor": "#898781", "clusterBkg": "transparent", "clusterBorder": "#898781", "edgeLabelBackground": "#f0efec"}}}%%
flowchart LR
    subgraph CB["Chatbot — you drive every step"]
        direction TB
        U1["you"] -->|question| M1["model"]
        M1 -->|"answer — you run it, verify it, re-ask"| U1
    end
    subgraph AG["Agent — a working loop"]
        direction TB
        P["plan"] --> A["act · edit · run · search"] --> O["observe results"] --> V{"verified?"}
        V -->|no| P
        V -->|yes| D["outcome delivered"]
    end
    CB ~~~ AG
    classDef neutral fill:#f0efec,stroke:#898781,color:#0b0b0b
    classDef flow fill:#cde2fb,stroke:#2a78d6,color:#0b0b0b
    classDef check fill:#fdeec9,stroke:#eda100,color:#0b0b0b
    classDef done fill:#d9f0d9,stroke:#0ca30c,color:#0b0b0b
    class U1,M1 neutral
    class P,A,O flow
    class V check
    class D done
```

### Context economics — the invisible difference

A model's context window is finite. *Where the tokens burn* is the real architectural difference — same task, measured as % of each context window consumed:

**Panel 1 — non-agentic: one session carries everything.** Every pasted file, build log, and diff accumulates in the single window until early decisions fall out of memory:

```mermaid
%%{init: {"xyChart": {"width": 760, "height": 170}, "theme": "base", "themeVariables": {"background": "transparent", "xyChart": {"backgroundColor": "transparent", "plotColorPalette": "#d03b3b", "titleColor": "#898781", "xAxisLabelColor": "#898781", "xAxisTitleColor": "#898781", "xAxisLineColor": "#898781", "xAxisTickColor": "#898781", "yAxisLabelColor": "#898781", "yAxisTitleColor": "#898781", "yAxisLineColor": "#898781", "yAxisTickColor": "#898781"}}}}%%
xychart-beta horizontal
    title "One window does all the work - near exhaustion"
    x-axis ["single session"]
    y-axis "% of context window consumed" 0 --> 100
    bar [96]
```

**Panel 2 — agentic: the orchestrating session stays lean.** The main bar is the orchestrator's window; the sub-bars (└) are its three *disposable* child windows, which do the heavy reading and return only distilled summaries:

```mermaid
%%{init: {"xyChart": {"width": 760, "height": 340}, "theme": "base", "themeVariables": {"background": "transparent", "xyChart": {"backgroundColor": "transparent", "plotColorPalette": "#2a78d6", "titleColor": "#898781", "xAxisLabelColor": "#898781", "xAxisTitleColor": "#898781", "xAxisLineColor": "#898781", "xAxisTickColor": "#898781", "yAxisLabelColor": "#898781", "yAxisTitleColor": "#898781", "yAxisLineColor": "#898781", "yAxisTickColor": "#898781"}}}}%%
xychart-beta horizontal
    title "Orchestrator session + its 3 disposable agent windows"
    x-axis ["orchestrator session", "└ agent A · reads 60 files", "└ agent B · reads hooks+scripts", "└ agent C · reviews full diff"]
    y-axis "% of own context window consumed" 0 --> 100
    bar [22, 52, 41, 47]
```

Same task, opposite failure modes: the single session hits the ceiling and *degrades*; the orchestrator's window (green) grows only by summaries, while the heavy tokens burn in child windows (orange) that are thrown away afterwards. **Real numbers from this repo's own overhaul:** the two review agents alone consumed ~357k tokens inside their own windows — the coordinating session received two reports of ~1,500 tokens each.

---

## 2. Architecture — one objective, end to end

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "lineColor": "#898781", "textColor": "#898781", "clusterBkg": "transparent", "clusterBorder": "#898781", "edgeLabelBackground": "#f0efec"}}}%%
flowchart TD
    O["🎯 Objective"] --> R["Routing<br/>CLAUDE.md rules · /delegate · agent descriptions"]
    R --> S["Specialist agent — 1 of 21<br/>implements, tests, commits"]
    SK["📚 Skills<br/>procedural knowledge"] -.-> S
    MCP["🔌 MCP servers<br/>code intel · live docs · web"] -.-> S
    S --> C1["code-review-gatekeeper<br/>quality review"]
    C1 -->|findings fixed| C2["peer-review-critic<br/>independent final review — read-only tools"]
    C2 --> GATE{"🚦 Stop gate<br/>review recorded?"}
    GATE -- no --> C2
    GATE -- yes --> DONE["✅ Session may end — work is done"]
    classDef flow fill:#cde2fb,stroke:#2a78d6,color:#0b0b0b
    classDef aid fill:#d2f0e4,stroke:#1baf7a,color:#0b0b0b
    classDef review fill:#ddd8f3,stroke:#4a3aa7,color:#0b0b0b
    classDef gate fill:#f8d7d7,stroke:#d03b3b,color:#0b0b0b
    classDef done fill:#d9f0d9,stroke:#0ca30c,color:#0b0b0b
    class O,R,S flow
    class SK,MCP aid
    class C1,C2 review
    class GATE gate
    class DONE done
```

**Proof it works:** the framework was recently overhauled through its own pipeline — a multi-agent audit found the gaps, 10 commits fixed them, both review agents signed off, 3 CI jobs passed, and the Stop gate enforced the final review live (PR #20).

---

## 3. Components

### 3.1 Agents — the workforce (21)

An agent = a markdown file: YAML frontmatter (name, routing description, model tier, tools) + a system prompt. **Routing is description-driven** — the task text is matched against agent descriptions, so a well-written description *is* the router.

```mermaid
mindmap
  root((21 agents))
    Language · 7
      rust-expert
      csharp-expert
      go-expert
      java-expert
      python-expert
      typescript-expert
      mql-trading-dev
    Automation · 2
      bash-expert
      powershell-expert
    Domain · 4
      database
      frontend
      security
      uiux
    Infrastructure · 1
      devops-orchestrator
    Architecture · 2
      system-architect
      product-owner
    Quality · 4
      comprehensive-analyst
      code-review-gatekeeper
      peer-review-critic
      spec-compliance-reviewer
    Documentation · 1
      technical-docs-writer
```

- **Model tiers scale with stakes**: `opus` = language implementation, security, architecture & review · `sonnet` = domain specialists, analysis & planning · `haiku` = executors, docs & UI/UX.
- **peer-review-critic runs a curated toolset** (no Write/Edit/Agent) that narrows its default surface; its independence rests on diff-scoped review by a separate instance, with the Stop-gate hook enforcing the verdict.
- Agents have full tool access in their domain and can invoke each other for cross-domain work.

### 3.2 Commands — the operations console (10)

| Command | Role |
|---|---|
| `/agentic-framework:delegate` | End-to-end orchestration: auto-runs the spec interview when no source of truth exists, then hands off to build |
| `/agentic-framework:spec` | Interview the user one question at a time, then write `specs/<name>.md` with checkable acceptance criteria |
| `/agentic-framework:build` | Build exactly what the spec says, then loop build ↔ spec-compliance-reviewer until `VERDICT: APPROVED` |
| `/agentic-framework:review-spec` | Manual conformance check: per-requirement PASS/FAIL of the current build against the spec |
| `/agentic-framework:list-agents` | Roster with categories, model tiers, status |
| `/agentic-framework:agent-status` | Per-agent configuration health |
| `/agentic-framework:analyze-framework` | Full health check (runs the real validators) |
| `/agentic-framework:quality-report` | Quality assessment from actual config state |
| `/agentic-framework:validate-hooks` | Hook registration parity check |
| `/agentic-framework:migrate-legacy` | Migrate a local ~/.claude clone to the plugin distribution |

### 3.3 Hooks — the enforcement layer (4)

The only component that can **say no**: hook scripts implemented as both PowerShell 7 (.ps1) and POSIX shell (.sh) pairs, registered on Claude Code lifecycle events as shell-form chains, receiving event JSON on stdin. The .sh implementations parse that JSON with `jq` and enforce nothing without it — if `jq` is absent on a POSIX host, the gate is disarmed; hooks fire but don't enforce. Windows runs the .ps1 via pwsh (which parses JSON natively with ConvertFrom-Json), or the .sh under Git Bash when jq is available.

| Hook (.ps1/.sh pair) | Event | Guards |
|---|---|---|
| `stop-peer-review-gate` | `Stop` | **The one hard gate** — no session ends with committed, unreviewed work |
| `record-subagent-run` | `PostToolUse` + `SubagentStop` | Records peer-review-critic runs and parses the review's `VERDICT:` line — `APPROVED` is what unlocks the gate |
| `session-start-context` | `SessionStart` | Injects branch + review status into context at startup |
| `pretooluse-delegation-hint` | `PreToolUse` | Suggests the matching specialist when a `.rs`/`.py`/`.cs`/… file is written |

The gate's lifecycle:

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "actorBkg": "#cde2fb", "actorBorder": "#2a78d6", "actorTextColor": "#0b0b0b", "signalColor": "#898781", "signalTextColor": "#898781", "noteBkgColor": "#fdeec9", "noteBorderColor": "#eda100", "noteTextColor": "#0b0b0b"}}}%%
sequenceDiagram
    participant M as Model
    participant CC as Claude Code
    participant G as stop-peer-review-gate
    participant PRC as peer-review-critic
    participant R as record-subagent-run

    Note over CC,M: SessionStart hook → "branch X is N commits ahead, gate armed"
    M->>CC: implement… commit on feature branch
    M->>CC: try to end session
    CC->>G: Stop event
    G-->>CC: 🚫 block — unreviewed commits
    CC->>PRC: launch final review
    PRC-->>CC: report ending "VERDICT: APPROVED"
    CC->>R: SubagentStop + PostToolUse events
    R->>R: write marker with verdict=APPROVED
    M->>CC: end session
    CC->>G: Stop event
    G-->>CC: ✅ allow (verdict APPROVED)
```

Its decision logic — every "no" answer allows the stop (**fail-open**):

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "lineColor": "#898781", "textColor": "#898781", "edgeLabelBackground": "#f0efec"}}}%%
flowchart TD
    A["Stop event"] --> B{"stop-hook<br/>continuation?"}
    B -- yes --> ALLOW(["allow"])
    B -- no --> C{"already fired<br/>this session?"}
    C -- yes --> ALLOW
    C -- no --> D{"review marker<br/>exists?"}
    D -- yes --> ALLOW
    D -- no --> E{"git worktree,<br/>feature branch?"}
    E -- no --> ALLOW
    E -- yes --> F{"commits ahead<br/>of base?"}
    F -- no --> ALLOW
    F -- yes --> G2{"working tree<br/>clean?"}
    G2 -- no --> ALLOW
    G2 -- yes --> BLOCK(["🚫 BLOCK<br/>run peer-review-critic"])
    ERR["any error anywhere"] -.-> ALLOW
    classDef q fill:#cde2fb,stroke:#2a78d6,color:#0b0b0b
    classDef ok fill:#d9f0d9,stroke:#0ca30c,color:#0b0b0b
    classDef bad fill:#f8d7d7,stroke:#d03b3b,color:#0b0b0b
    classDef neutral fill:#f0efec,stroke:#898781,color:#0b0b0b
    class A,B,C,D,E,F,G2 q
    class ALLOW ok
    class BLOCK bad
    class ERR neutral
```

Design philosophy: **one hard gate at the single choke point** (all work becomes committed code) · everything else advisory · fail-open everywhere · bounded blocking — once when no review ran, up to 3 while the verdict is `CHANGES_REQUIRED`: a gate, not a nag. Behavior pinned by 40+ test assertions; CI fails if a script and its registration ever drift apart.

*Field note: minutes after installation, the gate blocked its own author's session — for having unreviewed commits. It was reviewing the commits that created it.*

### 3.4 Skills — procedural knowledge (9)

Loaded on demand when a task matches. An agent is *someone to delegate to*; a skill is *knowledge the current agent absorbs*.

| Skill | Teaches Claude how to… |
|---|---|
| agent-debugger | Diagnose routing/loading/config failures |
| agent-routing-advisor | Pick the right agent or agent sequence |
| code-scaffolder | Bootstrap idiomatic projects per language |
| code-scoring-loop | Score a code diff via the specialist agents, rewrite the weakest parts, rescore until it plateaus — before, never instead of, the review gates |
| dependency-checker | Verify the toolchain (git, jq, pwsh 7, node, uv) |
| git-workflow-assistant | Branch/commit/PR flow, incl. working *with* the Stop gate |
| hook-config-generator | Add a new real hook (script → registration → tests) |
| refactoring-advisor | Spot code smells, prioritize refactorings |
| self-scoring-loop | Rubric-score a non-code deliverable, rewrite the weakest parts, rescore until it plateaus |

### 3.5 MCP servers — senses and instruments (5)

MCP (Model Context Protocol) = the open standard for plugging external tools into the model.

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "lineColor": "#898781", "textColor": "#0b0b0b"}}}%%
block-beta
    columns 5
    C["Claude Code session — one MCP protocol, five instruments"]:5
    space:5
    FS["filesystem<br/>bulk & atomic file ops<br/>Node · npx"] C7["context7<br/>live library docs<br/>Node · npx"] SE["serena<br/>semantic code intel<br/>Python · uvx"] ST["sequential-thinking<br/>stepwise reasoning<br/>Node · npx"] FE["fetch<br/>web → markdown<br/>Python · uvx"]
    C --> FS
    C --> C7
    C --> SE
    C --> ST
    C --> FE
    classDef hub fill:#cde2fb,stroke:#2a78d6,color:#0b0b0b
    classDef srv fill:#ddd8f3,stroke:#4a3aa7,color:#0b0b0b
    class C hub
    class FS,C7,SE,ST,FE srv
```

`context7` beats training-data recall with current docs; `serena` gives LSP-grade navigation instead of text grep; `sequential-thinking` scaffolds explicit reasoning chains for hard problems; `fetch` turns web pages into clean markdown.

### 3.6 Anti-drift consistency system — the immune system

In config-as-code, docs and reality drift apart silently. Here, drift **fails the build**:

```mermaid
%%{init: {"theme": "base", "themeVariables": {"background": "transparent", "actorBkg": "#cde2fb", "actorBorder": "#2a78d6", "actorTextColor": "#0b0b0b", "signalColor": "#898781", "signalTextColor": "#898781", "loopTextColor": "#898781", "labelBoxBkgColor": "#cde2fb", "labelBoxBorderColor": "#2a78d6", "labelTextColor": "#0b0b0b", "noteBkgColor": "#fdeec9", "noteBorderColor": "#eda100", "noteTextColor": "#0b0b0b"}}}%%
sequenceDiagram
    participant PR as PR / push
    participant CI as CI — 3 jobs
    participant V as validate-consistency.sh
    participant SOT as claude.json + filesystem

    PR->>CI: commit lands
    CI->>V: run the 15-check battery
    V->>SOT: derive all truth at runtime (no hardcoded lists)
    SOT-->>V: registry · rosters · hooks · skills · counts (15 checks)
    V->>V: compare docs & generated blocks against derived truth
    alt any drift found
        V-->>CI: FAIL (names the exact file & line)
        CI-->>PR: ❌ build fails — docs can't lie
    else everything in sync
        V-->>CI: PASS
        CI-->>PR: ✅ merge allowed
    end
```

- Nothing is hardcoded: registry↔filesystem parity, category partition, hook registration parity, model parity, roster presence, stated-count scanning — all derived.
- Headline numbers in the README are **generated blocks** — the docs physically cannot lie about counts.
- A 34-assertion harness injects defects into throwaway repo copies and proves the validator catches each class.

---

## 4. Getting started

**Modern plugin-based installation (4.0+):**

```
/plugin marketplace add tomas-rampas/agentic-framework
/plugin install agentic-framework@agentic-framework
/agentic-framework:validate-hooks
/agentic-framework:analyze-framework
```

Optional: install the MCP servers plugin:
```
/plugin install agentic-framework-mcp@agentic-framework
/agentic-framework-mcp:setup
```

**Prerequisites:** Claude Code CLI, git, bash + jq; PowerShell 7 (Windows only; Linux/macOS optional); Node/npx and uv for the optional MCP servers.

**Legacy installation (pre-4.0, historical reference):**
See [README.md Migration section](README.md#migration-existing-local-clones) if you have an existing local clone to migrate.

---

## 5. By the numbers

| | |
|---|---|
| Specialized agents | 21 (7 categories, 3 model tiers) |
| Hooks | 4 registered — 1 blocking gate, 3 advisory |
| Skills | 9 loadable knowledge modules |
| Commands | 10 management commands |
| MCP servers | 5 (filesystem, context7, serena, sequential-thinking, fetch) |
| Validator checks | 15, all derived at runtime |
| Test assertions | 72 (consistency) + 44+ (hook behavior) + 92 (migration) |
| CI jobs | 3, including a Windows leg |

**Takeaway:** agents write the code · hooks make quality non-negotiable · the consistency system keeps the whole thing honest.
