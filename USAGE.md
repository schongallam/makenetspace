# Usage
```
usage:
# makenetspace [OPTIONS] NETNS DEVICE

OPTIONS:
--essid, -e <ESSID> Attempt to join wireless network ESSID after creating namespace.
                    Ignored if using --cleanup.  Use quotes if it contains blank spaces.

--passwd, -p <PASSWORD>   Password to use with ESSID.  Ignored if --essid not used.
                    Use quotes if it contains blank spaces.

--getpw, -g         Gets PASSWORD from stdin instead of command line. Overrides --passwd.

--force, -f         Option to force execution without a proper resolv.conf in place.
                    otherwise, script will exit.  Ignored if using --cleanup option.

--virtual -v        Assume DEVICE is a virtual interface, forcing the script to check
                    for a different physical device name (as it does for wireless devices).

--noshell, -n       Exit the script instead of spawning a root shell in the new namespace.
                    use with --cleanup later to close the namespace.  Incompatible
                    with --cleanup.

--execute, -x <CMD>     Instead of running su, script will run CMD. Use quotes if it
                    contains blank spaces.

--cleanup, -c       Resumes execution as if the su shell was just exited.  This option
                    only attempts to remove the specified DEVICE, so if you manually
                    added other devices to the same namespace, be sure to manually remove
                    them before using this option.  Otherwise, you will have to search for
                    and kill the relevant processes to reclaim the extra devices.  This
                    option can also be employed as a rescue attempt. Incompatible with the
                    --noshell option.  NOTE: if you intend to cleanup a wifi device, it
                    will work the most cleanly if you use the --virtual option and provide
                    the physical device name (i.e. "phy0") as DEVICE.

--strict, -s        Strict verification that DEVICE was successfully moved into NETNS.
                    upon failure, cleans up the namespace before exiting.  Ignored if
                    using --cleanup option.

--strictkill -k     Like --strict, but exits immediately (no cleanup).  Takes precedence
                    over regular --strict.  Ignored if using --cleanup option.

--static <STATIC_IP> <GATEWAY>     Instead of running dhclient (default), uses ip(8) to add a
                    static ip address and default route.  IPv4 only at this time.
                    Incompatible with --noconfig option.
                    CIDR        standard format a.b.c.d/XX
                    GATEWAY     a.b.c.d

--noconfig, -o      Don't start dhclient and don't try to configure the IP manually.  Using
                    this option will still attempt to connect to the network, but it won't
                    be immediately usable in this state.  Incompatible with --static option.

--physical <WIFI>   Shows the physical name of WIFI device, then exits immediately.  This will
                    fail if WIFI device is already in a namespace.

--quiet, -q         Suppress unnecessary output (ignored if --debug flag used)
--verbose, -r       Print extra information when unexpected deviations happen, but script will
                    continue (overrides --quiet)
--debug, -d         Enable debug output (overrides --quiet and --verbose)


MANDATORY PARAMETERS
 NETNS                The name of the namespace you wish to create.
 DEVICE               The network interface that you want to assign to the namespace NETNS.

makenetspace will create the namespace NETNS, move the physical interface DEVICE to that space,
attempt to join the wireless network using the provided ESSID and PASSWORD, then finally (by
default) launch a root shell in that namespace.  Use the options to modify this process.

When you exit the shell, the script will by default attempt to kill dhclient and wpa_supplicant
within that namespace, revert the device to the default namespace, and remove the namespace.
Finally, it will reset network-manager unless otherwise instructed not to.

Note: this script must be run as the superuser.

Note: before using this script, you should have a custom resolv.conf file that already
exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to
/etc/resolv.conf within the new namespace.  Without this you will have to manually set up
DNS  (see -f option).

Examples:

# makenetspace TestNameSpace eth0
# makenetspace -e MyHomeWifi -p "I Love My Dog" MyNameSpace wifi0
# makenetspace --static 192.168.0.10/24 192.168.0.1 MyStaticHost eth0
# makenetspace --cleanup MyWifi wlp7s0
"""