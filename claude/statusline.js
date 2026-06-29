#!/usr/bin/env node
// Claude Code statusline.
// Shows: model | current in-progress todo | directory + git branch/worktree |
// context-window meter.
//
// The git segment reflects the session's ANCHORED dir (workspace.current_dir),
// never whatever a Bash command last `cd`'d into -- per-command cwd resets and
// is invisible to this render process. Enter worktrees via the native worktree
// tool (it re-anchors the session) so this segment tracks them; a worktree
// driven by per-command `cd` from the main checkout keeps showing the main
// branch because the anchor never moved.
//
// Ported from GSD's statusline (the model/dir/context/todo render only); all
// GSD-specific state, update-check, and context-monitor bridge logic dropped.
// Git branch/worktree segment added locally.

const fs = require("fs");
const path = require("path");
const os = require("os");
const { execFileSync } = require("child_process");

// Default total context window when the host does not report one.
const DEFAULT_TOTAL_CTX = 1_000_000;
// Claude Code reserves a buffer for autocompact (~16.5% of the window by
// default). Subtract it so the meter reflects usable context, not raw tokens.
const DEFAULT_AUTO_COMPACT_BUFFER_PCT = 16.5;

const RESET = "\x1b[0m";
const DIM = "\x1b[2m";
const BOLD = "\x1b[1m";

// Marker shown before the branch name when the cwd is a linked worktree, so a
// glance tells you you are not in the main checkout.
const WORKTREE_GLYPH = "⑂";

/**
 * Find the activeForm of the most recent in-progress todo for this session.
 * Returns '' when there is none or the todos dir is unreadable.
 */
function readActiveTask(session, claudeDir) {
  if (!session) return "";
  const todosDir = path.join(claudeDir, "todos");
  if (!fs.existsSync(todosDir)) return "";
  try {
    const files = fs
      .readdirSync(todosDir)
      .filter(
        (f) =>
          f.startsWith(session) && f.includes("-agent-") && f.endsWith(".json"),
      )
      .map((f) => ({
        name: f,
        mtime: fs.statSync(path.join(todosDir, f)).mtime,
      }))
      .sort((a, b) => b.mtime - a.mtime);
    if (files.length === 0) return "";
    const todos = JSON.parse(
      fs.readFileSync(path.join(todosDir, files[0].name), "utf8"),
    );
    const inProgress = todos.find((t) => t.status === "in_progress");
    return inProgress ? inProgress.activeForm || "" : "";
  } catch (e) {
    return "";
  }
}

/**
 * Read git branch, dirty state, and whether `dir` is a linked worktree.
 * Returns null when `dir` is not inside a git work tree or git is unavailable.
 * Fails silently: the statusline must never break on a non-git dir.
 */
function readGitInfo(dir) {
  if (!dir) return null;
  const run = (args) =>
    execFileSync("git", args, {
      cwd: dir,
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 1000,
    }).trim();
  try {
    // One call yields the branch, the per-worktree git dir, and the shared
    // common dir. A linked worktree has a git dir distinct from the common dir.
    const out = run([
      "rev-parse",
      "--abbrev-ref",
      "HEAD",
      "--git-dir",
      "--git-common-dir",
    ]);
    const [rawBranch, gitDir, commonDir] = out.split("\n");
    let branch = rawBranch;
    if (branch === "HEAD") {
      // Detached HEAD: show the short commit instead of the literal "HEAD".
      try {
        branch = run(["rev-parse", "--short", "HEAD"]);
      } catch (e) {
        branch = "detached";
      }
    }
    const resolvedCommon = path.resolve(dir, commonDir);
    const isWorktree = path.resolve(dir, gitDir) !== resolvedCommon;
    // Repo-root name, stable across the main checkout and every linked
    // worktree: the common dir is "<repo-root>/.git", so its parent's basename
    // is the repo name. Without this the segment would show the worktree's own
    // directory (e.g. "rw-bess-BESS-1704-..."), which duplicates the branch and
    // pushes the context meter off-screen. Fall back to the cwd basename for
    // non-standard layouts (custom git dir, bare repo) where the assumption
    // does not hold.
    const repoName =
      path.basename(resolvedCommon) === ".git"
        ? path.basename(path.dirname(resolvedCommon))
        : path.basename(dir);
    let dirty = false;
    try {
      dirty = run(["status", "--porcelain"]) !== "";
    } catch (e) {
      dirty = false;
    }
    return { branch, dirty, isWorktree, repoName };
  } catch (e) {
    return null; // not a git repo, or git not on PATH
  }
}

/**
 * Build the colored context-window meter segment, e.g. ' █████░░░░░ 47%'.
 * Returns '' when the host does not report remaining context.
 */
function buildContextMeter(remaining, totalCtx) {
  if (remaining == null) return "";
  const acw = parseInt(process.env.CLAUDE_CODE_AUTO_COMPACT_WINDOW || "0", 10);
  const bufferPct =
    acw > 0
      ? Math.min(100, (acw / totalCtx) * 100)
      : DEFAULT_AUTO_COMPACT_BUFFER_PCT;

  const usableRemaining = Math.max(
    0,
    ((remaining - bufferPct) / (100 - bufferPct)) * 100,
  );
  const used = Math.max(0, Math.min(100, Math.round(100 - usableRemaining)));

  const filled = Math.floor(used / 10);
  const bar = "█".repeat(filled) + "░".repeat(10 - filled);

  if (used < 50) return ` \x1b[32m${bar} ${used}%${RESET}`;
  if (used < 65) return ` \x1b[33m${bar} ${used}%${RESET}`;
  if (used < 80) return ` \x1b[38;5;208m${bar} ${used}%${RESET}`;
  return ` \x1b[5;31m${bar} ${used}%${RESET}`;
}

/**
 * Build the directory segment, suffixed with git branch/worktree info. Inside a
 * git repo the label is the repo-root name, not the cwd basename, so a linked
 * worktree reads 'rw-bess  ⑂ talon/BESS-1704/...' instead of repeating the
 * worktree's own long directory name. Outside git it falls back to the cwd
 * basename, e.g. 'Downloads'.
 */
function buildDirSegment(dir) {
  const git = readGitInfo(dir);
  if (!git) return `${DIM}${path.basename(dir)}${RESET}`;
  const wt = git.isWorktree ? `${WORKTREE_GLYPH} ` : "";
  const flag = git.dirty ? "*" : "";
  return `${DIM}${git.repoName}  ${wt}${git.branch}${flag}${RESET}`;
}

function render(data) {
  const model = data.model?.display_name || "Claude";
  const dir = data.workspace?.current_dir || process.cwd();
  const session = data.session_id || "";
  const claudeDir =
    process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), ".claude");

  const ctx = buildContextMeter(
    data.context_window?.remaining_percentage,
    data.context_window?.total_tokens || DEFAULT_TOTAL_CTX,
  );
  const task = readActiveTask(session, claudeDir);

  const modelSeg = `${DIM}${model}${RESET}`;
  const dirSeg = buildDirSegment(dir);
  if (task) return `${modelSeg} │ ${BOLD}${task}${RESET} │ ${dirSeg}${ctx}`;
  return `${modelSeg} │ ${dirSeg}${ctx}`;
}

function main() {
  let input = "";
  // Exit silently if stdin never closes (pipe issues), instead of hanging.
  const timeout = setTimeout(() => process.exit(0), 3000);
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    input += chunk;
  });
  process.stdin.on("end", () => {
    clearTimeout(timeout);
    try {
      process.stdout.write(render(JSON.parse(input)));
    } catch (e) {
      // Silent fail: never break the host's statusline on bad input.
    }
  });
}

module.exports = {
  render,
  buildContextMeter,
  readActiveTask,
  readGitInfo,
  buildDirSegment,
};

if (require.main === module) main();
