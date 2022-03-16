# makenetspace

makenetspace is a simple POSIX-compliant script which creates a network namespace, moves a specified interface into it, and spawns a root shell in that namespace.  Changes are reverted upon exiting.  It does basic error checking along the way, and will attempt to ignore certain minor errors.  It recognizes options for IP configuration by dhclient, static assignment, or skipping the configuration step.  It supports ethernet, open wifi, and WPA via wpa_supplicant.

Why might this be useful?  If you have multiple network interfaces on your device, and want a quick and convenient way to set up an environment where you can control which traffic goes through which interface, this script might be for you.  Suppose, for example, that you have two internet connections.  You may want to use browser A for connection 1, and browser B for connection 2.  This script will make it easy for you to do that.

Another example situation would be configuring a network device over a physical ethernet connection, and you want to simultaneously connect your wifi0 interface to that network device's wifi network for testing.  And, you might want to connect a second wifi interface to an internet access point, so you can search for relevant troubleshooting information without disconnecting any of your other connections.  Without network namespaces, the kernel would not know where you wanted which traffic to go.  Setting up network namespaces allows you to have different terminals or browsers open simultaneously, each one talking only through the device you want it to.

This script was created and tested on Linux Mint 20.1.

## usage:
```usage:

Briefly, 

# makenetspace.sh [OPTIONS] NETNS DEVICE

 OPTIONS        See included USAGE file for detailed options information.
 NETNS          The name of the namespace you wish to create
 DEVICE         The network interface that you want to assign to the namespace NETNS

Note 1: this script must be run as the superuser.

Note 2: before using this script, you should have a custom resolv.conf file that already exists in the folder /etc/netns/$NETNS, the purpose is to have this file bind to /etc/resolv.conf within the new namespace.  Without this you will have to manually set up DNS (see --force option).
```

## examples
Make a namespace called testspace, move the wifi interface into it, connect to ESSID myWifi with the given password:

`# makenetspace.sh --essid myWifi --passwd abcd1234 testspace wifi0`

Same, but get the password from stdin:

`# makenetspace.sh --essid myWifi --getpw testspace wifi0`

Try to find the name of the physical interface represented by a wifi device, then exit (does not require root):

`$ makenetspace.sh --physical wlp7s0`

Connect a wired interface to namespace myConfig, with a static IP configuration.  Cleanup if there are any errors, otherwise exit in the parent namespace:

`# makenetspace.sh --noshell --strict --static 192.168.0.2/24 192.168.0.1 myConfig eth0`

Connect a wired interface, but you want forego a shell and set up another IP and routing configuration separately:

`# makenetspace.sh --noconfig --noshell myConfig eth0`

Clean up a namespace with a wired interface:

`# makenetspace.sh --cleanup myConfig eth0`

If a namespace setup attempt with wifi failed due for some reason, you can cleanup with:

`# makenetspace.sh --cleanup --virtual testspace phy0`

For the last example, yes, it is counterintuitive to use --virtual and phy0 together.  The rationale is that if the interface is already in the namespace (which is likely), the script is not able to determine the physical interface name.  So, the physical interface name needs to be provided.  And the --virtual option tells the script to assume it's recovering a wireless interface, so call iw instead of ip.


## script flow:

-Set global variables
-Interpret command line arguments
-Confirm root
-If --cleanup option is used, skip below past spawning the shell
-Conditionally check for /etc/$NETNS/resolv.conf (can be overridden)
-Make sure network namespace doesn't already exist, then try to create it
-Bring down the device before moving it
-If it's a virtual or wireless device, detect the corresponding physical device name
-Make the namespace, and move the device into it
-Bring up both the loopback interface and the device
-Connect to wifi network using provided ESSID and password, if applicable
-Start dhclient, by default.  Or, can statically configure IPv4 or leave unconfigured.
-Spawn shell by default, otherwise exit here
-Stop dhclient, if running
-Move the device out of the namespace
-Delete the namespace
-Restart NetworkManager (by default)

## calls:
```
sh
su
ip
iw
iwconfig
wpa_passphrase
wpa_supplicant
dhclient
service network-manager
```
