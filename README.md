# makenetspace
makenetspace is a simple linux script which creates a network namespace, moves a specified interface into it, and spawns a shell in that namespace.  Changes are reverted upon exiting.  It does basic error checking along the way, and will attempt to ignore certain minor errors.

When this might be useful: If you have multiple network interfaces on your device, and want a quick and convenient way to set up an environment where you can control which traffic goes through which interface, this script might be for you.  Suppose, for example, that you have two internet connections.  You may want to use browser A for connection 1, and browser B for connection 2.  This script will make it easy for you to do that.

This script was created and tested on Linux Mint 20.1.

```usage:
 
makenetspace [-f] NETNS DEVICE [ESSID] [PASSWORD]

 -f                    option to force execution without a proper resolv.conf in place.
                       otherwise, script will exit.
 NETNS                 the name of the namespace you wish to create
 DEVICE                the network interface that you want to assign to the namespace NETNS
 ESSID and PASSWORD    used for wireless interfaces. Attempts to join network
                       with wpa_supplicant only.

makenetspace will create the namespace NETNS, move the physical interface DEVICE to that space,
attempt to join the wireless network ESSID using password PASSWORD, then finally launch
a root shell in that namespace.

when you exit the shell, the script will attempt to kill dhclient and wpa_supplicant
within that namespace, revert the device to the default namespace, and remove the namespace.

Note: this script must be run as the superuser.

Note: before using this script, you should have a custom resolv.conf file that already
exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to
/etc/resolv.conf within the new namespace.  Without this you will have to manually set up
DNS (see -f option).
```
