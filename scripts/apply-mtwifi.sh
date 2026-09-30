#!/usr/bin/env bash
# ==================================================================
# 导入 MT7916 闭源 WiFi 驱动 (mt_wifi) 到 ponwrt 源码树
#
# 在 ponwrt 源码根目录执行（由 CI 的 step 5.6 调用）。做四件事：
#
#   1. patch/kernel-generic/*.patch
#        -> 拷进 target/linux/generic/hack-6.18/
#        由内核构建流程自己打，作用是给 WIRELESS_EXT / WEXT_PRIV 加 prompt。
#        不加 prompt，这两个符号的选择会被 olddefconfig 静默丢掉。
#
#   2. patch/kernel-an7581/wext.conf
#        -> 幂等追加到 target/linux/airoha/an7581/config-6.18
#        打开 WEXT_CORE / WIRELESS_EXT / WEXT_PRIV / WEXT_PROC。
#        mt_wifi 完全靠 iwpriv 的 private ioctl 下配置。
#
#   3. packages/mt7916-ap
#        -> 拷成 package/custom/mt7916-ap，并把 patch/mtwifi/* 放进它的
#           patches/ 目录。包 Makefile 里 PATCH_DIR 已钉死，
#           Build/Prepare 阶段会按 series 顺序自动打。
#
#   4. 注册 custom feed 并重建索引
#        不做的话 buildroot 不扫这个目录，CONFIG_PACKAGE_kmod-mt7916-ap
#        会被 defconfig 当成无效符号静默删掉 —— 不报错，
#        表现为"步骤都绿了但固件里没有这个包"。
#
# 同时做两项前置校验，失败就尽早退出：
#   - 目标必须是 CONFIG_PREEMPT_NONE（可抢占内核会让 mt_wifi.ko
#     引用 EXPORT_SYMBOL_GPL 的 preempt_schedule_notrace，modpost 拒）
#   - 目标必须是 airoha/an7581（本包 DEPENDS 限定）
#
# 用法（全部走环境变量）：
#   WIFI_DRIVER=mtwifi PONWRT_DIR=. bash scripts/apply-mtwifi.sh
#   WIFI_DRIVER=mtwifi+whnat ./scripts/apply-mtwifi.sh
# ==================================================================
set -euo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
WIFI_DRIVER="${WIFI_DRIVER:-mac80211}"
SOC="${SOC:-an7581}"

cd "$PONWRT_DIR"
echo "=========================================="
echo "闭源 WiFi 驱动导入 (WIFI_DRIVER=$WIFI_DRIVER)"
echo "  源码树: $PWD"
echo "  CI 仓库: $REPO_DIR"
echo "=========================================="

# ---------------------------------------------------------
# 0. 未选择闭源驱动 -> 什么都不做
# ---------------------------------------------------------
case "$WIFI_DRIVER" in
  mtwifi)          WHNAT=n ;;
  mtwifi+whnat)    WHNAT=y ;;
  mac80211)
    echo "WIFI_DRIVER=mac80211，保持上游 mt7915e，跳过导入"
    exit 0
    ;;
  *)
    echo "::error::未知的 WIFI_DRIVER=$WIFI_DRIVER（mac80211 / mtwifi / mtwifi+whnat）"
    exit 1
    ;;
esac

PATCH_DIR="$REPO_DIR/patch"
PKG_SRC="$REPO_DIR/packages/mt7916-ap"
PKG_DST="package/custom/mt7916-ap"

for d in "$PATCH_DIR" "$PKG_SRC"; do
  [ -d "$d" ] || { echo "::error::找不到 $d"; exit 1; }
done

# ---------------------------------------------------------
# 1. 通用内核补丁 -> target/linux/generic/hack-<*>/
#
#    目录按 KERNEL_PATCHVER 选，不是写死的 6.18：源码树可能已经换了内核。
# ---------------------------------------------------------
# 注意是 sed 不是 awk：target/linux/airoha/Makefile 里写的是
#   KERNEL_PATCHVER:=6.18
# 等号两侧没有空格，awk '{print $3}' 取不到东西。
KVER="$(sed -ne 's/^KERNEL_PATCHVER[ \t]*:*[?+]\?=[ \t]*//p' target/linux/airoha/Makefile | head -1)"
KVER="${KVER:-6.18}"
HACK_DIR="target/linux/generic/hack-$KVER"
mkdir -p "$HACK_DIR"
echo ">>> 内核通用补丁目录: $HACK_DIR (KERNEL_PATCHVER=$KVER)"

n=0
for p in "$PATCH_DIR"/kernel-generic/*.patch; do
  [ -f "$p" ] || continue
  cp -f "$p" "$HACK_DIR/"
  echo "    ✅ $(basename "$p")"
  n=$((n + 1))
done
[ "$n" -gt 0 ] || { echo "::error::$PATCH_DIR/kernel-generic/ 下没有补丁"; exit 1; }

# ---------------------------------------------------------
# 2. 目标内核配置：开 WEXT
#
#    config-6.18 是 kconfig.pl 合并用的清单，顺序无所谓，但也正因如此
#    用 git apply 打 patch 很容易跟上游改动撞上下文。这里直接按行幂等追加。
# ---------------------------------------------------------
TARGET_CFG="target/linux/airoha/${SOC}/config-${KVER}"
[ -f "$TARGET_CFG" ] || { echo "::error::找不到 $TARGET_CFG"; exit 1; }

cp -f "$TARGET_CFG" "/tmp/$(basename "$TARGET_CFG").orig"
while IFS= read -r line; do
  case "$line" in
    ''|'#'*) continue ;;
  esac
  key="${line%%=*}"
  if grep -qx "$line" "$TARGET_CFG"; then
    echo "    = 已存在: $line"
    continue
  elif grep -qE "^(# )?${key}(=.*| is not set)" "$TARGET_CFG"; then
    sed -i "s|^# ${key} is not set|${line}|; s|^${key}=.*|${line}|" "$TARGET_CFG"
    echo "    ✏️  已改写: $line"
  else
    echo "$line" >> "$TARGET_CFG"
    echo "    ➕ 已追加: $line"
  fi
done < "$PATCH_DIR/kernel-an7581/wext.conf"

# ---------------------------------------------------------
# 3. 前置校验：抢占模型
#
#    这是唯一会导致 modpost 硬失败的配置项。
#    ponwrt 默认就是 PREEMPT_NONE，所以这里基本是防未来的改动。
# ---------------------------------------------------------
if grep -q "^CONFIG_PREEMPT=y" "$TARGET_CFG"; then
  echo "::error::$TARGET_CFG 里是 CONFIG_PREEMPT=y"
  echo "   mt_wifi.ko 是 Proprietary 模块，可抢占内核会让它引用"
  echo "   EXPORT_SYMBOL_GPL 的 preempt_schedule_notrace，modpost 会拒："
  echo "   \"GPL-incompatible module mt_wifi.ko uses GPL-only symbol\""
  echo "   请把目标改回 CONFIG_PREEMPT_NONE。"
  exit 1
fi
echo "✅ 抢占模型校验通过（非 PREEMPT）"

# ---------------------------------------------------------
# 4. 拷贝软件包 + 驱动补丁
# ---------------------------------------------------------
rm -rf "$PKG_DST"
mkdir -p "$PKG_DST"
cp -r "$PKG_SRC"/. "$PKG_DST/"
echo "✅ 已安装软件包: $PKG_DST"

mkdir -p "$PKG_DST/patches"
m=0
for p in "$PATCH_DIR"/mtwifi/*.patch; do
  [ -f "$p" ] || continue
  cp -f "$p" "$PKG_DST/patches/"
  m=$((m + 1))
done
cp -f "$PATCH_DIR/mtwifi/series" "$PKG_DST/patches/series"
echo "✅ 已安装驱动补丁: $m 个 -> $PKG_DST/patches"
[ "$m" -gt 0 ] || { echo "::error::$PATCH_DIR/mtwifi/ 下没有补丁"; exit 1; }

# 卸载适配层开关：mtwifi+whnat 时打开，由 step 7.6 把
# CONFIG_MT7916_AP_OFFLOAD=y 写进 .config（这里还没生成 .config）。
if [ "$WHNAT" = "y" ]; then
  echo "✅ mt_whnat 卸载适配层: 开（step 7.6 会写 CONFIG_MT7916_AP_OFFLOAD=y）"
else
  echo "✅ mt_whnat 卸载适配层: 关（走慢路径；想开请用 mtwifi+whnat）"
fi

# ---------------------------------------------------------
# 5. 注册 custom feed 并重建索引
#
#    跟 diy-part1.sh 里是一样的逻辑，这里必须再跑一遍 —— diy-part1
#    在这之前就结束了，而 indices 里还没有 mt7916-ap。
# ---------------------------------------------------------
if ! grep -qE '^src-link[[:space:]]+custom' feeds.conf.default; then
  echo "src-link custom $PWD/package/custom" >> feeds.conf.default
  echo "✅ 已注册 feed: src-link custom"
else
  echo "feed 已注册: $(grep -E '^src-link[[:space:]]+custom' feeds.conf.default)"
fi

rm -f tmp/.packageinfo tmp/.targetinfo 2>/dev/null || true
./scripts/feeds update custom 2>&1 | tail -3
./scripts/feeds install -a >/dev/null 2>&1 || true

echo "------------------------------------------"
# 判据优先用 tmp/.packageinfo —— 这才是 defconfig 真正读的东西。
# package/feeds/custom/mt7916-ap 这个链接不保证存在：src-link custom 指向的
# 就是 package/custom，而 prepare-tmpinfo 直接扫 package/（find -L
# -maxdepth 5），两条路都会命中；feeds install 若认为包已 installed 会跳过
# 建链接。所以链接缺失不等于失败，但 .packageinfo 里没有就一定是失败。
if grep -qx "Package: kmod-mt7916-ap" tmp/.packageinfo 2>/dev/null; then
  echo "✅ 已进索引: tmp/.packageinfo 里有 Package: kmod-mt7916-ap"
  grep -A3 "^Package: kmod-mt7916-ap$" tmp/.packageinfo | head -4
elif [ -e "package/feeds/custom/mt7916-ap" ]; then
  echo "✅ 已建链接: package/feeds/custom/mt7916-ap"
  echo "   ⚠️ 但 tmp/.packageinfo 里没查到，请确认 prepare-tmpinfo 已跑"
else
  echo "::error::kmod-mt7916-ap 未进索引，defconfig 会把 .config 里的 =y 静默剔除"
  echo "  1) 包目录:            $([ -d "$PKG_DST" ] && echo '存在' || echo '不存在')"
  echo "  2) Makefile:          $([ -f "$PKG_DST/Makefile" ] && echo '存在' || echo '缺失')"
  echo "  3) .packageinfo:      $(grep -c '^Package: kmod-mt7916-ap$' tmp/.packageinfo 2>/dev/null || echo 0) 条"
  echo "  4) feeds.conf custom: $(grep -cE '^src-link[[:space:]]+custom' feeds.conf.default 2>/dev/null || echo 0) 条"
  echo "  5) 手工复现: make -C package/custom/mt7916-ap DUMP=1"
  for f in logs/package/custom/mt7916-ap/dump.txt logs/feeds/custom/*/*/dump.txt; do
    [ -f "$f" ] && { echo "===== $f ====="; tail -25 "$f"; }
  done 2>/dev/null
  exit 1
fi
echo "=========================================="
