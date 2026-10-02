# WZY Linux · ISO 构建工程

基于 **Ubuntu 26.04 LTS（resolute · Resolute Raccoon）** 的 live 系统，**amd64 架构**，
桌面为完整的 `ubuntu-desktop`（GNOME 50），安装器用 Ubuntu 官方的
`ubuntu-desktop-bootstrap`（snap）。视觉体系取自 `wzylinux-design-tokens.*`：

- GRUB 开机菜单：深色画布 + 极光渐变背景 + 玻璃风菜单（品牌色注入）
- 终端：primary / cyan / green 配色的提示符与别名
- 登录横幅：WZY 字标 + 系统信息
- `/usr/share/wzy/` 内置原始设计令牌（CSS / JSON / 组件 / 集成说明）

## 在 Ubuntu WSL 里构建

```bash
cd ~/wzylinux-iso          # 必须是 WSL 原生 ext4，不能是 /mnt/c
sudo ./build.sh
```

> **必须在 WSL 原生文件系统（ext4）里跑**，例如 `~/wzylinux-iso`。
> 放在 `/mnt/c`（Windows NTFS）下 debootstrap 解包根文件系统会 `tar failed`。

构建过程会：

1. `apt` 安装 `debootstrap / squashfs-tools / grub-* / xorriso / mtools` 等依赖
2. `debootstrap` 拉取 resolute 最小根文件系统
   （若构建主机的 debootstrap 太旧、没有 resolute 脚本，脚本会自动软链兜底）
3. chroot 内装入内核 + `casper` + `initramfs-tools` + 网络/SSH/字体 + snapd
4. 安装完整 `ubuntu-desktop` + `gdm3`
5. 强制用 initramfs-tools 重建 initrd，并校验 casper 钩子确实进去了
6. 应用 `overlay/` 里的 WZY 视觉覆盖层
7. 打包 `filesystem.squashfs`，复制内核与 initrd
8. 生成 GRUB 主题（若装了 ImageMagick 会自动画出品牌渐变背景）
9. 构建 BIOS + UEFI 双启引导镜像
10. `xorriso` 合成 hybrid ISO → `out/wzylinux-x86_64.iso`

> 第 2~4 步首次需要联网下载数 GB（完整桌面远大于原来的 minimal），耗时取决于网速。
> **已下载的包会缓存在工程内的 `cache/` 目录**，后续重跑会跳过下载、直接复用。
> 切换发行版后旧缓存不会命中（文件名带版本号），脚本会提示但**不自动删除**。

## 26.04 带来的破坏性变更（已在本工程处理）

| 变更 | 影响 | 本工程的处理 |
| --- | --- | --- |
| GNOME 移除 X11 会话，Wayland-only | 旧方案靠 `WaylandEnable=false` 强制 X11 让 root 跑 Calamares；26.04 没有 X11 会话可切，那样连登录界面都进不去 | 放弃 Calamares，改用官方 snap 安装器（Wayland 原生）；`gdm3/custom.conf` 不再禁用 Wayland |
| dracut 取代 initramfs-tools 成为默认 | casper 的 live 引导钩子是 initramfs-tools 的，被 dracut 接管就进不了 initrd，live 起不来 | 显式安装 initramfs-tools 并强制重建 initrd，构建时校验 `casper` 是否真的进了 initrd |
| 官方安装器是 snap，不是 deb | 需要 snapd | 安装 snapd；安装器首次点击时联网获取 snap |
| sudo 换成 sudo-rs、coreutils 换成 Rust 版 | overlay 里的 sudoers 需验证 | `overlay/etc/sudoers.d/wzy-live` 沿用标准语法，sudo-rs 可识别 |

## 已知限制 / 风险

- **内存**：26.04 桌面版官方建议 6GB（GNOME 50 + Wayland）。老机器上会明显吃力。
- **x86-64 基线**：网上有说法称 26.04 要求 x86-64-v3（那样 2013 年前的 CPU 直接出局），
  但 [Ubuntu 官方架构文档](https://ubuntu.com/project/docs/how-ubuntu-is-made/concepts/supported-architectures/)
  写明 amd64 基线仍是 v1，v3 只是可选变体。**老机器上务必实测确认。**
- **安装器需要联网**：本工程不在构建期预置 `ubuntu-desktop-bootstrap` snap
  （预置要求连同 base snap 一起写进 `/var/lib/snapd/seed`，依赖多、失败会拖累 live 桌面本身）。
  首次点击桌面上的「安装 WZY Linux」会联网下载。离线环境请先手动装：
  ```bash
  sudo snap install ubuntu-desktop-bootstrap --channel=26.04/stable
  ```
- **ISO 体积**：完整桌面会让 ISO 远大于原来的 1.5G（官方 26.04 桌面 ISO 已达 ~6.5GB）。

## 烧录与启动

- **U 盘**：`sudo dd if=out/wzylinux-x86_64.iso of=/dev/sdX bs=4M status=progress`
  （Windows 下用 Rufus，写入模式选 **DD 镜像**，别选 ISO 模式）
- **虚拟机**：直接把 ISO 挂到 VMware / VirtualBox / Hyper-V 即可。
- 老机器 BIOS 启动选 "WZY Linux (Live)"；若黑屏/花屏，选 "安全图形模式"（加了 `nomodeset`）。
- UEFI 需关闭 Secure Boot（本工程未签名）。

## 默认行为

- 以 **live 模式**运行：不写硬盘，重启即还原。
- live 用户：`ubuntu`（casper 自动登录，无需密码；`sudo` 免密）。

## 调参

- 改发行版 / 架构 / 桌面范围：编辑 `config.sh`
  （`DISTRO` / `ARCH` / `MIRROR` / `DESKTOP_FLAVOR`）。
  `DESKTOP_FLAVOR=full` 装 `ubuntu-desktop`（含 LibreOffice 等全套）；
  改成 `minimal` 则装 `ubuntu-desktop-minimal`，ISO 会小很多。
- 改品牌色：编辑 `config.sh` 里的 `C_*` 变量，`build.sh` 会自动注入 GRUB 主题与终端配色。
- 加预装软件：在 `build.sh` 的 `apt-get install` 列表里追加包名
  （注意那段整体在 `bash -c "..."` 双引号字符串内，注释里**禁止出现 ASCII 双引号**，
  历史上因为这个踩过坑：字符串被提前截断、后面的安装命令被静默吞掉）。
