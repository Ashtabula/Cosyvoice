# Set Up a Global ChatGPT–Codex Development Workflow on This Mac

You are Codex running locally on my Mac.

Your task is to install and configure a reusable development-executor Skill for my existing development workflow:

ChatGPT reviews code and results → ChatGPT creates engineering instructions → Codex executes locally → Codex submits a report to GitHub → ChatGPT reviews the results.

Perform the setup now. Do not merely describe how to perform it.

1. Inspect the existing Mac environment

Identify:

- Current macOS version and architecture.
- Installed Codex version and configuration.
- Existing "~/.codex/AGENTS.md" and "~/.codex/config.toml".
- Existing skills under "~/.agents/skills/".
- Existing Git repositories, particularly "Ashtabula".
- Existing GitHub remotes, active branches, and working-tree state.
- Installed Xcode, "xcodebuild", signing capabilities, and available iOS test devices.
- Existing project-level "AGENTS.md" instructions.
- Existing GitHub handoff folders, such as "next step", and experiment reports.

Do not modify unrelated system settings. Never expose credentials, tokens, or private keys in logs.

2. Create a global Codex Skill

Install the Skill at:

"~/.agents/skills/development-executor/SKILL.md"

Use valid YAML front matter with:

- "name: development-executor"
- A description explaining when it should execute ChatGPT-approved GitHub engineering tasks.

Define this execution workflow:

1. Identify the repository and active experiment branch.
2. Fetch or inspect the latest approved ChatGPT instructions.
3. Read the task requirements and acceptance criteria.
4. Inspect relevant source code and existing implementation history.
5. Implement only the approved task.
6. Run appropriate local validation.
7. Run Xcode and physical iPhone tests when required and available.
8. Produce detailed machine-readable and human-readable reports.
9. Commit changes to the correct experiment branch.
10. Push to GitHub when authorized and credentials permit.
11. Stop and hand control back to ChatGPT for review.

The Skill must not independently authorize a new engineering direction.

3. Configure global Codex instructions

Inspect "~/.codex/AGENTS.md".

Preserve existing instructions, then add a concise section for the new workflow.

Rules:

- Prefer local Mac execution and local testing.
- Never activate GitHub Actions or GitHub CI.
- Never merge into "main" automatically.
- Never force-push or delete branches.
- Never overwrite uncommitted changes.
- Never fabricate test results.
- Require human intervention for listening tests or other subjective validation.
- Respect existing project-specific instructions.
- Only run the development-executor Skill when explicitly requested or when an approved handoff task clearly requires it.

Avoid changing unrelated global Codex configuration.

4. Configure the Ashtabula repository

Find the existing local checkout of "Ashtabula". Do not assume its location.

Inspect its current GitHub workflow and file structure.

Reuse existing task and report directories whenever possible. Do not break existing scripts or automation.

If necessary, introduce a small, documented handoff structure:

- "workflow/NEXT_STEP.md" — approved task
- "workflow/FINAL_REPORT.md" — execution and validation results
- "workflow/REVIEW.md" — ChatGPT review and approval

If the project already uses different paths, preserve the existing paths and configure the Skill accordingly.

Update the repository's "AGENTS.md" non-destructively to describe how to invoke the global Skill.

Do not modify application source code during this setup.

5. Standardize the execution report

The final report must include:

- Repository, branch, and commit hash.
- Task ID and the exact instructions executed.
- Source files changed.
- Implementation summary.
- Build and test commands.
- Tests passed, failed, skipped, or blocked.
- Actual iPhone model and test environment, if tested.
- Performance comparisons when available.
- Memory and ANE performance metrics when relevant.
- Audio validation status when relevant.
- Known regressions and remaining issues.
- Exact GitHub submission status.
- A clear review handoff to ChatGPT.

Never claim that a test passed unless it was actually executed.

6. Validate the installation

Perform a safe installation validation:

- Confirm the Skill exists with valid front matter.
- Confirm Codex discovers it.
- Confirm global and repository instructions are readable.
- Confirm the Ashtabula GitHub remote is configured.
- Confirm existing local iOS testing tools are detectable.
- Confirm no GitHub CI was enabled.
- Confirm the handoff files are accessible.

Do not execute the existing NEXT_STEP task or run expensive benchmarks as part of installation validation.

If testing Skill discovery requires a fresh Codex session, provide exact instructions rather than claiming it succeeded.

7. Commit and report

If repository files were changed, prepare a dedicated setup branch without disturbing existing work.

Do not merge to "main".

Do not push without authorization.

Create a setup report summarizing:

- Installed Skill path.
- Files created or updated.
- Existing configuration preserved.
- Verified capabilities.
- Missing dependencies or access.
- GitHub handoff locations.
- Exact command or prompt required to start the first real execution.

Acceptance criteria: The Mac is ready to receive reviewed engineering tasks from ChatGPT and execute them locally through Codex without relying on GitHub CI.

Do the setup, validate it, and report the actual outcome.

## User steering during setup (exact answers)

"GitHub/Ashtabula"

"不同项目应该放在不同目录下"

## Scope resolution

Ashtabula is a GitHub owner with multiple local repositories. Global Skill supports each repository independently. Repository-level setup is isolated within the current Ashtabula/Cosyvoice project; other repositories were inventoried read-only and are not modified. No engineering NEXT_STEP, benchmark, push, merge or CI execution is authorized by this installation.
