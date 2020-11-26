# archlinux-server-setup
Interactive Arch Linux post-install script for server setup. Nginx, php, redis, mariadb, smartmontools, netdata, ...

## Warning
Depending on your reason for using this script, its usage might go against the Arch Linux mentality which emphasizes the Y in DIY. Only if you 1. already have performed the scripted tasks manually, 2. have read and understood the respective Archwiki articles, and 3. have read and understood the script, you should consider using it. Do not ask for support from the Arch Linux Community if you are not able to explain the commands executed by this script.

This script is meant to be run *after* the installation of Arch Linux. It also requires a working internet connection. If BTRFS is used as the root filesystem, it is detected and supported.

## Start
On your fresh Arch Linux installation, call:

`bash <(curl -sSL https://raw.githubusercontent.com/amo13/archlinux-server-setup/main/setup.sh)`


## What to expect
All in all, this script tries to setup things as closely as possible to what is recommended by the Archwiki.

### Reflector
Reflector is installed and its systemd timer is enabled and started to periodically update the pacman mirrorlist.

### Default unprivileged user
A default unprivileged user is created (if none is found) for default access to the server and for unprivileged tasks like building AUR packages. This user gets added to the wheel group for sudo commands. 

### Sudo
Allow all users in the wheel group to use sudo. (For convenience reasons, this is first set to allow sudo without entering the password so that the script is not interrupted by password prompts. At the end of the script, this is modified again to allow sudo only with the password.)

### yay AUR helper
Install the yay AUR helper for easier installation and update of packages from the AUR.

### SSH
Configure SSH access on the default port 22 and do not allow to log in as the root user.

### Pacman clean cache hook
Add a pacman hook to clean the cached packages potentially freeing a lot of disk space automatically. You can choose how many package versions to keep in the cache (maybe for downgrading in case something breaks). Default is 2: keep the current version and the one before.

### fstrim
Activate periodic fstrim of drives supporting the feature using the systemd timer and service files provided by the system. Trim daily instead of weekly though.

### Nginx
Install, setup, enable and start nginx. Create `sites-available` and `sites-enabled` folders for easy management of many virtual hosts in separate files. Also put a template file for static sites into sites-available. 
If you have a domain, you can enter it when prompted and web services installed afterwards will automatically be assigned a subdomain and get a nginx virtual host file accordingly.

### PHP

### MariaDB

### Redis
Install, enable and start redis. Also install php-redis and python-redis client software. Redis will be listening on port 6379 and will accept unix socket connections at /run/redis/redis.sock. Members of the redis group can access the socket. The default user and the http user are added to the redis group. A reboot is necessary to mitigate the warnings mentioned in the Archwiki under troubleshooting. 

### Namecheap dynamic DNS update
If you registered a domain with Namecheap, you can enter it together with the dynamic DNS password when prompted. This will create a small script in the `scripts` folder of your default user and setup a systemd service and timer to call it every 5 minutes. 

### Gotify
Install, enable and start the gotify server. It will listen on port 8057. You can specify the default admin user name. You should change its password using the web UI after the script finished.

### Systemd service failure notification with gotify
Create a systemd toplevel override file adding `OnFailure=failure-notification@%n` to all systemd services. Also add the `failure-notification@` service that is to be started if another service somehow fails. This, in turn, will send information about the unit that has failed and its status to the gotify server using the gotify-cli command (also gets installed and configured to use your gotify server). You can receive and view all messages on the web UI or using the android application.
If you want to change how and where the notifications are delivered, you should modify the contents of the failure-notification.sh script in the scripts folder of your default user accordingly.

### fail2ban
Install, activate and start fail2ban. It will monitor the ssh and nginx logs.

### Smartmontools
Install, activate and start smartmontools. It will monitor all drives and send notifications on potential problems using gotify.
If you want to change how and where the notifications are delivered, you should modify the contents of the `/usr/share/smartmontools/smartd_warning.d/smartd-warning.sh` script accordingly. Also periodically dump the smartd logs to `/var/log/smartd` so it can be parsed by netdata if needed.


## Still to do afterwards

### BTRFS check and scrub other drives

You might have more BTRFS filesystems than just the root filesystem. If so, you need to enable and start the appropriate instance of the `btrfs-check@.timer` systemd template unit. For example, if you want to periodically have the BTRFS mount point `/storage/array` checked, call `sudo systemctl enable --now btrfs-check@storage-array.timer`.
If you have a BTRFS RAID array able to use copies to automatically repair corrupted blocks, you might want to enable and start periodic scrubs: `systemctl enable --now btrfs-scrub@storage-array.timer`.