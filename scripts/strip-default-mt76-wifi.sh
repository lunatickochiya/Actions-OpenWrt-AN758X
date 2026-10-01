#!/usr/bin/env bash
# ==================================================================
# 把 mt76 链路的 WiFi 包从 target 的 DEVICE_PACKAGES 里摘掉
#
# 为什么必须做（这一步是 7.6 改 .config 解决不了的）：
#   kmod-mt7915e 写在 an7581 各机型的 DEVICE_PACKAGES 里
#     target/linux/airoha/image/an7581.mk:213  （fiberhome 系）
#     target/linux/airoha/image/an7581.mk:296  （znxt zn515xg-d）
#   buildroot 会据此在 tmp/.config-target.in 里生成
#       select MODULE_DEFAULT_kmod-mt7915e if TARGET_PER_DEVICE_ROOTFS
#   一旦选中某个机型，这个 select 就是**硬强制**的 —— .config 里写
#   "# CONFIG_PACKAGE_kmod-mt7915e is not set" 压不住它。
#
#   实测（ponwrt an7581 + fiberhome_hg5585f-ct）：
#     7.6 之后  : # CONFIG_PACKAGE_kmod-mt7915e is not set
#     defconfig : CONFIG_PACKAGE_kmod-mt7915e=m   ← 回弹
#                 CONFIG_MODULE_DEFAULT_kmod-mt7915e=y
#
#   所以只能跟 4.5 摘 stock NPU 固件一样，从源头改 DEVICE_PACKAGES。
#
# ⚠️ 续行写法同 4.5：DEVICE_PACKAGES 是多行反斜杠续行，
#    只按单行匹配会漏掉续行里的 token，必须跟踪续行状态整段处理。
#
# 用法：
#   PONWRT_DIR=. STRICT=1 ./scripts/strip-default-mt76-wifi.sh
# ==================================================================
set -euo pipefail

PONWRT_DIR="${PONWRT_DIR:-.}"
STRICT="${STRICT:-0}"
cd "$PONWRT_DIR"

# ------------------------------------------------------------------
# 要摘掉的包
#   kmod-mt7915e          —— 与闭源 mt_wifi 抢 PCI 设备 14C3:7906
#   kmod-mt7916-firmware  —— 与 kmod-mt7915e 写在同一行，且它在
#                            tmp/.config-package.in 里有
#                              select PACKAGE_kmod-mt7915e
#                            不一起摘，mt7915e 照样被拉回来。
#                            mt_wifi 自带 MCU 固件（装进 /lib/firmware/），
#                            不依赖这个包，摘了没副作用。
#
#   不摘 wpad-openssl：它只是用户态 WPA，跟无线链路选择无关，留在
#   rootfs 里无害（闭源链路下用不上，但摘了会让机型定义变得难读）。
# ------------------------------------------------------------------
STRIP_RE='kmod-mt7915e|kmod-mt7916-firmware'

# ------------------------------------------------------------------
# 只扫 airoha 这一个 target
#   上游 4.5 的 grep -rl ... target/ 之所以安全，是因为 NPU 固件只有
#   airoha 有。kmod-mt7915e 不一样：mediatek/filogic.mk、econet/en751627.mk
#   里也有一堆，照抄会把无关 target 的机型定义一起改掉。
#   本 CI 只编 AN758x，所以限定 target/linux/airoha/。
# ------------------------------------------------------------------
SCAN_DIRS="${SCAN_DIRS:-target/linux/airoha}"

RC=0
perl -e '
my $STRIP_RE = qr/kmod-mt7915e|kmod-mt7916-firmware/;
my ($modified, $residual) = (0, 0);

for my $f (@ARGV) {
    open(my $fh, "<", $f) or next;
    local $/; my $c = <$fh>; close $fh;
    my @lines = split(/(?<=\n)/, $c);

    my @out; my @removed; my $in = 0; my $changed = 0; my $ln = 0;
    for my $l (@lines) {
        $ln++;
        my $orig = $l;
        if ($l =~ /^[ \t]*(?:DEFAULT_PACKAGES|DEVICE_PACKAGES)[ \t]*[+:?!]?=/) {
            $in = 1;
        }
        if ($in && $l =~ /$STRIP_RE/) {
            my @tok;
            while ($l =~ /($STRIP_RE)/g) { push @tok, $1; }
            $l =~ s/[ \t]*$STRIP_RE\b//g;
            $changed = 1;
            push @removed, [$ln, join(", ", @tok), $orig, $l];
        }
        # 行尾没有续行反斜杠 -> 这一段结束
        $in = 0 if $in && $l !~ /\\\s*\n?$/;
        push @out, $l;
    }

    if ($changed) {
        open(my $w, ">", $f) or die "write $f: $!";
        print $w join("", @out); close $w;
        $modified++;
        print "[MODIFIED] $f\n";
        for my $r (@removed) {
            my ($ln, $tok, $before, $after) = @$r;
            chomp $before; chomp $after;
            print "[REMOVED ] $f:$ln -> $tok\n";
            print "   before| $before\n";
            print "   after | $after\n";
        }
    }

    # 残留复核
    my $n = 0; my $in2 = 0;
    for my $l (@out) {
        $n++;
        $in2 = 1 if $l =~ /^[ \t]*(?:DEFAULT_PACKAGES|DEVICE_PACKAGES)[ \t]*[+:?!]?=/;
        if ($in2 && $l =~ /$STRIP_RE/) {
            chomp $l; print "[RESIDUAL] $f:$n:$l\n"; $residual++;
        }
        $in2 = 0 if $in2 && $l !~ /\\\s*\n?$/;
    }
}

print "[SUMMARY] modified=$modified residual=$residual\n";
exit($residual > 0 ? 3 : 0);
' $(grep -rlE '(DEFAULT_PACKAGES|DEVICE_PACKAGES)' $SCAN_DIRS 2>/dev/null || true) || RC=$?

if [ "$RC" = "3" ]; then
  echo "::error::mt76 WiFi 包仍残留在 DEFAULT_PACKAGES / DEVICE_PACKAGES 里（见 [RESIDUAL] 行）"
  [ "$STRICT" = "1" ] && exit 1
elif [ "$RC" != "0" ]; then
  echo "::warning::摘除脚本退出码 $RC（未匹配到任何 target 文件？）"
fi

# ------------------------------------------------------------------
# 不在这里重建索引 —— 实测踩过坑，别再加回去
#
#   试过 rm -f tmp/.targetinfo tmp/.config-target.in + make prepare-tmpinfo
#   OPENWRT_BUILD=，结果是**把 target 索引搞坏**：
#       tmp/.config-target.in 从 14 MB 掉到 1860 字节（只剩骨架，
#       "default TARGET_mediatek"，一个 TARGET_airoha 都没有），
#     defconfig 于是把 CONFIG_TARGET_SUBTARGET 解析成 "generic"，
#     mt7916-ap 的 depends on TARGET_airoha_an7581 不满足、整包被丢。
#   原因：prepare-tmpinfo 在这个阶段只扫当前已配置的 target，
#   生成的是残缺索引，不能替代 defconfig 自己那一次。
#
#   正确做法是什么都不做：include/scan.mk 第 22 行
#       SCAN_DEPS = image/Makefile profiles/*.mk ... image/*.mk
#   stamp 依赖里就有 image/*.mk，改了 an7581.mk 时间戳一变，
#   defconfig 会自动重扫 target。真正的验收放在 defconfig 之后。
# ------------------------------------------------------------------
echo ""
echo "----- 验收要等 defconfig 之后 -----"
echo "  ⚠️ 别拿「tmp/.config-target.in 里没有 select MODULE_DEFAULT_kmod-mt7915e」"
echo "     当判据 —— 那个文件是**所有 target 机型**的展开（an7581 下实测仍有"
echo "     240 处，来自别的未选中机型），只要当前选中的机型不含它就没事。"
echo "     正确判据是 defconfig 之后 CONFIG_PACKAGE_kmod-mt7915e 不为 =y/=m，"
echo "     由工作流的「Generate toolchain cache key」步骤校验。"
