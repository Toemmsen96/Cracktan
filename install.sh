#!/usr/bin/env bash
# Small helper to find Catan Universe installations inside Steam libraries
# Usage: ./install.sh --find-catan

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  cat <<EOF
Usage: $0 [--find-catan|--uninstall]

Options:
  --find-catan   Search Steam library folders for installed "Catan Universe" app(s) and install cracked files.
  --uninstall    Search Steam library folders for installed "Catan Universe" app(s) and restore original files.
  -h, --help     Show this help message.
EOF
}

# Parse common Steam library locations and appmanifest files to locate installed apps.
# Parameters:
#   $1 - mode: "install" or "uninstall"
find_catan_universe() {
  local mode="${1:-install}"
  
  # Determine source directory based on mode
  local source_dir_name
  local action_verb
  if [[ "$mode" == "uninstall" ]]; then
    source_dir_name="OriginalFiles"
    action_verb="Restoring"
  else
    source_dir_name="cracktanedFiles"
    action_verb="Installing"
  fi
  
  # Possible Steam config locations
  local STEAM_USER_DIRS=("$HOME/.steam" "$HOME/.local/share/Steam" "$HOME/.steam/steam" "/usr/local/share/steam" "/usr/share/steam")

  local checked=()
  local libraries=()

  # Helper: add library path if libraryfolders.vdf exists
  add_if_vdf() {
    local vdfpath="$1/steamapps/libraryfolders.vdf"
    if [[ -f "$vdfpath" ]]; then
      libraries+=("$1")
    fi
  }

  # Look for Steam installation directories
  for d in "${STEAM_USER_DIRS[@]}"; do
    if [[ -d "$d" ]] && [[ -f "$d/steamapps/libraryfolders.vdf" ]]; then
      libraries+=("$d")
    fi
  done

  # Also search common user Steam root in case of different layouts
  if [[ -d "$HOME/.local/share/Steam/steamapps" ]]; then
    libraries+=("$HOME/.local/share/Steam")
  fi

  # If we didn't find any libraryfolders.vdf yet, try scanning ~/.steam/* for steamapps
  if [[ ${#libraries[@]} -eq 0 ]]; then
    while IFS= read -r -d $'\0' path; do
      add_if_vdf "$(dirname "$path")"
    done < <(find "$HOME" -maxdepth 3 -type f -name libraryfolders.vdf -print0 2>/dev/null || true)
  fi

  # De-duplicate
  local uniq_libs=()
  for p in "${libraries[@]}"; do
    if [[ ! " ${uniq_libs[*]} " =~ " $p " ]]; then
      uniq_libs+=("$p")
    fi
  done

  libraries=("${uniq_libs[@]}")

  if [[ ${#libraries[@]} -eq 0 ]]; then
    echo "No Steam libraryfolders found. Checked: ${STEAM_USER_DIRS[*]} and searched $HOME" >&2
    return 1
  fi

  # Search each library for appmanifest_*.acf files that indicate installed apps
  local found=()
  for lib in "${libraries[@]}"; do
    local steamapps="$lib/steamapps"
    if [[ ! -d "$steamapps" ]]; then
      continue
    fi

    # Check appmanifest files
    for acf in "$steamapps"/appmanifest_*.acf; do
      [[ -e "$acf" ]] || continue
      # Extract the "name" field from the ACF (simple grep+sed, robust for common formats)
      local name
      name=$(grep '"name"' "$acf" 2>/dev/null | sed 's/^[[:space:]]*"name"[[:space:]]*"\(.*\)".*$/\1/' | sed -n '1p' || true)
      if [[ -z "$name" ]]; then
        # fallback: try to parse quoted strings in the file
        name=$(awk -F'"' '/"name"/{print $4; exit}' "$acf" || true)
      fi
      if [[ -n "$name" ]]; then
        # Case-insensitive match for 'Catan Universe'
        if echo "$name" | grep -qi "catan universe"; then
          # Try to deduce install dir from acf (common: "installdir" entry)
          local installdir
          installdir=$(awk -F'"' '/"installdir"/{print $4; exit}' "$acf" || true)
          if [[ -n "$installdir" ]]; then
            local candidate="$steamapps/common/$installdir"
            if [[ -d "$candidate" ]]; then
              found+=("$candidate")
            else
              # sometimes the folder exists with spaces/or different case; try find
              local match
              match=$(find "$steamapps/common" -maxdepth 2 -type d -iname "$installdir" -print -quit 2>/dev/null || true)
              if [[ -n "$match" ]]; then
                found+=("$match")
              else
                found+=("$steamapps (appmanifest: $acf) - installdir '$installdir' not found")
              fi
            fi
          else
            # No installdir: search common for directories containing the game name
            local guess
            guess=$(find "$steamapps/common" -maxdepth 2 -type d -iname "*catan*" -print 2>/dev/null || true)
            if [[ -n "$guess" ]]; then
              while IFS= read -r line; do
                found+=("$line")
              done <<<"$guess"
            else
              found+=("$steamapps (appmanifest: $acf) - name '$name' matched but no folder found")
            fi
          fi
        fi
      fi
    done
  done

  # Print results
  if [[ ${#found[@]} -eq 0 ]]; then
    echo "No Catan Universe installations found in detected Steam libraries." >&2
    return 2
  fi

  # Unique and print
  local uniq_found=()
  for p in "${found[@]}"; do
    if [[ ! " ${uniq_found[*]} " =~ " $p " ]]; then
      uniq_found+=("$p")
    fi
  done

  echo "Found ${#uniq_found[@]} Catan Universe installation(s):"
  for p in "${uniq_found[@]}"; do
    echo "  $p"
  done
  echo ""

  # Process each installation
  local success_count=0
  for install_dir in "${uniq_found[@]}"; do
    # Check if this is a valid directory path
    if [[ ! -d "$install_dir" ]]; then
      echo "Skipping: $install_dir (not a valid directory)" >&2
      continue
    fi

    # Look for the game executable (.exe or .x86_64)
    local exe_found=""
    if [[ -f "$install_dir/Catan.exe" ]]; then
      exe_found="Catan.exe"
    elif [[ -f "$install_dir/CatanUniverse.exe" ]]; then
      exe_found="CatanUniverse.exe"
    elif [[ -f "$install_dir/Catan.x86_64" ]]; then
      exe_found="Catan.x86_64"
    elif [[ -f "$install_dir/CatanUniverse.x86_64" ]]; then
      exe_found="CatanUniverse.x86_64"
    else
      # Try to find any .exe or .x86_64 file
      exe_found=$(find "$install_dir" -maxdepth 1 -type f \( -name "*.exe" -o -name "*.x86_64" \) -print -quit 2>/dev/null || true)
      if [[ -n "$exe_found" ]]; then
        exe_found=$(basename "$exe_found")
      fi
    fi

    if [[ -z "$exe_found" ]]; then
      echo "Skipping: $install_dir (no game executable found)" >&2
      continue
    fi

    echo "Found executable: $exe_found in $install_dir"

    # Look for CatanUniverse_Data directory
    local data_dir="$install_dir/CatanUniverse_Data"
    if [[ ! -d "$data_dir" ]]; then
      # Try alternative names
      if [[ -d "$install_dir/Catan_Data" ]]; then
        data_dir="$install_dir/Catan_Data"
      else
        echo "Warning: CatanUniverse_Data directory not found in $install_dir" >&2
        continue
      fi
    fi

    echo "Found data directory: $data_dir"

    # Check if source files directory exists
    local source_dir="$SCRIPT_DIR/$source_dir_name"
    if [[ ! -d "$source_dir" ]]; then
      echo "Error: $source_dir_name directory not found at $source_dir" >&2
      return 3
    fi

    # Copy files from source directory to CatanUniverse_Data
    echo "$action_verb files to $data_dir..."
    if cp -v "$source_dir"/* "$data_dir/" 2>&1; then
      if [[ "$mode" == "uninstall" ]]; then
        echo "✓ Successfully restored original files to $data_dir"
      else
        echo "✓ Successfully installed cracked files to $data_dir"
      fi
      ((success_count++))
    else
      echo "✗ Failed to copy files to $data_dir" >&2
    fi
    echo ""
  done

  if [[ $success_count -eq 0 ]]; then
    echo "No installations were successfully modified." >&2
    return 4
  else
    if [[ "$mode" == "uninstall" ]]; then
      echo "Successfully restored original files in $success_count installation(s)."
    else
      echo "Successfully modified $success_count installation(s)."
    fi
  fi
}

# CLI
if [[ ${#@} -eq 0 ]]; then
  read -p "No option provided. Do you want to install cracked files to Catan Universe? [Y/n]: " reply
  if [[ -z "$reply" || "$reply" =~ ^[Yy]$ ]]; then
    mode="install"
  else
    echo "Aborted."
    exit 0
  fi
  find_catan_universe "install"
  exit $?
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall)
      find_catan_universe "uninstall"
      exit $?
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    --install|--find-catan | *)
      find_catan_universe "install"
      exit $?
      ;;
  esac
done
