#!/usr/bin/env bash
set -euo pipefail

#=============================================================================
# Arch Linux Btrfs Multi-Disk Setup Script
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
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Error handler
error_exit() {
    log_error "$1"
    exit 1
}

# Check if running as root
[[ $EUID -eq 0 ]] || error_exit "This script must be run as root"

# Detect available disks
detect_disks() {
    log_info "Detecting available disks..."
    lsblk -ndo NAME,SIZE,TYPE | grep disk
    echo ""
}

# Main configuration
configure() {
    echo -e "${GREEN}╔═══════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  Arch Linux Btrfs Multi-Disk Setup Configuration  ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════╝${NC}"
    echo ""

    detect_disks

    read -p "Enter ROOT disk (e.g., vda, sda, nvme0n1): " ROOT_DISK
    ROOT_DEV="/dev/${ROOT_DISK}"
    [[ -b "$ROOT_DEV" ]] || error_exit "Root disk $ROOT_DEV not found"

    read -p "Enter HOME disk (e.g., vdb, sdb, nvme1n1): " HOME_DISK
    HOME_DEV="/dev/${HOME_DISK}"
    [[ -b "$HOME_DEV" ]] || error_exit "Home disk $HOME_DEV not found"

    # Detect partition naming scheme
    if [[ "$ROOT_DISK" =~ nvme ]]; then
        ROOT_EFI="${ROOT_DEV}p1"
        ROOT_PART="${ROOT_DEV}p2"
        HOME_PART="${HOME_DEV}p1"
    else
        ROOT_EFI="${ROOT_DEV}1"
        ROOT_PART="${ROOT_DEV}2"
        HOME_PART="${HOME_DEV}1"
    fi

    echo ""
    log_info "Configuration:"
    echo "  Root disk:  $ROOT_DEV"
    echo "  EFI:        $ROOT_EFI"
    echo "  Root part:  $ROOT_PART"
    echo "  Home disk:  $HOME_DEV"
    echo "  Home part:  $HOME_PART"
    echo ""

    read -p "Does this look correct? (yes/no): " CONFIRM
    [[ "$CONFIRM" == "yes" ]] || error_exit "Configuration cancelled by user"
}

# Verify prerequisites
verify_prerequisites() {
    log_info "Verifying prerequisites..."

    # Check if partitions exist
    [[ -b "$ROOT_EFI" ]] || error_exit "EFI partition $ROOT_EFI not found"
    [[ -b "$ROOT_PART" ]] || error_exit "Root partition $ROOT_PART not found"
    [[ -b "$HOME_PART" ]] || error_exit "Home partition $HOME_PART not found"

    # Check filesystem types
    ROOT_FS=$(lsblk -no FSTYPE "$ROOT_PART")
    HOME_FS=$(lsblk -no FSTYPE "$HOME_PART")
    EFI_FS=$(lsblk -no FSTYPE "$ROOT_EFI")

    [[ "$ROOT_FS" == "btrfs" ]] || error_exit "Root partition is not btrfs (found: $ROOT_FS)"
    [[ "$HOME_FS" == "btrfs" ]] || error_exit "Home partition is not btrfs (found: $HOME_FS)"
    [[ "$EFI_FS" == "vfat" ]] || error_exit "EFI partition is not vfat (found: $EFI_FS)"

    log_success "Prerequisites verified"
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
    mkdir -p /mnt/{root_top,home_top,final}
}

# Mount top-level btrfs filesystems
mount_toplevel() {
    log_info "Mounting top-level Btrfs filesystems..."
    mount -o subvolid=5 "$ROOT_PART" /mnt/root_top || error_exit "Failed to mount root top-level"
    mount -o subvolid=5 "$HOME_PART" /mnt/home_top || error_exit "Failed to mount home top-level"
    log_success "Top-level filesystems mounted"
}

# Create subvolumes
create_subvolumes() {
    log_info "Creating Btrfs subvolumes..."

    # Check if @ already exists
    if btrfs subvolume list /mnt/root_top | grep -q "path @$"; then
        log_warn "Subvolume @ already exists, skipping creation"
    else
        # Root disk subvolumes
        btrfs subvolume create /mnt/root_top/@ || error_exit "Failed to create @"
        btrfs subvolume create /mnt/root_top/@var_log
        btrfs subvolume create /mnt/root_top/@var_cache
        btrfs subvolume create /mnt/root_top/@var_tmp
        btrfs subvolume create /mnt/root_top/@var_lib_docker
        btrfs subvolume create /mnt/root_top/@var_lib_libvirt
        log_success "Root disk subvolumes created"
    fi

    # Home disk subvolumes
    if ! btrfs subvolume list /mnt/home_top | grep -q "path @home$"; then
        btrfs subvolume create /mnt/home_top/@home || error_exit "Failed to create @home"
        btrfs subvolume create /mnt/home_top/@games
        log_success "Home disk subvolumes created"
    else
        log_warn "Home subvolumes already exist"
    fi
}

# Copy existing installation
copy_installation() {
    log_info "Checking if installation needs to be copied..."

    # Check if @ is empty or already populated
    if [[ $(ls -A /mnt/root_top/@ 2>/dev/null | wc -l) -gt 0 ]]; then
        log_warn "@ subvolume already contains data, skipping copy"
        return 0
    fi

    # Check if there's data at top-level to copy
    if [[ ! -d /mnt/root_top/etc ]]; then
        log_warn "No installation found at top-level, assuming clean install"
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

# Copy existing home data
copy_home_data() {
    log_info "Checking for existing home directory data..."

    # After copy_installation(), home data is now in @/home, not at top-level
    # Check both locations to be safe

    if [[ -d /mnt/root_top/@/home ]]; then
        HOME_SOURCE="/mnt/root_top/@/home"
        log_info "Found home directory in @ subvolume at $HOME_SOURCE"
    elif [[ -d /mnt/root_top/home ]]; then
        HOME_SOURCE="/mnt/root_top/home"
        log_info "Found home directory at top-level (before @ was created)"
    elif [[ -d /mnt/home_top/home ]]; then
        HOME_SOURCE="/mnt/home_top/home"
        log_info "Found home directory on home disk (unusual but OK)"
    else
        log_info "No home directory found, skipping home copy"
        return 0
    fi

    # Check if @home is empty or already populated
    if [[ $(ls -A /mnt/home_top/@home 2>/dev/null | wc -l) -gt 0 ]]; then
        log_warn "@home subvolume already contains data, skipping copy"
        return 0
    fi

    # Count items to be copied (check for actual user directories)
    HOME_ITEM_COUNT=$(find "$HOME_SOURCE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    if [[ $HOME_ITEM_COUNT -eq 0 ]]; then
        log_warn "Home directory exists but contains no user directories"
        log_info "Checking for any files..."
        HOME_FILE_COUNT=$(find "$HOME_SOURCE" -mindepth 1 2>/dev/null | wc -l)
        if [[ $HOME_FILE_COUNT -eq 0 ]]; then
            log_info "Home directory is truly empty, nothing to copy"
            return 0
        fi
        log_info "Found $HOME_FILE_COUNT items in home directory"
    fi

    log_info "Copying home directory to @home subvolume..."
    log_warn "This may take a while depending on home directory size..."

    rsync -aHAX --numeric-ids --info=progress2 \
        "$HOME_SOURCE/" /mnt/home_top/@home/ || error_exit "Failed to copy home directory"

    # Verify copy
    COPIED_DIRS=$(find /mnt/home_top/@home -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    log_success "Home directory copied successfully ($COPIED_DIRS user directories)"

    # Show what was copied
    if [[ $COPIED_DIRS -gt 0 ]]; then
        echo ""
        log_info "Users found in @home:"
        find /mnt/home_top/@home -mindepth 1 -maxdepth 1 -type d -printf '  - %f\n'
    fi
}

# Set default subvolume
set_default_subvol() {
    log_info "Setting @ as default subvolume..."

    ROOT_AT_ID=$(btrfs subvolume show /mnt/root_top/@ | awk '/Subvolume ID:/ {print $3}')
    [[ -n "$ROOT_AT_ID" ]] || error_exit "Failed to get @ subvolume ID"

    btrfs subvolume set-default "$ROOT_AT_ID" /mnt/root_top || error_exit "Failed to set default subvolume"

    # Verify
    DEFAULT_ID=$(btrfs subvolume get-default /mnt/root_top | awk '{print $2}')
    [[ "$DEFAULT_ID" == "$ROOT_AT_ID" ]] || error_exit "Default subvolume verification failed"

    log_success "Default subvolume set to @ (ID: $ROOT_AT_ID)"
}

# Mount final layout
mount_final_layout() {
    log_info "Unmounting top-level views..."
    umount /mnt/root_top /mnt/home_top

    log_info "Mounting final filesystem layout..."

    # Root with @
    mount -o subvol=@,noatime,compress=zstd:3 "$ROOT_PART" /mnt || error_exit "Failed to mount root @"

    # Create mountpoints
    mkdir -p /mnt/{boot,home,games,var/log,var/cache,var/tmp,var/lib/docker,var/lib/libvirt}

    # EFI
    mount "$ROOT_EFI" /mnt/boot || error_exit "Failed to mount EFI"

    # Home disk subvolumes
    mount -o subvol=@home,noatime,compress=zstd:3 "$HOME_PART" /mnt/home || error_exit "Failed to mount @home"
    mount -o subvol=@games,noatime,compress=zstd:3 "$HOME_PART" /mnt/games || error_exit "Failed to mount @games"

    # /var splits
    mount -o subvol=@var_log,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/log
    mount -o subvol=@var_cache,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/cache
    mount -o subvol=@var_tmp,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/tmp
    mount -o subvol=@var_lib_docker,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/lib/docker
    mount -o subvol=@var_lib_libvirt,noatime,compress=zstd:3 "$ROOT_PART" /mnt/var/lib/libvirt

    log_success "Final layout mounted"
}

# Generate fstab
generate_fstab() {
    log_info "Generating /etc/fstab..."

    genfstab -U /mnt > /mnt/etc/fstab || error_exit "Failed to generate fstab"

    log_success "fstab generated"
    echo ""
    log_info "Preview of fstab:"
    echo "----------------------------------------"
    head -n 30 /mnt/etc/fstab
    echo "----------------------------------------"
}

# Cleanup old top-level installation (both root and home)
cleanup_old_installation() {
    log_info "Checking for old installation data at top-level..."

    # Remount top-level to see what's there
    mkdir -p /mnt/cleanup_check
    mount -o subvolid=5 "$ROOT_PART" /mnt/cleanup_check

    # Count directories that aren't subvolumes
    OLD_DIRS=$(find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' 2>/dev/null | wc -l)

    echo ""
    log_warn "Cleanup Phase: Root Disk"
    if [[ $OLD_DIRS -eq 0 ]]; then
        log_info "No old installation data found on root disk"
    else
        log_warn "Found $OLD_DIRS old directories at root Btrfs top-level"
        echo ""
        echo "Directories to be removed from root disk:"
        find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' -printf '  - %f\n'
        echo ""

        read -p "Remove old top-level data from root disk? (yes/no): " CLEANUP_CONFIRM

        if [[ "$CLEANUP_CONFIRM" == "yes" ]]; then
            log_info "Removing old top-level directories from root disk..."

            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                -type d ! -name '@*' \
                -exec rm -rf --one-file-system {} + || log_warn "Some files couldn't be removed"

            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                ! -name '@*' ! -type d \
                -exec rm -f -- {} + 2>/dev/null || true

            log_success "Old root disk data removed"
        else
            log_info "Skipping root disk cleanup"
        fi
    fi

    umount /mnt/cleanup_check

    # Now check home disk
    log_warn "Cleanup Phase: Home Disk"
    mount -o subvolid=5 "$HOME_PART" /mnt/cleanup_check

    OLD_HOME_DIRS=$(find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' 2>/dev/null | wc -l)

    if [[ $OLD_HOME_DIRS -eq 0 ]]; then
        log_info "No old data found on home disk"
    else
        log_warn "Found $OLD_HOME_DIRS old directories at home Btrfs top-level"
        echo ""
        echo "Directories to be removed from home disk:"
        find /mnt/cleanup_check -mindepth 1 -maxdepth 1 -type d ! -name '@*' -printf '  - %f\n'
        echo ""

        read -p "Remove old top-level data from home disk? (yes/no): " CLEANUP_HOME_CONFIRM

        if [[ "$CLEANUP_HOME_CONFIRM" == "yes" ]]; then
            log_info "Removing old top-level directories from home disk..."

            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                -type d ! -name '@*' \
                -exec rm -rf --one-file-system {} + || log_warn "Some files couldn't be removed"

            find /mnt/cleanup_check -mindepth 1 -maxdepth 1 \
                ! -name '@*' ! -type d \
                -exec rm -f -- {} + 2>/dev/null || true

            log_success "Old home disk data removed"
        else
            log_info "Skipping home disk cleanup"
        fi
    fi

    umount /mnt/cleanup_check
    rmdir /mnt/cleanup_check 2>/dev/null || true
}

# Post-setup tasks
post_setup() {
    echo ""
    log_success "Btrfs layout setup complete!"
    echo ""
    echo "Next steps:"
    echo "  1. Review /mnt/etc/fstab"
    echo "  2. (Optional) Enable fstrim:"
    echo "       arch-chroot /mnt"
    echo "       systemctl enable fstrim.timer"
    echo "       exit"
    echo "  3. Reboot:"
    echo "       umount -R /mnt"
    echo "       reboot"
    echo ""

    read -p "Would you like to chroot now? (yes/no): " CHROOT_NOW
    if [[ "$CHROOT_NOW" == "yes" ]]; then
        log_info "Entering chroot (type 'exit' to return)..."
        arch-chroot /mnt || true
    fi
}

# Main execution
main() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}    Arch Linux Btrfs Multi-Disk Setup Script       ${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""

    log_warn "This script will restructure your Arch installation"
    log_warn "Make sure you have completed archinstall first!"
    echo ""
    read -p "Continue? (yes/no): " START
    [[ "$START" == "yes" ]] || error_exit "Setup cancelled by user"

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
    post_setup

    log_success "All done!"
}

# Run main function
main "$@"
