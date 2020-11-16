#!/bin/bash

### Interactive Arch Linux post-install script for server setup

### Presumptions:
###		- Running on a freshly installed archlinux system
###		- Working internet connection (networking already set up)


### Script needs to be started as root
if [ ! '$(whoami)' == 'root' ]; then
	echo "Please start this script as root or with sudo."
	exit
fi


### Default unprivileged user
create_default_user() {
	useradd -m -G ftp,http,mail,wheel "$1"
	echo "Set a password for the new user:"
	passwd "$1"
}
users_count=$(ls -x /home | wc -l)
if [ "$users_count" -eq 0 ]; then
	echo "No default unprivileged user found. Creating one..."
	read -p "Enter new user name: " default_user
	create_default_user "$default_user"
elif [ "$users_count" -eq 1 ]; then
	default_user="$(ls -x /home | tr -d '\n')"
	echo "Setting default unprivileged user to $default_user"
else
	read -p "Enter the name of your default unprivileged user: " default_user
	while [ -z "$default_user" ] || [ ! -d /home/"$default_user" ]; do
		echo "Either you left the user name empty or the user you entered has no home directory."
		read -p "Enter the name of your default unprivileged user: " default_user
	done
	create_default_user "$default_user"
fi


### Sudo
read -p "Install and setup sudo for your user? [Y,n]: " setup_sudo
if [ "$setup_sudo" != "n" ]; then
	# Install sudo
	pacman -S --noconfirm sudo
	# Modify sudoers file to allow members of the wheel group
	sed '/%wheel ALL=(ALL) ALL/s/^# //g' /etc/sudoers | EDITOR='tee' visudo
fi
