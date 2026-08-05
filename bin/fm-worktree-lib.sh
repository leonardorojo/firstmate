#!/usr/bin/env bash
# Shared task-root identity and WSL path validation for spawn, reporting, and teardown.
# The canonical WSL root is the only path accepted by Git, Treehouse, and cleanup.

fm_worktree_canonical_dir() {  # <path>
  local path=$1 real
  case "$path" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  real=$(CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || return 1
  case "$real" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s\n' "$real"
}

fm_worktree_common_dir() {  # <worktree>
  local worktree=$1 common
  common=$(git -C "$worktree" rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$common" in
    /*) ;;
    *) common="$worktree/$common" ;;
  esac
  fm_worktree_canonical_dir "$common"
}

fm_worktree_registered() {  # <project> <worktree>
  local project=$1 worktree=$2 line candidate matches=0
  while IFS= read -r line; do
    case "$line" in
      'worktree '*)
        candidate=$(fm_worktree_canonical_dir "${line#worktree }" 2>/dev/null || true)
        if [ "$candidate" = "$worktree" ]; then
          matches=$((matches + 1))
        fi
        ;;
    esac
  done < <(git -C "$project" worktree list --porcelain 2>/dev/null || true)
  [ "$matches" -eq 1 ]
}

fm_worktree_windows_path() {  # <canonical-wsl-path>
  local wsl=$1 windows roundtrip
  FM_WORKTREE_WINDOWS_PATH=
  case "$wsl" in
    /mnt/[A-Za-z]/*) ;;
    *) return 0 ;;
  esac
  command -v wslpath >/dev/null 2>&1 || {
    FM_WORKTREE_PATH_ERROR="wslpath is required for mounted WSL task roots"
    return 1
  }
  windows=$(wslpath -w "$wsl" 2>/dev/null) || {
    FM_WORKTREE_PATH_ERROR="WSL task-root conversion failed"
    return 1
  }
  case "$windows" in
    ''|*$'\n'*|*$'\r'*|*$'\t'*)
      FM_WORKTREE_PATH_ERROR="WSL task-root conversion was empty or ambiguous"
      return 1
      ;;
  esac
  case "$windows" in
    [A-Za-z]:\\*|\\\\*) ;;
    *)
      FM_WORKTREE_PATH_ERROR="WSL task-root conversion was not a Windows path"
      return 1
      ;;
  esac
  roundtrip=$(wslpath -u "$windows" 2>/dev/null) || {
    FM_WORKTREE_PATH_ERROR="Windows task-root conversion could not round-trip"
    return 1
  }
  [ "$roundtrip" = "$wsl" ] || {
    FM_WORKTREE_PATH_ERROR="Windows task-root conversion did not round-trip to the acquired root"
    return 1
  }
  FM_WORKTREE_WINDOWS_PATH=$windows
}

fm_worktree_validate_pair() {  # <primary> <task-root>
  local primary=$1 task_root=$2 primary_common task_common
  FM_WORKTREE_PRIMARY_WSL=
  FM_WORKTREE_WSL=
  FM_WORKTREE_PRIMARY_COMMON=
  FM_WORKTREE_COMMON=
  FM_WORKTREE_WINDOWS=
  FM_WORKTREE_PRIMARY_WINDOWS=
  FM_WORKTREE_PATH_ERROR=
  FM_WORKTREE_PRIMARY_WSL=$(fm_worktree_canonical_dir "$primary") || {
    FM_WORKTREE_PATH_ERROR="primary repository root is not a readable directory"
    return 1
  }
  FM_WORKTREE_WSL=$(fm_worktree_canonical_dir "$task_root") || {
    FM_WORKTREE_PATH_ERROR="acquired task root is not a readable directory"
    return 1
  }
  [ "$FM_WORKTREE_WSL" != "$FM_WORKTREE_PRIMARY_WSL" ] || {
    FM_WORKTREE_PATH_ERROR="acquired task root is the primary checkout"
    return 1
  }
  { [ -d "$FM_WORKTREE_WSL/.git" ] || [ -f "$FM_WORKTREE_WSL/.git" ]; } || {
    FM_WORKTREE_PATH_ERROR="acquired task root is not a Git worktree root"
    return 1
  }
  FM_WORKTREE_PRIMARY_COMMON=$(fm_worktree_common_dir "$FM_WORKTREE_PRIMARY_WSL") || {
    FM_WORKTREE_PATH_ERROR="primary repository identity is unavailable"
    return 1
  }
  FM_WORKTREE_COMMON=$(fm_worktree_common_dir "$FM_WORKTREE_WSL") || {
    FM_WORKTREE_PATH_ERROR="acquired task repository identity is unavailable"
    return 1
  }
  [ "$FM_WORKTREE_COMMON" = "$FM_WORKTREE_PRIMARY_COMMON" ] || {
    FM_WORKTREE_PATH_ERROR="acquired task root belongs to an unrelated repository"
    return 1
  }
  fm_worktree_registered "$FM_WORKTREE_PRIMARY_WSL" "$FM_WORKTREE_WSL" || {
    FM_WORKTREE_PATH_ERROR="acquired task root is not a registered worktree of the primary repository"
    return 1
  }
  fm_worktree_windows_path "$FM_WORKTREE_WSL" || return 1
  FM_WORKTREE_WINDOWS=$FM_WORKTREE_WINDOWS_PATH
  fm_worktree_windows_path "$FM_WORKTREE_PRIMARY_WSL" || return 1
  FM_WORKTREE_PRIMARY_WINDOWS=$FM_WORKTREE_WINDOWS_PATH
  return 0
}

fm_worktree_sha() {  # <canonical-task-root>
  local sha
  sha=$(git -C "$1" rev-parse --verify HEAD 2>/dev/null) || return 1
  fm_worktree_sha_valid "$sha" || return 1
  printf '%s\n' "$sha"
}

fm_worktree_sha_valid() {  # <sha>
  case "$1" in
    ''|*[!0-9a-fA-F]*) return 1 ;;
  esac
  [ "${#1}" -eq 40 ] || [ "${#1}" -eq 64 ]
}

fm_worktree_meta_optional_exact() {  # <meta> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -le 1 ] || return 1
  [ "$count" -eq 0 ] && return 0
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  case "$value" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  printf '%s' "$value"
}

fm_worktree_validate_meta_identity() {  # <meta> <task-id>
  local meta=$1 id=$2 recorded_wsl recorded_common actual_wsl actual_common explicit_wsl sha_key sha_value
  explicit_wsl=$(fm_worktree_meta_optional_exact "$meta" worktree_wsl) || return 1
  recorded_wsl=$explicit_wsl
  [ -n "$recorded_wsl" ] || recorded_wsl=$(fm_worktree_meta_optional_exact "$meta" worktree) || return 1
  actual_wsl=$(fm_worktree_canonical_dir "$recorded_wsl") || return 1
  if [ -n "$explicit_wsl" ] && [ "$actual_wsl" != "$recorded_wsl" ]; then
    return 1
  fi
  recorded_common=$(fm_worktree_meta_optional_exact "$meta" worktree_common_dir) || return 1
  if [ -n "$recorded_common" ]; then
    actual_common=$(fm_worktree_common_dir "$actual_wsl") || return 1
    [ "$actual_common" = "$recorded_common" ] || return 1
  fi
  for sha_key in spawn_head_sha current_head_sha final_head_sha; do
    sha_value=$(fm_worktree_meta_optional_exact "$meta" "$sha_key") || return 1
    [ -z "$sha_value" ] || fm_worktree_sha_valid "$sha_value" || return 1
  done
  FM_WORKTREE_META_WSL=$actual_wsl
  FM_WORKTREE_META_COMMON=${actual_common:-$recorded_common}
  return 0
}
