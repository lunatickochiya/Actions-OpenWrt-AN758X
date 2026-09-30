#!/bin/bash
# mt_wifi (MT7916) external module build against Linux 6.18 -- ponwrt AN7581
#
# The CONFIG_* list below is derived from the driver's own Kconfig default-y
# closure (see /tmp/genconf.py) plus the handful of options this particular
# source revision actually needs.  Hand-picking these one at a time is how you
# spend a week guessing, so we don't.
#
# Usage: ./build.sh [log-file]
LOG="${1:-/tmp/build/build_$(date +%H%M%S).log}"
mkdir -p /tmp/build

cd /tmp/kern/linux || exit 1

CONF=(
  # ---- baseline (Kconfig default-y closure for MT7916) ----
  CONFIG_SUPPORT_OPENWRT=y
  CONFIG_WIFI_DRIVER=y
  CONFIG_PROPRIETARY_DRIVER=y
  CONFIG_CHIP_MT7916=y
  CONFIG_FIRST_IF_MT7916=y
  CONFIG_SECOND_IF_NONE=y
  CONFIG_THIRD_IF_NONE=y   # else -DCONFIG_RT_THIRD_CARD= lands empty and rt_profile.c breaks
  CONFIG_7916_USE_PCI=y
  CONFIG_MT_MAC=y
  CONFIG_RTMP_MAC=y
  CONFIG_RTMP_MAC_PCI=y
  CONFIG_DOT11_N_SUPPORT=y
  CONFIG_DOT11_VHT_AC=y
  CONFIG_DOT11_HE_AX=y
  CONFIG_RATE_ADAPTION=y
  CONFIG_RATE_ADAPT_AGBS_SUPPORT=y
  CONFIG_HDR_TRANS_TX_SUPPORT=y
  CONFIG_HDR_TRANS_RX_SUPPORT=y
  CONFIG_MT_DFS_SUPPORT=y
  CONFIG_BACKGROUND_SCAN_SUPPORT=y
  CONFIG_TXBF_SUPPORT=y
  CONFIG_SINGLE_SKU=y
  CONFIG_TPC_SUPPORT=y
  CONFIG_SPECTRUM_SUPPORT=y
  CONFIG_ICAP_SUPPORT=y
  CONFIG_SMART_CARRIER_SENSE_SUPPORT=y
  CONFIG_MUMIMO_SUPPORT=y
  CONFIG_MU_RA_SUPPORT=y
  CONFIG_GREENAP_SUPPORT=y
  CONFIG_BAND_STEERING=y
  CONFIG_DYNAMIC_WMM_SUPPORT=y
  CONFIG_IGMP_SNOOP_SUPPORT=y
  CONFIG_MCAST_RATE_SPECIFIC=y
  CONFIG_VOW_SUPPORT=y
  # enable_bss_ext_feature / LINK_TEST_SUPPORT ships a syntactically broken
  # MTWF_PRINT() (cmm_cfg.c: unbalanced ")"), and it is lab-only. Keep it off.
  # CONFIG_LINK_TEST_SUPPORT=y
  CONFIG_MBSS_SUPPORT=y
  CONFIG_WDS_SUPPORT=y
  CONFIG_APCLI_SUPPORT=y      # also turns on -DCONFIG_STA_SUPPORT inside the Makefile
  # AN7581 uses Airoha's userspace EEPROM flow (ecnt_wl_e2p -> /lib/firmware/
  # mediatek/mt7916_eeprom.bin), i.e. E2P_BIN_MODE.  RTMP_FLASH_SUPPORT would
  # make ee_flash.c pull in the MTK-proprietary mt_eeprom_{read,write}_wifi()
  # hooks which nothing on this platform exports.  Keep it OFF.
  CONFIG_RTMP_FLASH_SUPPORT=n
  CONFIG_CAL_BIN_FILE_SUPPORT=y
  CONFIG_PCIE_ASPM_DYM_CTRL_SUPPORT=y
  CONFIG_WIFI_GPIO_CTRL=y
  CONFIG_G_BAND_256QAM_SUPPORT=y
  CONFIG_WIRELESS_EXT=y
  CONFIG_WEXT_PRIV=y
  CONFIG_WEXT_SPY=y
  CONFIG_WIFI_EAP_FEATURE=y
  CONFIG_WIFI_DBG_TXCMD=y
  CONFIG_WIFI_SYSTEM_DVT=y

  # ---- extras this source revision needs but Kconfig leaves off by default ----
  # referenced from ap_cfg.c (ApCfg.MgmtTxPwr / EpaFeGain, wdev->TxPwrDelta)
  CONFIG_MGMT_TXPWR_CTRL=y
  # referenced from ap_mgmt_auth.c under DOT11W_PMF_SUPPORT (wdev->FtCfg)
  CONFIG_DOT11R_FT_SUPPORT=y
  # referenced from ap.c / rtmp.h (SaeCfg, delete_saeinstance_entry)
  CONFIG_WPA3_SUPPORT=y
  CONFIG_DOT11W_PMF_SUPPORT=y
  # referenced from rtmp.h (RRM_BEACON_REQ_INFO)
  CONFIG_DOT11K_RRM_SUPPORT=y
  CONFIG_WSC_INCLUDED=y
  # MAC_TABLE_ENTRY.bAPSDCapablePerAC / MaxSPLength are behind UAPSD_SUPPORT
  CONFIG_UAPSD=y
  # SCAN_CTRL.Num_Of_Channels / ScanTime / ApSiteSurveyNew_by_wdev (rrm.c)
  CONFIG_OFFCHANNEL_SCAN_FEATURE=y
  # 802.11ax TWT; cmm_info_element.c's parse_twt_ie() is compiled unconditionally
  CONFIG_WIFI_TWT_SUPPORT=y

  # ---- this MUST stay m: obj-$(CONFIG_MT_AP_SUPPORT) needs =m for an external
  #      module build, =y makes it built-in and nothing gets emitted ----
  CONFIG_MT_AP_SUPPORT=m

  # referenced from include/chip/common_cr.h unconditionally, but their
  # definitions in ap_muru.h / he_cfg.h sit behind these Falcon macros --
  # without them common_cr.h cannot compile at all.
  CONFIG_CFG_SUPPORT_FALCON_MURU=y
  CONFIG_CFG_SUPPORT_FALCON_TXCMD_DBG=y

  # ---- string-valued settings ----
  # MUST be y: exports mt_wlan_hook_{register,unregister} from os/linux/
  # rt_txrx_hook.c -- those two are the entry points the Airoha offload
  # adapter (mt_whnat) uses to attach to this driver.
  CONFIG_WLAN_HOOK=y
  CONFIG_RT_FIRST_CARD=7916
  CONFIG_RT_FIRST_IF_RF_OFFSET=0
  CONFIG_FIRST_IF_EEPROM_FLASH=y

  # ---- not available / not wanted on AN7581 ----
  CONFIG_WHNAT_SUPPORT=m
  CONFIG_CFG80211_SUPPORT=n
  CONFIG_CONNINFRA_APSOC=n
  CONFIG_WLAN_SERVICE=n
  CONFIG_ATE_SUPPORT=n
  CONFIG_6G_SUPPORT=n
)

echo "=== build $(date '+%F %T') ===" | tee -a "$LOG"
{
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" \
    M=/tmp/mtsrc/mt_wifi_ap "${CONF[@]}" modules 2>&1
  echo "EXIT=$?"
} | tee -a "$LOG"

echo "--- log: $LOG ---"
