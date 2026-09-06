#!/usr/bin/env bash
# bin/fm-treehouse-lib.sh - resolve the treehouse command for spawn panes.
#
# Firstmate resolves treehouse in its own shell. Herdr can then receive the
# concrete native executable path when its pane is a Windows PowerShell process
# whose PATH does not include the Git Bash installation directory.

fm_treehouse_is_msys_mingw() {
  case "${OSTYPE:-}" in
    msys*|mingw*|cygwin*) return 0 ;;
  esac
  case "$(uname -s 2>/dev/null || true)" in
    MSYS*|MINGW*|CYGWIN*) return 0 ;;
  esac
  return 1
}

fm_treehouse_powershell_quote() {  # <native-executable>
  printf "'"
  printf '%s' "$1" | sed "s/'/''/g"
  printf "'"
}

# fm_treehouse_resolve_command <backend>: resolve treehouse once and publish
# FM_TREEHOUSE_EXECUTABLE plus FM_TREEHOUSE_GET_COMMAND for fm-spawn.sh.
# A POSIX absolute path on MSYS/MINGW must cross into Herdr's PowerShell as a
# native Windows path; cygpath is therefore required for that one boundary.
fm_treehouse_resolve_command() {  # <backend>
  local backend=${1:-} executable native
  executable=$(command -v treehouse 2>/dev/null || true)
  if [ -z "$executable" ] || [ ! -f "$executable" ] || [ ! -x "$executable" ]; then
    echo "error: treehouse is missing or is not an executable regular file in the Firstmate PATH" >&2
    return 1
  fi

  FM_TREEHOUSE_EXECUTABLE=$executable
  FM_TREEHOUSE_GET_COMMAND='treehouse get'
  if [ "$backend" = herdr ] && fm_treehouse_is_msys_mingw; then
    case "$executable" in
      /*)
        command -v cygpath >/dev/null 2>&1 || {
          echo "error: Herdr on MSYS/MINGW requires cygpath to convert treehouse '$executable' for PowerShell" >&2
          return 1
        }
        native=$(cygpath -w "$executable" 2>/dev/null || true)
        case "$native" in
          [A-Za-z]:\\*|[A-Za-z]:/*) ;;
          *)
            echo "error: cygpath did not return a native Windows path for treehouse '$executable'" >&2
            return 1
            ;;
        esac
        FM_TREEHOUSE_EXECUTABLE=$native
        FM_TREEHOUSE_GET_COMMAND="& $(fm_treehouse_powershell_quote "$native") get"
        ;;
    esac
  fi
}
