# AI 交接文档 —— WZY Linux 构建

> 给接手这个项目的 AI 助手看的。目的是**少踩坑**——下面每一条都是实际调试总结出来的，
> 有的花了好几轮才定位到。动手前请先读完，尤其是「已解决的关键坑」那一节。

最后更新：2026-10-04

---

## 一、项目是什么

基于 **Ubuntu 26.04 LTS（resolute）** 定制的 live ISO，品牌名「WZY Linux（基于 Ubuntu 开发）」。

- 桌面 flavor：`ubuntu-desktop-minimal`（config.sh 里 `DESKTOP_FLAVOR` 可切 full/minimal）
- 安装器：**Ubuntu 官方安装器**，是 snap 包 `ubuntu-desktop-bootstrap`，**不是 deb**
- 产物流：`debootstrap` → chroot 内 `apt-get install` → overlay → `mksquashfs` → GRUB → `xorriso`
- 品牌色：bg `#0A0D1A` / fg `#F5F7FF` / highlight `#5B6CFF` / violet `#A855F7` / cyan `#22D3EE`

仓库：`https://github.com/wzywzy000/wzylinux`（分支 `main`）

---

## 二、⚠️ 环境硬要求：必须是原生 Linux 内核

**不要在 WSL1 上构建。** 这不是性能问题，是必失败。已实测的两种崩法：

1. `./build.sh: fork: Invalid argument` —— 伪内核 fork 返回 EINVAL，崩溃点**随机**落在任意包
   的触发器上（一次是 ca-certificates 的 `Updating certificates in /etc/ssl/certs`）。
   资源全都宽裕（内存空闲 6.3G、进程数 6、ulimit 7823），事后 fork 压测 50/50 全成功。
2. **进程静默消失** —— 没有任何报错，日志停在某行就不动了（一次停在第 097 号包
   `adwaita-icon-theme` 的 Unpacking）。

WSL2 / Hyper-V / 实体机 / 云服务器都可以，只要是真内核。

### 构建命令

```bash
cd ~/wzylinux-iso
sudo WZY_NO_STUB=1 ./build.sh
```

| 变量 | 何时用 |
|---|---|
| `WZY_NO_STUB=1` | **真机必加**。跳过为 WSL1 写的 systemd 替身，用原版工具（见下） |
| `WZY_RESUME=1` | 上一轮跑完 debootstrap 却崩在后面时，跳过第 5 步复用 chroot，省约 2 小时。chroot 不可用时自动回退全新构建 |

**为什么 `WZY_NO_STUB=1` 很重要**：替身只实现了 sysusers.d 的 `u`（用户）/ `g`（组）两类声明，
而**原版 `systemd-sysusers` 还会处理 `m`（组成员）和 `r`（ID 范围）**。真机上不加这个开关，
可能埋下组成员缺失的隐患。替身的存在只是为了绕开 WSL1 缺的两个 syscall。

---

## 三、26.04 相对 22.04 的破坏性变更（迁移时踩过）

1. **Wayland-only，X11 会话彻底移除**。旧的 Calamares 方案靠 `gdm3 WaylandEnable=false`
   强制 X11 让 root 跑 Qt —— 已死。更糟的是：禁用 Wayland 后 GDM **没有任何会话可起**，
   连登录界面都进不去。→ `overlay/etc/gdm3/custom.conf` 里**不要再设 WaylandEnable**。
2. **dracut 取代 initramfs-tools 成为默认**。casper 的 live 钩子是 initramfs-tools 的，
   被 dracut 接管就进不了 live。→ build.sh 里显式装 initramfs-tools 并强制 `update-initramfs`
   重建，**构建后必须验证**（见第六节）。官方 manifest 确认 `casper 26.04.2` 仍在。
3. **官方安装器是 snap**。manifest 里没有任何 installer/subiquity/curtin 的 deb。
4. x86-64 基线网上说法打架（有称强制 v3 会杀死 2013 年前的老 CPU），但 ubuntu.com 官方架构
   文档写明 amd64 基线仍是 v1、v3 只是可选变体。**用户的老机器需实测。**

---

## 四、已解决的关键坑（按发现顺序）

### 4.1 `systemd-sysusers` 替身不能写成 `exit 0`

曾经把替身写成空壳，导致 dbus 配置失败并连锁拖垮 libpam-systemd / systemd-resolved /
networkd-dispatcher / chrony / ubuntu-minimal 一整串。原因链条：

- `dbus.postinst` **自己不建账户**，只做
  `dpkg-statoverride --update --add root messagebus 4754 <launcher>`
- 真正建 `messagebus` 组的是 **`dbus-system-bus-common.postinst`**：
  ```sh
  if command -v systemd-sysusers >/dev/null; then
      systemd-sysusers ${DPKG_ROOT:+--root="$DPKG_ROOT"} dbus.conf
  else
      in_sysroot adduser --system --quiet --group "$MESSAGEUSER"
  fi
  ```
- `systemd.postinst` 只处理 `basic.conf systemd-journal.conf systemd-network.conf`，**不含 dbus.conf**

所以替身必须真正干活。用 `useradd`/`groupadd` 复刻时又有三个坑：

- **字段位置**：`read` 拆列时 **home 是第 5 列，不是最后一列**。
  用 `$NF` 会取到 shell。例：`u messagebus - "System Message Bus" /nonexistent`
  得先把带引号的 GECOS 折叠成单字段（`sed 's/"[^"]*"/GECOS/g'`）再拆。
- **类型要认 `u!`**：systemd-network / systemd-resolve / dhcpcd 用的都是 `u!` 变体，
  只匹配 `u` 会漏。
- **不能「先建同名组、再不带 `-g` 调 useradd」**（这个最隐蔽）：
  `login.defs` 里 `USERGROUPS_ENAB yes` 时 useradd 会想自己建同名组，发现已存在就报错退出
  ```
  useradd: group messagebus exists - if you want to add this user to that group, use -g.  (exit 9)
  ```
  表现极具迷惑性：**组全建出来了，用户一个都没有**。
  二选一——要么不预建组，要么预建 + 显式 `-g` 指过去。代码选了后者。

### 4.2 dpkg-divert 才能保住替身

直接覆盖 `/usr/bin/systemd-sysusers` 无效：systemd 是在 debootstrap **第二阶段才解包**的，
覆盖会被随后的解包还原。必须用 `dpkg-divert --local --rename --add` 注册持久规则。

### 4.3 `dpkg --configure -a` 的位置

会看到 `E: dpkg was interrupted, you must manually run 'dpkg --configure -a' to correct the problem.`
这句**必须放在挂载 /proc/sys/dev 之后、apt 之前** —— 放在挂载前会因缺 /proc
导致 postinst 失败。build.sh 第 7 步里已处理。

### 4.4 `--second-stage` 不要让 `set -e` 掐死

dbus 配置失败会让 debootstrap 返回非零。用 `if ! ...; then` 包住，之后补账户再让 dpkg 重试自救。

### 4.5 本机 `core.autocrlf=true`

已加 `.gitattributes`（`* text=auto eol=lf`）。否则 checkout 转 CRLF 后脚本在 Linux 全线报
`\r: command not found`。

---

## 五、当前状态

**已完成**：26.04 全部迁移改造；debootstrap 阶段已在生产环境验证通过
（日志出现 `I: Base system installed successfully.`，`messagebus:x:995` 建出）。

**未验证**：桌面安装之后的部分（squashfs / GRUB / xorriso / 出 ISO）。
26.04 版本**至今没有一个完整跑通的 ISO**。

**参考成果**：`out/wzylinux-x86_64.iso`（1.5GB，2026-09-28 基于 **jammy** 构建，成功过）
sha256 `7f6bc02715fb2dc6cf27d861ec184e1b9cc4bdaedf1f9e0f483ad0dd2ec91217`

---

## 六、构建成功后必做四项校验

```bash
cd ~/wzylinux-iso
# 1) 【最要命】initrd 里必须有 casper 的 live 引导脚本
lsinitramfs chroot/boot/initrd.img-* | grep -c casper        # 应 > 0

# 2) Plymouth 主题名已改名
grep -c "WZY Linux" chroot/usr/share/plymouth/themes/ubuntu-text/ubuntu-text.script

# 3) 系统名
grep PRETTY_NAME chroot/etc/os-release

# 4) 产物
ls -lh out/wzylinux-x86_64.iso && sha256sum out/wzylinux-x86_64.iso
```

第 1 条是 26.04 最容易翻车的地方（dracut 默认化，见第三节第 2 条）。

---

## 七、文件地图

| 路径 | 作用 |
|---|---|
| `build.sh` | 主构建脚本，全部编排在这里 |
| `config.sh` | 发行版 / 架构 / 桌面 flavor / 安装器 snap / 品牌色 |
| `overlay/` | 覆盖层：gdm3、os-release、lsb-release、Plymouth、安装器入口 `wzy-install`、设计令牌 |
| `overlay/etc/gdm3/custom.conf` | **别再加 WaylandEnable** |
| `overlay/usr/local/bin/wzy-install` | 拉起官方安装器 snap（snapd 就绪后启动） |
| `grub/` | GRUB 配置与主题 |
| `.gitattributes` | 强制 LF，务必保留 |
| `.wzy-*.sh` | 临时排障脚本，已 gitignore |

---

## 八、其它已知阻塞

- **GitHub push**：这台机器上 HTTPS 443 被拦，但 **SSH 22 通**。remote 用
  `git@github.com:wzywzy000/wzylinux.git`。SSH key 已注册（`ssh -T git@github.com` 有响应）。
- **写 ISO 到 U 盘**：非管理员 + 安全策略拦截，未曾执行过。
- **x86-64 基线**：26.04 是否要求 v3 存疑，用户的老机器需实测。
