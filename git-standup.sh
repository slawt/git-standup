#!/usr/bin/env bash
# git-standup.sh — Daily git activity digest across multiple repositories
# Usage: git-standup.sh [--hours N] [--repos path1,path2,...] [--root /path]
#                       [--format text|telegram] [--notify] [--no-color] [--help]
#
# Scans git repos for commits in the last N hours (default: 24).
# Groups output by repo with short hash, author, relative time, and message.
# Optionally sends the digest via: openclaw system event --text "$msg" --mode now
#
# Requires: git, bash, standard POSIX/BSD tools (date, find, awk, sed, basename)
# Optional: openclaw (only needed when --notify is passed)

# Intentionally NOT using set -e; errors are handled manually so output is robust.
set -uo pipefail

# ── Colors (text format only; stripped in telegram format) ────────────────────
BOLD='\033[1m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
DIM='\033[2m'
RESET='\033[0m'
SEP='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'

# ── Defaults ──────────────────────────────────────────────────────────────────
HOURS=24
REPOS_ARG=""
ROOT_ARG=""
FORMAT="text"
NOTIFY=0
NO_COLOR=0

# Disable colors if stdout is not a terminal
if [[ ! -t 1 ]]; then
    NO_COLOR=1
fi

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --hours N          Look back N hours (default: 24)
  --repos p1,p2,...  Comma-separated list of repo paths to scan
  --root /path       Auto-discover git repos under this directory (maxdepth 3)
  --format FORMAT    Output format: text (default) or telegram
  --notify           Send output via: openclaw system event --text MSG --mode now
  --no-color         Disable ANSI colors in text output
  --help, -h         Show this help

Notes:
  - If neither --repos nor --root is given, the current directory is used.
  - --repos and --root are mutually exclusive; --repos takes precedence.
  - --notify uses telegram-safe output regardless of --format.
  - Merge commits are excluded.
  - Repos with no commits in the window are silently skipped.

Examples:
  $(basename "$0") --hours 48 --root ~/code
  $(basename "$0") --repos ~/projects/api,~/projects/web --format telegram
  $(basename "$0") --hours 8 --notify
EOF
}

# ── Argument Parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hours)
            HOURS="${2:?--hours requires a value}"
            # Validate: must be a positive integer
            if ! [[ "$HOURS" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: --hours must be a positive integer (got: $HOURS)" >&2
                exit 1
            fi
            shift 2
            ;;
        --repos)
            REPOS_ARG="${2:?--repos requires a value}"
            shift 2
            ;;
        --root)
            ROOT_ARG="${2:?--root requires a value}"
            shift 2
            ;;
        --format)
            FORMAT="${2:?--format requires a value}"
            if [[ "$FORMAT" != "text" && "$FORMAT" != "telegram" ]]; then
                echo "ERROR: --format must be 'text' or 'telegram' (got: $FORMAT)" >&2
                exit 1
            fi
            shift 2
            ;;
        --notify)
            NOTIFY=1
            shift
            ;;
        --no-color)
            NO_COLOR=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        --*)
            echo "WARNING: Unknown flag '$1' (ignored)" >&2
            shift
            ;;
        *)
            echo "WARNING: Unexpected argument '$1' (ignored)" >&2
            shift
            ;;
    esac
done

# ── Prerequisite checks ───────────────────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    echo "ERROR: git is not installed or not in PATH" >&2
    exit 1
fi

if [[ "$NOTIFY" -eq 1 ]] && ! command -v openclaw >/dev/null 2>&1; then
    echo "ERROR: openclaw not found in PATH; required for --notify" >&2
    exit 1
fi

# --notify implies telegram-safe (no ANSI escape codes)
if [[ "$NOTIFY" -eq 1 ]]; then
    FORMAT="telegram"
    NO_COLOR=1
fi

# Strip colors when NO_COLOR is set
if [[ "$NO_COLOR" -eq 1 ]]; then
    BOLD=''; CYAN=''; YELLOW=''; DIM=''; RESET=''; SEP='─────────────────────────────────────────────────'
fi

# ── Resolve repo list ─────────────────────────────────────────────────────────
declare -a REPOS=()

if [[ -n "$REPOS_ARG" && -n "$ROOT_ARG" ]]; then
    echo "WARNING: Both --repos and --root specified; --repos takes precedence." >&2
fi

if [[ -n "$REPOS_ARG" ]]; then
    # Split comma-separated list; trim whitespace around each entry
    IFS=',' read -ra raw_repos <<< "$REPOS_ARG"
    for r in "${raw_repos[@]}"; do
        # Trim leading/trailing whitespace
        r="${r#"${r%%[![:space:]]*}"}"
        r="${r%"${r##*[![:space:]]}"}"
        [[ -n "$r" ]] && REPOS+=("$r")
    done
elif [[ -n "$ROOT_ARG" ]]; then
    if [[ ! -d "$ROOT_ARG" ]]; then
        echo "ERROR: --root path does not exist or is not a directory: $ROOT_ARG" >&2
        exit 1
    fi
    # Discover git repos; use while+read to handle spaces in paths
    while IFS= read -r git_dir; do
        repo_path="${git_dir%/.git}"
        REPOS+=("$repo_path")
    done < <(find "$ROOT_ARG" -maxdepth 3 -name ".git" -type d 2>/dev/null | sort)
else
    # Default: use current directory
    REPOS+=("$(pwd)")
fi

if [[ "${#REPOS[@]}" -eq 0 ]]; then
    echo "No repositories found to scan." >&2
    exit 0
fi

# ── Build git --since value ───────────────────────────────────────────────────
# Use "N hours ago" — git parses this portably on all platforms; avoids GNU vs BSD date issues.
SINCE="${HOURS} hours ago"

# ── Output builder ─────────────────────────────────────────────────────────────
# Collect full output into a variable so we can both print and --notify with it.
OUTPUT=""

append() {
    OUTPUT="${OUTPUT}${1}"$'\n'
}

# ── Scan repos ────────────────────────────────────────────────────────────────
total_commits=0
active_repos=0

for repo in "${REPOS[@]}"; do
    # Validate: must exist and be a directory
    if [[ ! -d "$repo" ]]; then
        echo "WARNING: Path does not exist or is not a directory, skipping: $repo" >&2
        continue
    fi

    # Validate: must be a git repo (works for both regular and bare repos)
    if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
        echo "WARNING: Not a git repository, skipping: $repo" >&2
        continue
    fi

    # Repo name from top-level directory name
    repo_name="$(basename "$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null || echo "$repo")")"

    # Current branch (handles detached HEAD gracefully)
    branch="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
    if [[ "$branch" == "HEAD" ]]; then
        # Detached HEAD — show short commit hash
        detached_hash="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo "unknown")"
        branch="HEAD detached at ${detached_hash}"
    fi

    # Collect commits: tab-delimited to avoid collisions with commit messages
    # Fields: %h (short hash) %x09 %an (author) %x09 %ar (relative time) %x09 %s (subject)
    # Use while+read instead of mapfile for bash 3.2 (macOS) compatibility
    commit_lines=()
    while IFS= read -r cline; do
        commit_lines+=("$cline")
    done < <(
        git -C "$repo" log \
            --since="$SINCE" \
            --format="%h%x09%an%x09%ar%x09%s" \
            --no-merges \
            2>/dev/null
    )

    # Skip repos with no activity
    if [[ "${#commit_lines[@]}" -eq 0 ]]; then
        continue
    fi

    repo_count="${#commit_lines[@]}"
    total_commits=$(( total_commits + repo_count ))
    active_repos=$(( active_repos + 1 ))

    # ── Format repo section ───────────────────────────────────────────────────
    if [[ "$FORMAT" == "telegram" ]]; then
        append ""
        append "*${repo_name}* [${branch}]"
        append "─────────────────────────────────"
    else
        append ""
        append "${CYAN}${SEP}${RESET}"
        append "${BOLD}${repo_name}${RESET}  ${DIM}[branch: ${branch}]${RESET}"
        append "${CYAN}${SEP}${RESET}"
    fi

    for line in "${commit_lines[@]}"; do
        # Split on tab
        IFS=$'\t' read -r hash author rel_time subject <<< "$line"

        if [[ "$FORMAT" == "telegram" ]]; then
            append "\`${hash}\`  ${author}  ${rel_time}"
            append "  ${subject}"
            append ""
        else
            append "  ${YELLOW}${hash}${RESET}  ${author}  ${DIM}${rel_time}${RESET}"
            append "  ${subject}"
            append ""
        fi
    done
done

# ── Footer ────────────────────────────────────────────────────────────────────
if [[ "$active_repos" -eq 0 ]]; then
    if [[ "$FORMAT" == "telegram" ]]; then
        append "No commits found in the last ${HOURS}h across ${#REPOS[@]} repo(s)."
    else
        append "${DIM}No commits found in the last ${HOURS}h across ${#REPOS[@]} repo(s).${RESET}"
    fi
else
    if [[ "$FORMAT" == "telegram" ]]; then
        append "─────────────────────────────────"
        append "Total: ${total_commits} commit(s) across ${active_repos} repo(s) (last ${HOURS}h)"
    else
        append "${CYAN}${SEP}${RESET}"
        append "${BOLD}Total: ${total_commits} commit(s) across ${active_repos} repo(s) (last ${HOURS}h)${RESET}"
    fi
fi

# ── Emit output ───────────────────────────────────────────────────────────────
# Strip leading blank line from OUTPUT before printing
OUTPUT="${OUTPUT#$'\n'}"

printf '%s\n' "$OUTPUT"

# ── Notify via openclaw ───────────────────────────────────────────────────────
if [[ "$NOTIFY" -eq 1 ]]; then
    openclaw system event --text "$OUTPUT" --mode now 2>/dev/null || true
fi
