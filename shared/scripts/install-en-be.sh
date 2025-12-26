#!/usr/bin/env bash
set -euo pipefail

# Configuration
readonly LOCALE_NAME="en_BE.UTF-8"
readonly LOCALE_FILE="/usr/share/i18n/locales/en_BE"
readonly LOCALE_URL="https://raw.githubusercontent.com/BOAScripts/BOAScripts.github.io/refs/heads/main/shared/en_BE.UTF-8"
readonly BACKUP_DIR="${HOME}/.locale_backups"
readonly TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Check if running with sufficient privileges for system modifications
check_privileges() {
  if [[ $EUID -eq 0 ]]; then
    echo "Warning: Running as root. Consider using sudo for individual commands instead."
  fi
}

# Create backup directory
ensure_backup_dir() {
  if [[ ! -d "$BACKUP_DIR" ]]; then
    mkdir -p "$BACKUP_DIR"
    echo "==> Created backup directory: $BACKUP_DIR"
  fi
}

# Backup current locale configuration
backup_config() {
  ensure_backup_dir
  local backup_file="${BACKUP_DIR}/locale_backup_${TIMESTAMP}.tar.gz"
  
  echo "==> Creating backup of current configuration"
  
  local files_to_backup=()
  [[ -f /etc/locale.conf ]] && files_to_backup+=(/etc/locale.conf)
  [[ -f /etc/locale.gen ]] && files_to_backup+=(/etc/locale.gen)
  [[ -f /etc/default/locale ]] && files_to_backup+=(/etc/default/locale)
  
  if [[ ${#files_to_backup[@]} -gt 0 ]]; then
    sudo tar -czf "$backup_file" "${files_to_backup[@]}" 2>/dev/null || true
    sudo chown "$USER:$USER" "$backup_file"
    echo "==> Backup saved to: $backup_file"
    echo "$backup_file" > "${BACKUP_DIR}/latest_backup.txt"
  else
    echo "==> No locale configuration files found to backup"
  fi
}

# List available backups
list_backups() {
  ensure_backup_dir
  
  echo
  echo "Available backups:"
  echo "----------------"
  
  if compgen -G "${BACKUP_DIR}/locale_backup_*.tar.gz" > /dev/null; then
    ls -lh "${BACKUP_DIR}"/locale_backup_*.tar.gz | \
      awk '{print $9, "(" $5 ", " $6, $7, $8 ")"}'
  else
    echo "No backups found"
  fi
  echo
}

# Restore from backup
restore_config() {
  ensure_backup_dir
  
  list_backups
  
  if ! compgen -G "${BACKUP_DIR}/locale_backup_*.tar.gz" > /dev/null; then
    echo "No backups available to restore"
    return 1
  fi
  
  echo -n "Enter backup filename (or 'latest' for most recent): "
  read -r backup_choice
  
  local backup_file
  if [[ "$backup_choice" == "latest" ]]; then
    if [[ -f "${BACKUP_DIR}/latest_backup.txt" ]]; then
      backup_file=$(cat "${BACKUP_DIR}/latest_backup.txt")
    else
      backup_file=$(ls -t "${BACKUP_DIR}"/locale_backup_*.tar.gz | head -1)
    fi
  else
    backup_file="${BACKUP_DIR}/${backup_choice}"
  fi
  
  if [[ ! -f "$backup_file" ]]; then
    echo "Error: Backup file not found: $backup_file" >&2
    return 1
  fi
  
  echo "==> Restoring from: $backup_file"
  sudo tar -xzf "$backup_file" -C / 2>/dev/null
  
  echo "==> Running locale-gen to apply restored configuration"
  sudo locale-gen
  
  echo "==> Configuration restored successfully"
  echo "==> Please log out and back in for changes to take effect"
}

# Display locale examples
show_locale_examples() {
  echo
  echo "==> Testing $LOCALE_NAME formatting"
  echo "===================================="
  echo
  
  # Temporarily set locale for examples
  export LC_ALL="$LOCALE_NAME"
  export LANG="$LOCALE_NAME"
  
  echo "Date & Time Examples:"
  echo "  Short date:      $(date '+%x')"
  echo "  Long date:       $(date '+%A, %d %B %Y')"
  echo "  Time (24h):      $(date '+%X')"
  echo "  Date & Time:     $(date '+%c')"
  echo
  
  echo "Number & Currency Examples:"
  if command -v python3 &>/dev/null; then
    python3 << 'EOF'
import locale
locale.setlocale(locale.LC_ALL, 'en_BE.UTF-8')

print(f"  Large number:    {locale.format_string('%d', 1234567, grouping=True)}")
print(f"  Decimal:         {locale.format_string('%.2f', 1234.56, grouping=True)}")
print(f"  Currency:        {locale.currency(1234.56, grouping=True)}")
EOF
  else
    echo "  (Install python3 for number/currency formatting examples)"
  fi
  
  echo
  echo "Typical Belgian Formatting:"
  echo "  Date format:     dd/mm/yyyy (e.g., 26/12/2025)"
  echo "  Time format:     24-hour (e.g., 18:00)"
  echo "  Decimal sep:     , (comma)"
  echo "  Thousands sep:   . (period)"
  echo "  Currency:        € (Euro)"
  echo
}

# Verify locale installation
verify_locale() {
  if locale -a 2>/dev/null | grep -qi "^en_be\.utf8$"; then
    return 0
  fi
  return 1
}

# Download and install locale
install_locale() {
  echo "==> Downloading locale definition from remote source"
  if ! sudo curl -fsSL "$LOCALE_URL" -o "$LOCALE_FILE"; then
    echo "Error: Failed to download locale file" >&2
    return 1
  fi

  echo "==> Updating /etc/locale.gen"
  if [[ -f /etc/locale.gen ]]; then
    if ! grep -q "^en_BE.UTF-8 UTF-8" /etc/locale.gen; then
      echo "en_BE.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
    fi
  else
    echo "Warning: /etc/locale.gen not found. Skipping this step."
  fi

  echo "==> Generating locales (this may take a moment)"
  if ! sudo locale-gen; then
    echo "Error: locale-gen failed" >&2
    return 1
  fi

  echo "==> Locale $LOCALE_NAME installed successfully"
}

# Prompt user to change system-wide LANG
prompt_lang_change() {
  local current_lang
  current_lang=$(locale 2>/dev/null | awk -F= '/^LANG=/{print $2}' | tr -d '"')
  
  echo
  echo "Current LANG: ${current_lang:-not set}"
  echo -n "Switch LANG to $LOCALE_NAME system-wide? [y/N]: "
  read -r answer

  if [[ "$answer" =~ ^[Yy]$ ]]; then
    backup_config
    echo "LANG=$LOCALE_NAME" | sudo tee /etc/locale.conf >/dev/null
    echo "==> LANG updated to $LOCALE_NAME"
    echo "==> Please log out and back in for changes to take effect"
  else
    echo "==> LANG unchanged"
  fi
}

# Display usage information
show_usage() {
  cat << EOF
Usage: $0 [OPTION]

Install and configure en_BE.UTF-8 locale

Options:
  --install       Install locale and optionally set as system default
  --examples      Show date/time/currency formatting examples
  --backup        Create backup of current locale configuration
  --restore       Restore locale configuration from backup
  --list-backups  List available backups
  --help          Display this help message

If no option is provided, --install is assumed.

EOF
}

# Main execution
main() {
  local action="${1:-install}"
  
  case "$action" in
    --install|install)
      check_privileges
      echo "==> Checking for $LOCALE_NAME"
      
      if verify_locale; then
        echo "==> Locale $LOCALE_NAME is already installed"
        show_locale_examples
      else
        echo "==> Locale not found, proceeding with installation"
        backup_config
        install_locale || exit 1
        show_locale_examples
      fi
      
      prompt_lang_change
      ;;
    
    --examples|examples)
      if verify_locale; then
        show_locale_examples
      else
        echo "Error: Locale $LOCALE_NAME is not installed" >&2
        echo "Run '$0 --install' first" >&2
        exit 1
      fi
      ;;
    
    --backup|backup)
      backup_config
      ;;
    
    --restore|restore)
      restore_config
      ;;
    
    --list-backups|list-backups)
      list_backups
      ;;
    
    --help|help|-h)
      show_usage
      ;;
    
    *)
      echo "Error: Unknown option: $action" >&2
      echo "Run '$0 --help' for usage information" >&2
      exit 1
      ;;
  esac
}

main "$@"