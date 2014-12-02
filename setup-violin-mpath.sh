#!/bin/bash

# setup-violin-mpath.sh : script for configuring the multipath.conf file with Violin devices
#                         The output can be cut and pasted into the "multipaths {}" section
#                         of /etc/multipath.conf or alternatively the -l option can be used
#                         to print a list of devices
#
# See GitHub repository at https://github.com/flashdba/scripts
#
#  ###########################################################################
#  #                                                                         #
#  # Copyright (C) {2014,2015}  Author: flashdba (http://flashdba.com)       #
#  #                                                                         #
#  # This program is free software; you can redistribute it and/or modify    #
#  # it under the terms of the GNU General Public License as published by    #
#  # the Free Software Foundation; either version 2 of the License, or       #
#  # (at your option) any later version.                                     #
#  #                                                                         #
#  # This program is distributed in the hope that it will be useful,         #
#  # but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#  # MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#  # GNU General Public License for more details.                            #
#  #                                                                         #
#  # You should have received a copy of the GNU General Public License along #
#  # with this program; if not, write to the Free Software Foundation, Inc., #
#  # 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.             #
#  #                                                                         #
#  ###########################################################################

# TODO: Currently only written for use with Red Hat 6 / Oracle Linux 6 / SLES 11

# Setup variables and arrays
VERBOSE=0
LISTMODE=0
MULTIPATH_DEVICES=()

# Setup print functions
echoerr() { echo "Error: $@" 1>&2; }
echovrb() { [[ "$VERBOSE" = 1 ]] && echo "Info : ${@}" 1>&2; }
echoout() { echo "$@"; }
echolst() { echo "$@" | tr '±' '\t' | expand -t 5 1>&2; }

# Function for printing usage information
usage() {
	echo "" 1>&2
	if [ "$#" -gt 0 ]; then
		echo "Error: $@" 1>&2
		echo "" 1>&2
	fi
	echo "Usage: $0 [-v ]" 1>&2
	echo "" 1>&2
	echo "  Script for configuring the /etc/multipath.conf file" 1>&2
	echo "  Creates entries for the \"multipath \{\}\" section" 1>&2
	echo "  Requires the sg3_utils package to be present" 1>&2
	echo "  Errors and info are printed to stderr" 1>&2
	echo "" 1>&2
	echo "  Options:" 1>&2
	echo "    -h   Help     (print help and version information)" 1>&2
	echo "    -l   List     (print a list of devices and their details)" 1>&2
	echo "    -v   Verbose  (show processing details)" 1>&2
	echo "" 1>&2
	exit 1
}

while getopts ":hvl" opt; do
	case $opt in
		h)
			usage
			;;
		v)
			VERBOSE=1
			echovrb "Running in verbose mode"
			;;
		l)
			LISTMODE=1
			echovrb "Running in list mode"
			;;
		\?)
			echo "Invalid option: -$OPTARG" >&2
			usage
			;;
	esac
done

# Check that the s3_utils package has been installed and is in the path
if hash sg_inq 2> /dev/null; then
	echovrb "Using sg_inq `sg_inq -V 2>&1`"
else
	echoerr "sg3_utils package not installed - exiting..."
	exit 1
fi

# Build a list of multipath devices to scan
MULTIPATH_FILELIST=$( ls -1 /dev/dm-* )

# Iterate through the list
for MPDEVICE in $MULTIPATH_FILELIST; do

	echovrb "Issuing inquiry to device $MPDEVICE"

	# Issue sg3 inquiry to device
	SG3_OUTPUT=`sg_inq -i $MPDEVICE 2> /dev/null`
	SG3_RETVAL=$?

	# If inquiry returned error code then skip
	if [ "$SG3_RETVAL" -ne 0 ]; then
		echovrb "Skipping device $MPDEVICE"
		continue
	fi

	# Scan output to find vendor id
	SG3_VENDORID=`echo "$SG3_OUTPUT" | grep "vendor id:" | cut -d':' -f2- | sed 's/^ *//g' | sed 's/ *$//g' ` 2> /dev/null

	# Check the vendor is VIOLIN otherwise skip
	if [ "$SG3_VENDORID" != "VIOLIN" ]; then
		echovrb "Ignoring device on $MPDEVICE with vendor id = $SG3_VENDORID"
		continue
	fi

	# Get the sysfs device location (required for udevinfo)
	MPATH_DEVBASE=`basename $MPDEVICE`
	MPATH_SYSFS="/block/$MPATH_DEVBASE"

	# Process device specific details
	LUN_CONTAINER=`echo "$SG3_OUTPUT" | grep "vendor specific:" | cut -d':' -f2 | sed 's/^ *//g'`
	LUN_NAME=`echo "$SG3_OUTPUT" | grep "vendor specific:" | cut -d':' -f3`
	LUN_SERIAL=`echo "$SG3_OUTPUT" | grep "vendor specific:" | cut -d':' -f4`
	LUN_UUID=`udevadm info --query=property --path=$MPATH_SYSFS 2> /dev/null | grep "DM_UUID=" | sed 's/^DM_UUID=mpath-*//g'`
	echovrb "Found Violin device on $MPDEVICE: Container = $LUN_CONTAINER LUN Name = $LUN_NAME Serial = $LUN_SERIAL UUID = $LUN_UUID"

	# Add details to an array variable of Violin devices
	MULTIPATH_DEVICES+=(`echo "$LUN_NAME:$LUN_UUID:$LUN_CONTAINER:$LUN_SERIAL:$MPDEVICE"`)
done

# Sort the array into alphabetical order based on LUN name
echovrb "Sorting discovered devices into alphabetical order..."
MULTIPATH_DEVICES=($(for MPDEVICE in ${MULTIPATH_DEVICES[@]}; do
	echo $MPDEVICE
done | sort))
echovrb "Sort complete"

if [ "$LISTMODE" = 1 ]; then
	echolst "Device Name±Container  ±LUN Name±WWID"
	echolst "-----------±-----------±--------±----------------------------------"
else
	if [ -r /etc/multipath.conf ]; then
		echovrb "Backup up /etc/multipath.conf to /tmp"
		cp /etc/multipath.conf /tmp
	fi
fi
	
echovrb "Printing multipath.conf configuration details..."
echovrb ""

# Now print the multipath.conf output for each device, converting the LUN name to lowercase
for MPDEVICE in ${MULTIPATH_DEVICES[@]}; do
	MP_WWID=`echo $MPDEVICE | cut -d':' -f2`
	MP_ALIAS=`echo $MPDEVICE | cut -d':' -f1 | tr '[:upper:]' '[:lower:]'`
	MP_CONTAINER=`echo $MPDEVICE | cut -d':' -f3`
	MP_DEVNAME=`echo $MPDEVICE | cut -d':' -f5`

	if [ "$LISTMODE" = 1 ]; then
		echolst "$MP_DEVNAME  ±$MP_CONTAINER±$MP_ALIAS±$MP_WWID"
	else
		echoout "    multipath {"
		echoout "        # Container $MP_CONTAINER"
		echoout "        wwid $MP_WWID"
		echoout "        alias $MP_ALIAS"
		echoout "    }"
	fi
done

echovrb "Successful completion"
exit 0
