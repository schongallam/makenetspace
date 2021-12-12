# makespace
A simple linux script which creates a network namespace, moves a specified interface into it, and spawns a shell in that namespace.  Changes are reverted upon exiting.
 usage:
makespace [-f] NETNS DEVICE [ESSID] [PASSWORD]
 -f                    option to force execution without a proper resolv.conf in place.
                      otherwise, script will exit.
 NETNS                 the name of the namespace you wish to create
 DEVICE                the network interface that you want to assign to the namespace NETNS
 ESSID and PASSWORD    used for wireless interfaces. Attempts to join network
                       with wpa_supplicant only.

makespace will create the namespace NETNS, move the physical interface DEVICE to that space,
attempt to join the wireless network ESSID using password PASSWORD, then finally launch
a root shell in that namespace.

when you exit the shell, the script will attempt to kill dhclient and wpa_supplicant
within that namespace, revert the device to the default namespace, and remove the namespace.

Note: this script must be run as the superuser.

Note: before using this script, you should have a custom resolv.conf file that already
exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to
/etc/resolv.conf within the new namespace.  Without this you will have to manually set up
DNS.


Other internal variables:
 NO_CHECK             1 if skipping check for /etc/netns/$NETNS/resolv.conf
                      otherwise, 0
 INTERFACE_TYPE       1 for wired DEVICE, 2 for wireless DEVICE
 EXIT_CODE            captures and preserves an abnormal exit code from a command in the
                      event that we need to exit the script with it
 PHY                  physical interface name for given wifi interface DEVICE
 PHY_FALLBACK         (UNUSED) 1 if unable to confirm PHY, and using DEVICE instead.
                      Otherwise, undefined
 UNCONFIRMED_MOVE     (UNUSED) 1 if grep can't find DEVICE listed in the new namespace after
                      attempting to move it

OTHER EXIT CODES:

 NORMAL=0                # normal exit
 HELP=0                  # help/description shown
 NO_ROOT=1               # not run as root
 NO_RESOLV_CONF=2        # unable to find appropriate resolv.conf file
 BAD_NAMESPACE=3         # namespace is bad or already exists
