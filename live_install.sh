#!/bin/sh
#
# FIXME: do fdisk and partitions first
#

case $# in
0)
	echo "Usage: $0 [ -m device ] device [overlay ... ]"
	exit 1
	;;
esac

DRIVELIST=""
#
# handle zfs mirrors
#
case $1 in
-m)
	shift
	DRIVE1=$1
	shift
	if [ ! -e /dev/dsk/$DRIVE1 ]; then
	    echo "ERROR: Unable to find device $DRIVE1"
	    exit 1
	fi
	ZFSARGS="mirror"
	DRIVELIST="$DRIVE1"
	;;
-*)
	echo "Usage: $0 [ -m device ] device [overlay ... ]"
	exit 1
	;;
esac

case $# in
0)
	echo "Usage: $0 [ -m device ] device [overlay ... ]"
	exit 1
	;;
esac

DRIVE2=$1
shift
DRIVELIST="$DRIVELIST $DRIVE2"

if [ ! -e /dev/dsk/$DRIVE2 ]; then
    echo "ERROR: Unable to find device $DRIVE2"
    exit 1
fi

#
# FIXME allow ufs
# FIXME allow svm
#
/usr/bin/mkdir /a
echo "Creating root pool"
/usr/sbin/zpool create -f -o failmode=continue rpool $ZFSARGS $DRIVELIST

echo "Creating filesystems"
/usr/sbin/zfs create -o mountpoint=legacy rpool/ROOT
/usr/sbin/zfs create -o mountpoint=/a rpool/ROOT/tribblix
/usr/sbin/zpool set bootfs=rpool/ROOT/tribblix rpool
/usr/sbin/zfs create -o mountpoint=/a/export rpool/export
/usr/sbin/zfs create rpool/export/home
/usr/sbin/zfs create -V 2g -b 8k rpool/swap
/usr/sbin/zfs create -V 2g rpool/dump

#
# this gives the initial BE a UUID, necessary for 'beadm list -H'
# to not show null, and for zone uninstall to work
#
/usr/sbin/zfs set org.opensolaris.libbe:uuid=`/usr/lib/zap/generate-uuid` rpool/ROOT/tribblix

echo "Copying main filesystems"
cd /
/usr/bin/find boot kernel lib platform root sbin usr etc var opt zonelib -print -depth | cpio -pdm /a
echo "Copying other filesystems"
cd /.cdrom
/usr/bin/find boot -print -depth | cpio -pdm /a
/usr/bin/find boot -print -depth | cpio -pdm /rpool

#
echo "Adding extra directories"
cd /a
/usr/bin/ln -s ./usr/bin .
/usr/bin/mkdir -m 1777 tmp
/usr/bin/mkdir -p system/contract system/object proc mnt dev devices/pseudo
/usr/bin/mkdir -p dev/fd dev/rmt dev/swap dev/dsk dev/rdsk dev/net dev/ipnet
/usr/bin/mkdir -p dev/sad dev/pts dev/term dev/vt dev/zcons
/usr/bin/chgrp -R sys dev devices
cd dev
/usr/bin/ln -s ./fd/2 stderr
/usr/bin/ln -s ./fd/1 stdout
/usr/bin/ln -s ./fd/0 stdin
/usr/bin/ln -s ../devices/pseudo/dld@0:ctl dld
cd /

#
# add overlays, from the pkgs directory on the iso
#
#
# give ourselves some swap to avoid /tmp exhaustion
# only necessary if we add packages which use /tmp for unpacking
# also, do it after copying the main OS as it changes the dump settings
#
if [ $# -gt 0 ]; then
  swap -a /dev/zvol/dsk/rpool/swap
  LOGFILE="/a/var/sadm/install/logs/initial.log"
  echo "Installing overlays" | tee $LOGFILE
  /usr/bin/date | tee -a $LOGFILE
  if [ -d /.cdrom/pkgs ]; then
    TMPDIR=/tmp
    export TMPDIR
    for overlay in $*
    do
      echo "Installing $overlay overlay" | tee -a $LOGFILE
      /var/sadm/overlays/install-overlay -R /a -s /.cdrom/pkgs $overlay | tee -a $LOGFILE
    done
  else
    echo "No packages found, unable to install overlays"
  fi
  echo "Overlay installation complete" | tee -a $LOGFILE
  /usr/bin/date | tee -a $LOGFILE
fi

echo "Deleting live packages"
/usr/sbin/pkgrm -n -a /var/sadm/overlays/pkg.force -R /a TRIBsys-install-media-internal
#
# use a prebuilt repository if available
#
/usr/bin/rm /a/etc/svc/repository.db
if [ -f /.cdrom/repository-installed.db ]; then
    /usr/bin/cp -p /.cdrom/repository-installed.db /a/etc/svc/repository.db
elif [ -f /.cdrom/repository-installed.db.gz ]; then
    /usr/bin/cp -p /.cdrom/repository-installed.db.gz /a/etc/svc/repository.db.gz
    /usr/bin/gunzip /a/etc/svc/repository.db.gz
else
    /usr/bin/cp -p /lib/svc/seed/global.db /a/etc/svc/repository.db
fi
if [ -f /a/var/sadm/overlays/installed/kitchen-sink ]; then
    if [ -f /.cdrom/repository-kitchen-sink.db.gz ]; then
	/usr/bin/rm /a/etc/svc/repository.db
	/usr/bin/cp -p /.cdrom/repository-kitchen-sink.db.gz /a/etc/svc/repository.db.gz
	/usr/bin/gunzip /a/etc/svc/repository.db.gz
    fi
fi

#
# reset the SMF profile from the live image to regular
#
/usr/bin/rm /a/etc/svc/profile/generic.xml
/usr/bin/ln -s generic_limited_net.xml /a/etc/svc/profile/generic.xml

#
# try and kill any copies of pkgserv, as they block the unmount of the
# target filesystem
#
pkill pkgserv

#
# /boot/grub is on the iso, but not necessarily in the ramdisk
#
echo "Installing GRUB"
for DRIVE in $DRIVELIST
do
    /sbin/installgrub -fm /.cdrom/boot/grub/stage1 /.cdrom/boot/grub/stage2 /dev/rdsk/$DRIVE
done

echo "Configuring devices"
/a/usr/sbin/devfsadm -r /a
touch /a/reconfigure

echo "Setting up boot"
/usr/bin/mkdir -p /rpool/boot/grub/bootsign /rpool/etc
touch /rpool/boot/grub/bootsign/pool_rpool
echo "pool_rpool" > /rpool/etc/bootsign

/usr/bin/cat > /rpool/boot/grub/menu.lst << _EOF
title Tribblix 0.7
findroot (pool_rpool,0,a)
bootfs rpool/ROOT/tribblix
kernel\$ /platform/i86pc/kernel/\$ISADIR/unix -B \$ZFS-BOOTFS
module\$ /platform/i86pc/\$ISADIR/boot_archive
_EOF

#
# FIXME: why is this so much larger than a regular system?
# FIXME and why does it take so long - it's half the install budget
#
echo "Updating boot archive"
/usr/bin/mkdir -p /a/platform/i86pc/amd64
/sbin/bootadm update-archive -R /a
/usr/bin/sync
sleep 2

#
# enable swap
#
/bin/echo "/dev/zvol/dsk/rpool/swap\t-\t-\tswap\t-\tno\t-" >> /a/etc/vfstab

#
# Copy /jack to the installed system
#
cd /
find jack -print | cpio -pmud /a
/usr/bin/rm -f /a/jack/.bash_history
sync
#
# this is to fix a 3s delay in xterm startup
#
echo "*openIm: false" > /a/jack/.Xdefaults
/usr/bin/chown jack:staff /a/jack/.Xdefaults

/usr/sbin/fuser -c /a
#
# remount zfs filesystem in the right place for next boot
#
/usr/sbin/zfs set mountpoint=/export rpool/export
/usr/sbin/zfs set mountpoint=/ rpool/ROOT/tribblix
