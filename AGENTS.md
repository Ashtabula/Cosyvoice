# Repository agent instructions

Read `AGENT_PERSONAL_CUSTOMIZATION.md` before changing this project. Preserve its rules and append-only `历史工作记录.txt`. Read REQUIREMENTS.md when present; it is absent in this setup baseline.

## ChatGPT–Codex local execution

Use the user-scoped `~/.agents/skills/development-executor/SKILL.md` only when explicitly invoked or a clearly approved ChatGPT handoff requires execution. ChatGPT approves engineering direction; Codex implements only that task, validates locally, reports evidence, and stops for review.

Keep each project in its own directory and verify its GitHub remote before writing. This checkout belongs to `Ashtabula/Cosyvoice`; `Ashtabula/VOX2` and other Ashtabula repositories are separate projects. Do not reuse this project's task, assets, branch or report destination for a different repository. The global Skill is reusable and does not designate a default repository.

Handoff mapping for this project:

1. `workflow/NEXT_STEP.md`: task/repository/experiment branch/approval/acceptance criteria/push authorization. The installation template is DRAFT and must not execute.
2. `workflow/FINAL_REPORT.md`: report index. Preserve existing `ios/validation/` evidence and `reports/voxcpm2/` experiment reports when present; future task reports belong to their established directories. Workflow setup evidence is in `reports/development-executor/setup-20261010/`.
3. `workflow/REVIEW.md`: ChatGPT/human review. Codex must not author its own engineering approval. Review must bind the exact instruction revision/hash.

Prefer established task-specific paths over these fallback files when explicitly named in an approved handoff. Do not execute prior experiments, old local authorization notes, or the newest remote instruction merely because they exist. Installation checks never run NEXT_STEP or expensive benchmarks.

Run builds/tests on the local Mac. Never activate GitHub Actions/CI, merge main automatically, force-push, delete branches, overwrite uncommitted changes, fabricate results, or auto-accept listening tests. Existing workflow definitions remain intact; inspect their triggers and establish suppression before any authorized push/PR. No push is authorized by this setup.

Use both Markdown and JSON reports as defined in the global Skill's `references/report-contract.md`. Record exact task/instruction identity, source/tested/submitted commits, changed files, commands and actual test dispositions, physical device/environment if tested, performance/memory/ANE/audio evidence when relevant, issues, and exact GitHub submission state. Build/host/simulator/device detection/MLComputePlan are separate evidence levels. Human listening remains pending until supplied by a human.

Invoke from this project's checkout: `Use $development-executor. Execute only task <ID> from <approved path/URL and pinned revision/hash> on <experiment branch>. Push authorization: no. Stop after reports for ChatGPT review.`
