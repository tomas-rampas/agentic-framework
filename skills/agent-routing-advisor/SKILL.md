---
name: agent-routing-advisor
description: Recommends which framework agent (or multi-agent workflow) should handle a task; use when the user asks which agent to use, how to delegate a piece of work, or how to sequence agents for a multi-domain task.
---

# Agent Routing Advisor

Analyze a task and recommend the right agent(s) from this framework's roster, plus a delegation prompt and workflow sequence. Recommendations must reflect the registry (claude.json), never memory or legacy docs.

## Ground Truth First

- The roster lives in the registry (claude.json) under `.sub_agents`; each agent's definition is `agents/<name>.md`; canonical categories are in `.agent_categories`.
- Before recommending an agent, verify it exists in the registry. Never invent agent names. There is no "backend-expert" — backend/API work routes to the language expert matching the stack (csharp-expert, go-expert, python-expert, typescript-expert, java-expert, rust-expert).
- If the stack is unknown, inspect the repository (build files, extensions) or ask before picking a language expert.

## Canonical Categories

| Category | Agents | Route here when |
|---|---|---|
| language_experts | rust-expert, csharp-expert, go-expert, java-expert, python-expert, typescript-expert, mql-trading-dev | Implementation in a specific language/stack, including backend/API work |
| automation_experts | bash-expert, powershell-expert | Long, output-heavy shell runs (selective policy — short commands run inline), shell scripting, OS automation |
| domain_specialists | database-specialist, frontend-specialist, security-specialist, uiux-specialist | Schema/query work, UI components, security audits, UX/accessibility |
| infrastructure_operations | devops-orchestrator | CI/CD, containers, IaC, deployment |
| architecture_planning | system-architect, product-owner | System design, technical decisions; requirements, user stories |
| quality_analysis | comprehensive-analyst, code-review-gatekeeper, peer-review-critic | Investigation/profiling; code review; final diff-scoped peer review |
| documentation | technical-docs-writer | Guides, API docs, developer documentation |

## Single-Agent Routing

Match dominant signals in the task description:

- Rust, cargo, tokio → rust-expert. C#, .NET, ASP.NET Core, Azure → csharp-expert. Go, goroutines, gRPC → go-expert. Java, Spring Boot, Maven/Gradle → java-expert. Python, Django/Flask, pandas → python-expert. TypeScript/JavaScript, React/Next.js, Node → typescript-expert. MQL4/MQL5, MetaTrader, Expert Advisors → mql-trading-dev.
- "REST API", "backend", "microservice" → the language expert for the project's stack (not a generic backend agent).
- Long, output-heavy command-line runs — test batteries, log grinding, paged gh enumerations, multi-step throwaway pipelines — → bash-expert (POSIX/CI) or powershell-expert (Windows); short commands run inline in whichever agent needs them. Bash/Linux script authoring → bash-expert. PowerShell/Windows/cloud scripting → powershell-expert.
- Schema, migrations, query optimization, SQL/NoSQL → database-specialist.
- UI components, responsive design, CSS → frontend-specialist. Design systems, user flows, accessibility audits → uiux-specialist.
- Authentication, encryption, vulnerabilities, compliance → security-specialist.
- CI/CD, Kubernetes, Docker, Terraform → devops-orchestrator.
- Architecture, scalability, technical trade-offs → system-architect. Requirements, backlog, user stories → product-owner.
- Investigate, debug, profile, benchmark, evaluate → comprehensive-analyst (which runs its own commands inline, delegating only long, noisy runs per the selective policy).
- Documentation deliverables → technical-docs-writer.
- Review of implemented code → code-review-gatekeeper. Final independent review of the branch diff vs base → peer-review-critic (final gate only; see below).

Decision order: (0) the task is purely running/summarizing commands → bash-expert or powershell-expert; (1) single language implementation → that language expert; (2) clearly one specialized domain → that specialist; (3) spans domains → multi-agent workflow; (4) ambiguous or investigative → comprehensive-analyst first.

## Review Gates (Mandatory Ending)

Every workflow that produces or changes code ends with, in this order:

1. **code-review-gatekeeper** — quality validation, test coverage, standards compliance.
2. **peer-review-critic** — the mandatory final gate: independent, diff-scoped review of branch vs base, run after code-review-gatekeeper and after the change is committed. Resolve every BLOCKER/MAJOR finding (or get explicit user sign-off) before declaring the work done.

Never place peer-review-critic mid-workflow, and never end a coding workflow without it.

## Multi-Agent Workflow Patterns

**Feature development**
product-owner (stories, acceptance criteria) → system-architect (design) → [language expert] (implementation + tests) → technical-docs-writer (docs) → code-review-gatekeeper → peer-review-critic

**Security-critical feature**
security-specialist (requirements, threat model) → [language expert] (secure implementation) → security-specialist (audit) → code-review-gatekeeper → peer-review-critic

**Full-stack feature**
system-architect (design) → database-specialist (schema, migrations) → [language expert] (API/backend) → frontend-specialist (UI) → uiux-specialist (UX/accessibility validation) → code-review-gatekeeper → peer-review-critic

**Performance optimization**
comprehensive-analyst (profile, identify bottlenecks) → [language expert] (optimizations) → comprehensive-analyst (verify improvement) → code-review-gatekeeper → peer-review-critic

Skip phases that don't apply (e.g., no database-specialist if no schema change), but never skip the two closing review gates when code changed.

## Handling Vague Tasks

If the task is underspecified (e.g., "optimize performance", "improve the app"):

1. Ask what component, what symptom, and what the target outcome is.
2. Offer a preliminary route: comprehensive-analyst to investigate, then a language expert to implement, then the closing review gates.
3. Do not guess a language expert without evidence of the stack.

## Delegation Template

When handing the recommendation to `/agentic-framework:delegate` or a Task invocation, structure the prompt as:

- **Objective**: what must be accomplished, in one sentence.
- **Context**: relevant file paths, existing code, dependencies.
- **Requirements**: functional and non-functional requirements.
- **Constraints**: standards, technical limits, patterns to follow.
- **Deliverables**: code, tests, docs — be explicit.
- **Validation**: how to verify (build passes, tests pass, lint clean).

## Recommendation Output

Present each recommendation as:

- **Task analysis**: detected language(s), domain(s), complexity.
- **Primary agent** with confidence (high/medium/low) and a one-line rationale.
- **Supporting agents / workflow** if multi-domain, as an ordered sequence ending with code-review-gatekeeper → peer-review-critic.
- **Delegation prompt** filled in from the template above.
- **Alternatives**: when a different agent would be better (e.g., comprehensive-analyst if requirements turn out unclear).

Do not include invented time estimates, pass rates, or cost figures — only what can be derived from the task and the registry.
