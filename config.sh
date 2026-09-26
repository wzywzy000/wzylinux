#!/usr/bin/env bash
# ============================================================
# WZY Linux — 构建配置
# 由 wzylinux-design-tokens.* 抽出的品牌色（深色优先体系）
# ============================================================

# —— 发行版 / 架构 ——
DISTRO="jammy"                       # Ubuntu 22.04 LTS（内核 5.15，兼容老酷睿）
ARCH="amd64"                         # AMD64 / x86-64
MIRROR="https://mirrors.huaweicloud.com/ubuntu"
KERNEL_PKG="linux-image-generic"     # 通用内核，老款酷睿（Core 2 及以后）没问题

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
