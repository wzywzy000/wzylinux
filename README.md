# WZY Linux · ISO 构建工程

最小可启动的 Linux live 系统，**amd64 架构**，内核为 Ubuntu 22.04 的  
`linux-image-generic`（5.15），**兼容老款 Intel 酷睿**（Core 2 及以后、  
第一代~三代 Core i 系列均没问题）。视觉体系取自 `wzylinux-design-tokens.*`：

- GRUB 开机菜单：深色画布 + 极光渐变背景 + 玻璃风菜单（品牌色注入）
- 终端：primary / cyan / green 配色的提示符与别名
- 登录横幅：WZY 字标 + 系统信息
- `/usr/share/wzy/` 内置原始设计令牌（CSS / JSON / 组件 / 集成说明）

## 在 Ubuntu WSL 里构建

```bash
# 1) 进入工程目录（在 WSL 里对应路径，例如）
cd /mnt/c/Users/25257/Desktop/新建文件夹/wzylinux-iso

# 2) 一键构建（会自动 sudo，并安装构建依赖）
sudo ./build.sh
```

构建过程会：

1. `apt` 安装 `debootstrap / squashfs-tools / grub-* / xorriso / mtools` 等依赖
2. `debootstrap` 拉取 jammy 最小根文件系统
3. chroot 内装入内核 + `casper`（live 引导）+ 网络/SSH/字体等最小组件
4. 应用 `overlay/` 里的 WZY 视觉覆盖层
5. 打包 `filesystem.squashfs`，复制内核与 initrd
6. 生成 GRUB 主题（若装了 ImageMagick 会自动画出品牌渐变背景）
7. 构建 BIOS + UEFI 双启引导镜像
8. `xorriso` 合成 hybrid ISO → `out/wzylinux-x86_64.iso`

> 第 2~3 步首次需要联网下载数百 MB，耗时取决于网速（通常 5~20 分钟）。
> **已下载的包会缓存在工程内的 `cache/` 目录**，后续重跑 `build.sh` 会跳过下载、直接复用，不会重复拉取（别手滑删掉 `cache/`）。

## 烧录与启动

- **U 盘**：`sudo dd if=out/wzylinux-x86_64.iso of=/dev/sdX bs=4M status=progress`  
  （Windows 下用 Rufus，写入模式选 **DD 镜像**，别选 ISO 模式）
- **虚拟机**：直接把 ISO 挂到 VMware / VirtualBox / Hyper-V 即可。
- 老机器 BIOS 启动选 "WZY Linux (Live)"；若黑屏/花屏，选 "安全图形模式"  
  （加了 `nomodeset`）。

## 默认行为

- 以 **live 模式**运行：不写硬盘，重启即还原。
- live 用户：`ubuntu`（casper 自动登录，无需密码；`sudo` 免密）。

## 调参

- 改发行版 / 架构：编辑 `config.sh`（`DISTRO` / `ARCH` / `MIRROR`）。
- 改品牌色：编辑 `config.sh` 里的 `C_*` 变量，`build.sh` 会自动注入 GRUB 主题  
  与终端配色。
- 加预装软件：在 `build.sh` 的 `apt-get install` 列表里追加包名。
