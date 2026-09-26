# WZYLinux 设计系统 · 集成指引

本设计系统交付的是「视觉规范 + 设计令牌（Design Tokens）」，可直接对接真实发行版的构建链路：

| 令牌 / 规范 | 对接点 | 工具 / 技术 |
|------------|--------|-------------|
| `--wzy-gradient-brand` · `canvas` | 启动菜单背景、开机动画 | GRUB2 主题 · Plymouth |
| 全套色彩 + 字体 + 圆角 | 安装器界面主题 | Calamares（QML）|
| 玻璃卡片 · 圆角 · 间距 · 文本层级 | 桌面环境外观 | GTK4（libadwaita）· Qt（Kvantum）|
| `--wzy-font-mono` + 语义色 | 终端配色方案 | Alacritty / Kitty / Konsole |
| 设计令牌（JSON / CSS） | 官网、文档、物料 | 本设计系统（.ardot）|

## 使用方式
1. 将 `wzylinux-design-tokens.css` 引入发行版的主题包（GTK/Qt 资源或 Calamares 资产目录）。
2. 将 `wzylinux-components.css` 作为基础组件层，覆盖默认控件样式。
3. `wzylinux-design-tokens.json` 可用于脚本化生成 GRUB / Plymouth 的主题色（提取 `color` 与 `gradient` 字段即可）。

> 说明：生成可启动 `.iso`、编译最新 Linux 内核、制作图形安装程序属于**操作系统工程**范畴，
> 超出设计助手的能力边界。上述令牌正是进入该构建链路的标准输入（design tokens → 构建配置）。
