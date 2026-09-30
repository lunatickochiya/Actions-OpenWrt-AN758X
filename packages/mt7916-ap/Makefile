#
# kmod-mt7916-ap -- MT7916 闭源 AP 驱动 (mt_wifi)，在 ponwrt 里从源码编译
#
# 为什么必须源码编译：
#   vendor mt7916d_ap.ko   vermagic=5.4.55 SMP mod_unload aarch64
#   ponwrt an7581 内核     linux 6.18
#   -> vermagic 不匹配会被模块加载器直接拒；即便绕过去，这个二进制还依赖
#      Linux 早已删掉的一批符号 (netif_rx_ni / __dev_kfree_skb_any /
#      del_timer_sync / from_timer ...)。唯一的出路是重编。
#
# 本包产出最多三个 ko：
#   airoha_mt7916_offload.ko   [Dual BSD/GPL] Airoha 侧转发端点
#   mt_wifi.ko                 [Proprietary] 自带 MLME/AP，不走 cfg80211
#   mt_whnat.ko                [Dual BSD/GPL] WIFI-to-Eth 卸载适配（可选）
#
# 三者放在一起而不是拆成多个 KernelPackage，是因为 mt_whnat 需要前两者的
# Module.symvers 才能 modpost，而 OpenWrt 不保证 kmod 包之间的编译顺序。
# 同一个包内的多条 $(MAKE) 是按 Makefile 书写顺序串行的，这一点有保证。
#
# 目标内核必须先开 WEXT，否则驱动能加载但没法配置（详见
# patch/kernel-an7581/wext.conf）：
#     CONFIG_WIRELESS_EXT=y CONFIG_WEXT_CORE=y
#     CONFIG_WEXT_PRIV=y    CONFIG_WEXT_PROC=y
# 并且必须保持 CONFIG_PREEMPT_NONE。
#

include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

PKG_NAME:=mt7916-ap
PKG_VERSION:=7.6.7.3
PKG_RELEASE:=1
PKG_LICENSE:=Proprietary
PKG_LICENSE_FILES:=

# 源码包：18 MB。20250408-705eb4 == 7.6.7.3，hash 来自上游 Makefile 验证。
MTK_DRIVER_VERSION ?= 20250408-705eb4
PKG_SOURCE:=mt79xx_$(MTK_DRIVER_VERSION).tar.xz
PKG_SOURCE_URL:=https://raw.githubusercontent.com/hanwckf/immortalwrt-mt798x/refs/heads/openwrt-21.02/dl
PKG_HASH:=b029d7b43c498193092dc6a3c857361c8835ce34bb306561c550ac0539784a78

PKG_BUILD_DIR:=$(KERNEL_BUILD_DIR)/$(PKG_NAME)-source

# 补丁目录必须在这里显式钉死。
#
# 不能依赖 kernel.mk 那句
#     PATCH_DIR ?= $(CURDIR)/patches$(if $(wildcard ./patches-$(KERNEL_PATCHVER)),-$(KERNEL_PATCHVER))
# 因为 package-defaults.mk 里是
#     Build/Patch:=$(Build/Patch/Default)
# —— 立即展开，PATCH_DIR 的值在 include package.mk 那一刻就被固化了。
# 放在 include 之后再写就太晚。
#
# apply-mtwifi.sh 会把 patch/mtwifi/* 拷到这里的 patches/。
PATCH_DIR:=$(CURDIR)/patches

include $(INCLUDE_DIR)/package.mk

# =========================================================
# 编译选项集
#
# 这一整块不是可以慢慢挑的：它取自驱动自身 Kconfig 的 default-y 闭包，
# 外加这一版源码真正需要、但 Kconfig 默认关着的那几项。
# files/reference-build-config.sh 里是跑通过的那条命令。
#
# 其中三项写错会产生看起来完全无关的失败：
#   CONFIG_MT_AP_SUPPORT=m  必须 m。=y 会把对象塞进 obj-y，
#                           外部 M= 构建会静默地一个 .ko 都不产出。
#   CONFIG_WLAN_HOOK=y      必须 y。不开就导出不了
#                           mt_wlan_hook_{register,unregister}，
#                           mt_whnat 无法挂载。
#   CONFIG_RTMP_FLASH_SUPPORT=n  必须 n。它会拉进 ee_flash.c，
#                           后者引用 MTK 私有的
#                           mt_eeprom_{read,write}_wifi()，
#                           AN7581 上没有任何模块导出这两个符号。
#                           用文件 EEPROM (E2P_BIN_MODE) 代替。
# =========================================================
WIFI_CONF := \
	CONFIG_SUPPORT_OPENWRT=y \
	CONFIG_WIFI_DRIVER=y \
	CONFIG_PROPRIETARY_DRIVER=y \
	CONFIG_CHIP_MT7916=y \
	CONFIG_FIRST_IF_MT7916=y \
	CONFIG_SECOND_IF_NONE=y \
	CONFIG_THIRD_IF_NONE=y \
	CONFIG_7916_USE_PCI=y \
	CONFIG_MT_MAC=y CONFIG_RTMP_MAC=y CONFIG_RTMP_MAC_PCI=y \
	CONFIG_DOT11_N_SUPPORT=y CONFIG_DOT11_VHT_AC=y CONFIG_DOT11_HE_AX=y \
	CONFIG_RATE_ADAPTION=y CONFIG_RATE_ADAPT_AGBS_SUPPORT=y \
	CONFIG_HDR_TRANS_TX_SUPPORT=y CONFIG_HDR_TRANS_RX_SUPPORT=y \
	CONFIG_MT_DFS_SUPPORT=y CONFIG_BACKGROUND_SCAN_SUPPORT=y \
	CONFIG_TXBF_SUPPORT=y CONFIG_SINGLE_SKU=y CONFIG_TPC_SUPPORT=y \
	CONFIG_SPECTRUM_SUPPORT=y CONFIG_ICAP_SUPPORT=y \
	CONFIG_SMART_CARRIER_SENSE_SUPPORT=y CONFIG_MUMIMO_SUPPORT=y \
	CONFIG_MU_RA_SUPPORT=y CONFIG_GREENAP_SUPPORT=y \
	CONFIG_BAND_STEERING=y CONFIG_DYNAMIC_WMM_SUPPORT=y \
	CONFIG_IGMP_SNOOP_SUPPORT=y CONFIG_MCAST_RATE_SPECIFIC=y \
	CONFIG_VOW_SUPPORT=y \
	CONFIG_MBSS_SUPPORT=y CONFIG_WDS_SUPPORT=y CONFIG_APCLI_SUPPORT=y \
	CONFIG_RTMP_FLASH_SUPPORT=n CONFIG_CAL_BIN_FILE_SUPPORT=y \
	CONFIG_PCIE_ASPM_DYM_CTRL_SUPPORT=y CONFIG_WIFI_GPIO_CTRL=y \
	CONFIG_G_BAND_256QAM_SUPPORT=y \
	CONFIG_WIRELESS_EXT=y CONFIG_WEXT_PRIV=y CONFIG_WEXT_SPY=y \
	CONFIG_WIFI_EAP_FEATURE=y CONFIG_WIFI_DBG_TXCMD=y \
	CONFIG_WIFI_SYSTEM_DVT=y \
	CONFIG_MGMT_TXPWR_CTRL=y \
	CONFIG_DOT11R_FT_SUPPORT=y \
	CONFIG_WPA3_SUPPORT=y CONFIG_DOT11W_PMF_SUPPORT=y \
	CONFIG_DOT11K_RRM_SUPPORT=y CONFIG_WSC_INCLUDED=y \
	CONFIG_UAPSD=y CONFIG_OFFCHANNEL_SCAN_FEATURE=y \
	CONFIG_WIFI_TWT_SUPPORT=y \
	CONFIG_MT_AP_SUPPORT=m \
	CONFIG_CFG_SUPPORT_FALCON_MURU=y \
	CONFIG_CFG_SUPPORT_FALCON_TXCMD_DBG=y \
	CONFIG_WLAN_HOOK=y \
	CONFIG_RT_FIRST_CARD=7916 \
	CONFIG_RT_FIRST_IF_RF_OFFSET=0 \
	CONFIG_FIRST_IF_EEPROM_FLASH=y \
	CONFIG_WHNAT_SUPPORT=$(if $(CONFIG_MT7916_AP_OFFLOAD),m,n) \
	CONFIG_CFG80211_SUPPORT=n \
	CONFIG_CONNINFRA_APSOC=n CONFIG_WLAN_SERVICE=n \
	CONFIG_ATE_SUPPORT=n CONFIG_6G_SUPPORT=n

# +wireless-tools 是硬依赖，不是锦上添花：闭源 mt_wifi 只有
# iwpriv / iwconfig 这两个用户态入口，没有它们就算 ko 加载成功、
# 网卡起来了，也配不了 SSID / 加密方式。
define KernelPackage/mt7916-ap
  SUBMENU:=Wireless Drivers
  TITLE:=MT7916 closed-source AP driver (mt_wifi, built from source)
  DEPENDS:=@TARGET_airoha_an7581 +wireless-tools
  FILES:=$(PKG_BUILD_DIR)/offload/airoha_mt7916_offload.ko \
	$(PKG_BUILD_DIR)/mt_wifi_ap/mt_wifi.ko \
	$(if $(CONFIG_MT7916_AP_OFFLOAD),$(PKG_BUILD_DIR)/mt_wifi/embedded/plug_in/whnat/mt_whnat.ko)
  AUTOLOAD:=$(call AutoProbe,airoha_mt7916_offload mt_wifi $(if $(CONFIG_MT7916_AP_OFFLOAD),mt_whnat))
endef

define KernelPackage/mt7916-ap/config
	source "$(SOURCE)/Config.in"
endef

define KernelPackage/mt7916-ap/description
  MediaTek MT7916 (PCI 14C3:7906) 闭源 AP 驱动，针对 ponwrt an7581 的
  kernel 6.18 从 mt_wifi 源码包编译。

  驱动自带 MLME/AP 协议栈，不使用 cfg80211 / mac80211，也没有 phy 设备，
  iw 和 hostapd 都管不到它。配置全走 iwpriv / iwconfig 的 WEXT ioctl，
  netifd 这边由本包提供的 mtwifi.sh 代替标准 mac80211.sh。

  【目标内核 config 的前置要求】
  驱动的控制面依赖 WEXT。那些 ioctl 在 net/core/dev_ioctl.c 里被交给
  wext_ioctl_dispatch()，而该函数只存在于 net/wireless/wext-core.c，
  编译条件是 CONFIG_WEXT_CORE。必须在
  target/linux/airoha/an7581/config-6.18 里开这四个：

      CONFIG_WIRELESS_EXT=y
      CONFIG_WEXT_CORE=y
      CONFIG_WEXT_PRIV=y
      CONFIG_WEXT_PROC=y

  而 WIRELESS_EXT / WEXT_PRIV 在 upstream 里是无 prompt 的隐藏 bool，
  直接写进 .config 会被 olddefconfig 静默丢掉，所以还需要
  patch/kernel-generic/299-add-wext-kconfig-prompts.patch 给它们加 prompt。

  同时必须保持 CONFIG_PREEMPT_NONE（ponwrt 默认）。可抢占内核会生成
  preempt_schedule_notrace 调用，该符号是 EXPORT_SYMBOL_GPL，
  Proprietary 的 mt_wifi.ko 会卡在 modpost 的 GPL 检查上。

  【EEPROM】
  未指定 profile 时 MT7916 走 mt7916_get_default_bin_image_file() 的默认
  路径 /lib/firmware/e2p（源码确认：chips/mt7916.c:3816）。本包不塞
  EEPROM —— 那是每块板子各自的校准数据，见 /etc/mt7916/README.
endef

# Build/Prepare 不重写，用 package-defaults.mk 的默认实现，它按
#   解源码包 -> 拷 ./src/ -> $(Build/Patch) 打 patches/
# 的顺序执行。PATCH_DIR 已在上面钉死，所以这 23 个补丁会在这里落上去。
#
# ./src/offload 会被拷成 $(PKG_BUILD_DIR)/offload。

# mt_whnat 需要前两步产出的 Module.symvers 才能 modpost 通过，所以三条
# build 的书写顺序就是编译顺序，不能调换。
MTK_WIFI_BUILD := +$(MAKE) $(PKG_JOBS) -C "$(LINUX_DIR)" $(KERNEL_MAKE_FLAGS) \
	M="$(PKG_BUILD_DIR)/mt_wifi_ap" $(WIFI_CONF) modules

MTK_WHNAT_BUILD := +$(MAKE) $(PKG_JOBS) -C "$(LINUX_DIR)" $(KERNEL_MAKE_FLAGS) \
	M="$(PKG_BUILD_DIR)/mt_wifi/embedded/plug_in/whnat" $(WIFI_CONF) \
	KBUILD_EXTRA_SYMBOLS="$(PKG_BUILD_DIR)/offload/Module.symvers $(PKG_BUILD_DIR)/mt_wifi_ap/Module.symvers" \
	modules

define Build/Compile
	# 1) Airoha 侧端点。它导出 ra_sw_nat_hook_tx，mt_whnat 要引用。
	+$(MAKE) $(PKG_JOBS) -C "$(LINUX_DIR)" $(KERNEL_MAKE_FLAGS) \
		M="$(PKG_BUILD_DIR)/offload" CONFIG_AIROHA_MT7916_OFFLOAD=m modules

	# 2) mt_wifi 本体
	$(MTK_WIFI_BUILD)

	# 3) 卸载适配层（可选）
	$(if $(CONFIG_MT7916_AP_OFFLOAD),$(MTK_WHNAT_BUILD))
endef

define KernelPackage/mt7916-ap/install
	# MCU 固件。这三个文件名是从源码里核对过的，不是猜的：
	#   include/chip/mt7916.h:
	#     MT7916_BIN_FILE_NAME_E1         "WIFI_RAM_CODE_MT7916.bin"
	#     MT7916_ROM_PATCH_BIN_FILE_NAME_E1 "mt7916_patch_e1_hdr.bin"
	#     MT7916_WA_BIN_FILE_NAME         "7916_WACPU_RAM_CODE_release.bin"
	#   os/linux/rt_linux.c:3021 OS_LOAD_CODE_FROM_BIN() -> request_firmware()
	# 所以必须落在 /lib/firmware/ 根，而不是某个子目录。
	$(INSTALL_DIR) $(1)/lib/firmware
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/bin/mt7916/rebb/WIFI_RAM_CODE_MT7916.bin \
		$(1)/lib/firmware/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/bin/mt7916/rebb/mt7916_patch_e1_hdr.bin \
		$(1)/lib/firmware/
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/bin/mt7916/rebb/7916_WACPU_RAM_CODE_release.bin \
		$(1)/lib/firmware/

	# EEPROM 参考模板。每块板子的实际校准数据不同，这里只给模板，
	# 由管理员挑一个放到 /lib/firmware/e2p（驱动默认路径）。
	$(INSTALL_DIR) $(1)/etc/mt7916/eeprom-templates
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/bin/mt7916/rebb/MT7916_*_EEPROM.bin \
		$(1)/etc/mt7916/eeprom-templates/
	$(INSTALL_DATA) ./files/etc/mt7916/README \
		$(1)/etc/mt7916/README

	# 模块的加载顺序交给 KernelPackage 的 AUTOLOAD
	# (airoha_mt7916_offload -> mt_wifi -> [mt_whnat])，
	# 这里不再额外丢一份 /etc/modules.d，免得重复 insmod。

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/mt7916-ap.init $(1)/etc/init.d/mt7916-ap

	$(INSTALL_DIR) $(1)/etc/hotplug.d/net
	$(INSTALL_BIN) ./files/etc/hotplug.d/net/10-mtwifi-detect \
		$(1)/etc/hotplug.d/net/

	$(INSTALL_DIR) $(1)/lib/netifd/wireless
	$(INSTALL_BIN) ./files/lib/netifd/wireless/mtwifi.sh \
		$(1)/lib/netifd/wireless/
endef

$(eval $(call KernelPackage,mt7916-ap))
