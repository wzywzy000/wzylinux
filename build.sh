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
apt-get update -y
apt-get install -y --no-install-recommends \
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
echo "[WZY] debootstrap ${DISTRO} (${ARCH}) … 已缓存的包会跳过下载"
debootstrap --arch="${ARCH}" --components=main,universe \
  --cache-dir="${CACHE_DIR}/debootstrap" "${DISTRO}" "${CHROOT}" "${MIRROR}"

# 6) 准备 chroot 内环境（网络解析）
cp /etc/resolv.conf "${CHROOT}/etc/resolv.conf"

# 7) 在 chroot 内安装系统包
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

chroot "${CHROOT}" /bin/bash -c "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  # 最小但可用的 live 系统
  apt-get install -y --no-install-recommends \
    ${KERNEL_PKG} \
    casper \
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
    fonts-noto-cjk
  # GNOME 桌面 + 登录管理器 + 图形化安装器（Calamares）
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal \
    gdm3 \
    calamares
"

# 8) 应用 WZY 视觉覆盖层（主题 / 终端配色 / 设计令牌 / Calamares）
echo "[WZY] 应用 WZY 覆盖层…"
cp -a "${SCRIPT_DIR}/overlay/." "${CHROOT}/"
# 修正权限：sudoers 必须 0440，桌面启动器需可执行
chmod 0440 "${CHROOT}/etc/sudoers.d/wzy-live" 2>/dev/null || true
chmod 0755 "${CHROOT}/etc/skel/Desktop/install-wzy.desktop" 2>/dev/null || true

# 9) 卸载 chroot 挂载
cleanup_mounts
trap - EXIT

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
