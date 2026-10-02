#!/usr/bin/env bash
# ============================================================
# WZY Linux — 构建配置
# 由 wzylinux-design-tokens.* 抽出的品牌色（深色优先体系）
# ============================================================

# —— 发行版 / 架构 ——
DISTRO="resolute"                    # Ubuntu 26.04 LTS（Resolute Raccoon，内核 7.0）
ARCH="amd64"                         # AMD64 / x86-64
MIRROR="https://mirrors.huaweicloud.com/ubuntu"
KERNEL_PKG="linux-image-generic"     # 通用内核元包（26.04 上解析为 linux-image-7.0.0-*-generic）

# —— 桌面范围 ——
# full   = ubuntu-desktop（完整桌面：LibreOffice / Thunderbird / GIMP 等全套）
# minimal= ubuntu-desktop-minimal（仅 GNOME 核心）
DESKTOP_FLAVOR="full"

# —— 安装器 ——
# 26.04 起 GNOME 已移除 X11 会话（Wayland-only），旧的 Calamares 方案
# （依赖强制 X11 让 root 跑 Qt）不再可用。改用 Ubuntu 官方安装器，
# 它是 snap 包 ubuntu-desktop-bootstrap，天然支持 Wayland。
INSTALLER_SNAP="ubuntu-desktop-bootstrap"
INSTALLER_SNAP_CHANNEL="26.04/stable"

# —— 产物 ——
ISO_NAME="wzylinux-x86_64.iso"
VOLID="WZYLINUX"
OUT_DIR="${PWD}/out"

# —— 品牌色（取自 design tokens，dark-first）——
C_CANVAS="#0A0D1A"
C_SURFACE="#121626"
C_SURFACE_CARD="#1A1F35"
C_PRIMARY="#5B6CFF"
C_VIOLET="#A855F7"
C_CYAN="#22D3EE"
C_GREEN="#35ED7E"
C_MAGENTA="#EC48BD"
C_TEXT_HI="#F5F7FF"
C_TEXT_MID="#B9C0D4"
C_TEXT_LOW="#7C8499"
C_BORDER="rgba(255,255,255,0.12)"

# GRUB 用纯色（去掉 #）
G_CANVAS="${C_CANVAS#\#}"
G_PRIMARY="${C_PRIMARY#\#}"
G_CYAN="${C_CYAN#\#}"
G_TEXT_HI="${C_TEXT_HI#\#}"
G_TEXT_MID="${C_TEXT_MID#\#}"
