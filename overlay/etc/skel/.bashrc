# WZY Linux — 用户 shell 配置（玻璃拟态终端）
# 颜色取自 wzylinux design tokens
export WZY_PRIMARY="\[\e[38;2;91;108;255m\]"   # #5B6CFF
export WZY_CYAN="\[\e[38;2;34;211;238m\]"      # #22D3EE
export WZY_VIOLET="\[\e[38;2;168;85;247m\]"    # #A855F7
export WZY_GREEN="\[\e[38;2;53;237;126m\]"     # #35ED7E
export WZY_TEXT_HI="\[\e[38;2;245;247;255m\]"  # #F5F7FF
export WZY_TEXT_LOW="\[\e[38;2;124;132;153m\]" # #7C8499
export RESET="\[\e[0m\]"

# 提示符：用户@主机 用 primary，路径用 cyan，尾接绿色 ❯
PS1="${WZY_PRIMARY}\u${WZY_TEXT_LOW}@${WZY_PRIMARY}\h${RESET} ${WZY_CYAN}\w${RESET} ${WZY_GREEN}❯${RESET} "

# 基础别名
alias ll='ls -lh --color=auto'
alias la='ls -lha --color=auto'
alias grep='grep --color=auto'

# 256 色支持
[ -x /usr/bin/setterm ] && export TERM=xterm-256color 2>/dev/null || true
