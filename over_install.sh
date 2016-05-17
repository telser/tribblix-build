#!/bin/sh
#
# This script allows you to install a copy of Tribblix into an existing
# zfs pool.
#
# ./over_install.sh [-B] rpool [overlays ...]
#
# You need to specify the name of the pool, usually rpool.
# You can specify overlays just like the normal install.
# We install a new bootloader to the pool, to be sure it's consistent
# with the bits we install. With -B, also update the MBR.
#
# While the grub menu will only show this new instance of Tribblix, any
# old BEs will still be present and can be seen (and activated) using beadm
#
# We copy account details (group, passwd, shadow) and the system ssh keys
# from the existing BE. Any existing ZFS file systems will automatically
# transfer across unchanged. All other customizations are left to the user.
#

#
# these properties are available for customization
#
ROOTPOOL="rpool"
SWAPSIZE="2g"
BFLAG=""
REBOOT="no"
OVERLAYS=""
NODENAME=""
TIMEZONE=""
DOMAINNAME=""
BEGIN_SCRIPT=""
FINISH_SCRIPT=""
FIRSTBOOT_SCRIPT=""
NEWBE="tribblix-m17"

FSTYPE="ZFS"
PKGLOC="/.cdrom/pkgs"
SMFREPODIR="/usr/lib/zap"
ALTROOT="/a"

#
# read an external configuration file, if supplied
#
IPROFILE=`/sbin/devprop install_profile`
if [ ! -z "$IPROFILE" ]; then
REBOOT="yes"
case $IPROFILE in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${IPROFILE%/*}
	IPROFNAME=${IPROFILE##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    . ${TMPMNT}/${IPROFNAME}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	DELAY=0
	while [ ! -f "$TMPF" ]
	do
	    sleep $DELAY
	    DELAY=$(($DELAY+1))
	    /usr/bin/curl -f -s -S --retry 6 -o $TMPF $IPROFILE
	done
	. $TMPF
	rm -fr $TMPF
	;;
esac
fi

#
# begin script handling
# the begin script is run and its output saved
# then we source the output, this allows you to
# dynamically create install settings
#
if [ -n "$BEGIN_SCRIPT" ]; then
BEGINF="/tmp/begin.$$"
case $BEGIN_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${BEGIN_SCRIPT%/*}
	IPROFNAME=${BEGIN_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    ${TMPMNT}/${IPROFNAME} > $BEGINF
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	/usr/bin/curl -f -s -S --retry 6 -o $TMPF $BEGIN_SCRIPT
	if [ -s "$TMPF" ]; then
	    chmod a+x $TMPF
	    $TMPF > $BEGINF
	fi
	rm -f $TMPF
	;;
esac
if [ -s "$BEGINF" ]; then
    . $BEGINF
fi
rm -f $BEGINF
fi

#
# interactive argument handling
#
while getopts "Bn:t:" opt; do
    case $opt in
        B)
	    BFLAG="-M"
	    ;;
        n)
	    NODENAME="$OPTARG"
	    ;;
        t)
	    TIMEZONE="$OPTARG"
	    ;;
    esac
done
shift $((OPTIND-1))

#
# the first remaining argument is a pool to install to
#
case $# in
0)
	echo "ERROR: You must specify an existing pool to install to"
	echo "Usage: $0 [-B] old_pool [overlay ... ]"
	exit 1
	;;
*)
	ROOTPOOL=$1
	shift
	;;
esac

#
# everything else is an overlay
#
OVERLAYS="$OVERLAYS $*"

#
# end interactive argument handling
#

#
# use the existing pool; we assume everything was set up
# correctly on that pool, but check that menu.lst is present
# as a sanity check
#
/usr/bin/mkdir -p ${ALTROOT}
echo "Importing old root pool"
/usr/sbin/zpool import ${ROOTPOOL}
if [ ! -f /${ROOTPOOL}/boot/grub/menu.lst ]; then
    echo "Import of old pool failed, cannot find menu.lst"
    exit 0
fi

#
# this is what the original boot file system was set to
# we mount it later to recover specific data
#
OLDBE=`/usr/sbin/zpool get -Hp -o value bootfs ${ROOTPOOL}`
if [ -z "$OLDBE" ]; then
    echo "Pool ${ROOTPOOL} has no bootfs property, cannot use."
    exit 1
fi

echo "Creating filesystems"
/usr/sbin/zfs create -o mountpoint=${ALTROOT} ${ROOTPOOL}/ROOT/${NEWBE}
/usr/sbin/zpool set bootfs=${ROOTPOOL}/ROOT/${NEWBE} ${ROOTPOOL}

#
# this gives the new BE a UUID, necessary for 'beadm list -H'
# to not show null, and for zone uninstall to work
#
/usr/sbin/zfs set org.opensolaris.libbe:uuid=`/usr/lib/zap/generate-uuid` ${ROOTPOOL}/ROOT/${NEWBE}

echo "Copying main filesystems"
cd /
ZONELIB=""
if [ -d zonelib ]; then
    ZONELIB="zonelib"
fi
/usr/bin/find boot kernel lib platform root sbin usr etc var opt ${ZONELIB} -print -depth | cpio -pdm ${ALTROOT}
echo "Copying other filesystems"
/usr/bin/find boot -print -depth | cpio -pdm /${ROOTPOOL}

#
echo "Adding extra directories"
cd ${ALTROOT}
/usr/bin/ln -s ./usr/bin .
/usr/bin/mkdir -m 1777 tmp
/usr/bin/mkdir -p system/contract system/object system/boot proc mnt dev devices/pseudo
/usr/bin/mkdir -p dev/fd dev/rmt dev/swap dev/dsk dev/rdsk dev/net dev/ipnet
/usr/bin/mkdir -p dev/sad dev/pts dev/term dev/vt dev/zcons
/usr/bin/chgrp -R sys dev devices mnt
/usr/bin/chmod 555 system system/* proc
cd dev
/usr/bin/ln -s ./fd/2 stderr
/usr/bin/ln -s ./fd/1 stdout
/usr/bin/ln -s ./fd/0 stdin
/usr/bin/ln -s ../devices/pseudo/dld@0:ctl dld
cd /

#
# delete mkisofs from the installed image, we have an unpackaged copy
# on the bootable /usr which we use to optimize boot archive creation
#
/usr/bin/rm -f ${ALTROOT}/usr/bin/mkisofs

#
# add overlays, from the pkgs directory on the iso
# or an alternate location supplied by boot
#
# we create a zap config based on boot properties, should we copy that
# to the installed image as the highest priority repo? The problem
# there is that it will block all future updates
#
# give ourselves some swap to avoid /tmp exhaustion
# do it after copying the main OS as it changes the dump settings
#
swap -a /dev/zvol/dsk/${ROOTPOOL}/swap
LOGFILE="${ALTROOT}/var/sadm/install/logs/initial.log"
echo "Installing overlays" | tee $LOGFILE
/usr/bin/date | tee -a $LOGFILE
TMPDIR=/tmp
export TMPDIR
PKGMEDIA=`/sbin/devprop install_pkgs`
if [ -d ${PKGLOC} ]; then
    for overlay in base $OVERLAYS
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} -s ${PKGLOC} $overlay | tee -a $LOGFILE
    done
elif [ -z "$PKGMEDIA" ]; then
    echo "No packages found, unable to install overlays"
else
    echo "${ALTROOT}/var/zap/cache" > /etc/zap/cache_dir
    echo "5 cdrom" >> /etc/zap/repo.list
    echo "NAME=cdrom" > /etc/zap/repositories/cdrom.repo
    echo "DESC=Tribblix packages from CD image" >> /etc/zap/repositories/cdrom.repo
    echo "URL=${PKGMEDIA}" >> /etc/zap/repositories/cdrom.repo
    /usr/lib/zap/refresh-catalog cdrom
    for overlay in base $OVERLAYS
    do
	echo "Installing $overlay overlay" | tee -a $LOGFILE
	/usr/lib/zap/install-overlay -R ${ALTROOT} $overlay | tee -a $LOGFILE
    done
fi
echo "Overlay installation complete" | tee -a $LOGFILE
/usr/bin/date | tee -a $LOGFILE

echo "Deleting live package"
/usr/bin/zap uninstall -R ${ALTROOT} TRIBsys-install-media-internal

#
# use a prebuilt repository if available
#
/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
if [ -f ${SMFREPODIR}/repository-installed.db ]; then
    /usr/bin/cp -p ${SMFREPODIR}/repository-installed.db ${ALTROOT}/etc/svc/repository.db
elif [ -f ${SMFREPODIR}/repository-installed.db.gz ]; then
    /usr/bin/cp -p ${SMFREPODIR}/repository-installed.db.gz ${ALTROOT}/etc/svc/repository.db.gz
    /usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
else
    /usr/bin/cp -p /lib/svc/seed/global.db ${ALTROOT}/etc/svc/repository.db
fi
#
# We have an x11 version because we have to enable hal
#
if [ -f ${ALTROOT}/var/sadm/overlays/installed/x11 ]; then
    if [ -f ${SMFREPODIR}/repository-x11.db.gz ]; then
	/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
	/usr/bin/cp -p ${SMFREPODIR}/repository-x11.db.gz ${ALTROOT}/etc/svc/repository.db.gz
	/usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
    fi
fi
if [ -f ${ALTROOT}/var/sadm/overlays/installed/kitchen-sink ]; then
    if [ -f ${SMFREPODIR}/repository-kitchen-sink.db.gz ]; then
	/usr/bin/rm ${ALTROOT}/etc/svc/repository.db
	/usr/bin/cp -p ${SMFREPODIR}/repository-kitchen-sink.db.gz ${ALTROOT}/etc/svc/repository.db.gz
	/usr/bin/gunzip ${ALTROOT}/etc/svc/repository.db.gz
    fi
fi

#
# reset the SMF profile from the live image to regular
#
/usr/bin/rm ${ALTROOT}/etc/svc/profile/generic.xml
/usr/bin/ln -s generic_limited_net.xml ${ALTROOT}/etc/svc/profile/generic.xml

#
# shut down pkgserv, as it blocks the unmount of the target filesystem
#
pkgadm sync -R ${ALTROOT} -q

echo "Configuring devices"
${ALTROOT}/usr/sbin/devfsadm -r ${ALTROOT}
touch ${ALTROOT}/reconfigure

echo "Setting up boot"
/usr/bin/mkdir -p /${ROOTPOOL}/boot/grub/bootsign /${ROOTPOOL}/etc
touch /${ROOTPOOL}/boot/grub/bootsign/pool_${ROOTPOOL}
echo "pool_${ROOTPOOL}" > /${ROOTPOOL}/etc/bootsign

#
# copy any console settings to the running system
#
BCONSOLE=""
ICONSOLE=`/sbin/devprop console`
if [ ! -z "$ICONSOLE" ]; then
  BCONSOLE=",console=${ICONSOLE},input-device=${ICONSOLE},output-device=${ICONSOLE}"
fi

#
# the real grub menu is under the root pool, not under /boot on the root
# filesystem. zero the latter to avoid confusion
#
/usr/bin/cat > /${ROOTPOOL}/boot/grub/menu.lst << _EOF
default 0
timeout 3
title Tribblix 0.17
findroot (pool_${ROOTPOOL},0,a)
bootfs ${ROOTPOOL}/ROOT/${NEWBE}
kernel\$ /platform/i86pc/kernel/\$ISADIR/unix -B \$ZFS-BOOTFS${BCONSOLE}
module\$ /platform/i86pc/\$ISADIR/boot_archive
_EOF
cp /dev/null ${ALTROOT}/boot/grub/menu.lst

#
# set nodename if requested
#
if [ -n "$NODENAME" ]; then
    echo $NODENAME > ${ALTROOT}/etc/nodename
fi

#
# set domain name if requested
#
if [ -n "$DOMAINNAME" ]; then
    echo $DOMAINNAME > ${ALTROOT}/etc/defaultdomain
fi

#
# set timezone if requested
#
if [ -n "$TIMEZONE" ]; then
    mv ${ALTROOT}/etc/default/init ${ALTROOT}/etc/default/init.pre
    cat ${ALTROOT}/etc/default/init.pre | /usr/bin/sed s:PST8PDT:${TIMEZONE}: > ${ALTROOT}/etc/default/init
    rm ${ALTROOT}/etc/default/init.pre
fi

#
# FIXME: why is this so much larger than a regular system?
# FIXME and why does it take so long - it's half the install budget
#
echo "Updating boot archive"
/usr/bin/mkdir -p ${ALTROOT}/platform/i86pc/amd64
/sbin/bootadm update-archive -R ${ALTROOT}

#
# enable swap
#
/bin/echo "/dev/zvol/dsk/${ROOTPOOL}/swap\t-\t-\tswap\t-\tno\t-" >> ${ALTROOT}/etc/vfstab

#
# Copy /jack to the installed system
#
cd /
find jack -print | cpio -pmud ${ALTROOT}
/usr/bin/rm -f ${ALTROOT}/jack/.bash_history

#
# this is to fix a 3s delay in xterm startup
#
echo "*openIm: false" > ${ALTROOT}/jack/.Xdefaults
/usr/bin/chown jack:staff ${ALTROOT}/jack/.Xdefaults

#
# if specified, run a finish script
# the new root directory is passed as the only argument
#
if [ -n "$FINISH_SCRIPT" ]; then
case $FINISH_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${FINISH_SCRIPT%/*}
	IPROFNAME=${FINISH_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    ${TMPMNT}/${IPROFNAME} ${ALTROOT}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	/usr/bin/curl -f -s -S --retry 6 -o $TMPF $FINISH_SCRIPT
	if [ -s "$TMPF" ]; then
	    chmod a+x $TMPF
	    $TMPF ${ALTROOT}
	fi
	rm -f $TMPF
	;;
esac
fi

#
# remove the autoinstall startup script
#
/bin/rm -f ${ALTROOT}/etc/rc2.d/S99auto_install
sync
sleep 2

#
# if specified, enable a first-boot script
#
if [ -n "$FIRSTBOOT_SCRIPT" ]; then
FIRSTDIR="${ALTROOT}/etc/tribblix"
FIRSTF="${FIRSTDIR}/firstboot"
mkdir ${FIRSTDIR}
case $FIRSTBOOT_SCRIPT in
nfs*)
	TMPMNT="/tmp/mnt1"
	mkdir -p ${TMPMNT}
	IPROFDIR=${FIRSTBOOT_SCRIPT%/*}
	IPROFNAME=${FIRSTBOOT_SCRIPT##*/}
	mount $IPROFDIR $TMPMNT
	if [ -f ${TMPMNT}/${IPROFNAME} ]; then
	    cp ${TMPMNT}/${IPROFNAME} ${FIRSTF}
	fi
	umount ${TMPMNT}
	rmdir ${TMPMNT}
	;;
http*)
	TMPF="/tmp/profile.$$"
	/usr/bin/curl -f -s -S --retry 6 -o $TMPF $FIRSTBOOT_SCRIPT
	if [ -s "$TMPF" ]; then
	    cp $TMPF $FIRSTF
	fi
	rm -f $TMPF
	;;
esac
if [ -s "${FIRSTF}" ]; then
    chmod a+x $FIRSTF
cat >> ${ALTROOT}/etc/rc3.d/S99firstboot <<EOF
#!/bin/sh
if [ -f /etc/tribblix/firstboot ]; then
mv /etc/tribblix/firstboot /etc/tribblix/firstboot.run
/etc/tribblix/firstboot.run
rm /etc/tribblix/firstboot.run
fi
rm /etc/rc3.d/S99firstboot
EOF
    chmod a+x ${ALTROOT}/etc/rc3.d/S99firstboot
fi
fi

#
# copy selected keyboard type to installed system
#
KLAYOUT=`/usr/bin/kbd -l | /usr/bin/grep layout= | /usr/bin/awk -F= '{print $2}' | /usr/bin/awk '{print $1}'`
if [ -n "${KLAYOUT}" ]; then
  NLAYOUT=`/usr/bin/nawk -v ntyp=${KLAYOUT} -F= '{if ($2 == ntyp) print $1}' /usr/share/lib/keytables/type_6/kbd_layouts`
  if [ -n "${NLAYOUT}" ]; then
    /usr/bin/grep -v keyboard-layout ${ALTROOT}/boot/solaris/bootenv.rc > ${ALTROOT}/boot/solaris/bootenv.rc.tmp
    echo "setprop keyboard-layout ${NLAYOUT}" >> ${ALTROOT}/boot/solaris/bootenv.rc.tmp
    /usr/bin/mv ${ALTROOT}/boot/solaris/bootenv.rc.tmp ${ALTROOT}/boot/solaris/bootenv.rc
  fi
fi

#
# we need to copy some stuff off the existing system,
# just basic identity
# not the ssh config files because of sunssh vs openssh differences
#
TDIR=/tmp/oldmnt
mkdir -p $TDIR
/usr/sbin/zfs set mountpoint=${TDIR} ${OLDBE}
/usr/sbin/zfs mount ${OLDBE}
/usr/bin/cp -p ${TDIR}/etc/passwd ${ALTROOT}/etc/passwd
/usr/bin/cp -p ${TDIR}/etc/group ${ALTROOT}/etc/group
/usr/bin/cp -p ${TDIR}/etc/shadow ${ALTROOT}/etc/shadow
/usr/bin/cp -p ${TDIR}/etc/ssh/ssh* ${ALTROOT}/etc/ssh
if [ -z "$NODENAME" ]; then
    /usr/bin/cp -p ${TDIR}/etc/nodename ${ALTROOT}/etc/nodename
fi
/usr/sbin/zfs unmount ${OLDBE}
/usr/sbin/zfs set canmount=noauto ${OLDBE}

#
# remount zfs filesystem in the right place for next boot
#
/usr/sbin/zfs set canmount=noauto ${ROOTPOOL}/ROOT/${NEWBE}
/usr/sbin/zfs set mountpoint=/ ${ROOTPOOL}/ROOT/${NEWBE}

#
# we need to install our version of grub to be sure we have one
# that is compatible
# we overwrite the MBR if -B was passed
#
/sbin/bootadm install-bootloader ${BFLAG} -f -P ${ROOTPOOL}

#
# if specified, reboot
#
case $REBOOT in
yes)
	echo "Install complete, rebooting"
	/sbin/sync
	/usr/sbin/reboot -p
	;;
esac
