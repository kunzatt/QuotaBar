#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
install_path=${1:-"$HOME/Applications/QuotaBar.app"}
install_dir=${install_path:h}
bundle_path="$project_dir/dist/QuotaBar.app"

if pgrep -f "$install_path/Contents/MacOS/QuotaBar" >/dev/null 2>&1; then
  print -u2 "QuotaBar is running at $install_path. Quit it before updating."
  exit 1
fi

"$project_dir/scripts/package-app.sh"
mkdir -p "$install_dir"
staging_dir=$(mktemp -d "$install_dir/.quotabar-update.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
ditto "$bundle_path" "$staging_dir/QuotaBar.app"

if [ -e "$install_path" ]; then
  backup_path="$HOME/.Trash/QuotaBar.app-replaced-$(date +%Y%m%d-%H%M%S)"
  mv "$install_path" "$backup_path"
  print "Previous version moved to $backup_path"
fi

mv "$staging_dir/QuotaBar.app" "$install_path"
print "Installed $install_path"
