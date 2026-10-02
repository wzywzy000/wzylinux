#!/usr/bin/env bash
# ============================================================
# WZY Linux ISO 构建脚本
# 运行环境：Ubuntu WSL（需 root）
# 产物：wzylinux-x86_64.iso  —— amd64，兼容老款 Intel 酷睿
#
# 用法：
#   sudo ./build.sh
# 构建完会在 ./out/ 下生成 ISO，并打印 sha256。
# ============================================================
set -euo pipefail

# 1) 确保在 root 下运行
if [ "$(id -u)" -ne 0 ]; then
  echo "[WZY] 需要 root，尝试 sudo 重新执行…"
  exec sudo "$0" "$@"
fi

# 0.5) 修正系统时钟漂移：WSL/虚拟机休眠后时钟可能落后数小时，
#      导致 apt 认为仓库 Release 文件"尚未生效"而拒绝更新。从镜像站 HTTP 头取权威时间校准。
fix_clock() {
  local _h _now _set
  for _h in https://mirrors.huaweicloud.com/ubuntu/ https://archive.ubuntu.com/ubuntu/ https://www.google.com/; do
    _now=$(timeout 8 curl -fsI "$_h" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="date"{print $2; exit}')
    [ -n "$_now" ] && break
  done
  if [ -n "$_now" ]; then
    _set=$(date -d "$_now" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [ -n "$_set" ]; then
      date -s "$_set" >/dev/null 2>&1 && echo "[WZY] 已校准系统时钟 -> $_set" || true
    fi
  else
    echo "[WZY] 警告：无法获取网络时间，若 apt 报 Release 未生效请先校正本机时钟"
  fi
}
fix_clock

# 2) 载入配置
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

CHROOT="${SCRIPT_DIR}/chroot"
ISO_ROOT="${SCRIPT_DIR}/iso"
WORK="${SCRIPT_DIR}/work"

echo "[WZY] 配置：DISTRO=${DISTRO} ARCH=${ARCH} -> ${ISO_NAME}"

# 3) 安装构建依赖
echo "[WZY] 安装构建依赖…"
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Check-Valid-Until=false update -y
apt-get -o Acquire::Check-Valid-Until=false install -y --no-install-recommends \
  debootstrap \
  squashfs-tools \
  grub-pc-bin \
  grub-efi-amd64-bin \
  grub-common \
  xorriso \
  mtools \
  ca-certificates \
  gdisk

# 4) 准备目录（cache 不删除，跨次构建复用已下载的包）
CACHE_DIR="${SCRIPT_DIR}/cache"
mkdir -p "${CACHE_DIR}/debootstrap" "${CACHE_DIR}/apt/archives" "${CACHE_DIR}/apt/lists"
rm -rf "${CHROOT}" "${ISO_ROOT}" "${WORK}" "${OUT_DIR}"
mkdir -p "${CHROOT}" "${ISO_ROOT}" "${WORK}" "${OUT_DIR}"

# 5) debootstrap 拉取最小根文件系统（--cache-dir 复用已下载的基础包）

# 5.1) 发行版切换检测：旧的 .deb 缓存带旧版本号，不会被误用，但会一直占空间。
#      这里只提示、不自动删除（避免误删后想回退旧版本时又要重下）。
if [ -f "${CACHE_DIR}/.distro" ] && [ "$(cat "${CACHE_DIR}/.distro")" != "${DISTRO}" ]; then
  echo "[WZY] 注意：cache/ 里是 $(cat "${CACHE_DIR}/.distro") 的包，本次 ${DISTRO} 不会命中，将重新下载。"
  echo "[WZY]      确认不再需要旧缓存可手动清理： rm -rf ${CACHE_DIR}/debootstrap ${CACHE_DIR}/apt"
fi
echo "${DISTRO}" > "${CACHE_DIR}/.distro"

# 5.2) debootstrap 脚本兜底：构建主机的 debootstrap 若比目标发行版旧，
#      会没有对应 suite 的脚本（报 no script for ...）。软链一个已有版本顶上。
if [ ! -f "/usr/share/debootstrap/scripts/${DISTRO}" ]; then
  echo "[WZY] 构建主机 debootstrap 缺少 ${DISTRO} 脚本，尝试兜底…"
  _db_base=""
  for _s in questing plucky noble jammy; do
    if [ -f "/usr/share/debootstrap/scripts/${_s}" ]; then _db_base="${_s}"; break; fi
  done
  if [ -n "${_db_base}" ]; then
    ln -sf "/usr/share/debootstrap/scripts/${_db_base}" "/usr/share/debootstrap/scripts/${DISTRO}"
    echo "[WZY] 已把 ${DISTRO} 脚本软链到 ${_db_base}"
  else
    echo "[WZY] 警告：找不到可复用的 debootstrap 脚本，debootstrap 可能失败"
  fi
fi

# debootstrap 偶发下载失败：镜像同步竞态或网络抖动，包其实在（历史上踩过 perl-base、
# libcap-ng0，这次是 dhcpcd-base）。单次抖动不该让整个构建挂掉，所以重试 3 次。
# 每次重试前清空 chroot（debootstrap 不能往非空目录里装），但 cache/ 保留，
# 已下好的包会命中缓存，重试只会补下缺的那几个。
# ---- WSL1 兼容替身 ----
# 26.04 的 systemd 259 在 WSL1 上装不起来，卡在两个 maintainer 脚本步骤：
#   1) systemd-machine-id-setup 打开 /etc/machine-id 返回 ENOSYS
#   2) systemd-sysusers 锁 /etc/passwd 返回 EINVAL（WSL1 不支持 OFD 文件锁）
# 注意 flock 和 useradd 都实测可用，所以受影响的只有 systemd 自己的这两个工具，
# 用户/组数据本身不会丢 —— 还原后我们用 useradd/groupadd 补建即可。
# 真机跑的是完整内核，这两步本来就正常，所以这只是构建期的权宜之计。
# 必须用 dpkg-divert，不能直接覆盖文件：systemd 是在 debootstrap 第二阶段
# 才解包的，直接覆盖的话替身会被随后的解包瞬间还原成真身（第一版就这么失败的）。
# divert 会注册一条持久规则——之后任何解包该路径的包都改写到 xxx.distrib，
# 替身因此能一直活到桌面包装完。
WZY_DIVERT_BINS="systemd-machine-id-setup systemd-sysusers"
wzy_stub_in() {
  local b
  for b in ${WZY_DIVERT_BINS}; do
    # 无条件注册：即使此刻文件还没解包出来，规则也已生效，后面解包照样被 divert。
    chroot "${CHROOT}" dpkg-divert --local --rename --add "/usr/bin/${b}" >/dev/null 2>&1
    printf '#!/bin/sh\nexit 0\n' > "${CHROOT}/usr/bin/${b}"
    chmod 0755 "${CHROOT}/usr/bin/${b}"
  done
  return 0
}
wzy_stub_out() {
  local b
  for b in ${WZY_DIVERT_BINS}; do
    # 有 .distrib 才说明 divert 真的建了，避免误删真身
    if [ -f "${CHROOT}/usr/bin/${b}.distrib" ]; then
      rm -f "${CHROOT}/usr/bin/${b}"
      chroot "${CHROOT}" dpkg-divert --local --rename --remove "/usr/bin/${b}" >/dev/null 2>&1
    fi
    if [ -s "${CHROOT}/usr/bin/${b}" ]; then
      echo "[WZY]   已还原 ${b} ($(stat -c %s "${CHROOT}/usr/bin/${b}") 字节)"
    else
      echo "[WZY]   警告：${b} 未还原成功"
    fi
  done
  return 0
}

DB_OK=""
for db_attempt in 1 2 3; do
  echo "[WZY] debootstrap ${DISTRO} (${ARCH}) … 第 ${db_attempt} 次尝试（第一阶段只解包）"
  if debootstrap --foreign --arch="${ARCH}" --components=main,universe \
       --cache-dir="${CACHE_DIR}/debootstrap" "${DISTRO}" "${CHROOT}" "${MIRROR}"; then
    DB_OK="1"
    break
  fi
  echo "[WZY] debootstrap 第 ${db_attempt} 次失败，清理 chroot 后重试…"
  # 抢救内部日志：chroot 一删 debootstrap.log 就没了，而真实原因只写在那里。
  cp "${CHROOT}/debootstrap/debootstrap.log" \
     "${SCRIPT_DIR}/debootstrap-failed-${db_attempt}.log" 2>/dev/null || true
  rm -rf "${CHROOT}"
  mkdir -p "${CHROOT}"
  sleep 10
done
if [ -z "${DB_OK}" ]; then
  echo "[WZY] debootstrap 连续 3 次失败，终止构建。可尝试：换 MIRROR（config.sh）或稍后重跑。"
  exit 1
fi

# 第二阶段前：挂好 proc/sys/dev，预置 machine-id，放上替身
echo "[WZY] debootstrap 第二阶段（配置包）…"
mkdir -p "${CHROOT}/proc" "${CHROOT}/sys" "${CHROOT}/dev" "${CHROOT}/dev/pts"
mount --bind /proc      "${CHROOT}/proc"
mount --bind /sys       "${CHROOT}/sys"
mount --bind /dev       "${CHROOT}/dev"
mount --bind /dev/pts   "${CHROOT}/dev/pts" 2>/dev/null || true

mkdir -p "${CHROOT}/etc"
if [ ! -s "${CHROOT}/etc/machine-id" ]; then
  cat /proc/sys/kernel/random/uuid | tr -d -- '-' > "${CHROOT}/etc/machine-id"
fi
wzy_stub_in

chroot "${CHROOT}" /debootstrap/debootstrap --second-stage

# 卸掉第二阶段临时挂载，后面第 7 步会重新挂（保持原有流程不变）
umount -lf "${CHROOT}/dev/pts" 2>/dev/null || true
umount -lf "${CHROOT}/dev"     2>/dev/null || true
umount -lf "${CHROOT}/sys"     2>/dev/null || true
umount -lf "${CHROOT}/proc"    2>/dev/null || true

# 6) 准备 chroot 内环境（网络解析）
cp /etc/resolv.conf "${CHROOT}/etc/resolv.conf"

# 7) 在 chroot 内安装系统包
fix_clock  # 校准时钟（见顶部定义），确保 chroot 内 apt 更新不被"Release 未生效"拦截
echo "[WZY] chroot 内安装内核与 live 组件…"
mount --bind /proc  "${CHROOT}/proc"
mount --bind /sys   "${CHROOT}/sys"
mount --bind /dev   "${CHROOT}/dev"
mount --bind /dev/pts "${CHROOT}/dev/pts" 2>/dev/null || true
# 持久化 apt 缓存：下载的 .deb 与索引跨次复用，避免重复下载
mkdir -p "${CHROOT}/var/cache/apt/archives" "${CHROOT}/var/lib/apt/lists"
mount --bind "${CACHE_DIR}/apt/archives" "${CHROOT}/var/cache/apt/archives"
mount --bind "${CACHE_DIR}/apt/lists"    "${CHROOT}/var/lib/apt/lists"

cleanup_mounts() {
  umount -lf "${CHROOT}/var/lib/apt/lists"    2>/dev/null || true
  umount -lf "${CHROOT}/var/cache/apt/archives" 2>/dev/null || true
  umount -lf "${CHROOT}/dev/pts" 2>/dev/null || true
  umount -lf "${CHROOT}/dev"     2>/dev/null || true
  umount -lf "${CHROOT}/sys"     2>/dev/null || true
  umount -lf "${CHROOT}/proc"    2>/dev/null || true
}
trap cleanup_mounts EXIT

cat > "${CHROOT}/etc/apt/sources.list" <<EOF
deb ${MIRROR} ${DISTRO} main universe
deb ${MIRROR} ${DISTRO}-updates main universe
deb ${MIRROR} ${DISTRO}-security main universe
EOF

# 7.1) 阻止 chroot 内 postinst 拉起服务（gdm3 / snapd / network-manager 等），
#      否则在容器里起服务会卡死或直接失败。装完立刻移除，不会进最终系统。
printf '#!/bin/sh\nexit 101\n' > "${CHROOT}/usr/sbin/policy-rc.d"
chmod 0755 "${CHROOT}/usr/sbin/policy-rc.d"

# 7.2) 桌面元包选择。ubuntu-desktop 本体几乎不带 Depends，
#      真正的 LibreOffice / Thunderbird / GIMP 全在 Recommends 里，
#      所以要完整桌面就必须放开 Recommends，不能用 --no-install-recommends。
case "${DESKTOP_FLAVOR}" in
  full)    DESKTOP_PKG="ubuntu-desktop"         ; APT_REC_FLAG=""                      ;;
  minimal) DESKTOP_PKG="ubuntu-desktop-minimal" ; APT_REC_FLAG="--no-install-recommends" ;;
  *) echo "[WZY] 未知 DESKTOP_FLAVOR=${DESKTOP_FLAVOR}，回退 full"; DESKTOP_PKG="ubuntu-desktop"; APT_REC_FLAG="" ;;
esac
echo "[WZY] 桌面：${DESKTOP_PKG}（flavor=${DESKTOP_FLAVOR}）"

chroot "${CHROOT}" /bin/bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o Acquire::Check-Valid-Until=false update -y
  # live 基础组件：内核 + casper + 网络 + 字体 + 开机动画
  # 注意 26.04：默认 initramfs 工具已换成 dracut，但 casper 的 live 引导钩子
  # 是 initramfs-tools 的。所以这里显式安装 initramfs-tools，
  # 稍后会强制用它重建 initrd，确保 live 能起来。
  apt-get -o Acquire::Check-Valid-Until=false \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef \
    install -y --no-install-recommends \
    ${KERNEL_PKG} \
    casper \
    initramfs-tools \
    systemd-sysv \
    sudo \
    network-manager \
    netplan.io \
    openssh-server \
    bash-completion \
    less \
    vim-tiny \
    ca-certificates \
    fonts-noto-core \
    fonts-noto-cjk \
    plymouth \
    plymouth-theme-ubuntu-text \
    curl
  # 重要：本段整体位于 chroot 的 bash -c 双引号字符串内，
  # 注释与代码里禁止出现 ASCII 双引号（会提前截断字符串、吞掉后续命令），必须用全角引号。
  # snapd：26.04 官方安装器是 snap 包，必须有 snapd 才能装。
  # 这里带 Recommends 装，免得少了 squashfs/fuse 之类的依赖导致 snapd 起不来。
  apt-get -o Acquire::Check-Valid-Until=false \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef \
    install -y snapd
  # GNOME 桌面 + 登录管理器。
  # 26.04 起 GNOME 已移除 X11 会话（Wayland-only），旧的 Calamares 方案
  # （靠强制 X11 让 root 跑 Qt）不再可用，故不再安装 calamares。
  apt-get -o Acquire::Check-Valid-Until=false \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef \
    install -y ${APT_REC_FLAG} \
    ${DESKTOP_PKG} \
    gdm3
"

# 7.3) 移除 policy-rc.d，别把它打进最终系统（否则装完系统里服务起不来）
rm -f "${CHROOT}/usr/sbin/policy-rc.d"

# 7.4) 强制用 initramfs-tools 重建 initrd。
#      26.04 上内核 postinst 可能用 dracut 生成 initrd.img，那样 casper 钩子不会进去，
#      live 就起不来。这里显式重建一次，用 initramfs-tools 覆盖它。
echo "[WZY] 重建 initramfs（initramfs-tools）…"
chroot "${CHROOT}" /bin/bash -c "update-initramfs -c -k all 2>/dev/null || update-initramfs -u -k all" || \
  echo "[WZY] 警告：initramfs 重建失败，live 引导可能受影响"

# 8) 应用 WZY 视觉覆盖层（主题 / 终端配色 / 设计令牌 / 安装器入口）
echo "[WZY] 应用 WZY 覆盖层…"
cp -a "${SCRIPT_DIR}/overlay/." "${CHROOT}/"
# 修正权限：sudoers 必须 0440，桌面启动器需可执行
chmod 0440 "${CHROOT}/etc/sudoers.d/wzy-live" 2>/dev/null || true
chmod 0755 "${CHROOT}/etc/skel/Desktop/install-wzy.desktop" 2>/dev/null || true
chmod 0755 "${CHROOT}/usr/local/bin/wzy-install" 2>/dev/null || true

# 8.5) 开机动画：采用 Ubuntu 原生主题(ubuntu-text)，仅把其中的 "Ubuntu" 文案改为 WZY Linux
echo "[WZY] 配置 Plymouth 开机动画（Ubuntu 原生 + 改名 WZY Linux）…"
# 注意：ubuntu-text 主题并不提供 ubuntu-text.script，
# 开机文案实际在 ubuntu-text.plymouth 的 title= / Name= 行里，必须改这个文件。
# （26.04 的 manifest 确认 plymouth-theme-ubuntu-text 仍然存在，方案可沿用）
UBT="${CHROOT}/usr/share/plymouth/themes/ubuntu-text/ubuntu-text.plymouth"
if [ -f "${UBT}" ]; then
  sed -i 's/^title=Ubuntu/title=WZY Linux/' "${UBT}"
  sed -i 's/^Name=Ubuntu Text/Name=WZY Linux Text/' "${UBT}"
fi
# 兜底写入默认主题配置，确保 plymouth 启动时真的用 ubuntu-text
mkdir -p "${CHROOT}/etc/plymouth"
printf '[Daemon]\nTheme=ubuntu-text\n' > "${CHROOT}/etc/plymouth/plymouthd.conf"
chroot "${CHROOT}" plymouth-set-default-theme ubuntu-text 2>/dev/null || true

# 9) 卸载 chroot 挂载
cleanup_mounts
trap - EXIT

# 9.5) 还原 WSL1 替身，并补建账户。
#      构建期 systemd-sysusers 被替身跳过，这里用 useradd/groupadd 把它声明的
#      用户/组补齐 —— 真机上 journald / resolved / networkd 等服务依赖这些账户，
#      不补会导致 User= 解析失败、服务起不来。
echo "[WZY] 还原 systemd 真身并补建系统账户…"
wzy_stub_out
cat > "${CHROOT}/usr/local/sbin/wzy-apply-sysusers" <<'WZYSU'
#!/bin/sh
# 替代 systemd-sysusers：按 sysusers.d 声明补齐用户/组。
for f in /usr/lib/sysusers.d/*.conf /etc/sysusers.d/*.conf; do
  [ -f "$f" ] || continue
  awk '{ gsub(/"/,""); if ($1=="u" && NF>=2) print "u",$2,$NF; else if ($1=="g" && NF>=2) print "g",$2,"" }' "$f"
done | while read -r kind name extra; do
  case "$kind" in
    g) getent group  "$name" >/dev/null 2>&1 || groupadd --system "$name" >/dev/null 2>&1 ;;
    u)
       getent passwd "$name" >/dev/null 2>&1 && continue
       case "$extra" in -|''|"$name") extra=/nonexistent ;; esac
       useradd --system -M -d "$extra" -s /usr/sbin/nologin "$name" >/dev/null 2>&1
       ;;
  esac
done
exit 0
WZYSU
chmod 0755 "${CHROOT}/usr/local/sbin/wzy-apply-sysusers"
chroot "${CHROOT}" /usr/local/sbin/wzy-apply-sysusers || true
rm -f "${CHROOT}/usr/local/sbin/wzy-apply-sysusers"

# 10) 打包 squashfs（排除一些运行时目录）
echo "[WZY] 生成 squashfs…"
mkdir -p "${ISO_ROOT}/casper"
mksquashfs "${CHROOT}" "${ISO_ROOT}/casper/filesystem.squashfs" \
  -comp zstd -b 1M -Xcompression-level 3 -no-progress -e "proc/*" "sys/*" "dev/*" "run/*" "tmp/*"

# 复制内核与 initrd
VMLINUZ=$(ls "${CHROOT}/boot"/vmlinuz-* | head -n1)
INITRD=$(ls "${CHROOT}/boot"/initrd.img-* | head -n1)
cp "${VMLINUZ}" "${ISO_ROOT}/casper/vmlinuz"
cp "${INITRD}" "${ISO_ROOT}/casper/initrd"

# 10.1) 校验 casper 的 live 引导脚本是否真的进了 initrd。
#       26.04 上 dracut 可能接管 initramfs，若这里是红的，live 一定起不来。
if command -v lsinitramfs >/dev/null 2>&1; then
  if lsinitramfs "${INITRD}" 2>/dev/null | grep -q casper; then
    echo "[WZY] initrd 已包含 casper live 引导脚本 ✓"
  else
    echo "[WZY] 警告：initrd 里没找到 casper 脚本，live 大概率无法引导"
    echo "[WZY]   排查：确认 chroot 内装的是 initramfs-tools，且 dracut 没有接管 /boot/initrd.img-*"
  fi
fi

# 11) 生成 GRUB 主题背景（可选：有 ImageMagick 就画品牌渐变，否则纯色）
echo "[WZY] 生成 GRUB 主题…"
THEME_DIR="${ISO_ROOT}/boot/grub/theme"
mkdir -p "${THEME_DIR}"
BG="${THEME_DIR}/background.png"
if command -v convert >/dev/null 2>&1; then
  convert -size 1920x1080 \
    gradient:"${C_PRIMARY}"-"${C_VIOLET}" \
    -fill "${C_CANVAS}" -colorize 78% \
    -flatten "${BG}" 2>/dev/null || true
fi
cp "${SCRIPT_DIR}/grub/theme/theme.txt" "${THEME_DIR}/theme.txt"
# 把品牌色注入 theme.txt 占位符
sed -i "s/__CANVAS__/${G_CANVAS}/g; s/__PRIMARY__/${G_PRIMARY}/g; s/__CYAN__/${G_CYAN}/g; s/__TEXT_HI__/${G_TEXT_HI}/g; s/__TEXT_MID__/${G_TEXT_MID}/g" "${THEME_DIR}/theme.txt"
# 有背景图才启用 desktop-image，否则保持纯色画布
if [ -f "${BG}" ]; then
  sed -i 's|^#desktop-image.*|desktop-image: "background.png"|' "${THEME_DIR}/theme.txt"
else
  sed -i '/^#desktop-image/d' "${THEME_DIR}/theme.txt"
fi

# 12) GRUB 配置与引导镜像（BIOS + UEFI 双启）
echo "[WZY] 构建 GRUB 引导镜像…"
mkdir -p "${ISO_ROOT}/boot/grub/i386-pc" "${ISO_ROOT}/EFI/BOOT"
cp "${SCRIPT_DIR}/grub/grub.cfg" "${ISO_ROOT}/boot/grub/grub.cfg"

# 复制 Unicode 字体（含 CJK 字形），让 GRUB 菜单正确显示中文
mkdir -p "${ISO_ROOT}/boot/grub/fonts"
UF=$(ls /usr/share/grub/unicode.pf2 2>/dev/null || true)
if [ -n "${UF}" ]; then
  cp "${UF}" "${ISO_ROOT}/boot/grub/fonts/unicode.pf2"
  echo "[WZY] 已写入字体: ${UF}"
fi

# BIOS 与 UEFI 使用不同模块集：efi_gop/efi_uga 仅存在于 x86_64-efi，不能进 i386-pc
GRUB_MODULES_BIOS="boot linux normal configfile part_gpt part_msdos fat ext2 iso9660 \
loopback search search_fs_file search_fs_uuid search_label chain exfat ntfs \
font gfxterm gfxterm_background png video_bochs video_cirrus \
video_fb all_video gzio echo test true regexp sleep halt reboot"
GRUB_MODULES_EFI="${GRUB_MODULES_BIOS} efi_gop efi_uga"

grub-mkimage -O i386-pc -o "${ISO_ROOT}/boot/grub/i386-pc/eltorito.img" \
  -p /boot/grub ${GRUB_MODULES_BIOS}
grub-mkimage -O x86_64-efi -o "${ISO_ROOT}/EFI/BOOT/BOOTX64.EFI" \
  -p /boot/grub ${GRUB_MODULES_EFI}

# 13) 用 xorriso 合成 hybrid ISO（BIOS + UEFI，可写 U 盘直启）
echo "[WZY] 合成 ISO…"
xorriso -as mkisofs \
  -iso-level 3 \
  -full-iso9660-filenames \
  -volid "${VOLID}" \
  -eltorito-boot boot/grub/i386-pc/eltorito.img \
  -eltorito-catalog boot/grub/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI \
  -no-emul-boot -isohybrid-gpt-basdat \
  -o "${OUT_DIR}/${ISO_NAME}" \
  "${ISO_ROOT}"

# 14) 收尾
echo "[WZY] 完成！"
echo "  ISO: ${OUT_DIR}/${ISO_NAME}"
ls -lh "${OUT_DIR}/${ISO_NAME}"
sha256sum "${OUT_DIR}/${ISO_NAME}"

echo
echo "[WZY] 提示："
echo "  - 用 dd 或 Rufus(写入模式: DD) 烧到 U 盘即可在真机启动。"
echo "  - 老酷睿（Core 2 / 一代~三代 i 系列）选 'WZY Linux (Legacy/BIOS)' 启动项；"
echo "    新机器选 'WZY Linux (UEFI)'。"
echo "  - 默认以 live 模式运行（不往硬盘装），登录用户 ubuntu / 无需密码，sudo 免密。"
