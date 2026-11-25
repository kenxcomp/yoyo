#!/usr/bin/env bash
# install-skills.sh — install or uninstall t3-cr-loop's three skills for T3 Code.
#
# Usage:
#   bash plugins/t3-cr-loop/scripts/install-skills.sh                  # symlink into ~/.agents/skills/
#   bash plugins/t3-cr-loop/scripts/install-skills.sh --project <repo> # symlink into <repo>/.agents/skills/
#   bash plugins/t3-cr-loop/scripts/install-skills.sh --target <dir>   # symlink into custom skills dir
#   bash plugins/t3-cr-loop/scripts/install-skills.sh --check          # verify installation and script paths
#   bash plugins/t3-cr-loop/scripts/install-skills.sh --uninstall      # remove symlinks created by this plugin
#
# Compatible with macOS bash 3.2.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd -P)
SKILLS_SRC="$PLUGIN_ROOT/skills"
SKILLS="t3-cr-loop t3-cr-loop-merge t3-cr-loop-pr"

die() { printf 'install-skills: %s\n' "$*" >&2; exit 2; }

resolve_link_target() {
  perl -MCwd=abs_path -e '
    my ($p) = @ARGV;
    my $raw = readlink($p);
    exit 1 unless defined $raw;
    if ($raw !~ m{^/}) {
      require File::Basename;
      $raw = File::Basename::dirname($p) . "/" . $raw;
    }
    my $r = abs_path($raw);
    print defined($r) ? $r : $raw;
  ' -- "$1" 2>/dev/null
}

is_owned_symlink() {
  dst="$1"
  expected_src="$2"
  [ -L "$dst" ] || return 1
  resolved=$(resolve_link_target "$dst") || return 1
  [ "$resolved" = "$expected_src" ]
}

TARGET_DIR="$HOME/.agents/skills"
MODE="install"

while [ $# -gt 0 ]; do
  case "$1" in
    --project)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || die "--project requires a repo path"
      case "$2" in /*) _proj_p="$2" ;; *) _proj_p="./$2" ;; esac
      TARGET_DIR="$(cd -- "$_proj_p" && pwd -P)/.agents/skills" || die "invalid --project path: $2"
      shift 2
      ;;
    --target)
      [ $# -ge 2 ] && [ -n "${2:-}" ] || die "--target requires a directory path"
      TARGET_DIR="$2"
      shift 2
      ;;
    --check)     MODE="check"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "unknown arg: $1" ;;
  esac
done

case "$MODE" in
  install)
    mkdir -p -- "$TARGET_DIR" || die "cannot create $TARGET_DIR"
    for s in $SKILLS; do
      src="$SKILLS_SRC/$s"
      dst="$TARGET_DIR/$s"
      [ -d "$src" ] || die "missing source skill dir: $src"
      if [ -L "$dst" ]; then
        if ! is_owned_symlink "$dst" "$src"; then
          existing=$(resolve_link_target "$dst" || printf '<unresolvable>')
          die "refusing to overwrite foreign symlink at $dst -> $existing (expected $src)"
        fi
        rm -f -- "$dst" || die "cannot replace owned symlink $dst"
      elif [ -e "$dst" ]; then
        die "refusing to overwrite non-symlink at $dst — move or remove it first"
      fi
      ln -s -- "$src" "$dst" || die "failed to symlink $dst -> $src"
      printf 'INSTALLED %s -> %s\n' "$dst" "$src"
    done
    printf 'PLUGIN_ROOT=%s\n' "$PLUGIN_ROOT"
    printf 'Note: restart your T3 Code agent session ("Restart agent session") so the new skills appear.\n'
    ;;
  uninstall)
    for s in $SKILLS; do
      src="$SKILLS_SRC/$s"
      dst="$TARGET_DIR/$s"
      if [ -L "$dst" ]; then
        if is_owned_symlink "$dst" "$src"; then
          rm -f -- "$dst" || die "cannot remove $dst"
          printf 'REMOVED %s\n' "$dst"
        else
          existing=$(resolve_link_target "$dst" || printf '<unresolvable>')
          printf 'SKIPPED %s (foreign symlink -> %s; preserved)\n' "$dst" "$existing"
        fi
      else
        printf 'SKIPPED %s (not a symlink; preserved)\n' "$dst"
      fi
    done
    ;;
  check)
    ok=1
    for s in $SKILLS; do
      dst="$TARGET_DIR/$s"
      if [ ! -f "$dst/SKILL.md" ]; then
        printf 'MISSING %s/SKILL.md\n' "$dst"
        ok=0
        continue
      fi
      case "$dst" in /*) _dst_p="$dst" ;; *) _dst_p="./$dst" ;; esac
      real_skill=$(cd -- "$_dst_p" && pwd -P)
      real_root=$(cd "$real_skill/../.." && pwd -P)
      if [ -x "$real_root/scripts/t3-cr-state.sh" ] && [ -f "$real_root/references/review-protocol.md" ]; then
        printf 'OK %s (plugin_root=%s)\n' "$s" "$real_root"
      else
        printf 'BROKEN %s (cannot resolve scripts/t3-cr-state.sh from %s)\n' "$s" "$real_root"
        ok=0
      fi
    done
    [ "$ok" -eq 1 ] || exit 1
    ;;
esac
