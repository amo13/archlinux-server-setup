#!/bin/bash

### Define relevant paths
### No trailing slashes
# Absolute path for MariaDB config file containing user and password
mycnf_path=/root/.my.cnf
# Absolute path for database dumps
db_dumps_path=/storage/@SQL
# Absolute Path to the ssh key file
sshkeyfile=/path/to/ssh/key.file
# Absolute path to the luks key file for the backup sparse file
lukskeyfile=/root/remote_backup.keyfile
# Host and remote path
remote_path=user@host:/path/to/backup/drive/mountpoint
# Mount point for the remote drive
remote_drive_mount_point=/.backup_remote_server
# Absolute path to the backup sparse file
sparse_file_path=$remote_drive_mount_point/backup.luks
# UUID of the backup sparse file
sparse_uuid=aa3f2557-a32f-46c4-9d30-43e6a524fa52
# Mount point of the backup sparse file
sparse_mount_point=/backup
# How many MariaDB dumps to keep
keep_db_dumps=12

# check for root privileges
privileges() {
	if [ ! "$(whoami)" == "root" ]; then
		echo "Please start this script as root."
		exit
	fi
}

# datestamp for the backup
today="$(date +"%Y-%m-%d")"

backup_mariadb() {
	# backup the database
	if [ -f $db_dumps_path/"$today"-all_databases.sql.gz ]; then
		echo "Database backup of today found. Skipping."
	else
		echo "Backing up MariaDB databases..."
		mysqldump --defaults-file=$mycnf_path --default-character-set=utf8mb4 --single-transaction --flush-logs --master-data=2 --all-databases | gzip > $db_dumps_path/"$today"-all_databases.sql.gz
		# purge old binary logs taking up a lot of disk space
		echo "purge binary logs before '$today';" | mysql
	fi
	# Keep only the latest $keep_db_dumps MariaDB dumps
	for dump in $(find $db_dumps_path -mindepth 1 -maxdepth 1 -type f -printf '%f\n' | sort -nr | tail -n +$((keep_db_dumps+1))); do
		echo "Delete old MariaDB dump $dump"
		rm "$dump"
	done
}

mount_remote_drive() {
	sshfs -oIdentityFile=$sshkeyfile $remote_path $remote_drive_mount_point
	cryptsetup open $sparse_file_path remote_backup --key-file $lukskeyfile
	mount UUID=$sparse_uuid $sparse_mount_point
}

unmount_remote_drive() {
	umount $sparse_mount_point
	cryptsetup close remote_backup
	fusermount3 -u $remote_drive_mount_point
}

privileges

echo "Performing a full system backup..."

backup_mariadb
mount_remote_drive
./btrfs-backup.sh || btrfs_backup_failed="true"
# Health check on the remote BTRFS sparse file
systemctl start btrfs-check@"$(systemd-escape -p $sparse_mount_point)"
sleep 5
unmount_remote_drive

if [ "$btrfs_backup_failed" = "true" ]; then
	echo "BTRFS backup failed."
	exit 1
fi

echo "Full system backup done."
echo "Fuck the police."