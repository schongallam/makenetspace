# makenetspace

makenetspace is a simple POSIX-compliant script which creates a network namespace, moves a specified interface into it, and spawns a root shell in that namespace.  Changes are reverted upon exiting.  It does basic error checking along the way, and will attempt to ignore certain minor errors.  It recognizes options for IP configuration by dhclient, static assignment, or skipping the configuration step.  It supports ethernet, open wifi, and WPA2 via wpa_supplicant.

Why might this be useful?  If you have multiple network interfaces on your device, and want a quick and convenient way to set up an environment where you can control which traffic goes through which interface, this script might be for you.  Suppose, for example, that you have two internet connections.  You may want to use browser A for connection 1, and browser B for connection 2.  This script will make it easy for you to do that.

Another example situation would be configuring a network device over a physical ethernet connection, and you want to simultaneously connect your wifi0 interface to that network device's wifi network for testing.  And, you might want to connect a second wifi interface to an internet access point, so you can search for relevant troubleshooting information without disconnecting any of your other connections.  Without network namespaces, the kernel would not know where you wanted which traffic to go.  Setting up network namespaces allows you to have different terminals or browsers open simultaneously, each one talking only through the device you want it to.

This script was created and tested on Linux Mint 20.1.

## usage:
See USAGE for more details.
```usage:

# makenetspace.sh [OPTIONS] NETNS DEVICE

 OPTIONS  See included USAGE file for detailed options information.
 NETNS    The name of the namespace you wish to create
 DEVICE   The network interface that you want to assign to the namespace NETNS

OPTIONS:
--essid, -e <ESSID>         Connect wifi interface to ESSID
--passwd, -p <PASSWORD>     WPA2 only
--getpw, -g       Get wifi password from STDIN
--force, -f       Proceed even if resolv.conf is not found
--virtual -v      Use iw instead if ip to move the interface around
--noshell, -n     Don't spawn a shell in the new network namespace
--execute, -x <CMD>         Run CMD instead of su in the new namespace
--cleanup, -c     Skip setup and configuration, and go straight to cleanup
--strict, -s      Treat all errors as fatal, but try to cleanup before exiting
--strictkill -k   Treat all errors as fatal and exit immediately (no cleanup)
--static <STATIC_IP> <GATEWAY>    Static IP in lieu of dhclient
--noconfig, -o    Don't apply IP configuration with dhclient or --static option
--physical <WIFI> Print the physical name of the WIFI interface, then exit
--quiet, -q       Suppress unnecessary output (ignored if --debug flag used)
--verbose, -r     (overrides --quiet)
--debug, -d       (overrides --quiet and --verbose)


Note 1: this script must be run as the superuser.

Note 2: before using this script, you should have a custom resolv.conf file
that already exists in the folder /etc/netns/\$NETNS, the purpose is to have
this file bind to /etc/resolv.conf within the new namespace.  Without this you
will have to manually set up DNS (see --force option).                       (overrides --quiet and --verbose)
```

Note 1: this script must be run as the superuser.

Note 2: before using this script, you should have a custom resolv.conf file that already exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to /etc/resolv.conf within the new namespace.  Without this you will have to manually set up DNS (see --force option).

## tips
RESCUE:
if script fails and deletes the namespace without first removing the interface from the netns, the interface might appear "gone."  You can try:
```
$ sudo find /proc/ -name wlp7s0 # or interface name as appropriate
$ sudo kill [process_id]
```
and the interface should re-appear.  If all else fails, restarting your system should restore everything.

## examples
Make a namespace called testspace, move the wifi interface into it, connect to ESSID myWifi with the given password:

`# makenetspace.sh --essid myWifi --passwd abcd1234 testspace wifi0`

Connect to an ESSID containing a blankspace, and get the password from stdin:

`# makenetspace.sh --essid "Cafe Wifi" --getpw testspace wifi0`

Try to find the name of the physical interface represented by a wifi device, then exit (does not require root):

`$ makenetspace.sh --physical wlp7s0`

Connect a wired interface to namespace myConfig, with a static IP configuration.  Cleanup if there are any errors, otherwise exit in the parent namespace:

`# makenetspace.sh --noshell --strict --static 192.168.0.2/24 192.168.0.1 myConfig eth0`

Connect a wired interface, but you want forego a shell and set up another IP and routing configuration separately:

`# makenetspace.sh --noconfig --noshell myConfig eth0`

Clean up a namespace with a wired interface:

`# makenetspace.sh --cleanup myConfig eth0`

If a namespace setup attempt with wifi failed due to some reason, you can cleanup with:

`# makenetspace.sh --cleanup --virtual testspace phy0`

For the last example, yes, it is counterintuitive to use --virtual and phy0 together.  The rationale is that if the interface is already in the namespace (which is likely), the script is not able to determine the physical interface name.  So, the physical interface name needs to be provided.  And the --virtual option tells the script to assume it's recovering a wireless interface, so call iw instead of ip.


## script flow:

- Set global variables
- Interpret command line arguments
- Confirm root
- If --cleanup option is used, skip below past spawning the shell
- Conditionally check for /etc/$NETNS/resolv.conf (can be overridden)
- Make sure network namespace doesn't already exist, then try to create it
- Bring down the device before moving it
- If it's a virtual or wireless device, detect the corresponding physical device name
- Make the namespace, and move the device into it
- Bring up both the loopback interface and the device
- Connect to wifi network using provided ESSID and password, if applicable
- Start dhclient, by default.  Or, can statically configure IPv4 or leave unconfigured.
- Spawn shell by default, execute the indicated command, or otherwise exit, per options
- Stop processes inside the namespace
- Move the device out of the namespace
- Delete the namespace

## releases

currently still in initial beta testing

## dependencies
### utility (package):
```
sh (dash)
su (util-linux)
ip (iproute2)
iw (iw)
iwconfig (wireless-tools)
wpa_passphrase (wpasupplicant)
wpa_supplicant (wpasupplicant)
dhclient (isc-dhcp-client)
```
