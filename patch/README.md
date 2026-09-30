# patch/ —— 闭源 WiFi（MT7916 / mt_wifi）所需补丁集

本目录是 `wifi_driver` 选项的输入。CI 上的 `scripts/apply-mtwifi.sh`
会按下面的规则把它们落位，**不需要手工拷任何东西**。

```
patch/
├── kernel-generic/          → 拷进 ponwrt 的 target/linux/generic/hack-6.18/
│   └── 299-add-wext-kconfig-prompts.patch      由内核构建流程自动打
│
├── kernel-an7581/           → 追加到 ponwrt 的 target/linux/airoha/an7581/config-6.18
│   └── wext.conf                               不是 patch，是一段追加的 CONFIG
│
└── mtwifi/                  → 拷进 package/custom/mt7916-ap/patches/
    ├── 010-…118-*.patch                        打开解包后的 mt79xx 源码根（-p1）
    └── series
```

## 三个区域为什么是三种落法

| 区域 | 作用对象 | 由谁打 | 为什么要这样 |
|------|----------|--------|--------------|
| `kernel-generic/` | Linux 内核源码树 `net/wireless/Kconfig` | ponwrt 的 kernel build | 只有放进 `target/linux/generic/hack-6.18/` 才会被内核构建流程施加到；自己 `patch -p1` 打没有针对的对象 |
| `kernel-an7581/` | 目标的内核配置文件 | apply-mtwifi.sh 追加 | `config-6.18` 是 OpenWrt 用 `kconfig.pl` 合并的配置清单，不是普通源码，直接 `git apply` 容易冲突；追加是幂等的 |
| `mtwifi/` | MTK 闭源源码包 | ponwrt 的 `Build/Prepare`（quilt/PatchDir） | 包 Makefile 里已显式指定 `PATCH_DIR`，`PKG_UNPACK` 之后自动按 `series` 顺序打 |

---

## 一、kernel-generic/299-add-wext-kconfig-prompts.patch

**解决的问题：闭源 mt_wifi 加载后完全没法配置。**

mt_wifi 的控制面是 `iwpriv` / `iwconfig`，走 `SIOCIWFIRST..SIOCIWLAST`
这一组 ioctl。它们由 `net/core/dev_ioctl.c` 交给 `wext_ioctl_dispatch()`
分派，而这个函数在 `net/wireless/wext-core.c` 里，编译条件是：

```makefile
# net/wireless/Makefile
obj-$(CONFIG_WEXT_CORE) += wext-core.o
```

```kconfig
config WEXT_CORE
	def_bool y
	depends on CFG80211_WEXT || WIRELESS_EXT
```

所以必须有 `WEXT_CORE=y`。而 upstream 里 `WIRELESS_EXT` 和 `WEXT_PRIV`
都是**没有 prompt 的隐藏 bool**：

```kconfig
config WIRELESS_EXT
	bool
```

把 `CONFIG_WIRELESS_EXT=y` 直接写进 `.config`，`olddefconfig` 会**静默丢掉它**
（无 prompt 的布尔符号，命令行/文件给的值不属于任何可见菜单，Kconfig 不保留）。
这个补丁就是给它们加上 prompt，让值能存活。

### 实测：这个补丁是必需的，不是保险措施

在干净的 v6.18 tree 上跑 `make olddefconfig`，输入都是那四个符号 `=y`：

| 场景 | 输入 | olddefconfig 之后的结果 |
|------|------|--------------------------|
| **A. ponwrt 真实情形**（`CFG80211_WEXT` 未启用），**不打补丁** | `WIRELESS_EXT` `WEXT_CORE` `WEXT_PRIV` `WEXT_PROC` 全写 =y | 只剩 `CONFIG_WIRELESS=y`，**四个全被丢掉**；等于什么都没做 ❌ |
| **B. ponwrt 真实情形，打上本补丁** | 同上 | `CONFIG_WIRELESS_EXT=y` `CONFIG_WEXT_CORE=y` `CONFIG_WEXT_PROC=y` `CONFIG_WEXT_PRIV=y` ✅ |
| **C. 替代路线**：不补补丁，改成开 `CONFIG_CFG80211=m` + `CONFIG_CFG80211_WEXT=y` | 同上 | `WEXT_CORE=y` `WEXT_PROC=y`，但 **`CONFIG_WEXT_PRIV` 拿不到** ❌ |

C 行值得单独讲：走 CFG80211_WEXT 这条路也能让 `wext-core.o` 编出来
（我最早的验证构建就是这么做的，`iwe_stream_add_point` 之类确实能解析），
但 `WEXT_PRIV` 依旧是隐藏符号、依旧设不上 —— 于是私有 ioctl 分发整段被
`#ifdef` 掉。**编译能过不等于运行时能用**：`iwpriv` 会返回 `EOPNOTSUPP`。
所以最终选的是"给符号加 prompt + 直接写 WEXT 四件套"，不走 CFG80211。

`WEXT_CORE` 之所以在 C 里能活下来，是因为它是 `def_bool y` 且依赖是
`CFG80211_WEXT || WIRELESS_EXT` 的或关系；一旦把 `CFG80211_WEXT` 也关掉
（也就是 ponwrt 的默认态），它照样一起丢 —— 这就是 A 行。

顺带一个必要条件：`net/wireless/Kconfig` 整段被 `net/Kconfig` 包在
`if WIRELESS` 里。ponwrt 的 `target/linux/generic/config-6.18` 已经写了
`CONFIG_WIRELESS=y`（第 8232 行），所以这条不需要我们操心 —— 但换到别的
target 时要记得确认。

```c
#ifdef CONFIG_WEXT_PRIV
	/* Try as a private command */
	index = cmd - SIOCIWFIRSTPRIV;
	if (index < handlers->num_private)
		return handlers->private[index];
#endif
```

整条 private ioctl 分发链（以及 `SIOCGIWPRIV`）都在这个 `#ifdef` 里。
没有 `WEXT_PRIV`，`iwpriv` 会一律返回 `EOPNOTSUPP`。

### 与参考树 6.12 补丁的差异（重要）

mediatek 生态里常见的 `299-add-wext-kconfig.patch` 是给 **6.12** 写的，
在 6.18 上**打不上**，因为：

- `WEXT_SPY` 在 6.18 已被移除（6.12 里 `WEXT_PROC` 之后紧跟 `WEXT_SPY`，
  6.18 里直接就是 `WEXT_PRIV`）
- `LIB80211*` 系列在 6.18 也已从 `net/wireless/Kconfig` 移走

本补丁是针对 v6.18.0 重新生成的，只剩两个 hunk（`WIRELESS_EXT`、
`WEXT_PRIV`）。已 `git apply --check` 验证通过。

---

## 二、kernel-an7581/wext.conf

追加到 `target/linux/airoha/an7581/config-6.18` 的 CONFIG 片段：

```
CONFIG_WIRELESS_EXT=y
CONFIG_WEXT_CORE=y
CONFIG_WEXT_PRIV=y
CONFIG_WEXT_PROC=y
```

只改 an7581 subtarget，不影响其他 target。同时**不开 `CFG80211`** ——
mt_wifi 自带 MLME/AP，不用 cfg80211/mac80211，开了反而会跟 `kmod-mt7915e`
那条链路抢资源。

另有一条硬约束：**目标必须保持 `CONFIG_PREEMPT_NONE`**（ponwrt 默认值）。
可抢占内核会让编译器插入 `preempt_schedule_notrace` 调用，那个符号是
`EXPORT_SYMBOL_GPL`，Proprietary 的 `mt_wifi.ko` 过不了 GPL 检查。
append-mtwifi.sh → apply-mtwifi.sh 会检查并在不是 PREEMPT_NONE 时报错。

---

## 三、mtwifi/*.patch

打开 `mt79xx_20250408-705eb4.tar.xz` 解包后的源码根目录，`-p1`。
这一组补丁的作用是把 MTK 源码从它原本适配的 5.4.x/5.10 环境修到 **6.18**
能编过并产出 `.ko`。

| 编号 | 补丁 | 解决什么 |
|------|------|----------|
| 010 | sec_cmm_sae 的 include guard 与 `CONFIG_` 开启条件错位 | 条件编译不一致，SAE 源码整段被跳过或整段重复包含 |
| 020 | `from_timer()` 改名 | 6.18 起叫 `timer_container_of()` |
| 030 | `del_timer()` 改名 | 6.15 起叫 `timer_delete()` |
| 040 | `struct page_frag_cache` 丢了 `va` 成员 | 6.13 起改存 `virt_addr`/`encoded_va` |
| 050 / 060 | 缺 `mt_fmac.h` 包含 | 头文件依赖关系被拆散 |
| 070–076 | 恢复 `rt_config.h` 的 OS 层包含 | OS 层对象编译时没有前置声明，爆出上百个未声明错误 |
| 080–082 | 同上的 `mgmt_txpwr` / andes_core 变体 | 同上 |
| 090 | kbuild 6.1 起删了 `EXTRA_CFLAGS` 兼容层 | `EXTRA_CFLAGS` 不再被转发，必须显式挂到 `ccflags-y`，否则所有 CONFIG_* 定义消失 |
| 100 / 101 | pre-cal 枚举与指示字节在非 flash 模式下也需要 | 它们原先被包在 `#ifdef RTMP_FLASH_SUPPORT` 里，但 BIN 模式同样引用（`RTMP_FLASH_SUPPORT=n` 时编译失败） |
| 110 | `platform_driver::remove` 6.12 起返回 void | mt_whnat 的 probe/remove 类型不匹配 |
| 112 | 5.6 起 `proc_create_data` 要 `proc_ops` | 9 处 file_operations 需要按内核版本分支 |
| 117 | `ra_nat.h` 在 WHNAT 模式下也要包含 | `rt_linux.c` 的 include 条件只写了 `CONFIG_FAST_NAT_SUPPORT` |
| 118 | 新增 `mt_wifi/include/net/ra_nat.h` | FOE 元数据头，Airoha 侧没有独立版本，从 mediatek 树取并补了 `FOE_MAGIC_TAG` / `FOE_AI` 的 `_HEAD` 别名 |

### 编号为什么留空

补丁编号故意留空 `091–099`、`102–109`、`111`、`113–116`：
编号只代表落位顺序，中间空号方便日后在不 renumber 的情况下插新补丁。

---

## 校验方式

本地想自己打一遍（需要已解包的 mt79xx 源码）：

```bash
cd mt79xx-src
export PATCH_DIR=/dev/null          # 不用 quilt 时
for p in $(cat /path/to/patch/mtwifi/series); do
  patch -p1 -f -s -g0 --no-backup-if-mismatch < "/path/to/patch/mtwifi/$p" || exit 1
done
```

每个补丁都做过 `patch -p1 --dry-run --forward` 空跑校验，全部干净通过。
`118` 是新增文件类补丁，GNU patch 会自动创建 `mt_wifi/include/net/` 目录，
已实测。
