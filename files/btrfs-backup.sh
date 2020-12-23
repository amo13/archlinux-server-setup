#!/bin/bash

### Define the paths to use for BTRFS backup ###
### No trailing slashes
# Where to put snapshots of the root fs
root_snaps=/.snaps
# How many root fs snapshots to keep locally
keep_local=10
# How many root fs snapshots to keep on destination
keep_remote=3
# Path to storage fs containing subvolumes to backup
storage=/storage
# Where to put snapshots of the storage fs subvolumes
# Needs to be inside $storage
storage_snaps=/storage/.snaps
# Path to the mounted remote (destination) fs
destination=/backup

# Check for root privileges
privileges() {
	if [ ! "$(whoami)" == "root" ]; then
		echo "Please start this script as root."
		exit 1
	fi
}

checks() {
	# Confirm that the given paths are btrfs fs
	root_fs_type=$(mount | grep "^/dev" | grep -oP "(?<=on / type )[^ ]+" | tr -d '\n')
	storage_fs_type=$(mount | grep "^/dev" | grep -oP "(?<=on $storage type )[^ ]+" | tr -d '\n')
	destination_fs_type=$(mount | grep "^/dev" | grep -oP "(?<=on $destination type )[^ ]+" | tr -d '\n')
	if [[ "$root_fs_type" != "btrfs" || "$storage_fs_type" != "btrfs" || "$destination_fs_type" != "btrfs" ]]; then
		echo "At least one of the given paths is no BTRFS filesystem. Aborting."
		exit 1
	fi
	# Confirm that the destination is mounted
	if [ "$(mountpoint $destination)" != "$destination is a mountpoint" ]; then
		echo "$destination is not a mount point. Is the backup drive mounted?. Aborting."
		exit 1
	fi
	# $destination/@rootfs subvolume should not be read-only
	if [ "$(btrfs property get -ts $destination/@rootfs)" == "ro=true" ]; then
		echo "$destination/@rootfs is read-only. Aborting."
		exit 1
	fi
}

# Datestamp for the backup
today="$(date +"%Y-%m-%d")"

# Backup the root fs to $storage
backup_rootfs() {
	# Make sure the @rootfs subvolume exists in $destination
	[ -d $destination/@rootfs ] || btrfs subvolume create $destination/@rootfs
	# Create snapshot of /
	if [ -d $root_snaps/"$today"-rootfs ]; then
		echo "System snapshot of today found. Skipping."
	else
		echo "Creating BTRFS snapshot of the root fs..."
		btrfs subvolume snapshot -r / $root_snaps/"$today"-rootfs
		sync
		# Set symlinks second_latest and latest
		if [ -d $root_snaps/latest ]; then
			echo "Linking $(readlink $root_snaps/latest) to $root_snaps/second_latest"
			ln -sfn "$(readlink $root_snaps/latest)" $root_snaps/second_latest
		fi
		echo "Linking $root_snaps/$today-rootfs to $root_snaps/latest"
		ln -sfn $root_snaps/"$today"-rootfs $root_snaps/latest
	fi
	# Initially or incrementally send the snapshot to the destination pool
	if [ -d $destination/@rootfs/"$today"-rootfs ]; then
		echo "Today's snapshot is already backed up."
	else
		# Send incrementally only if a second latest snapshot already exists locally and in the destination pool
		if [[ -d $root_snaps/second_latest && -d $destination/@rootfs/$(basename "$(readlink $root_snaps/second_latest)") ]]; then
			echo "Incrementally sending the new snapshot to the destination pool..."
			btrfs send -p $root_snaps/second_latest $root_snaps/latest | btrfs receive $destination/@rootfs/
		else
			echo "Initially sending the new snapshot to the destination pool..."
			btrfs send $root_snaps/latest | btrfs receive $destination/@rootfs/
		fi
	fi
	# Keep only the latest $keep_local snapshots locally
	for snap in $(find $root_snaps -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -nr | tail -n +$((keep_local+1))); do
		echo "Delete local snapshot $snap"
		btrfs subvolume delete "$snap"
	done
	# Keep only the latest $keep_remote snapshots on destination
	for snap in $(find $destination/@rootfs -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -nr | tail -n +$((keep_remote+1))); do
		echo "Delete remote snapshot $snap"
		btrfs subvolume delete "$snap"
	done
}

# Backup storage subvolumes
backup_storage() {
	# Make sure the local snapshots subvolume exists
	[ -d $storage_snaps ] || btrfs subvolume create $storage_snaps
	# Loop through the subvolumes found under the storage path
	for subvol_path in "$storage"/*; do
		# Extract the (base)name of the subvolume from subvol_path
		subvol=$(basename "$subvol_path")
		# Create a snapshot of the subvolume
		echo "Creating BTRFS snapshot of $subvol..."
		btrfs subvolume snapshot -r $storage/"$subvol" $storage_snaps/"$subvol"-new
		sync
		# Initially or incrementally send the snapshot to the backup destination
		if [[ -d $storage_snaps/$subvol && -d $destination/$subvol ]]; then
			echo "Incrementally sending the new snapshot to the backup destination..."
			btrfs send -p $storage_snaps/"$subvol" $storage_snaps/"$subvol"-new | btrfs receive $destination/
		else
			echo "Initially sending the new snapshot to the backup destination..."
			btrfs send $storage_snaps/"$subvol"-new | btrfs receive $destination/
		fi
		# Rename backups to prepare for the next incremental backup
		# On the local side
		btrfs subvolume delete $storage_snaps/"$subvol"
		mv $storage_snaps/"$subvol"-new $storage_snaps/"$subvol"
		# On the remote side
		btrfs subvolume delete $destination/"$subvol"
		mv $destination/"$subvol"-new $destination/"$subvol"
	done
}

privileges
checks
backup_rootfs
backup_storage

echo "Backup of root fs and storage done."
echo "Fuck the police."