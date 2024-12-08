#!/bin/bash
# -*- mode: sh; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: et sts=2 sw=2
#
# A collection of functions to repair and modify a Steam Deck installation.
# This makes a number of assumptions about the target device and will be
# destructive if you have modified the expected partition layout.
#

set -eu

clear

echo SteamOS Installer with Dual Boot Wizard
echo https://github.com/ryanrudolfoba/SteamOS-installer-dualboot-wizard
sleep 1

###### Main menu. Ask user for the preferred SteamOS /home partition size
InternalSSD=$(lsblk | grep nvme | head -n1 | tr -s " " | cut -d " " -f 4 | cut -d "." -f 1)

if [ $InternalSSD -eq 1 ]
then
	InternalSSD=1900
	echo Internal SSD is 2TiB
else
	echo Internal SSD is $InternalSSD\GiB
fi

Choice=$(zenity --width 1280 --height 400 --list --radiolist --multiple --title "SteamOS Installer with Dual Boot Wizard - https://github.com/ryanrudolfoba/SteamOS-installer-dualboot-wizard"\
	--column "Select One" \
	--column "SteamOS /home Partition" \
	--column="Comments"\
	FALSE 16GiB "Allocate 16GiB for SteamOS. I use this for testing, BIOS updates etc etc..."\
	FALSE 32GiB "Allocate 32GiB for SteamOS. 50% for STeamOS and 50% for Windows on a 64GiB Steam Deck."\
	FALSE 128GiB "Allocate 128GiB for SteamOS. 50% for SteamOS and 50% for Windows on a 256GiB Steam Deck."\
	FALSE 256GiB "Allocate 256GiB for SteamOS. 50% for SteamOS and 50% for Windows on a 512GiB Steam Deck."\
	FALSE 512GiB "Allocate 512GiB for SteamOS. 50% for SteamOS and 50% for Windows on a custom 1TiB Steam Deck."\
	FALSE 768GiB "Allocate 768GiB for SteamOS. 75% for SteamOS and 25% for Windows on a custom 1TiB Steam Deck."\
	FALSE 1024GiB "Allocate 1024GiB for SteamOS. 50% for SteamOS and 50% for Windows on a custom 2TiB Steam Deck."\
	FALSE 1536GiB "Allocate 1536GiB for SteamOS. 75% for SteamOS and 25% for Windows on a custom 2TiB Steam Deck."\
	FALSE CUSTOM "Select this if you want to set your own SteamOS /home partition."\
	TRUE EXIT "Select this if you changed your mind and don't want to proceed anymore.")

if [ "$Choice" == "CUSTOM" ]
then
  echo $Choice
  echo OK lets do custom partitioning!
  CustomPartition=$(zenity --entry --title "Custom Partitioning" --text "How much space to allocate for SteamOS /home parition? (in GiB)")
  PartitionSize=$(echo $CustomPartition | tr -d [:upper:] | tr -d [:lower:])
  echo $InternalSSD
  echo $PartitionSize

elif [ "$Choice" == "EXIT" ]
then
  echo $Choice
  echo Make no changes. Exiting immediately.
  exit

else
  PartitionSize=$(echo $Choice | tr -d [:upper:] | tr -d [:lower:])
  echo $InternalSSD
  echo $PartitionSize
fi

if [ $PartitionSize -ge $InternalSSD ]
then
	zenity --width 350 --height 200 --error --text "Whoopsie you cant do that!\n\nMake sure that the SteamOS partition you want to set is smaller than your internal SSD.\n\n$PartitionSize\GiB is greater than your $InternalSSD\GiB internal SSD.\n\n\nRun the script again and choose a smaller allocation size for SteamOS."
	exit
fi

###### Valve SteamOS recovery begins.......

die() { echo >&2 "!! $*"; exit 1; }
readvar() { IFS= read -r -d '' "$1" || true; }

DISK=/dev/nvme0n1
DISK_SUFFIX=p
DOPARTVERIFY=1
# Partition table, sfdisk format
readvar PARTITION_TABLE <<END_PARTITION_TABLE
  label: gpt
  ${DISK}${DISK_SUFFIX}1: name="esp",      size=    512MiB, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
  ${DISK}${DISK_SUFFIX}2: name="efi-A",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  ${DISK}${DISK_SUFFIX}3: name="efi-B",    size=    32MiB, type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
  ${DISK}${DISK_SUFFIX}4: name="rootfs-A", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  ${DISK}${DISK_SUFFIX}5: name="rootfs-B", size=  5120MiB, type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709
  ${DISK}${DISK_SUFFIX}6: name="var-A",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  ${DISK}${DISK_SUFFIX}7: name="var-B",    size=   256MiB, type=4D21B016-B534-45C2-A9FB-5C16E091FD2D
  ${DISK}${DISK_SUFFIX}8: name="home",     size= ${PartitionSize}GiB  type=933AC7E1-2EB4-4F13-B844-0E14E2AEF915
  ${DISK}${DISK_SUFFIX}9: name="Windows",                   type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7
END_PARTITION_TABLE

# Partition numbers on ideal target device, by index
FS_ESP=1
FS_EFI_A=2
FS_EFI_B=3
FS_ROOT_A=4
FS_ROOT_B=5
FS_VAR_A=6
FS_VAR_B=7
FS_HOME=8

diskpart() { echo "$DISK$DISK_SUFFIX$1"; }

##
## Util colors and such
##

err() {
  echo >&2
  eerr "Imaging error occured, see above and restart process."
  sleep infinity
}
trap err ERR

_sh_c_colors=0
[[ -n $TERM && -t 1 && ${TERM,,} != dumb ]] && _sh_c_colors="$(tput colors 2>/dev/null || echo 0)"
sh_c() { [[ $_sh_c_colors -le 0 ]] || ( IFS=\; && echo -n $'\e['"${*:-0}m"; ); }

sh_quote() { echo "${@@Q}"; }
estat()    { echo >&2 "$(sh_c 32 1)::$(sh_c) $*"; }
emsg()     { echo >&2 "$(sh_c 34 1)::$(sh_c) $*"; }
ewarn()    { echo >&2 "$(sh_c 33 1);;$(sh_c) $*"; }
einfo()    { echo >&2 "$(sh_c 30 1)::$(sh_c) $*"; }
eerr()     { echo >&2 "$(sh_c 31 1)!!$(sh_c) $*"; }
die() { local msg="$*"; [[ -n $msg ]] || msg="script terminated"; eerr "$msg"; exit 1; }
showcmd() { showcmd_unquoted "${@@Q}"; }
showcmd_unquoted() { echo >&2 "$(sh_c 30 1)+$(sh_c) $*"; }
cmd() { showcmd "$@"; "$@"; }

# Helper to format
fmt_ext4()  { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.ext4 -F -L "$1" "$2"; }
fmt_fat32() { [[ $# -eq 2 && -n $1 && -n $2 ]] || die; cmd sudo mkfs.vfat -n"$1" "$2"; }

##
## Prompt mechanics - currently using Zenity
##

# Give the user a choice between Proceed, or Cancel (which exits this script)
#  $1 Title
#  $2 Text
#
prompt_step()
{
  title="$1"
  msg="$2"
  if [[ ${NOPROMPT:-} ]]; then
    echo -e "$msg"
    return 0
  fi
  zenity --title "$title" --question --ok-label "Proceed" --cancel-label "Cancel" --no-wrap --text "$msg"
  [[ $? = 0 ]] || exit 1
}

prompt_reboot()
{
  prompt_step "Action Complete" "${1}\n\nChoose Proceed to reboot the Steam Deck now, or Cancel to stay in the repair image."
  [[ $? = 0 ]] || exit 1
  if [[ ${POWEROFF:-} ]]; then
    cmd systemctl poweroff
  else
    cmd systemctl reboot
  fi
}

##
## Repair functions
##

# verify partition on target disk - at least make sure the type and partlabel match what we expect.
#   $1 device
#   $2 expected type
#   $3 expected partlabel
#
verifypart()
{
  [[ $DOPARTVERIFY = 1 ]] || return 0
  TYPE="$(blkid -o value -s TYPE "$1" )"
  PARTLABEL="$(blkid -o value -s PARTLABEL "$1" )"
  if [[ ! $TYPE = "$2" ]]; then
    eerr "Device $1 is type $TYPE but expected $2 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 1
  fi

  if [[ ! $PARTLABEL = $3 ]] ; then 
    eerr "Device $1 has label $PARTLABEL but expected $3 - cannot proceed. You may try full recovery."
    sleep infinity ; exit 2
  fi
}

# Replace the device rootfs (btrfs version). Source must be frozen before calling.
#   $1 source device
#   $2 target device
#
imageroot()
{
  local srcroot="$1"
  local newroot="$2"
  # copy then randomize target UUID - careful here! Duplicating btrfs ids is a problem
  cmd dd if="$srcroot" of="$newroot" bs=128M status=progress oflag=sync
  cmd btrfstune -f -u "$newroot"
  cmd btrfs check "$newroot"
}

# Set up boot configuration in the target partition set
#   $1 partset name
finalize_part()
{
  estat "Finalizing install part $1"
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- mkdir /efi/SteamOS
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- mkdir -p /esp/SteamOS/conf
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- steamos-partsets /efi/SteamOS/partsets
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- steamos-bootconf create --image "$1" --conf-dir /esp/SteamOS/conf --efi-dir /efi --set title "$1"
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- grub-mkimage
  cmd steamos-chroot --disk "$DISK" --partset "$1" -- update-grub
}

##
## Main
##

onexit=()
exithandler() {
  for func in "${onexit[@]}"; do
    "$func"
  done
}
trap exithandler EXIT

# Check existence of target disk
if [[ ! -e "$DISK" ]]; then
  eerr "$DISK does not exist -- no nvme drive detected?"
  sleep infinity
  exit 1
fi


# Reinstall a fresh SteamOS copy.
#
repair_steps()
{
  if [[ $writePartitionTable = 1 ]]; then
    estat "Write known partition table"
    echo "$PARTITION_TABLE" | sfdisk "$DISK"

  elif [[ $writeOS = 1 || $writeHome = 1 ]]; then

    # verify some partition settings to make sure we are ok to proceed with partial repairs
    # in the case we just wrote the partition table, we know we are good and the partitions
    # are unlabelled anyway
    verifypart "$(diskpart $FS_ESP)" vfat esp
    verifypart "$(diskpart $FS_EFI_A)" vfat efi-A
    verifypart "$(diskpart $FS_EFI_B)" vfat efi-B
    verifypart "$(diskpart $FS_VAR_A)" ext4 var-A
    verifypart "$(diskpart $FS_VAR_B)" ext4 var-B
    verifypart "$(diskpart $FS_HOME)" ext4 home
  fi

  # clear the var partition (user data), but also if we are reinstalling the OS
  # a fresh system partition has problems with overlay otherwise
  if [[ $writeOS = 1 || $writeHome = 1 ]]; then
    estat "Creating var partitions"
    fmt_ext4  var  "$(diskpart $FS_VAR_A)"
    fmt_ext4  var  "$(diskpart $FS_VAR_B)"
  fi

  if [[ $writeHome = 1 ]]; then
    estat "Creating home partition..."
    cmd sudo mkfs.ext4 -F -O casefold -T huge -L home "$(diskpart $FS_HOME)"
    estat "Remove the reserved blocks on the home partition..."
    tune2fs -m 0 "$(diskpart $FS_HOME)"
  fi

  if [[ $writeOS = 1 ]]; then
    # Find rootfs
    rootdevice="$(findmnt -n -o source / )"
    if [[ -z $rootdevice || ! -e $rootdevice ]]; then
      eerr "Could not find USB installer root -- usb hub issue?"
      sleep infinity
      exit 1
    fi
  
    # Set up ESP/EFI boot partitions
    estat "Creating boot partitions"
    fmt_fat32 esp  "$(diskpart $FS_ESP)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_A)"
    fmt_fat32 efi  "$(diskpart $FS_EFI_B)"

    # Freeze our rootfs
    estat "Freezing rootfs"
    unfreeze() { fsfreeze -u /; }
    onexit+=(unfreeze)
    cmd fsfreeze -f /

    estat "Imaging OS partition A"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_A)"
  
    estat "Imaging OS partition B"
    imageroot "$rootdevice" "$(diskpart $FS_ROOT_B)"
  
    estat "Finalizing boot configurations"
    finalize_part A
    finalize_part B
    estat "Finalizing EFI system partition"
    cmd steamos-chroot --disk "$DISK" --partset A -- steamcl-install --flags restricted --force-extra-removable
  fi
}

# drop into the primary OS partset on the Deck
#
chroot_primary()
{
  partset=$( steamos-chroot --disk "$DISK" --partset "A" -- steamos-bootconf selected-image )

  estat "Dropping into a chroot on the $partset partition set."
  estat "You can make any needed changes here, and exit when done."

  cmd steamos-chroot --disk "$DISK" --partset "$partset" 
}

# return sanitize state (and echo the current percentage complete)
# 0 : ready to sanitize
# 1 : sanitize in progress (echo the current percentage)
# 2 : drive does not support sanitize
#
get_sanitize_progress()
{
  status=$(nvme sanitize-log "${DISK}" | grep "(SSTAT)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  [[ $(( status % 8 )) -eq 2 ]] || return 0

  progress=$(nvme sanitize-log "${DISK}" | grep "(SPROG)" | grep -oEi "(0x)?[[:xdigit:]]+$") || return 2
  echo "sanitize progress: $(( ( progress * 100 )/ 65535 ))%"
  return 1
}

# call nvme sanitize, blockwise, and wait for it to complete.
#
sanitize_all()
{
  sres=0
  get_sanitize_progress || sres=$?
  case $sres in
    0)
      echo
      echo "Warning!"
      echo
      echo "This action irrevocably clears *all* user data from ${DISK}"
      echo "Pausing five seconds in case you didn't mean to do this..."
      sleep 5
      echo "Ok, let's go. Sanitizing ${DISK}:"
      nvme sanitize -a 2 "${DISK}"
      echo "Sanitize action started."
      ;;
    1) echo "An NVME sanitize action is already in progress."
      ;;
    2) # use NVME secure-format since this device does not appear to support sanitize
      nvme format "${DISK}" -n 1 -s 1 -r
      return 0
      ;;
    *) echo "Unexpected result from sanitize-log"
      return $sres
      ;;
  esac

  while ! get_sanitize_progress ; do
    sleep 5
  done

  echo "... sanitize done."
}

#[[ "$EUID" -ne 0 ]] && help
#
#writePartitionTable=0
#writeOS=0
#writeHome=0

writePartitionTable=1
writeOS=1
writeHome=1
prompt_step "Reimage Steam Deck" "This action will reimage the Steam Deck and allocate $PartitionSize\GiB for SteamOS /home partition.\n\nThis will permanently destroy all data on your Steam Deck and reinstall SteamOS.\n\nThis cannot be undone.\n\nChoose Proceed only if you wish to clear and reimage this device."
repair_steps
prompt_reboot "Reimaging complete."

###### Valve SteamOS recovery finished.......
