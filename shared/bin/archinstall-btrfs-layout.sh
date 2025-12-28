#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Arch Linux Btrfs Multi-Disk Setup Script v2.1
#
# This script automates the post-archinstall restructuring into a subvolume
# layout with split /var directories and separate home disk.
#
# REQUIREMENTS:
# - Run in Arch live environment
# - archinstall completed (btrfs, no encryption)
# - Two disks available
#=============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Script state
LOG_FILE="/tmp/btrfs-setup-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=false
HOME_COPY_SUCCESS=false

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"
}
log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"
}
log_warn() {
    echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"
}
log_error() {
    echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"
}
log_step() {
    echo "" | tee -a "$LOG_FILE"
    echo -e "${CYAN}${BOLD}━━━ $* ━━━${NC}" | tee -a "$LOG_FILE"
}

# Error handler
error_exit() {
    log_error "$1"
    echo ""
    echo -e "${DIM}Log file saved to: $LOG_FILE${NC}"
    exit 1
}

# Check if running as root
[[ $EUID -eq 0 ]] || error_exit "This script must be run as root"

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dry-run)
                DRY_RUN=true
                log_warn "DRY-RUN MODE: No changes will be made"
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Restructure an archinstall btrfs installation into a proper subvolume layout.

Options:
    --dry-run    Show what would be done without making changes
    --help, -h   Show this help message

Requirements:
    - Run from Arch live environment
    - archinstall completed with btrfs (no encryption)
    - Two disks: one for root, one for home

Supported Bootloaders:
    - Limine
    - GRUB
    - systemd-boot
    - rEFInd
EOF
}

# Interactive disk selection - FIXED numbering
select_disk() {
    local prompt="$1"
    local exclude="${2:-}"
    local -A disk_map
    local i=1

    echo ""
    echo -e "${BOLD}$prompt${NC}"
    echo ""

    while IFS= read -r line; do
        local name size
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')

        disk_map[$i]="$name"

        if [[ -n "$exclude" && "$name" == "$exclude" ]]; then
            echo -e "  ${DIM}$i) $name ($size) [already selected as root]${NC}"
        else
            echo -e "  $i) $name ($size)"
        fi
        ((i++))
    done < <(lsblk -ndo NAME,SIZE,TYPE | grep disk)

    local max=$((i - 1))
    echo ""

    while true; do
        read -p "Select disk number (1-$max): " selection

        if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
            echo -e "${RED}Please enter a number${NC}"
            continue
        fi

        if ((selection < 1 || selection > max)); then
            echo -e "${RED}Invalid selection. Please enter a number between 1 and $max${NC}"
            continue
        fi

        local selected_name="${disk_map[$selection]}"

        if [[ -n "$exclude" && "$selected_name" == "$exclude" ]]; then
            echo -e "${RED}That disk is already selected as root. Please choose a different disk.${NC}"
            continue
        fi

        SELECTED_DISK="$selected_name"
        return 0
    done
}

# Main configuration
configure() {
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Arch Linux Btrfs Multi-Disk Setup Configuration  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"

    select_disk "Select ROOT disk (system installation):"
    ROOT_DISK="$SELECTED_DISK"
    ROOT_DEV="/dev/${ROOT_DISK}"

    select_disk "Select HOME disk (user data):" "$ROOT_DISK"
    HOME_DISK="$SELECTED_DISK"
    HOME_DEV="/dev/${HOME_DISK}"

    # Detect partition naming scheme
    if [[ "$ROOT_DISK" =~ nvme|mmcblk ]]; then
        ROOT_EFI="${ROOT_DEV}p1"
        ROOT_PART="${ROOT_DEV}p2"
    else
        ROOT_EFI="${ROOT_DEV}1"
        ROOT_PART="${ROOT_DEV}2"
    fi

    if [[ "$HOME_DISK" =~ nvme|mmcblk ]]; then
        HOME_PART="${HOME_DEV}p1"
    else
        HOME_PART="${HOME_DEV}1"
    fi

    # Show configuration summary
    echo ""
    echo -e "${BOLD}Configuration Summary:${NC}"
    echo "┌─────────────────────────────────────────┐"
    echo "│  Root disk:    $ROOT_DEV"
    echo "│  ├─ EFI:       $ROOT_EFI"
    echo "│  └─ Root:      $ROOT_PART"
    echo "│"
    echo "│  Home disk:    $HOME_DEV"
    echo "│  └─ Home:      $HOME_PART"
    echo "└─────────────────────────────────────────┘"
    echo ""

    # Show planned subvolume layout
    echo -e "${BOLD}Planned Subvolume Layout:${NC}"
    echo "┌─────────────────────────────────────────┐"
    echo "│  Root Disk ($ROOT_DISK):"
    echo "│  ├─ @                  → /"
    echo "│  ├─ @var_log           → /var/log"
    echo "│  ├─ @var_cache         → /var/cache"
    echo "│  ├─ @var_tmp           → /var/tmp"
    echo "│  ├─ @var_lib_docker    → /var/lib/docker"
    echo "│  └─ @var_lib_libvirt   → /var/lib/libvirt"
    echo "│"
    echo "│  Home Disk ($HOME_DISK):"
    echo "│  ├─ @home              → /home"
    echo "│  └─ @games             → /games"
    echo "└─────────────────────────────────────────┘"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN] Would proceed with this configuration${NC}"
        read -p "Continue dry-run? (yes/no): " CONFIRM
    else
        read -p "Proceed with this configuration? (yes/no): " CONFIRM
    fi
    [[ "$CONFIRM" == "yes" ]] || error_exit "Configuration cancelled by user"
}

# Verify prerequisites
verify_prerequisites() {
    log_step "Verifying Prerequisites"

    local errors=0

    # Check partitions exist
    for part in "$ROOT_EFI:EFI" "$ROOT_PART:Root" "$HOME_PART:Home"; do
        local dev="${part%:*}"
        local name="${part#*:}"
        if [[ -b "$dev" ]]; then
            log_info "$name partition found: $dev"
        else
            log_error "$name partition not found: $dev"
            ((errors++))
        fi
    done

    [[ $errors -eq 0 ]] || error_exit "Missing partitions. Did archinstall complete successfully?"

    # Check filesystem types
    ROOT_FS=$(lsblk -no FSTYPE "$ROOT_PART")
    HOME_FS=$(lsblk -no FSTYPE "$HOME_PART")
    EFI_FS=$(lsblk -no FSTYPE "$ROOT_EFI")

    [[ "$ROOT_FS" == "btrfs" ]] || error_exit "Root partition is not btrfs (found: $ROOT_FS)"
    [[ "$HOME_FS" == "btrfs" ]] || error_exit "Home partition is not btrfs (found: $HOME_FS)"
    [[ "$EFI_FS" == "vfat" ]] || error_exit "EFI partition is not vfat (found: $EFI_FS)"

    log_success "All prerequisites verified"
}

# Unmount any existing mounts
cleanup_mounts() {
    log_info "Cleaning up existing mounts..."
    umount -R /mnt 2>/dev/null || true
    mkdir -p /mnt
}

# Create directory structure
setup_directories() {
    log_info "Setting up working directories..."
    mkdir -p /mnt/{root_top,home_top}
}

# Mount top-level btrfs filesystems
mount_toplevel() {
    log_step "Mounting Filesystems"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would mount $ROOT_PART to /mnt/root_top"
        log_info "[DRY-RUN] Would mount $HOME_PART to /mnt/home_top"
        return 0
    fi

    mount -o subvolid=5 "$ROOT_PART" /mnt/root_top || error_exit "Failed to mount root top-level"
    mount -o subvolid=5 "$HOME_PART" /mnt/home_top || error_exit "Failed to mount home top-level"
    log_success "Top-level filesystems mounted"
}

# Create subvolumes
create_subvolumes() {
    log_step "Creating Subvolumes"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would create subvolumes: @ @var_log @var_cache @var_tmp @var_lib_docker @var_lib_libvirt"
        log_info "[DRY-RUN] Would create subvolumes: @home @games"
        return 0
    fi

    # Root disk subvolumes
    if btrfs subvolume list /mnt/root_top | grep -q "path @$"; then
        log_warn "Subvolume @ already exists, skipping root subvolume creation"
    else
        local root_subvols=("@" "@var_log" "@var_cache" "@var_tmp" "@var_lib_docker" "@var_lib_libvirt")
        for subvol in "${root_subvols[@]}"; do
            btrfs subvolume create "/mnt/root_top/$subvol" || error_exit "Failed to create $subvol"
            log_info "Created subvolume: $subvol"
        done
        log_success "Root disk subvolumes created"
    fi

    # Home disk subvolumes
    if btrfs subvolume list /mnt/home_top | grep -q "path @home$"; then
        log_warn "Home subvolumes already exist, skipping"
    else
        local home_subvols=("@home" "@games")
        for subvol in "${home_subvols[@]}"; do
            btrfs subvolume create "/mnt/home_top/$subvol" || error_exit "Failed to create $subvol"
            log_info "Created subvolume: $subvol"
        done
        log_success "Home disk subvolumes created"
    fi
}

# Copy existing installation
copy_installation() {
    log_step "Copying System Installation"

    if [[ "$DRY_RUN" == true ]]; then
        if [[ -d /mnt/root_top/etc ]]; then
            log_info "[DRY-RUN] Would copy installation from top-level to @ subvolume"
        else
            log_info "[DRY-RUN] No installation found at top-level"
        fi
        return 0
    fi

    # Check if @ already has data
    if [[ $(ls -A /mnt/root_top/@ 2>/dev/null | wc -l) -gt 0 ]]; then
        log_warn "@ subvolume already contains data, skipping copy"
        return 0
    fi

    # Check if there's data to copy
    if [[ ! -d /mnt/root_top/etc ]]; then
        log_warn "No installation found at top-level, assuming subvolumes already set up"
        return 0
    fi

    log_info "Copying existing installation to @ subvolume..."
    log_warn "This may take several minutes..."

    rsync -aHAX --numeric-ids --info=progress2 \
        --exclude='/@*' \
        /mnt/root_top/ /mnt/root_top/@/ || error_exit "Failed to copy installation"

    # Verify copy
    [[ -f /mnt/root_top/@/etc/os-release ]] || error_exit "Installation copy verification failed"

    log_success "Installation copied successfully"
}

# Copy home data - handles all archinstall layouts
copy_home_data() {
    log_step "Copying Home Directory Data"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would detect and copy home directories to @home"
        return 0
    fi

    # Check if @home already has data
    local existing_count
    existing_count=$(find /mnt/home_top/@home -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [[ $existing_count -gt 0 ]]; then
        log_warn "@home already contains $existing_count directories, skipping copy"
        HOME_COPY_SUCCESS=true
        return 0
    fi

    HOME_SOURCE=""
    COPY_CONTENTS_ONLY=false

    # Priority 1: @ subvolume on root disk
    if [[ -d /mnt/root_top/@/home ]]; then
        local count
        count=$(find /mnt/root_top/@/home -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            HOME_SOURCE="/mnt/root_top/@/home"
            log_info "Found $count user directory(ies) in @/home on root disk"
        fi
    fi

    # Priority 2: Top-level home on root disk
    if [[ -z "$HOME_SOURCE" && -d /mnt/root_top/home ]]; then
        local count
        count=$(find /mnt/root_top/home -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            HOME_SOURCE="/mnt/root_top/home"
            log_info "Found $count user directory(ies) in /home on root disk"
        fi
    fi

    # Priority 3: /home subdirectory on home disk
    if [[ -z "$HOME_SOURCE" && -d /mnt/home_top/home ]]; then
        local count
        count=$(find /mnt/home_top/home -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            HOME_SOURCE="/mnt/home_top/home"
            log_info "Found $count user directory(ies) in /home on home disk"
        fi
    fi

    # Priority 4: User directories directly at top-level of home disk (archinstall does this!)
    if [[ -z "$HOME_SOURCE" ]]; then
        local count
        count=$(find /mnt/home_top -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name 'lost+found' 2>/dev/null | wc -l)
        if [[ $count -gt 0 ]]; then
            HOME_SOURCE="/mnt/home_top"
            COPY_CONTENTS_ONLY=true
            log_info "Found $count user directory(ies) at TOP-LEVEL of home disk"
            log_warn "This is the archinstall layout - user dirs are not inside /home"
        fi
    fi

    if [[ -z "$HOME_SOURCE" ]]; then
        log_warn "No home directory data found anywhere"
        log_info "Locations checked:"
        log_info "  - /mnt/root_top/@/home"
        log_info "  - /mnt/root_top/home"
        log_info "  - /mnt/home_top/home"
        log_info "  - /mnt/home_top/* (excluding @*)"
        return 0
    fi

    # Show what we'll copy
    echo ""
    echo -e "${BOLD}User directories to copy from ${CYAN}$HOME_SOURCE${NC}:"
    if [[ "$COPY_CONTENTS_ONLY" == true ]]; then
        find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name 'lost+found' -printf '  → %f\n'
        USER_DIR_COUNT=$(find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name 'lost+found' 2>/dev/null | wc -l)
    else
        find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' -printf '  → %f\n'
        USER_DIR_COUNT=$(find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | wc -l)
    fi
    echo ""

    log_info "Copying $USER_DIR_COUNT user directory(ies) to @home..."

    if [[ "$COPY_CONTENTS_ONLY" == true ]]; then
        # Copy each user directory individually, excluding subvolumes
        while IFS= read -r user_dir; do
            local username
            username=$(basename "$user_dir")
            log_info "Copying user: $username"
            rsync -aHAX --numeric-ids --info=progress2 \
                "$user_dir" /mnt/home_top/@home/ || error_exit "Failed to copy $username"
        done < <(find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d ! -name '@*' ! -name 'lost+found')
    else
        rsync -aHAX --numeric-ids --info=progress2 \
            "$HOME_SOURCE/" /mnt/home_top/@home/ || error_exit "Failed to copy home directory"
    fi

    # Verify copy
    local copied_count
    copied_count=$(find /mnt/home_top/@home -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' 2>/dev/null | wc -l)

    if [[ $copied_count -eq 0 ]]; then
        log_error "Copy verification failed: @home is empty after copy!"
        return 1
    fi

    if [[ $copied_count -ne $USER_DIR_COUNT ]]; then
        log_warn "Copy count mismatch: expected $USER_DIR_COUNT, got $copied_count"
    fi

    HOME_COPY_SUCCESS=true
    log_success "Home directory copied ($copied_count user directories)"

    echo ""
    echo -e "${BOLD}Users now in @home:${NC}"
    find /mnt/home_top/@home -mindepth 1 -maxdepth 1 -type d ! -name 'lost+found' -printf '  ✓ %f\n'
}

# Set default subvolume
set_default_subvol() {
    log_step "Setting Default Subvolume"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would set @ as default subvolume"
        return 0
    fi

    local root_at_id
    root_at_id=$(btrfs subvolume show /mnt/root_top/@ | awk '/Subvolume ID:/ {print $3}')
    [[ -n "$root_at_id" ]] || error_exit "Failed to get @ subvolume ID"

    btrfs subvolume set-default "$root_at_id" /mnt/root_top || error_exit "Failed to set default subvolume"

    # Verify
    local default_id
    default_id=$(btrfs subvolume get-default /mnt/root_top | awk '{print $2}')
    [[ "$default_id" == "$root_at_id" ]] || error_exit "Default subvolume verification failed"

    log_success "Default subvolume set to @ (ID: $root_at_id)"
}

# Cleanup old top-level installation
cleanup_old_installation() {
    log_step "Cleaning Up Old Data"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would check and optionally remove old top-level data"
        return 0
    fi

    # --- ROOT DISK CLEANUP ---
    mkdir -p /mnt/cleanup_check
    mount -o subvolid=5 "$ROOT_PART" /mnt/cleanup_check

    local old_root_dirs
    old_root_dirs=$(find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' 2>/dev/null | wc -l)

    echo ""
    echo -e "${BOLD}Root Disk Cleanup${NC}"

    if [[ $old_root_dirs -eq 0 ]]; then
        log_info "No old data found on root disk top-level"
    else
        log_warn "Found $old_root_dirs old directories at root disk top-level"
        echo ""
        echo "Directories that can be removed:"
        find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' -printf '  - %f\n'
        echo ""

        read -p "Remove old top-level data from root disk? (yes/no): " cleanup_confirm

        if [[ "$cleanup_confirm" == "yes" ]]; then
            log_info "Removing old directories..."
            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                -type d ! -name '@*' \
                -exec rm -rf --one-file-system {} + 2>/dev/null || log_warn "Some files couldn't be removed"
            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                ! -name '@*' ! -type d \
                -exec rm -f -- {} + 2>/dev/null || true
            log_success "Root disk cleanup complete"
        else
            log_info "Skipping root disk cleanup"
        fi
    fi

    umount /mnt/cleanup_check

    # --- HOME DISK CLEANUP ---
    echo ""
    echo -e "${BOLD}Home Disk Cleanup${NC}"

    mount -o subvolid=5 "$HOME_PART" /mnt/cleanup_check

    local old_home_dirs
    old_home_dirs=$(find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' 2>/dev/null | wc -l)

    if [[ $old_home_dirs -eq 0 ]]; then
        log_info "No old data found on home disk top-level"
    else
        # SAFETY CHECK: Verify @home has data before allowing deletion
        local athome_count
        athome_count=$(find /mnt/cleanup_check/@home -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)

        log_warn "Found $old_home_dirs old directories at home disk top-level"
        echo ""
        echo "Directories that would be removed:"
        find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' -printf '  - %f\n'
        echo ""

        if [[ $athome_count -eq 0 && "$HOME_COPY_SUCCESS" != true ]]; then
            echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}${BOLD}║  ⚠  DANGER: @home is EMPTY!                              ║${NC}"
            echo -e "${RED}${BOLD}║  Deleting these directories would cause DATA LOSS!       ║${NC}"
            echo -e "${RED}${BOLD}║  The home copy may have failed.                          ║${NC}"
            echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
            echo ""
            log_error "Refusing to delete user data when @home is empty"
            log_info "Please investigate why home copy failed before cleaning up"
            umount /mnt/cleanup_check
            rmdir /mnt/cleanup_check 2>/dev/null || true
            return 0
        fi

        if [[ $athome_count -gt 0 ]]; then
            echo -e "${GREEN}✓ @home contains $athome_count user directories - safe to proceed${NC}"
            echo ""
        fi

        read -p "Remove old top-level data from home disk? (yes/no): " cleanup_home_confirm

        if [[ "$cleanup_home_confirm" == "yes" ]]; then
            log_info "Removing old directories..."
            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                -type d ! -name '@*' \
                -exec rm -rf --one-file-system {} + 2>/dev/null || log_warn "Some files couldn't be removed"
            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                ! -name '@*' ! -type d \
                -exec rm -f -- {} + 2>/dev/null || true
            log_success "Home disk cleanup complete"
        else
            log_info "Skipping home disk cleanup"
        fi
    fi

    umount /mnt/cleanup_check
    rmdir /mnt/cleanup_check 2>/dev/null || true
}

# Mount final layout
mount_final_layout() {
    log_step "Mounting Final Layout"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would mount final subvolume layout"
        return 0
    fi

    log_info "Unmounting working mounts..."
    umount /mnt/root_top 2>/dev/null || true
    umount /mnt/home_top 2>/dev/null || true

    log_info "Mounting final filesystem layout..."

    # Root
    mount -o subvol=@,noatime,compress=zstd:3 "$ROOT_PART" /mnt || error_exit "Failed to mount @"

    # Create mountpoints
    mkdir -p /mnt/{boot,home,games,var/log,var/cache,var/tmp,var/lib/docker,var/lib/libvirt}

    # EFI
    mount "$ROOT_EFI" /mnt/boot || error_exit "Failed to mount EFI"

    # Home disk
    mount -o subvol=@home,noatime,compress=zstd:3 "$HOME_PART" /mnt/home || error_exit "Failed to mount @home"
    mount -o subvol=@games,noatime,compress=zstd:3 "$HOME_PART" /mnt/games || error_exit "Failed to mount @games"

    # /var subvolumes
    mount -o subvol=@var_log,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/log
    mount -o subvol=@var_cache,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/cache
    mount -o subvol=@var_tmp,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/tmp
    mount -o subvol=@var_lib_docker,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/lib/docker
    mount -o subvol=@var_lib_libvirt,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/lib/libvirt

    log_success "Final layout mounted"
}

# Generate fstab
generate_fstab() {
    log_step "Generating fstab"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would generate /etc/fstab"
        return 0
    fi

    genfstab -U /mnt > /mnt/etc/fstab || error_exit "Failed to generate fstab"

    log_success "fstab generated"
    echo ""
    echo -e "${BOLD}Generated /etc/fstab:${NC}"
    echo "────────────────────────────────────────"
    cat /mnt/etc/fstab
    echo "────────────────────────────────────────"
}

# Detect and update bootloader configuration
update_bootloader() {
    log_step "Updating Bootloader Configuration"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would detect and update bootloader configuration"
        return 0
    fi

    local bootloader=""
    local config_file=""
    local config_updated=false

    # Detect bootloader
    if [[ -d /mnt/boot/EFI/arch-limine ]] || [[ -f /mnt/boot/limine.conf ]]; then
        bootloader="limine"
        # Find limine config
        if [[ -f /mnt/boot/limine.conf ]]; then
            config_file="/mnt/boot/limine.conf"
        elif [[ -f /mnt/boot/EFI/arch-limine/limine.conf ]]; then
            config_file="/mnt/boot/EFI/arch-limine/limine.conf"
        elif [[ -f /mnt/boot/EFI/BOOT/limine.conf ]]; then
            config_file="/mnt/boot/EFI/BOOT/limine.conf"
        fi
    elif [[ -d /mnt/boot/grub ]]; then
        bootloader="grub"
        config_file="/mnt/etc/default/grub"
    elif [[ -d /mnt/boot/loader ]]; then
        bootloader="systemd-boot"
        # Find the arch entry
        config_file=$(find /mnt/boot/loader/entries -name '*.conf' -print -quit 2>/dev/null)
    elif [[ -d /mnt/boot/EFI/refind ]]; then
        bootloader="refind"
        config_file="/mnt/boot/EFI/refind/refind.conf"
    fi

    if [[ -z "$bootloader" ]]; then
        log_warn "Could not detect bootloader"
        log_info "You may need to manually add 'rootflags=subvol=@' to your kernel cmdline"
        return 0
    fi

    log_info "Detected bootloader: $bootloader"

    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_warn "Could not find config file for $bootloader"
        log_info "You may need to manually add 'rootflags=subvol=@' to your kernel cmdline"
        return 0
    fi

    log_info "Config file: $config_file"

    # Backup original config
    cp "$config_file" "${config_file}.bak.$(date +%Y%m%d-%H%M%S)"
    log_info "Backed up original config"

    case "$bootloader" in
        limine)
            update_limine_config "$config_file"
            config_updated=true
            ;;
        grub)
            update_grub_config "$config_file"
            config_updated=true
            ;;
        systemd-boot)
            update_systemd_boot_config "$config_file"
            config_updated=true
            ;;
        refind)
            update_refind_config "$config_file"
            config_updated=true
            ;;
    esac

    if [[ "$config_updated" == true ]]; then
        log_success "Bootloader configuration updated"
        echo ""
        echo -e "${BOLD}Updated config:${NC}"
        echo "────────────────────────────────────────"
        cat "$config_file"
        echo "────────────────────────────────────────"
    fi
}

update_limine_config() {
    local config="$1"
    log_info "Updating Limine configuration..."

    # Check if rootflags already present
    if grep -q "rootflags=subvol=@" "$config"; then
        log_info "rootflags=subvol=@ already present in config"
        return 0
    fi

    # Add rootflags=subvol=@ to cmdline
    # Limine format: cmdline: <options>
    if grep -q "^[[:space:]]*cmdline:" "$config"; then
        # Check if cmdline already has rootflags
        if grep -E "^[[:space:]]*cmdline:.*rootflags=" "$config"; then
            # Replace existing rootflags
            sed -i 's/rootflags=[^ ]*/rootflags=subvol=@/g' "$config"
        else
            # Append rootflags to existing cmdline
            sed -i '/^[[:space:]]*cmdline:/ s/$/ rootflags=subvol=@/' "$config"
        fi
        log_success "Added rootflags=subvol=@ to Limine cmdline"
    else
        log_warn "Could not find cmdline in Limine config"
        log_info "Please manually add 'rootflags=subvol=@' to your kernel cmdline"
    fi
}

update_grub_config() {
    local config="$1"
    log_info "Updating GRUB configuration..."

    # Check if rootflags already present
    if grep -q "rootflags=subvol=@" "$config"; then
        log_info "rootflags=subvol=@ already present in config"
        return 0
    fi

    # Add to GRUB_CMDLINE_LINUX_DEFAULT
    if grep -q "^GRUB_CMDLINE_LINUX_DEFAULT=" "$config"; then
        # Check current value
        local current
        current=$(grep "^GRUB_CMDLINE_LINUX_DEFAULT=" "$config" | cut -d'"' -f2)

        if [[ "$current" == *"rootflags="* ]]; then
            # Replace existing rootflags
            sed -i 's/rootflags=[^ ""]*/rootflags=subvol=@/g' "$config"
        else
            # Append to existing options
            sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 rootflags=subvol=@"/' "$config"
        fi
    else
        # Add the line
        echo 'GRUB_CMDLINE_LINUX_DEFAULT="rootflags=subvol=@"' >> "$config"
    fi

    log_success "Updated GRUB default config"
    log_info "Regenerating GRUB config..."

    # Regenerate grub.cfg
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg || {
        log_warn "Failed to regenerate GRUB config automatically"
        log_info "Please run 'grub-mkconfig -o /boot/grub/grub.cfg' after rebooting"
    }
}

update_systemd_boot_config() {
    local config="$1"
    log_info "Updating systemd-boot configuration..."

    # Check if rootflags already present
    if grep -q "rootflags=subvol=@" "$config"; then
        log_info "rootflags=subvol=@ already present in config"
        return 0
    fi

    # systemd-boot format: options <kernel options>
    if grep -q "^options" "$config"; then
        if grep -E "^options.*rootflags=" "$config"; then
            # Replace existing rootflags
            sed -i 's/rootflags=[^ ]*/rootflags=subvol=@/g' "$config"
        else
            # Append rootflags
            sed -i '/^options/ s/$/ rootflags=subvol=@/' "$config"
        fi
        log_success "Added rootflags=subvol=@ to systemd-boot options"
    else
        log_warn "Could not find options line in systemd-boot config"
    fi

    # Also update any other entry files
    for entry in /mnt/boot/loader/entries/*.conf; do
        if [[ -f "$entry" && "$entry" != "$config" ]]; then
            if ! grep -q "rootflags=subvol=@" "$entry"; then
                if grep -q "^options" "$entry"; then
                    sed -i '/^options/ s/$/ rootflags=subvol=@/' "$entry"
                    log_info "Updated entry: $(basename "$entry")"
                fi
            fi
        fi
    done
}

update_refind_config() {
    local config="$1"
    log_info "Updating rEFInd configuration..."

    # Check if rootflags already present
    if grep -q "rootflags=subvol=@" "$config"; then
        log_info "rootflags=subvol=@ already present in config"
        return 0
    fi

    # rEFInd: look for options lines within menuentry blocks
    # This is more complex; we'll try to add to existing options or add new line
    if grep -q "^[[:space:]]*options" "$config"; then
        if grep -E "^[[:space:]]*options.*rootflags=" "$config"; then
            sed -i 's/rootflags=[^ "]*/rootflags=subvol=@/g' "$config"
        else
            sed -i '/^[[:space:]]*options/ s/"$/ rootflags=subvol=@"/' "$config"
        fi
        log_success "Updated rEFInd options"
    else
        log_warn "Could not find options in rEFInd config"
        log_info "Please manually add 'rootflags=subvol=@' to your kernel options"
    fi

    # Also check refind_linux.conf if it exists
    local linux_conf="/mnt/boot/refind_linux.conf"
    if [[ -f "$linux_conf" ]]; then
        if ! grep -q "rootflags=subvol=@" "$linux_conf"; then
            cp "$linux_conf" "${linux_conf}.bak.$(date +%Y%m%d-%H%M%S)"
            sed -i 's/"$/ rootflags=subvol=@"/g' "$linux_conf"
            log_info "Also updated refind_linux.conf"
        fi
    fi
}

# Show final summary
show_summary() {
    log_step "Setup Complete"

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}${BOLD}║            ✓ Btrfs Layout Setup Complete!                ║${NC}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}This was a DRY-RUN. No changes were made.${NC}"
        echo "Run without --dry-run to apply changes."
        return 0
    fi

    # Show current mount status
    echo -e "${BOLD}Current Mounts:${NC}"
    findmnt -R /mnt --output TARGET,SOURCE,FSTYPE,OPTIONS -t btrfs,vfat | head -20
    echo ""

    # Show users in /home
    echo -e "${BOLD}Users in /home:${NC}"
    if [[ -d /mnt/home ]]; then
        find /mnt/home -mindepth 1 -maxdepth 1 -type d -printf '  ✓ %f\n' 2>/dev/null || echo "  (none found)"
    fi
    echo ""

    # Next steps
    echo -e "${BOLD}Next Steps:${NC}"
    echo "  1. Review /mnt/etc/fstab if needed"
    echo "  2. (Recommended) Enable TRIM support:"
    echo "       arch-chroot /mnt systemctl enable fstrim.timer"
    echo "  3. Reboot into your new system:"
    echo "       umount -R /mnt && reboot"
    echo ""
    echo -e "${DIM}Log file: $LOG_FILE${NC}"
    echo ""
}

# Post-setup chroot option
post_setup() {
    if [[ "$DRY_RUN" == true ]]; then
        return 0
    fi

    read -p "Would you like to chroot into the system now? (yes/no): " chroot_now
    if [[ "$chroot_now" == "yes" ]]; then
        log_info "Entering chroot (type 'exit' to return)..."
        arch-chroot /mnt || true
        echo ""
        log_info "Returned from chroot"
    fi
}

# Main execution
main() {
    parse_args "$@"

    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}       Arch Linux Btrfs Multi-Disk Setup Script v2.1       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    log_info "Log file: $LOG_FILE"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}${BOLD}DRY-RUN MODE - No changes will be made${NC}"
    fi

    echo ""
    log_warn "This script restructures your Arch installation"
    log_warn "Make sure archinstall has completed successfully!"
    echo ""

    read -p "Continue? (yes/no): " start
    [[ "$start" == "yes" ]] || error_exit "Setup cancelled by user"

    configure
    verify_prerequisites
    cleanup_mounts
    setup_directories
    mount_toplevel
    create_subvolumes
    copy_installation
    copy_home_data
    set_default_subvol
    cleanup_old_installation
    mount_final_layout
    generate_fstab
    update_bootloader  # NEW: Update bootloader config
    show_summary
    post_setup

    log_success "All done!"
}

main "$@"
