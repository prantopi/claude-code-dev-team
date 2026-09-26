#!/usr/bin/env bash
# setup.sh — set up the Claude Dev Team as real Claude Code subagents.
#
# Usage: ./setup.sh [project-dir] [options]
#
#   --auto             use defaults, ask nothing
#   --profile NAME     model profile: quality (default), balanced, economy, inherit
#   --parallel N       max agents Claude runs at once, 1-20 (default 3)
#   --budget N         optional soft token budget for the project (default: none)
#   --alert PCT        warn when the budget is this % used, 1-100 (default 80)
#   --no-git           don't use git (by default the team works on branches and commits)
#   --update-agents    regenerate .claude/agents/*.md, claude/TEAM.md and TEAM-CONFIG.md
#                      (never touches your notes in claude/)
#   -h, --help         show this help
#
# Creates:
#   .claude/agents/*.md   9 subagents (echo, luna, atlas, volt, iris, swift, sage, debug, quest)
#   claude/               shared workspace: requirements, plans, reviews, logs
#   claude/TEAM.md        orchestration rules, imported from CLAUDE.md
#
# Existing files are never overwritten (except with --update-agents, see above).

set -euo pipefail

GREEN=$'\033[0;32m'; BLUE=$'\033[0;34m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; NC=$'\033[0m'

ROOT="."
AUTO=0
UPDATE_AGENTS=0
PROFILE="quality"
MAX_PARALLEL=3
BUDGET=""
ALERT=80
USE_GIT=1

die() { echo "${RED}error:${NC} $*" >&2; exit 1; }
usage() { sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

check_profile() {
  case "$1" in balanced|economy|quality|inherit) ;; *) die "unknown profile '$1' (use quality, balanced, economy or inherit)" ;; esac
}
check_parallel() {
  is_int "$1" && [ "$1" -ge 1 ] && [ "$1" -le 20 ] || die "--parallel must be a number from 1 to 20 (got '$1')"
}
check_budget() {
  [ -z "$1" ] || { is_int "$1" && [ "$1" -gt 0 ]; } || die "--budget must be a positive number of tokens (got '$1')"
}
check_alert() {
  is_int "$1" && [ "$1" -ge 1 ] && [ "$1" -le 100 ] || die "--alert must be a percentage from 1 to 100 (got '$1')"
}

# ── arguments ────────────────────────────────────────────────────────────────
ROOT_SET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --auto) AUTO=1 ;;
    --update-agents) UPDATE_AGENTS=1 ;;
    --no-git) USE_GIT=0 ;;
    --profile) [ $# -ge 2 ] || die "--profile needs a value"; PROFILE="$2"; shift ;;
    --parallel) [ $# -ge 2 ] || die "--parallel needs a value"; MAX_PARALLEL="$2"; shift ;;
    --budget) [ $# -ge 2 ] || die "--budget needs a value"; BUDGET="$2"; shift ;;
    --alert) [ $# -ge 2 ] || die "--alert needs a value"; ALERT="$2"; shift ;;
    -h|--help) usage ;;
    -*) die "unknown option '$1' (see --help)" ;;
    *) [ "$ROOT_SET" -eq 0 ] || die "only one project directory allowed"; ROOT="$1"; ROOT_SET=1 ;;
  esac
  shift
done
check_profile "$PROFILE"; check_parallel "$MAX_PARALLEL"; check_budget "$BUDGET"; check_alert "$ALERT"

echo "${BLUE}🤖 Claude Dev Team setup v5${NC}"
echo "${DIM}   project: $ROOT${NC}"
echo ""

# ── questions ────────────────────────────────────────────────────────────────
ask() { # ask <prompt> <default> -> REPLY
  local answer
  read -r -p "$1 [$2]: " answer || answer=""
  REPLY="${answer:-$2}"
}

if [ "$AUTO" -eq 0 ] && [ -t 0 ]; then
  echo "1) Model profile — which model each agent uses by default"
  echo "   ${DIM}balanced: opus for ATLAS, haiku for SAGE, sonnet for the rest${NC}"
  echo "   ${DIM}economy:  haiku for SAGE and LUNA, sonnet for the rest${NC}"
  echo "   ${DIM}quality:  opus for ATLAS, IRIS and DEBUG, sonnet for the rest (default)${NC}"
  echo "   ${DIM}inherit:  every agent uses whatever model your session uses${NC}"
  while :; do
    ask "   profile (quality/balanced/economy/inherit)" "$PROFILE"
    case "$REPLY" in b*) PROFILE=balanced ;; e*) PROFILE=economy ;; q*) PROFILE=quality ;; i*) PROFILE=inherit ;; *) echo "   ${RED}pick one of the four${NC}"; continue ;; esac
    break
  done
  echo ""
  echo "2) Max agents running at the same time (1-20)"
  while :; do
    ask "   parallel agents" "$MAX_PARALLEL"
    if is_int "$REPLY" && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le 20 ]; then MAX_PARALLEL="$REPLY"; break; fi
    echo "   ${RED}enter a number from 1 to 20${NC}"
  done
  echo ""
  echo "3) Optional token budget for this project"
  echo "   ${DIM}Claude adds up the tokens each agent reports and pauses when the alert level is reached.${NC}"
  echo "   ${DIM}It's a soft limit: Claude Code itself does not cap spending.${NC}"
  while :; do
    ask "   budget in tokens (blank = no budget)" "${BUDGET:-none}"
    [ "$REPLY" = "none" ] && { BUDGET=""; break; }
    if is_int "$REPLY" && [ "$REPLY" -gt 0 ]; then BUDGET="$REPLY"; break; fi
    echo "   ${RED}enter a positive number, or press Enter for none${NC}"
  done
  if [ -n "$BUDGET" ]; then
    while :; do
      ask "   alert at % of budget" "$ALERT"
      if is_int "$REPLY" && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le 100 ]; then ALERT="$REPLY"; break; fi
      echo "   ${RED}enter a number from 1 to 100${NC}"
    done
  fi
  echo ""
  echo "4) Use git? Agents work on their own branches, commit, and get reviewed before merging"
  while :; do
    ask "   use git (y/n)" "$([ "$USE_GIT" -eq 1 ] && echo y || echo n)"
    case "$REPLY" in [yY]*) USE_GIT=1 ;; [nN]*) USE_GIT=0 ;; *) echo "   ${RED}answer y or n${NC}"; continue ;; esac
    break
  done
  echo ""
fi

# ── helpers ──────────────────────────────────────────────────────────────────
# write() often runs in a pipeline (a subshell), so it records results in a file, not variables.
TALLY=$(mktemp)
trap 'rm -f "$TALLY"' EXIT
count() { grep -cx "$1" "$TALLY" || true; }
TODAY=$(date +%Y-%m-%d)
CLAUDE_DIR="$ROOT/claude"
AGENT_DIR="$ROOT/.claude/agents"
GIT_NOTES=""

if [ "$USE_GIT" -eq 1 ]; then
  command -v git >/dev/null 2>&1 || die "git isn't installed. Install it, or run with --no-git."
  mkdir -p "$ROOT"
  if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT" init -q
    GIT_NOTES="${GIT_NOTES}created a new git repository in $ROOT\n"
  fi
  if [ -z "$(git -C "$ROOT" config user.name || true)" ] || [ -z "$(git -C "$ROOT" config user.email || true)" ]; then
    GIT_NOTES="${GIT_NOTES}git has no name or email set, so commits will fail. Set them with:\n      git config --global user.name \"Your Name\"\n      git config --global user.email \"you@example.com\"\n"
  fi
  # Keep agent worktrees and personal settings out of the repository.
  GITIGNORE="$ROOT/.gitignore"
  for pattern in ".claude/worktrees/" ".claude/settings.local.json"; do
    if ! { [ -e "$GITIGNORE" ] && grep -qxF "$pattern" "$GITIGNORE"; }; then
      [ -e "$GITIGNORE" ] && [ -n "$(tail -c1 "$GITIGNORE")" ] && echo >> "$GITIGNORE"
      echo "$pattern" >> "$GITIGNORE"
      echo updated >> "$TALLY"
    fi
  done
fi

# write <path> [overwrite] — content on stdin. Existing files are kept unless overwrite=1.
write() {
  local path="$1" overwrite="${2:-0}"
  if [ -e "$path" ]; then
    if [ "$overwrite" -ne 1 ]; then echo kept >> "$TALLY"; cat >/dev/null; return; fi
    echo updated >> "$TALLY"
  else
    echo created >> "$TALLY"
  fi
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

model_for() {
  case "$PROFILE:$1" in
    inherit:*) echo inherit ;;
    economy:sage|economy:luna) echo haiku ;;
    economy:*) echo sonnet ;;
    quality:atlas|quality:iris|quality:debug) echo opus ;;
    quality:*) echo sonnet ;;
    balanced:atlas) echo opus ;;
    balanced:sage) echo haiku ;;
    *) echo sonnet ;;
  esac
}

# Agents that change project code work in their own git worktree and branch.
is_coder() { case "$1" in volt|debug|swift|quest) return 0 ;; *) return 1 ;; esac; }

# agent <name> <color> <tools-line> <description> [extra frontmatter] — system prompt on stdin
agent() {
  local name="$1" color="$2" tools="$3" desc="$4" extra="${5:-}"
  if [ "$USE_GIT" -eq 1 ] && is_coder "$name"; then extra="${extra:+$extra
}isolation: worktree"; fi
  {
    printf -- '---\nname: %s\ndescription: "%s"\n%s\nmodel: %s\ncolor: %s\n' "$name" "$desc" "$tools" "$(model_for "$name")" "$color"
    [ -n "$extra" ] && printf '%s\n' "$extra"
    printf -- '---\n\n'
    cat
    cat <<'EOF'

## Shared rules
- Read only what your task needs: your task, the files it names, and `claude/PROJECT_SPEC.md`. Open other `claude/` files only when your task points you to them.
- Only write inside your own `claude/<your-name>/` folder, plus any project files your task names.
- Other agents may be running at the same time. Never edit a file another task in your batch owns.
- Don't guess at missing requirements: say what's missing in your report.

## Work efficiently
Every reply re-reads your whole conversation so far, so each extra step and each large read costs tokens
for the rest of the task. Save them without skipping anything the task needs:
- Do independent things in one step: several file reads or searches as parallel tool calls, and related
  shell checks in one command (`a && b; c`) rather than one command per reply.
- Read what you need, not whole files: search first (Grep), then read the relevant lines. When your task
  names doc sections or line ranges, read those. Read a whole file only when you need all of it.
- Don't read a file twice unless it changed. Keep what you learned instead of re-checking it.
- Keep command output short: quiet flags, `| tail -n 20`, grep for failures. Show full output only when
  you need it to fix something.
- If the task gives a base commit, check it with `git log -1 --format=%h` before you start.
- Keep your report short and factual. Don't paste code or logs the main session can read itself.

## Report back (your final message)
1. **Summary**: what you did, in 2-4 sentences.
2. **Files changed**: paths, one per line.
3. **Status**: `done` or `blocked` (and why).
4. **Follow-ups**: work another agent should pick up, if any.
EOF
    if [ "$USE_GIT" -eq 1 ] && is_coder "$name"; then
      cat <<'EOF'
5. **Branch and commit**: the output of `git branch --show-current` and `git log -1 --format=%h`.

## Git
You work in your own git worktree, on your own branch, so parallel agents can't overwrite each other.
- When your task is done, commit only the files you changed: `git add <files>`, then
  `git commit -m "<type>(<task id>): <what changed>"`, where type is feat, fix, test, docs, refactor or perf.
  Example: `feat(T4): add monthly/yearly pricing toggle`.
- Commit a checkpoint whenever a meaningful part works (for example a module and its tests pass):
  `git commit -m "wip(<task id>): <what works so far>"`. If you're interrupted, the next agent resumes
  from your last checkpoint instead of starting over. End with the final commit as above.
- Write notes only to files named after your task ID. Never edit shared logs (`claude/CHANGELOG.md`,
  indexes, other tasks' files): parallel branches would conflict there. The main session merges them.
- Never commit secrets, `.env` files or generated build output.
- Leave your worktree clean: after committing, delete anything your commands generated (for example
  `__pycache__/`, coverage or build folders), so `git status --short` shows nothing.
- Don't push, merge, rebase, reset, switch branches or rewrite history. The main session merges your branch after review.
EOF
    elif [ "$USE_GIT" -eq 1 ]; then
      cat <<'EOF'

## Git
Don't commit, branch, merge or push. The main session handles git for the whole team.
EOF
    fi
  } | write "$AGENT_DIR/$name.md" "$UPDATE_AGENTS"
}

NO_SPAWN="disallowedTools: Agent"
DOCS_TOOLS="tools: Read, Write, Edit, Glob, Grep"

# ── subagents ────────────────────────────────────────────────────────────────
agent echo cyan "$DOCS_TOOLS" \
  "Discovery agent. Use to turn the user's interview answers in claude/echo/project-notes.md into requirements, features, personas, scope and risks. Use before any planning on a new project." \
  "initialPrompt: Start the discovery interview." <<'EOF'
You are ECHO, the discovery agent. You make sure the team builds the right thing.

## If you are talking to the user directly (run with `claude --agent echo`)
Interview them using `claude/echo/discovery-questions.md`:
- Ask one or two questions at a time, in plain language. Skip questions already answered.
- Follow up when an answer is vague ("fast" → how fast? for whom?).
- Record answers as you go in `claude/echo/project-notes.md`.
- When the questions are covered, read the notes back as a short summary and ask the user to confirm or correct it, then do the synthesis below.

## If you were launched as a subagent
You can't ask the user questions. Work only from `claude/echo/project-notes.md` and do the synthesis.
If the notes are too thin to plan from, set Status to `blocked` and list the questions that still need answers.

## Synthesis
Fill in, replacing the placeholders:
- `claude/echo/requirements-summary.md`: overview, users, must-haves, constraints, success criteria
- `claude/echo/features-todo.md`: features in priority order, each with a one-line acceptance test
- `claude/echo/features-not-todo.md`: what is explicitly out of scope, and why
- `claude/echo/user-personas.md`, `claude/echo/scope.md`, `claude/echo/risks.md`
- `claude/PROJECT_SPEC.md`: the short version, for everyone else

Separate what the user said from what you inferred. Mark inferences with *(assumed)*.
EOF

agent luna purple "$DOCS_TOOLS" \
  "Planning agent. Use after discovery to break the requirements into batches of tasks in claude/luna/task-queue.md, choosing an agent and model for each task, and to update project status and blockers." <<EOF
You are LUNA, the planner. You turn requirements into a task queue that can run in parallel safely.

## Planning
Read \`claude/echo/requirements-summary.md\`, \`claude/echo/features-todo.md\` and \`claude/atlas/\` (if it exists), then write \`claude/luna/task-queue.md\`.

Rules for the queue:
- Each task is one row: ID, task, agent, model, depends on, files it touches, status (\`pending\`).
- Under each batch, add a **Read first** line that names the exact doc sections (for example \`atlas/components.md §store.py\`) and reference-code line ranges each task needs, so agents don't read whole documents.
- Group tasks into batches. A batch holds at most **$MAX_PARALLEL** tasks.
- Tasks in the same batch must not depend on each other. They must not touch the same files, except for different marked regions of a shared file when the project uses git.
- Put architecture (ATLAS) before implementation (VOLT). Every VOLT, DEBUG or SWIFT task gets its own IRIS review task that depends only on it, so the review starts as soon as that task is done, even while other tasks are still being built.
- Keep tasks small: something one agent can finish and report on in one go.
- **Split the build only when it's worth it.** Every extra agent re-reads the brief and the design before it starts, so splitting a small job costs more and doesn't finish sooner. Give each part its own VOLT task only when the part is substantial on its own: a feature with its own files and real logic, big enough to be a task by itself. For a small project, such as a single page or a few short files, use one VOLT task.
- When the build is worth splitting, follow ATLAS's build contract: a scaffold task first if the contract has one, then one VOLT task per feature (its own files and regions), all depending only on the scaffold so they can run at the same time.
- The Depends on column is what really controls the order: Claude starts a task as soon as everything it depends on is done. Only add a dependency when a task truly needs another's output.
- When the build was split across several VOLT tasks, add one short IRIS integration check that depends on all of them. It only checks that the parts fit the build contract, since each part already had its own review.
- Plan a QUEST task only when there are tests to write or a test suite to run, not to re-read code IRIS already reviews. If the project has no test setup, a QUEST task only does a quick check, unless the user has approved adding a test framework.

Choosing the Model column (leave it blank to use the agent's default):
- \`haiku\`: routine writing and mechanical changes (status updates, simple docs, renames)
- \`sonnet\`: most feature work, tests and reviews
- \`opus\` or \`fable\`: hard design or debugging, platform or OS internals, concurrency, and anything security-sensitive (auth, payments, secrets, permissions)

## Status
When asked for status, update \`claude/luna/status.md\`, \`claude/luna/blockers.md\` and \`claude/luna/timeline.md\` from the queue and the agents' folders.
Record decisions that change scope or plans in \`claude/luna/decisions.md\`.
EOF

agent atlas blue "$DOCS_TOOLS" \
  "Architect agent. Use to design system structure, components, data flow and key technical decisions before implementation, or when a change affects the architecture." <<'EOF'
You are ATLAS, the architect. You design; you don't write production code.

- Read the requirements in `claude/echo/` and the existing code before proposing anything. Fit the design to what already exists.
- Write `claude/atlas/architecture.md` (overview and main decisions), `components.md` (each component: responsibility, inputs, outputs, location in the codebase), `data-flow.md`, `patterns.md` and `dependencies.md`.
- For each significant decision, record the options you considered and why you chose one.
- Name concrete file paths where new code should go, so VOLT can follow the plan.
- Call out security-sensitive areas explicitly so LUNA can plan reviews for them.
- **Design for parallel work when the project is big enough.** For a small project (a single page or a few short files), one developer is faster and cheaper, so say so and skip the split. Otherwise, split the code by feature so separate developers can build different features at the same time: one file per component or feature where the stack allows it (for example `css/pricing.css` and `js/pricing.js`), and small shared files (entry points, global styles, routers) that mostly just include the feature files.
- When several features must live in one file (for example sections of a single `index.html`), plan a **scaffold**: a first task that writes the shared files with one marked region per feature, such as `<!-- region: pricing -->` … `<!-- /region: pricing -->`, with at least one unchanged line between regions. Each feature task then edits only its own region, so git can merge them.
- End `components.md` with a **Build contract**. For each file to be written, list exactly what it must provide to, and may rely on from, the others: element IDs, class names, data attributes, function names and signatures, API shapes. Also list which task owns which files and regions. Make it precise enough that separate developers can each build their part at the same time without talking to each other.
EOF

agent volt yellow "$NO_SPAWN" \
  "Developer agent. Use to implement a specific feature or change in the codebase, following ATLAS's design and the code standards." <<'EOF'
You are VOLT, the developer. You implement exactly the task you were given.

- Read the task, `claude/atlas/components.md` and `claude/volt/code-standards.md` first.
- Look at nearby code and follow its conventions. Reuse what exists before adding new helpers.
- Keep the change to the files your task names. If you must touch another file, say so in your report.
- Build or run the relevant tests before reporting. If you couldn't run them, say so.
- Track your task in `claude/volt/features/<task id>.md` (requirements checklist, files touched, test status) and write a one-line changelog entry to `claude/changelog.d/<task id>.md`.
EOF

agent iris orange "tools: Read, Write, Edit, Glob, Grep, Bash" \
  "Code review agent. Use after any implementation, debugging or optimization task to review the change for bugs, security issues and standards before it is marked done." <<'EOF'
You are IRIS, the reviewer. You review; you never modify project source code.

- Review only the changes your task names and the requirements they implement. With git, review the commit range you're given: `git diff <range>` and `git log <range>`. Don't read the rest of `claude/`; your task names the documents that matter.
- Start from the diff. Open surrounding code or reference code only where a change depends on it, and read those lines rather than whole files. Run the tests once; rerun only after something changed.
- A review usually covers one task's changes. Stay within them; other parts get their own reviews.
- For an integration check after a split build, check the parts fit together: every ID, class and function one file uses must exist in the others, as the build contract says.
- Check correctness first, then security, error handling, tests and `claude/volt/code-standards.md`.
- For each issue give the file and line, what goes wrong and in which situation, and a suggested fix.
- Rate issues Critical (must fix), Important (should fix) or Minor.
- Log findings in `claude/iris/issues-found.md` and a one-line entry in `claude/iris/code-review-log.md`.
- End your summary with a verdict: **APPROVED** or **NEEDS CHANGES**.
EOF

agent swift green "$NO_SPAWN" \
  "Performance agent. Use to measure and improve speed, memory use or bundle size in a specific part of the project." <<'EOF'
You are SWIFT, the optimizer.

- Measure before changing anything, and record the baseline in `claude/swift/performance-metrics.md`.
- Change one thing at a time, then measure again. Keep only changes that measurably help.
- Never change behavior. Run the tests after each change.
- Record what you tried, including what didn't help, in `claude/swift/log/<task id>.md`.
EOF

agent sage pink "$DOCS_TOOLS" \
  "Documentation agent. Use to write or update setup guides, API docs, architecture guides and troubleshooting notes from the actual code." <<'EOF'
You are SAGE, the documenter.

- Write from the code and `claude/atlas/`, not from memory. If the code and a doc disagree, the code wins; note the mismatch.
- Keep docs short and task-oriented: how to set up, how to run, how to use, what to do when it breaks.
- Work in `claude/sage/` unless the task names project docs (for example, README.md).
- Every command you document must be one you have confirmed exists in the project.
EOF

agent debug red "$NO_SPAWN" \
  "Debugging agent. Use to find the root cause of a specific bug, error or failing test and fix it." <<'EOF'
You are DEBUG, the debugger.

- Reproduce the problem first. If you can't reproduce it, report `blocked` with what you tried.
- Find the root cause, not just the symptom. Explain it in one or two sentences.
- Make the smallest fix that addresses the cause, and add a test that fails without it.
- Record the issue, its root cause and the fix in `claude/debug/fixes/<task id>.md`.
EOF

agent quest cyan "$NO_SPAWN" \
  "Testing agent. Use to write and run tests for a feature, cover edge cases, and report test results and coverage." <<'EOF'
You are QUEST, the tester.

- Your job is running tests, not reviewing code. Read only the files your task names.
- If the project has a test setup but you can't run it (for example, the command isn't permitted), write the tests, report that they haven't run and why, and stop. Don't check the code by reading it instead: that's IRIS's job.
- Use the project's existing test framework and conventions.
- **If the project has no test setup, don't build one.** Do a quick check with what's already available (for example, a syntax check or running the code once), keep it to a few minutes, and report that the project has no test setup. Recommend one in your Follow-ups; the user decides whether to add it. Only add a test framework when your task says the user approved it.
- Cover the happy path, error cases and the edge cases in `claude/quest/edge-cases.md`.
- Run the tests and report real results. Never report a test as passing that you didn't run.
- A failing test that reveals a real bug is a good result: report it, don't weaken the test.
- Write your results (suites run, passed, failed, coverage if measured) to `claude/quest/results/<task id>.md`.
EOF

# ── orchestration rules for the main session ─────────────────────────────────
git_section() {
  cat <<'EOF'
## Git workflow

The team works like a professional software team: every change is made on a branch, committed,
reviewed, and merged by you, the main session. Never commit to `main` or `master` directly. Never
push, force-push, reset, rebase or rewrite history unless the user explicitly asks.

1. **Start on a team branch.** Before the first build task:
   - If the repository has no commits yet, commit the team setup first:
     `git add .gitignore CLAUDE.md .claude/agents .claude/settings.json claude && git commit -m "chore: set up Claude dev team"`.
   - If you're on the default branch (`main` or `master`), create a branch for this work:
     `git switch -c team/<short-name>`, for example `team/landing-page`. Everything merges into it;
     the user decides when it goes into `main`.
2. **Commit before every batch.** Agents' worktrees start from the last commit and don't see
   uncommitted changes. First fold the changelog fragments: append each `claude/changelog.d/<task id>.md`
   entry to `claude/CHANGELOG.md` under Unreleased and delete the fragment. Then commit the plan and `claude/` updates:
   `git add claude && git commit -m "chore(team): plan batch <n>"`. Don't commit files the user
   changed themselves without asking. Write the commit's short hash under the batch heading in
   `claude/luna/task-queue.md`: it's where the batch's review range starts.
3. **Code tasks run in worktrees.** volt, debug, swift and quest each get their own worktree and
   branch automatically, commit their work there, and report the branch name.
4. **Merge each task as soon as its agent finishes,** without waiting for the rest of the batch:
   `git merge --no-ff <branch> -m "merge(<task id>): <task>"`.
   - On a conflict, run `git merge --abort`, mark the task `blocked`, and queue a fix task.
   - After merging, clean up: find the worktree with `git worktree list`, then
     `git worktree remove <path>` and `git branch -d <branch>`. If git refuses because the worktree
     has leftover files, check `git -C <path> status --short`: when it shows only generated files
     (build output, caches) and `git branch --merged` lists the branch, use `git worktree remove --force <path>`.
     Otherwise ask the user.
5. **Review each task as soon as it's merged.** Launch iris right away on just that task's changes,
   `git diff <merge hash>^1 <merge hash>`, while the other agents keep working. A task is `done` only
   after iris returns APPROVED. For NEEDS CHANGES, queue a fix task right away; it starts from the
   merged code. After a split build, run the integration check once every part is merged.
6. **If work is interrupted** (usage limit, crash, closed session), resume instead of restarting. For each
   task that was `running`: find its worktree with `git worktree list`; commit anything uncommitted there as
   `wip(<task id>): interrupted`; merge the branch with `git merge --no-ff <branch> -m "merge(<task id>): partial (wip)"`;
   mark the task `running (resumed from <hash>)`; then relaunch it, telling the agent to finish and verify the
   merged code, not to start over. Its iris review covers the whole task, wip commits included.
7. **Finish.** Fold any remaining changelog fragments. When the queue is complete, tell the user the team branch is ready to merge, with a
   summary of its commits (`git log --oneline main..HEAD`). Offer to push it and open a pull request
   with `gh pr create`, and only do so if the user says yes.

If a commit fails because git has no name or email, stop and ask the user to set them. Never invent an identity.

EOF
}
GIT_SECTION=""
[ "$USE_GIT" -eq 1 ] && GIT_SECTION=$(git_section)

if [ -n "$BUDGET" ]; then
  BUDGET_RULE="The project has a soft budget of **$BUDGET tokens**. After each batch, add the token counts reported for each finished agent to \`claude/luna/usage-log.md\`. When the running total reaches **$ALERT%** of the budget, stop and tell the user before starting anything else."
  BUDGET_LINE="$BUDGET tokens (alert at $ALERT%)"
else
  BUDGET_RULE="No token budget is set. Still log the token counts reported for each finished agent in \`claude/luna/usage-log.md\`."
  BUDGET_LINE="none"
fi

write "$CLAUDE_DIR/TEAM.md" "$UPDATE_AGENTS" <<EOF
# Claude Dev Team

This project uses a team of subagents defined in \`.claude/agents/\`. The shared workspace is \`claude/\`.

| Agent | Role | Default model |
|-------|------|---------------|
| echo | Discovery: requirements, scope, risks | $(model_for echo) |
| luna | Planning: task queue, status, blockers | $(model_for luna) |
| atlas | Architecture and design decisions | $(model_for atlas) |
| volt | Implementation | $(model_for volt) |
| iris | Code review (never edits source) | $(model_for iris) |
| swift | Performance | $(model_for swift) |
| sage | Documentation | $(model_for sage) |
| debug | Root-cause debugging | $(model_for debug) |
| quest | Tests | $(model_for quest) |

## Choose the path first

**Fast path, for small jobs.** If the request is one feature, fix or page touching a few files, and the user
has already said clearly what they want, skip discovery, design and planning:
1. Add the tasks to \`claude/luna/task-queue.md\` as a new batch, so progress is still tracked.
2. Delegate the build to **volt**: one task, or one per file in parallel if you can state a clear contract between them yourself.
3. Delegate the review to **iris**. Use **quest** only if there are tests to write or run.

**Full workflow, for everything else:** new projects, several features, or unclear requirements.
Use it whenever the user asks for it. If you can't tell which path fits, ask the user.

## Full workflow

1. **Discovery.** Best run as \`claude --agent echo\`, which interviews the user directly.
   In a normal session, subagents can't ask the user questions, so interview the user yourself
   with \`claude/echo/discovery-questions.md\`, save the answers to \`claude/echo/project-notes.md\`,
   then delegate the write-up to **echo**.
2. **Design.** Delegate to **atlas** once requirements exist.
3. **Plan.** Delegate to **luna** to write \`claude/luna/task-queue.md\`.
4. **Run a batch** when the user asks (for example, "run the next batch"):
   - A task is **ready** when it's \`pending\` and everything in its Depends on column is \`done\`.
   - Keep up to **$MAX_PARALLEL** agents working at all times: launch every ready task in the batch at
     once, in a single message with one agent call per task. When an agent finishes and more tasks
     become ready, start them right away instead of waiting for the rest of the batch.
     If the Model column is filled in, pass that model when launching the agent.
   - Give each agent its task row, the files it may touch, the base commit, and only the \`claude/\` sections
     that matter for that task (name sections and line ranges, not whole folders), so it doesn't spend
     tokens reading the rest. Tell it what's already verified so it doesn't re-check it.
   - Mark tasks \`running\`, then \`done\` or \`blocked\` from each agent's report.
   - After each batch, append each \`claude/changelog.d/<task id>.md\` entry to \`claude/CHANGELOG.md\`
     under Unreleased and delete the fragment.
   - Summarize the batch for the user and ask before starting the next one.
5. **Review.** Each VOLT, DEBUG or SWIFT task gets its own **iris** review, started as soon as that task
   finishes, while the other agents keep working. No such change is \`done\` until iris returns APPROVED.
   If iris says NEEDS CHANGES, queue a fix task for the original agent right away.
6. **Optional real-run check.** Tests can pass while the real thing is broken: a window that ignores
   clicks, a page that fails in one browser, a CLI that breaks on another OS. When the queue is done and
   the project is something that runs (an app, a site, a CLI), offer the user a real-run check: a **quest**
   task that launches it for real and tries the main features (with screenshots for anything visual), or
   short steps for the user to try it themselves. Only queue it if the user says yes.

$GIT_SECTION

## Budget

$BUDGET_RULE

## Ground rules

- Two tasks that touch the same file never run at the same time, unless the project uses git and
  the build contract gives each task its own marked region of that file.
- Agents report back to you; they don't launch other agents.
- Keep \`claude/luna/task-queue.md\` accurate. It is the source of truth for progress.
EOF

write "$CLAUDE_DIR/TEAM-CONFIG.md" "$UPDATE_AGENTS" <<EOF
# ⚙️ Team Configuration

Generated by setup.sh on $TODAY.

| Setting | Value | Where it lives |
|---------|-------|----------------|
| Model profile | $PROFILE | \`model:\` line in each \`.claude/agents/*.md\` |
| Parallel agents | $MAX_PARALLEL | \`claude/TEAM.md\` and \`.claude/settings.json\` |
| Token budget | $BUDGET_LINE | \`claude/TEAM.md\` |
| Git | $([ "$USE_GIT" -eq 1 ] && echo "on: branches, commits, reviewed merges" || echo off) | \`claude/TEAM.md\`, \`.claude/settings.json\`, \`isolation:\` in code agents |

## Changing settings

- **One agent's model:** edit the \`model:\` line in \`.claude/agents/<name>.md\`
  (\`haiku\`, \`sonnet\`, \`opus\`, \`fable\`, a full model ID, or \`inherit\`).
- **One task's model:** fill in the Model column in \`claude/luna/task-queue.md\`.
- **Everything at once:** re-run the setup script with \`--update-agents\`, for example
  \`./setup.sh . --update-agents --auto --profile quality --parallel 5\`.
  This rewrites the agent files, TEAM.md and this file only. Your notes in \`claude/\` are kept.
EOF

# Project settings: the parallel-agent cap, and with git, where worktrees branch from plus git permissions.
SETTINGS="$ROOT/.claude/settings.json"
settings_json() {
  if [ "$USE_GIT" -eq 1 ]; then
    cat <<EOF
{
  "env": {
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "$MAX_PARALLEL"
  },
  "worktree": {
    "baseRef": "head"
  },
  "permissions": {
    "allow": [
      "Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(git show:*)",
      "Bash(git branch:*)", "Bash(git switch:*)", "Bash(git rev-parse:*)", "Bash(git add:*)",
      "Bash(git commit:*)", "Bash(git merge:*)", "Bash(git worktree:*)"
    ],
    "deny": [
      "Bash(git push --force:*)", "Bash(git push -f:*)", "Bash(git reset --hard:*)", "Bash(git clean:*)",
      "Bash(git rebase:*)", "Bash(git branch -D:*)"
    ]
  }
}
EOF
  else
    cat <<EOF
{
  "env": {
    "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS": "$MAX_PARALLEL"
  }
}
EOF
  fi
}
# A settings file generated by an older version (only the parallel cap) is ours to replace.
OLD_TEMPLATE='^\{"env":\{"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS":"[0-9]+"\}\}$'
if [ ! -e "$SETTINGS" ]; then
  settings_json | write "$SETTINGS"
  SETTINGS_NOTE=""
elif tr -d ' \n\t' < "$SETTINGS" | grep -Eq "$OLD_TEMPLATE"; then
  settings_json | write "$SETTINGS" 1
  SETTINGS_NOTE=""
elif grep -q '"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"' "$SETTINGS"; then
  # Update just this value, leaving the rest of the file as it is.
  tmp=$(mktemp)
  sed -E "s/(\"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS\"[[:space:]]*:[[:space:]]*)\"[0-9]*\"/\1\"$MAX_PARALLEL\"/" "$SETTINGS" > "$tmp"
  if cmp -s "$tmp" "$SETTINGS"; then rm -f "$tmp"; else cat "$tmp" > "$SETTINGS"; rm -f "$tmp"; echo updated >> "$TALLY"; fi
  SETTINGS_NOTE=""
  if [ "$USE_GIT" -eq 1 ] && ! grep -q '"baseRef"' "$SETTINGS"; then
    SETTINGS_NOTE="add \"worktree\": { \"baseRef\": \"head\" } to $SETTINGS so agents branch from your current work, not the remote's main."
  fi
else
  SETTINGS_NOTE="$SETTINGS already exists, so it was left alone. To cap parallel agents, add \"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS\": \"$MAX_PARALLEL\" under \"env\"."
  [ "$USE_GIT" -eq 1 ] && SETTINGS_NOTE="$SETTINGS_NOTE For git, also add \"worktree\": { \"baseRef\": \"head\" } so agents branch from your current work."
fi

# CLAUDE.md imports TEAM.md so every session knows the workflow.
CLAUDE_MD="$ROOT/CLAUDE.md"
IMPORT_LINE="@claude/TEAM.md"
if [ ! -e "$CLAUDE_MD" ]; then
  write "$CLAUDE_MD" <<EOF
# Project instructions

$IMPORT_LINE
EOF
elif ! grep -qxF "$IMPORT_LINE" "$CLAUDE_MD"; then
  printf '\n%s\n' "$IMPORT_LINE" >> "$CLAUDE_MD"
  echo updated >> "$TALLY"
  echo "${YELLOW}note:${NC} added '$IMPORT_LINE' to your existing CLAUDE.md"
fi

# ── shared workspace (never overwritten) ─────────────────────────────────────
write "$CLAUDE_DIR/INDEX.md" <<'EOF'
# 🤖 Claude Dev Team: Project Dashboard

**How the team works:** [TEAM.md](./TEAM.md) · **Settings:** [TEAM-CONFIG.md](./TEAM-CONFIG.md)

## Start here
1. Discovery: run `claude --agent echo` and answer its questions
2. Ask Claude: "have atlas design the architecture"
3. Ask Claude: "have luna plan the tasks"
4. Ask Claude: "run the next batch", and repeat

## Key files
- [Project spec](./PROJECT_SPEC.md) · [Changelog](./CHANGELOG.md)
- [Requirements](./echo/requirements-summary.md) · [Task queue](./luna/task-queue.md) · [Status](./luna/status.md)
- [Architecture](./atlas/architecture.md) · [Open issues](./iris/issues-found.md) · [Blockers](./luna/blockers.md)
- [Token usage](./luna/usage-log.md)

## Agents
| Agent | Role | Dashboard |
|-------|------|-----------|
| 📋 ECHO | Discovery | [echo/INDEX.md](./echo/INDEX.md) |
| 🌙 LUNA | Planning | [luna/INDEX.md](./luna/INDEX.md) |
| 🏗️ ATLAS | Architecture | [atlas/INDEX.md](./atlas/INDEX.md) |
| ⚡ VOLT | Implementation | [volt/INDEX.md](./volt/INDEX.md) |
| 🔍 IRIS | Review | [iris/INDEX.md](./iris/INDEX.md) |
| ⚙️ SWIFT | Performance | [swift/INDEX.md](./swift/INDEX.md) |
| 📚 SAGE | Documentation | [sage/INDEX.md](./sage/INDEX.md) |
| 🐛 DEBUG | Debugging | [debug/INDEX.md](./debug/INDEX.md) |
| ✅ QUEST | Testing | [quest/INDEX.md](./quest/INDEX.md) |
EOF

write "$CLAUDE_DIR/PROJECT_SPEC.md" <<'EOF'
# Project Spec: [Project name]

*ECHO fills this in after the discovery interview.*

## In one paragraph
[What it is, who it's for, and the problem it solves]

## Must-haves (v1)
- [Feature]: [how we'll know it works]

## Out of scope
- [Feature]: [why]

## Constraints
- **Stack:** [languages, frameworks, hosting]
- **Deadline:** [date]
- **Other:** [security, compliance, devices, integrations]

## Status
- **Phase:** Discovery
- **Details:** see [luna/status.md](./luna/status.md)
EOF

write "$CLAUDE_DIR/CHANGELOG.md" <<EOF
# 📋 Changelog

## [Unreleased]

## $TODAY
- Team set up with setup.sh (profile: $PROFILE, parallel agents: $MAX_PARALLEL, budget: $BUDGET_LINE)
EOF

# index <agent> <title> <role> <file|label>...  — agent dashboard listing its files
index() {
  local agent="$1" title="$2" role="$3"; shift 3
  {
    printf '# %s\n\n**Role:** %s\n**Subagent:** [.claude/agents/%s.md](../../.claude/agents/%s.md)\n\n## Files\n' "$title" "$role" "$agent" "$agent"
    local item
    for item in "$@"; do printf -- '- [%s](./%s)\n' "${item#*|}" "${item%%|*}"; done
    printf '\n[← Dashboard](../INDEX.md)\n'
  } | write "$CLAUDE_DIR/$agent/INDEX.md"
}

# stub <path> <title> <body> — a simple placeholder file
stub() { printf '# %s\n\n%s\n' "$2" "$3" | write "$CLAUDE_DIR/$1"; }

# ECHO
index echo "📋 ECHO: Discovery" "Requirements, scope, personas and risks" \
  "discovery-questions.md|Discovery questions" "project-notes.md|Interview notes" \
  "requirements-summary.md|Requirements summary" "features-todo.md|Features to build" \
  "features-not-todo.md|Features to avoid" "user-personas.md|User personas" "scope.md|Scope" "risks.md|Risks"

write "$CLAUDE_DIR/echo/discovery-questions.md" <<'EOF'
# 📋 Discovery Questions

ECHO works through these in conversation, skipping any already answered.

## The project
1. What's the project called, and what does it do in one sentence?
2. What problem does it solve, and for whom?
3. Is this new, or does it build on existing code?
4. When does it need to be usable? Is there a hard deadline?

## Features
5. What's the single most important thing it must do?
6. What else must be in the first version?
7. What can wait for a later version?
8. What should it definitely *not* do?
9. Are there existing products you'd like it to resemble or avoid resembling?

## Technology
10. Any required languages, frameworks or hosting?
11. What does it need to connect to (APIs, databases, services)?
12. Any performance needs (users, data size, response time)?
13. Does it handle logins, payments, personal data or anything else sensitive?

## Constraints
14. Budget, and who else is working on it?
15. Which devices, browsers or platforms must it support?

## Success
16. How will you know it's working and worth it?
17. What would make this project fail?
18. What's the biggest risk you can see?
19. Anything else I should know?
EOF

stub echo/project-notes.md "📝 Interview Notes" "ECHO records the user's answers here during the interview, grouped by question.

*No interview yet.* Start one with \`claude --agent echo\`."
stub echo/requirements-summary.md "📊 Requirements Summary" "*Filled in by ECHO after the interview.*

## Overview
## Users
## Must-haves
## Constraints
## Success criteria"
stub echo/features-todo.md "✅ Features to Build" "*Filled in by ECHO.* Priority order; each feature has a one-line acceptance test.

| # | Feature | Acceptance test | Version |
|---|---------|-----------------|---------|"
stub echo/features-not-todo.md "❌ Features to Avoid" "*Filled in by ECHO.* What's out of scope, and why, so nobody builds it by accident.

| Feature | Why not | Reconsider when |
|---------|---------|-----------------|"
stub echo/user-personas.md "👥 User Personas" "*Filled in by ECHO.* For each type of user: goals, pain points, how often they use it."
stub echo/scope.md "📐 Scope" "*Filled in by ECHO.*

## In scope
## Out of scope
## Depends on"
stub echo/risks.md "⚠️ Risks" "*Filled in by ECHO, kept up to date by LUNA.*

| Risk | Impact | Likelihood | Mitigation | Owner |
|------|--------|------------|------------|-------|"

# LUNA
index luna "🌙 LUNA: Planning" "Task queue, status, timeline, blockers and decisions" \
  "task-queue.md|Task queue" "status.md|Status" "usage-log.md|Token usage" \
  "timeline.md|Timeline" "blockers.md|Blockers" "decisions.md|Decisions"

write "$CLAUDE_DIR/luna/task-queue.md" <<EOF
# 📋 Task Queue

*LUNA writes this after discovery. Claude runs it one batch at a time, up to $MAX_PARALLEL tasks in parallel.*

**Statuses:** \`pending\` · \`running\` · \`done\` · \`blocked\`
**Model:** blank = the agent's default (see [TEAM.md](../TEAM.md)); otherwise \`haiku\`, \`sonnet\`, \`opus\` or \`fable\`.

## Batch 1: Discovery

| ID | Task | Agent | Model | Depends on | Files | Status |
|----|------|-------|-------|------------|-------|--------|
| T1 | Write up requirements from the interview notes (run \`claude --agent echo\` first) | echo | | - | claude/echo/ | pending |
| T2 | Architecture | atlas | | T1 | claude/atlas/ | pending |
| T3 | Plan the remaining batches | luna | | T2 | claude/luna/ | pending |
EOF

stub luna/status.md "📊 Status" "**Phase:** Discovery
**Progress:** 0 of 3 tasks done

## Now
Waiting for the discovery interview.

## Next
1. ECHO interview
2. ATLAS architecture
3. LUNA plans the batches"

if [ -n "$BUDGET" ]; then BUDGET_HEAD="**Budget:** $BUDGET tokens · **Alert at:** $ALERT% ($((BUDGET * ALERT / 100)) tokens)"; else BUDGET_HEAD="**Budget:** none set"; fi
write "$CLAUDE_DIR/luna/usage-log.md" <<EOF
# 📈 Token Usage

$BUDGET_HEAD
**Used so far:** 0

Claude adds one row per finished agent, using the token count reported when it finishes.

| Batch | Task | Agent | Model | Tokens | Running total |
|-------|------|-------|-------|--------|---------------|
EOF

stub luna/timeline.md "📅 Timeline" "| Milestone | Target date | Status |
|-----------|-------------|--------|
| Discovery complete | | pending |
| Architecture agreed | | pending |
| First feature working | | pending |"
stub luna/blockers.md "🚫 Blockers" "None yet.

For each blocker: what's blocked, why, who can unblock it, and the status."
stub luna/decisions.md "✅ Decisions" "Decisions that change scope or plans, newest first: date, decision, reason, who decided."

# ATLAS
index atlas "🏗️ ATLAS: Architecture" "System design and technical decisions" \
  "architecture.md|Architecture" "components.md|Components" "data-flow.md|Data flow" \
  "patterns.md|Patterns" "dependencies.md|Dependencies"
stub atlas/architecture.md "🏗️ Architecture" "*Written by ATLAS after discovery.*

## Overview
## Main decisions
For each: the options considered, the choice, and why.
## Security-sensitive areas"
stub atlas/components.md "📦 Components" "For each component: responsibility, inputs, outputs, and where it lives in the codebase."
stub atlas/data-flow.md "🔀 Data Flow" "How data moves through the system, from input to storage to output."
stub atlas/patterns.md "🧩 Patterns" "Design patterns the codebase uses, with an example file for each."
stub atlas/dependencies.md "🔗 Dependencies" "External libraries and services, and which components depend on which."

# VOLT
index volt "⚡ VOLT: Implementation" "Builds features and changes" \
  "code-standards.md|Code standards" "features/in-progress.md|In progress" "reference-code/README.md|Reference code"
stub volt/code-standards.md "📋 Code Standards" "*Fill in from the project's existing code, or have ATLAS propose standards.*

## Language and formatting
## Naming
## Error handling
## Tests
Every feature ships with tests."
stub volt/features/in-progress.md "🚀 In Progress" "Each VOLT task keeps its own file here, \`<task id>.md\`, so parallel branches never edit the same notes file."
stub changelog.d/README.md "Changelog fragments" "Each task writes one \`<task id>.md\` here. The main session appends them to \`CHANGELOG.md\` before each batch and deletes them."
stub volt/reference-code/README.md "📚 Reference Code" "Short examples of how this codebase does common things (forms, API calls, auth checks), for VOLT to copy.
Add one file per pattern, for example \`pattern-api.md\`."

# IRIS
index iris "🔍 IRIS: Review" "Reviews every change before it's marked done" \
  "review-checklist.md|Review checklist" "issues-found.md|Open issues" "code-review-log.md|Review log"
write "$CLAUDE_DIR/iris/review-checklist.md" <<'EOF'
# ✅ Review Checklist

## Correctness
- [ ] Does what the task asked, including edge cases
- [ ] No crashes on empty, missing or unexpected input
- [ ] Errors are handled, not swallowed

## Security
- [ ] Input is validated; no injection (SQL, shell, HTML)
- [ ] No secrets in code or logs
- [ ] Access checks on anything user-specific

## Quality
- [ ] Follows [code standards](../volt/code-standards.md)
- [ ] Has tests, and they pass
- [ ] No leftover debug code

## Verdict
**APPROVED** or **NEEDS CHANGES**, with issues rated Critical, Important or Minor.
EOF
stub iris/issues-found.md "🐛 Open Issues" "| ID | File:line | Severity | Issue | Status |
|----|-----------|----------|-------|--------|"
stub iris/code-review-log.md "📝 Review Log" "| Date | Task | Verdict | Notes |
|------|------|---------|-------|"

# SWIFT
index swift "⚙️ SWIFT: Performance" "Measures and improves performance" \
  "performance-metrics.md|Metrics" "optimization-targets.md|Targets" "bottlenecks.md|Bottlenecks" "optimization-log.md|Optimization log"
stub swift/performance-metrics.md "📊 Performance Metrics" "| Metric | Baseline | Current | Target | Measured how |
|--------|----------|---------|--------|--------------|"
stub swift/optimization-targets.md "🎯 Targets" "What needs to be faster or smaller, and by how much."
stub swift/bottlenecks.md "🐌 Bottlenecks" "Known slow spots, with evidence (profiles, timings)."
stub swift/optimization-log.md "📝 Optimization Log" "| Date | Change | Before | After | Kept? |
|------|--------|--------|-------|-------|"

# SAGE
index sage "📚 SAGE: Documentation" "Setup, usage, API and troubleshooting docs" \
  "setup-guide.md|Setup guide" "api-docs.md|API docs" "architecture-guide.md|How it works" "troubleshooting.md|Troubleshooting"
stub sage/setup-guide.md "🔧 Setup Guide" "## Install
## Run
## Test"
stub sage/api-docs.md "📡 API Docs" "Each endpoint or public function: what it does, inputs, outputs, errors, an example."
stub sage/architecture-guide.md "📖 How It Works" "A newcomer's tour of the system. Source of truth: [atlas/architecture.md](../atlas/architecture.md)."
stub sage/troubleshooting.md "🆘 Troubleshooting" "| Symptom | Cause | Fix |
|---------|-------|-----|"

# DEBUG
index debug "🐛 DEBUG: Debugging" "Finds root causes and fixes bugs" \
  "known-issues.md|Known issues" "resolution-log.md|Resolution log" "issues/README.md|Issue write-ups"
stub debug/known-issues.md "🐛 Known Issues" "| ID | Title | Severity | Status |
|----|-------|----------|--------|"
stub debug/resolution-log.md "📝 Resolution Log" "| Date | Issue | Root cause | Fix | Regression test |
|------|-------|------------|-----|-----------------|"
stub debug/issues/README.md "🗂️ Issue Write-ups" "One file per complex bug (\`issue-001.md\`): reproduction steps, root cause, fix, test."

# QUEST
index quest "✅ QUEST: Testing" "Writes and runs tests" \
  "test-strategy.md|Test strategy" "test-cases.md|Test cases" "edge-cases.md|Edge cases" \
  "test-results.md|Latest results" "test-coverage.md|Coverage"
stub quest/test-strategy.md "🧪 Test Strategy" "Framework, where tests live, how to run them, and what must be tested before a task is done."
stub quest/test-cases.md "📝 Test Cases" "Per feature: Given / When / Then, and the test file that covers it."
stub quest/edge-cases.md "🎯 Edge Cases" "- Empty and very large input
- Missing or invalid data
- Slow or failing network
- Two users changing the same thing
- Permissions: a user reaching someone else's data"
stub quest/test-results.md "📊 Latest Test Results" "| Date | Suite | Passed | Failed | Notes |
|------|-------|--------|--------|-------|"
stub quest/test-coverage.md "📈 Coverage" "Coverage: not measured yet."

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "${GREEN}✅ Team ready${NC}  ${DIM}($(count created) created, $(count updated) updated, $(count kept) kept as they were)${NC}"
echo ""
echo "  Profile:          $PROFILE"
echo "  Parallel agents:  $MAX_PARALLEL"
echo "  Token budget:     $BUDGET_LINE"
echo ""
echo "  Agents:     $AGENT_DIR/"
echo "  Workspace:  $CLAUDE_DIR/"
echo "  Git:              $([ "$USE_GIT" -eq 1 ] && echo "on (agents use branches and worktrees)" || echo off)"
[ -n "$SETTINGS_NOTE" ] && { echo ""; echo "${YELLOW}note:${NC} $SETTINGS_NOTE"; }
[ -n "$GIT_NOTES" ] && { echo ""; printf "${YELLOW}git:${NC} %b" "$GIT_NOTES"; }
echo ""
echo "${YELLOW}Next:${NC}"
echo "  cd $ROOT"
echo "  claude --agent echo          # discovery interview"
echo "  claude                       # then: \"have luna plan the tasks\", \"run the next batch\""
