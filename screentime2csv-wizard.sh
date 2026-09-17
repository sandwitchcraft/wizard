#!/bin/bash
#
# ScreenTime2CSV setup wizard
#
# Checks prerequisites, downloads https://github.com/FelixKohlhas/ScreenTime2CSV,
# walks you through granting Full Disk Access, then exports your Screen Time
# data to output.csv.
#
# Usage:  ./screentime2csv-wizard.sh
#
# Everything is created in the directory you run it from:
#   ScreenTime2CSV/   the cloned repo
#   output.csv        your exported Screen Time data
#
# Safe to re-run: finished steps are skipped, and later runs can append just the
# usage recorded since the previous export.

set -u

REPO_URL="https://github.com/FelixKohlhas/ScreenTime2CSV.git"
REPO_DIR="$PWD/ScreenTime2CSV"
SCRIPT="$REPO_DIR/screentime2csv.py"
OUTPUT="$PWD/output.csv"
KNOWLEDGE_DB="$HOME/Library/Application Support/Knowledge/knowledgeC.db"
FULL_DISK_ACCESS_PANE="x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

if [ -t 1 ]; then
  BOLD=$'\033[1m' RED=$'\033[31m' GREEN=$'\033[32m' YELLOW=$'\033[33m' BLUE=$'\033[34m' RESET=$'\033[0m'
else
  BOLD="" RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

step() { printf '\n%s==> %s%s\n' "$BOLD$BLUE" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf '\n%sStopped:%s %s\n' "$BOLD$RED" "$RESET" "$1" >&2; exit 1; }

# Read a line from the keyboard into REPLY. Reads /dev/tty so prompts still
# work when the script is piped into bash.
ask() {
  printf '%s' "$1"
  read -r REPLY < /dev/tty || die "No terminal to read your answer from. Run this script directly in a terminal."
}

# Apple's /usr/bin/git and /usr/bin/python3 are stubs that fail until the
# Command Line Tools are installed and the Xcode license is accepted.
explain_failure() {
  printf '%s\n' "$1" | sed 's/^/      /'
  case "$1" in
    *license*)
      info "Fix: accept the Xcode license by running:  sudo xcodebuild -license" ;;
    *xcrun*|*"developer tools"*|*"developer path"*)
      info "Fix: install Apple's Command Line Tools by running:  xcode-select --install" ;;
  esac
}

# Prints ok, missing, or denied. stat works without Full Disk Access but
# reading the file doesn't, so actually read a byte.
database_access() {
  local err
  if err=$(head -c 1 "$KNOWLEDGE_DB" 2>&1 >/dev/null); then
    echo ok
  else
    case "$err" in
      *"No such file"*) echo missing ;;
      *)                echo denied ;;
    esac
  fi
}

# Best guess at the app this script runs inside, since that's the app that
# needs Full Disk Access.
host_app_name() {
  local app_path
  if [ -n "${__CFBundleIdentifier:-}" ]; then
    app_path=$(mdfind "kMDItemCFBundleIdentifier == '$__CFBundleIdentifier'" 2>/dev/null | head -n 1)
    if [ -n "$app_path" ]; then
      basename "$app_path" .app
      return
    fi
  fi
  case "${TERM_PROGRAM:-}" in
    Apple_Terminal) echo "Terminal" ;;
    iTerm.app)      echo "iTerm" ;;
    vscode)         echo "Visual Studio Code" ;;
    WezTerm)        echo "WezTerm" ;;
    ghostty)        echo "Ghostty" ;;
    WarpTerminal)   echo "Warp" ;;
    *)              echo "your terminal app" ;;
  esac
}

# Data rows in a CSV (lines minus the header), or 0 if the file doesn't exist.
count_rows() {
  local lines
  if [ -f "$1" ]; then
    lines=$(wc -l < "$1")
    echo $(( lines > 0 ? lines - 1 : 0 ))
  else
    echo 0
  fi
}

printf '%sScreenTime2CSV setup wizard%s\n' "$BOLD" "$RESET"
echo "Exports your Screen Time usage to $OUTPUT"

# ---------------------------------------------------------------------------
# 1. Requirements
# ---------------------------------------------------------------------------

step "Checking requirements"

[ "$(uname -s)" = "Darwin" ] || die "ScreenTime2CSV reads the macOS Screen Time database, so it only runs on macOS."
ok "macOS $(sw_vers -productVersion 2>/dev/null)"

missing=0

if ! command -v git >/dev/null 2>&1; then
  fail "git is not installed"
  info "Fix: install Apple's Command Line Tools by running:  xcode-select --install"
  missing=1
elif git_version=$(git --version 2>&1); then
  ok "$git_version"
else
  fail "git is installed but won't run:"
  explain_failure "$git_version"
  missing=1
fi

# screentime2csv.py only uses the standard library, but some Python builds
# leave out sqlite3.
PY_CHECK='
import sys
if sys.version_info < (3,):
    sys.exit("Python 3 is required, found Python %s" % sys.version.split()[0])
try:
    import sqlite3
except ImportError:
    sys.exit("Python %s was built without the sqlite3 module" % sys.version.split()[0])
print("Python %s" % sys.version.split()[0])
'
PYTHON=""
python_error=""
for candidate in python3 python; do
  command -v "$candidate" >/dev/null 2>&1 || continue
  if python_version=$("$candidate" -c "$PY_CHECK" 2>&1); then
    PYTHON=$(command -v "$candidate")
    break
  fi
  [ -n "$python_error" ] || python_error=$python_version
done

if [ -n "$PYTHON" ]; then
  ok "$python_version ($PYTHON)"
elif [ -n "$python_error" ]; then
  fail "Python is installed but can't be used:"
  explain_failure "$python_error"
  missing=1
else
  fail "Python 3 is not installed"
  info "Fix: run  xcode-select --install  or get it from https://www.python.org/downloads/"
  missing=1
fi

for cmd in head wc sed open; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    fail "Missing system command: $cmd"
    missing=1
  fi
done

[ "$missing" -eq 0 ] || die "Fix the issues above, then run this wizard again."

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------

step "Downloading ScreenTime2CSV"

if [ -d "$REPO_DIR/.git" ]; then
  origin=$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')
  case "$origin" in
    *github.com/felixkohlhas/screentime2csv*) ;;
    *) die "$REPO_DIR is a different git repository. Move it out of the way and run this wizard again." ;;
  esac
  if git -C "$REPO_DIR" pull --ff-only --quiet; then
    ok "Already downloaded to $REPO_DIR (checked for updates)"
  else
    warn "Already downloaded, but couldn't check for updates. Using the existing copy."
  fi
elif [ -e "$REPO_DIR" ]; then
  die "$REPO_DIR already exists but isn't a git clone. Move it out of the way and run this wizard again."
else
  git clone --depth 1 --quiet "$REPO_URL" "$REPO_DIR" \
    || die "Couldn't clone $REPO_URL. Check your internet connection and try again."
  ok "Cloned into $REPO_DIR"
fi

[ -f "$SCRIPT" ] || die "$SCRIPT is missing. Delete $REPO_DIR and run this wizard again."

# ---------------------------------------------------------------------------
# 3. Full Disk Access
# ---------------------------------------------------------------------------

step "Full Disk Access"

APP=$(host_app_name)

case "$(database_access)" in
  ok)
    ok "$APP can read the Screen Time database"
    ;;
  missing)
    die "There's no Screen Time database at $KNOWLEDGE_DB. Turn on Screen Time in System Settings, let it record some usage, then try again."
    ;;
  denied)
    # macOS only applies Full Disk Access after the app restarts, and quitting
    # the app ends this script anyway, so stop here and let the user rerun it.
    fail "$APP needs Full Disk Access to read your Screen Time data"
    open "$FULL_DISK_ACCESS_PANE" >/dev/null 2>&1 && info "Opening System Settings for you..."
    info ""
    info "  1. In System Settings, go to Privacy & Security > Full Disk Access"
    info "  2. Switch on $APP (use the + button to add it if it isn't listed)"
    info "  3. Quit $APP: choose Quit & Reopen if macOS asks, or press ⌘Q"
    info "     and open it again"
    info "  4. In the reopened $APP, press ${BOLD}↑ then Enter${RESET} to rerun this wizard"
    info ""
    info "The wizard will skip the steps that are already done. You can switch"
    info "Full Disk Access back off for $APP once your export is finished."
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 4. Export
# ---------------------------------------------------------------------------

step "Exporting Screen Time data"

if [ -f "$OUTPUT" ]; then
  warn "$OUTPUT already exists"
  ask "    [A]ppend usage recorded since the last export, [r]eplace the file, or [q]uit? "
  case "$REPLY" in
    [rR]*) rm -f "$OUTPUT" "$OUTPUT.last" ;;
    [qQ]*) echo "  Exiting without changes."; exit 0 ;;
  esac
else
  # screentime2csv.py keeps a checkpoint in output.csv.last. Without the CSV
  # beside it, a leftover checkpoint would silently skip older data.
  rm -f "$OUTPUT.last"
fi

rows_before=$(count_rows "$OUTPUT")
"$PYTHON" "$SCRIPT" -o "$OUTPUT" || die "screentime2csv.py reported an error (see above)."
rows_added=$(( $(count_rows "$OUTPUT") - rows_before ))

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

step "Done"

if [ "$rows_added" -gt 0 ]; then
  [ "$rows_added" -eq 1 ] && noun=row || noun=rows
  ok "Added $rows_added $noun to $OUTPUT"
  info "Columns: app, usage (seconds), start_time / end_time / created_at"
  info "(Unix timestamps), tz (seconds from GMT), device_id, device_model."
  info "Run this wizard again later to append only newer usage."
elif [ "$rows_before" -gt 0 ]; then
  ok "No new usage since the last export. $OUTPUT is up to date."
else
  warn "No Screen Time usage found, so $OUTPUT only has a header row."
  info "Make sure Screen Time is turned on. To include iPhone or iPad usage, sign"
  info "in to the same Apple Account and turn on Share Across Devices in Screen Time."
fi
