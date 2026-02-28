# git-standup

A daily git activity digest tool. Scans a configurable list of repositories, collects commits from the last N hours, and outputs a clean formatted summary grouped by repo.

## Usage

```
git-standup.sh [OPTIONS]

Options:
  --hours N          Look back N hours (default: 24)
  --repos p1,p2,...  Comma-separated list of repo paths to scan
  --root /path       Auto-discover git repos under this directory (maxdepth 3)
  --format FORMAT    Output format: text (default) or telegram
  --notify           Send output via: openclaw system event --text MSG --mode now
  --no-color         Disable ANSI colors in text output
  --help, -h         Show this help
```

If neither `--repos` nor `--root` is given, the current directory is scanned.

## Examples

```bash
# Standup for the last 24 hours across all projects
./git-standup.sh --root ~/code

# Last 48 hours, specific repos
./git-standup.sh --hours 48 --repos ~/projects/api,~/projects/web

# Send to Telegram via openclaw
./git-standup.sh --hours 8 --notify

# Telegram-formatted output (bold repo headers, backtick hashes)
./git-standup.sh --format telegram
```

## Output

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
my-api  [branch: main]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  abc1234  Jane Doe  2 hours ago
  feat: add user authentication

  def5678  Jane Doe  5 hours ago
  fix: resolve null pointer in login

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total: 2 commit(s) across 1 repo(s) (last 24h)
```

## Requirements

- `bash` (3.2+, macOS compatible)
- `git`
- `openclaw` (only needed when `--notify` is passed)
