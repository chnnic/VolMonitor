#!/bin/sh
# =============================================================
#  volmon-node.sh  —  VolMonitor 被控机助手
#  在被控机上安装「受限监控公钥」:该公钥只能触发只读采集脚本,
#  拿不到 shell、禁止端口/agent/X11 转发、不分配 pty,泄露也基本无害。
#  纯 POSIX sh,兼容 Debian/Ubuntu/Alpine/OpenWrt(OpenSSH 与 Dropbear)。
# =============================================================
VER="1.0.2"

# ---------- 颜色 ----------
if [ -t 1 ]; then
  N='\033[0m'; B='\033[1m'; R='\033[31m'; G='\033[32m'; Y='\033[33m'; C='\033[36m'; GR='\033[90m'
else
  N=''; B=''; R=''; G=''; Y=''; C=''; GR=''
fi
say(){ printf '%b\n' "$*"; }
cls(){ [ -t 1 ] && { clear 2>/dev/null || printf '\033[2J\033[3J\033[H'; }; }
pause(){ [ -t 0 ] && { printf "\n${GR}按回车返回...${N}"; read -r _; }; }

# =============================================================
#  只读采集脚本(与主控内嵌版一致;POSIX sh)
# =============================================================
COLLECTOR=$(cat <<'COLLECT'
LC_ALL=C; export LC_ALL
H=$(hostname 2>/dev/null || cat /proc/sys/kernel/hostname 2>/dev/null)
echo "HOST=$H"
echo "TIME=$(date '+%F %T %Z' 2>/dev/null)"
[ -r /proc/uptime ] && echo "UPTIME_S=$(cut -d. -f1 /proc/uptime)"
[ -r /proc/loadavg ] && echo "LOAD=$(cut -d' ' -f1-3 /proc/loadavg)"
CPU=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ -n "$CPU" ] && [ "$CPU" -gt 0 ] 2>/dev/null && echo "CPU=$CPU"
awk '/^MemTotal/{t=$2}/^MemAvailable/{a=$2}END{if(t>0){printf "MEM_USED_MB=%d\n",(t-a)/1024;printf "MEM_TOTAL_MB=%d\n",t/1024;printf "MEM_PCT=%.0f\n",(t-a)*100/t}}' /proc/meminfo 2>/dev/null
df -h -P / 2>/dev/null | awk 'NR==2{printf "DISK_USED=%s\nDISK_TOTAL=%s\nDISK_PCT=%s\n",$3,$2,$5}'
awk -F: 'NR>2{i=$1;gsub(/[ \t]/,"",i);if(i!="lo"){split($2,a," ");if((a[1]+a[9])>0)printf "NET=%s %s %s\n",i,a[1],a[9]}}' /proc/net/dev 2>/dev/null
if command -v ss >/dev/null 2>&1; then
  E=$(ss -tnH state established 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$E" ] && echo "TCP_EST=$E"
  L=$(ss -tlnH 2>/dev/null | wc -l | tr -d ' ')
  [ -n "$L" ] && echo "TCP_LISTEN=$L"
elif command -v netstat >/dev/null 2>&1; then
  echo "TCP_EST=$(netstat -tn 2>/dev/null | grep -c ESTABLISHED)"
fi
svc_check(){
  if command -v pgrep >/dev/null 2>&1 && pgrep -x "$1" >/dev/null 2>&1; then return 0; fi
  for c in /proc/[0-9]*/comm; do
    [ -r "$c" ] || continue
    [ "$(cat "$c" 2>/dev/null)" = "$1" ] && return 0
  done
  return 1
}
for p in xray sing-box shadowsocks-rust ss-server ss-rust hysteria hysteria2 tuic naive gost mihomo; do
  svc_check "$p" && echo "SVC=$p"
done
exit 0
COLLECT
)

# =============================================================
#  采集脚本落地路径(挑一个可写目录)
# =============================================================
collect_path(){
  for d in /usr/local/bin /usr/bin /opt; do
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then echo "$d/volmon-collect"; return; fi
  done
  echo "$HOME/.volmon-collect"
}

write_collector(){
  p=$1
  { echo '#!/bin/sh'; printf '%s\n' "$COLLECTOR"; } > "$p" || return 1
  chmod 755 "$p"
}

# =============================================================
#  安装受限公钥
# =============================================================
install_pubkey(){
  pub=$1
  case "$pub" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *|sk-*\ *) : ;;
    *) say "${R}公钥格式不对,应以 ssh-ed25519 / ssh-rsa 等开头${N}"; return 1 ;;
  esac
  cp=$(collect_path)
  if ! write_collector "$cp"; then say "${R}无法写入采集脚本到 $cp${N}"; return 1; fi
  sshdir="$HOME/.ssh"; ak="$sshdir/authorized_keys"
  mkdir -p "$sshdir"; chmod 700 "$sshdir"
  touch "$ak"; chmod 600 "$ak"
  opts="command=\"$cp\",no-port-forwarding,no-agent-forwarding,no-x11-forwarding,no-pty"
  body=$(echo "$pub" | awk '{print $2}')
  if [ -n "$body" ] && grep -qF "$body" "$ak" 2>/dev/null; then
    grep -vF "$body" "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"
  fi
  echo "$opts $pub" >> "$ak"
  chmod 600 "$ak"
  say "${G}已安装受限监控公钥${N}"
  say "  采集脚本: ${C}$cp${N}"
  say "  authorized_keys: ${C}$ak${N}"
  say "  ${GR}该公钥仅能执行只读采集,无 shell / 无转发 / 无 pty${N}"
  say "${GR}主控侧:用对应私钥添加节点即可拉取(host 填本机 DDNS 域名)${N}"
}

# =============================================================
#  本机生成密钥对(打印私钥转交主控)
# =============================================================
gen_key(){
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    say "${R}本机无 ssh-keygen(OpenWrt/Dropbear 常见)。${N}"
    say "${Y}请在主控生成密钥后,用 add 粘贴公钥安装。${N}"
    return 1
  fi
  tmp=$(mktemp -u "${TMPDIR:-/tmp}/volmon_key.XXXXXX")
  ssh-keygen -t ed25519 -N "" -C "volmon-monitor" -f "$tmp" -q || { say "${R}生成失败${N}"; return 1; }
  install_pubkey "$(cat "$tmp.pub")" || { rm -f "$tmp" "$tmp.pub"; return 1; }
  echo
  say "${Y}===== 以下私钥请复制到【主控】导入,然后从本机抹除 =====${N}"
  cat "$tmp"
  say "${Y}=========================================================${N}"
  shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
  rm -f "$tmp.pub"
  say "${GR}本机私钥已删除,只保留受限公钥${N}"
}

# =============================================================
#  卸载
# =============================================================
uninstall(){
  ak="$HOME/.ssh/authorized_keys"
  if [ -f "$ak" ]; then
    grep -v 'volmon-collect' "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"
  fi
  rm -f /usr/local/bin/volmon-collect /usr/bin/volmon-collect /opt/volmon-collect "$HOME/.volmon-collect" 2>/dev/null
  say "${G}已移除受限公钥行与采集脚本${N}"
}

# =============================================================
#  本机状态
# =============================================================
field(){ printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
do_local(){
  out=$(printf '%s\n' "$COLLECTOR" | sh)
  host=$(field HOST "$out"); t=$(field TIME "$out")
  up=$(field UPTIME_S "$out"); load=$(field LOAD "$out"); cpu=$(field CPU "$out")
  mu=$(field MEM_USED_MB "$out"); mt=$(field MEM_TOTAL_MB "$out"); mp=$(field MEM_PCT "$out")
  du=$(field DISK_USED "$out"); dt=$(field DISK_TOTAL "$out"); dp=$(field DISK_PCT "$out")
  est=$(field TCP_EST "$out")
  svcs=$(printf '%s\n' "$out" | sed -n 's/^SVC=//p' | tr '\n' ' ')
  read rxg txg <<EOF
$(printf '%s\n' "$out" | awk -F'[= ]' '/^NET=/{rx+=$3;tx+=$4}END{printf "%.2f %.2f",rx/1073741824,tx/1073741824}')
EOF
  say "${B}● 本机 ${G}${host}${N}  ${GR}${t}${N}"
  [ -n "$up" ] && say "  运行 $(awk -v s="$up" 'BEGIN{printf "%dd %02dh %02dm",s/86400,s%86400/3600,s%3600/60}')  负载 ${load}  CPU ${cpu}核"
  [ -n "$mt" ] && say "  内存 ${mu}/${mt} MB (${mp}%)   磁盘 ${du}/${dt} (${dp})"
  say "  流量 ↓${rxg}G ↑${txg}G   TCP活动 ${est:-?}"
  [ -n "$svcs" ] && say "  服务 ${G}${svcs}${N}"
}

# =============================================================
#  菜单
# =============================================================
menu(){
  while :; do
    cls
    say "${C}  ────────────────────────────────────────${N}"
    say "${B}${C}  VolMonitor 被控机助手${N}   ${GR}v${VER}${N}"
    say "${GR}  安装受限监控公钥 · 被控端零常驻${N}"
    say "${C}  ────────────────────────────────────────${N}"
    echo
    say "  ${B}1${N}) 粘贴主控公钥并安装(推荐,私钥不离开主控)"
    say "  ${B}2${N}) 本机生成密钥对(打印私钥转交主控)"
    say "  ${B}3${N}) 查看本机状态"
    say "  ${B}4${N}) 卸载受限公钥与采集脚本"
    say "  ${B}0${N}) 退出"
    echo
    printf "选择: "; read -r ch
    case "$ch" in
      1)
        say "${GR}粘贴主控的【公钥】单行内容(ssh-ed25519 AAAA... 形式):${N}"
        read -r pub
        [ -z "$pub" ] && { say "取消"; pause; continue; }
        install_pubkey "$pub"; pause ;;
      2) gen_key; pause ;;
      3) do_local; pause ;;
      4) uninstall; pause ;;
      0|q) exit 0 ;;
      *) say "${R}无效选择${N}"; pause ;;
    esac
  done
}

# =============================================================
#  入口
# =============================================================
case "${1:-}" in
  add)
    if [ -n "$2" ]; then install_pubkey "$2"
    else
      say "${GR}粘贴主控的公钥(单行)后回车:${N}"; read -r pub; install_pubkey "$pub"
    fi ;;
  gen|generate) gen_key ;;
  status|local) do_local ;;
  remove|uninstall) uninstall ;;
  ""|menu) menu ;;
  -h|--help|help)
    echo "用法: $0 [add [\"公钥\"]|gen|status|remove|menu]"
    echo "  add [公钥]   安装受限监控公钥(带参数则直接装,否则提示粘贴)"
    echo "  gen          本机生成密钥对并安装受限公钥,打印私钥给主控"
    echo "  status       查看本机状态"
    echo "  remove       卸载受限公钥与采集脚本"
    echo "  无参数        进入交互菜单" ;;
  *) echo "未知命令: $1 (用 $0 --help)"; exit 1 ;;
esac
