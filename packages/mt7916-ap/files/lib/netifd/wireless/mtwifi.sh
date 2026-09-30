#!/bin/sh
#
# netifd wireless driver for the MTK closed-source AP stack.
#
# This replaces mac80211.sh. The vendor driver does NOT register with
# cfg80211, so there is no phy device, no iw, no hostapd. Everything -- SSID,
# security, channel, even bringing the VAP up -- goes through an ioctl/ioctl
# family reachable with iwpriv.
#
# Expected behaviour:
#   * the driver creates ra* / rax* netdevs on its own
#   * netifd calls this script once per phy-less radio declared in
#     /etc/config/wireless with option type 'mtwifi'
#
# You need iwpriv from the driver package for this to do anything useful.

. /lib/netifd/netifd-proto.sh
. /lib/functions.sh

DRIVER_NAME=mtwifi

RADIO_IFACES="ra0 rai0 rax0 rax1 apclii0 apcli0"

mtwifi_log() {
	logger -t netifd-mtwifi "$@"
}

# Map a UCI band string onto the driver's radio index.
# MTK's closed stack numbers bands internally; confirm against your build by
# reading /proc/mt7916/mt_wifi* or whatever the driver exposes.
mtwifi_band_index() {
	case "$1" in
		2g|2.4g) echo 0 ;;
		5g) echo 1 ;;
		*) echo 0 ;;
	esac
}

mtwifi_detect_radios() {
	local present=""
	local name

	for name in $RADIO_IFACES; do
		grep -q "${name}:" /proc/net/dev 2>/dev/null && {
			case "$present" in
				*"$name"*) ;;
				*) present="$present $name" ;;
			esac
		}
	done

	echo "$present"
}

# Bring one netdev up and apply the UCI values through iwpriv.
mtwifi_setup_iface() {
	local ifname="$1"
	local cfg="$2"
	local ssid encryption key channel hwmode hidden
	local apcli=0

	config_get ssid "$cfg" ssid "OpenWrt"
	config_get encryption "$cfg" encryption "none"
	config_get key "$cfg" key ""
	config_get channel "$cfg" channel "auto"
	config_get hwmode "$cfg" hwmode "11axg"
	config_get hidden "$cfg" hidden "0"

	ip link set "$ifname" down 2>/dev/null

	iwpriv "$ifname" set SSID="$ssid" 2>/dev/null \
		|| mtwifi_log "iwpriv SSID failed on $ifname (iwpriv missing?)"

	case "$encryption" in
		psk2|psk-mixed|psk)
			iwpriv "$ifname" set AuthMode=WPA2PSK 2>/dev/null
			iwpriv "$ifname" set EncrypType=AES 2>/dev/null
			iwpriv "$ifname" set WPAPSK="$key" 2>/dev/null
			;;
		psk3|sae)
			iwpriv "$ifname" set AuthMode=WPA3PSK 2>/dev/null
			iwpriv "$ifname" set EncrypType=AES 2>/dev/null
			iwpriv "$ifname" set WPAPSK="$key" 2>/dev/null
			;;
		none|open|*)
			iwpriv "$ifname" set AuthMode=OPEN 2>/dev/null
			iwpriv "$ifname" set EncrypType=NONE 2>/dev/null
			;;
	esac

	[ "$hidden" = "1" ] && iwpriv "$ifname" set HideSSID=1 2>/dev/null

	[ "$channel" = "auto" ] || iwpriv "$ifname" set Channel="$channel" 2>/dev/null

	ip link set "$ifname" up 2>/dev/null
	mtwifi_log "configured $ifname ssid=$ssid enc=$encryption ch=$channel"
}

detect_mtwifi() {
	local radios
	radios=$(mtwifi_detect_radios)

	[ -z "$radios" ] && {
		mtwifi_log "no MTK radio netdevs present"
		return 1
	}

	local idx=0
	local radio

	for radio in $radios; do
		cat <<EOF

config wifi-device 'radio${idx}'
	option type 'mtwifi'
	option channel 'auto'
	option band '2.4g'
	option hwmode '11axg'
	option htmode 'HE80'
	option disabled '0'
	option iface '${radio}'

config wifi-iface 'default_radio${idx}'
	option device 'radio${idx}'
	option network 'lan'
	option mode 'ap'
	option ssid 'OpenWrt'
	option encryption 'psk2'
	option key '12345678'
	option ifname '${radio}'
EOF
		idx=$((idx + 1))
	done
}

# ---------------------------------------------------------------- netifd API

# netifd hands us: $1 = action, $2 = device (radio section name)
drv_mtwifi_init_device_config() {
	config_add_string iface
}

drv_mtwifi_setup() {
	local cfg="$1"
	local iface="$2"

	local ifname
	config_get ifname "$cfg" ifname

	json_init
	json_add_string ifname "$ifname"

	mtwifi_setup_iface "$ifname" "$cfg"

	netifd_set_bridge_config '' ''
	json_dump
}

drv_mtwifi_cleanup() {
	return 0
}

drv_mtwifi_teardown() {
	local cfg="$1"
	local ifname
	config_get ifname "$cfg" ifname
	ip link set "$ifname" down 2>/dev/null
}

add_driver "$DRIVER_NAME"
