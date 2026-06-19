#!/bin/sh
# =============================================================
#  volmon-node.sh  —  VolMonitor 被控机助手
#  在被控机上安装「受限监控公钥」:该公钥只能触发只读采集脚本,
#  拿不到 shell、禁止端口/agent/X11 转发、不分配 pty,泄露也基本无害。
#  纯 POSIX sh,兼容 Debian/Ubuntu/Alpine/OpenWrt(OpenSSH 与 Dropbear)。
# =============================================================
VER="1.0.7"

# ---------- 更新源 ----------
REPO_RAW="${VOLMON_REPO:-https://raw.githubusercontent.com/chnnic/VolMonitor/main}"
SELF_FILE="volmon-node.sh"

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
  pub=$1; from=$2
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
  [ -n "$from" ] && opts="from=\"$from\",$opts"
  body=$(echo "$pub" | awk '{print $2}')
  if [ -n "$body" ] && grep -qF "$body" "$ak" 2>/dev/null; then
    grep -vF "$body" "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"
  fi
  echo "$opts $pub" >> "$ak"
  chmod 600 "$ak"
  say "${G}已安装受限监控公钥${N}"
  say "  采集脚本: ${C}$cp${N}"
  say "  authorized_keys: ${C}$ak${N}"
  [ -n "$from" ] && say "  来源限制: ${C}from=\"$from\"${N}(仅此 IP 可用此钥)"
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
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/volmon_key.XXXXXX") || { say "${R}创建临时目录失败${N}"; return 1; }
  chmod 700 "$tmpdir" 2>/dev/null
  tmp="$tmpdir/key"
  ssh-keygen -t ed25519 -N "" -C "volmon-monitor" -f "$tmp" -q || { say "${R}生成失败${N}"; rm -rf "$tmpdir"; return 1; }
  install_pubkey "$(cat "$tmp.pub")" || { rm -rf "$tmpdir"; return 1; }
  echo
  say "${Y}===== 以下私钥请复制到【主控】导入,然后从本机抹除 =====${N}"
  cat "$tmp"
  say "${Y}=========================================================${N}"
  shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
  rm -f "$tmp.pub"; rmdir "$tmpdir" 2>/dev/null
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
#  修改 / 查看 受限公钥的来源 IP 限制(from=)
# =============================================================
current_from(){
  ak="$HOME/.ssh/authorized_keys"
  [ -f "$ak" ] || return 1
  grep 'volmon-collect' "$ak" 2>/dev/null | sed -n 's/^from="\([^"]*\)".*/\1/p' | head -1
}

set_from(){
  newfrom=$1
  ak="$HOME/.ssh/authorized_keys"
  [ -f "$ak" ] || { say "${R}未找到 $ak${N}"; return 1; }
  if ! grep -q 'volmon-collect' "$ak" 2>/dev/null; then
    say "${R}未找到已安装的受限公钥,请先用 add 安装${N}"; return 1
  fi
  tmp="$ak.tmp"; : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *volmon-collect*)
        rest=$(printf '%s' "$line" | sed 's/^from="[^"]*",//')
        if [ -n "$newfrom" ]; then
          printf 'from="%s",%s\n' "$newfrom" "$rest" >> "$tmp"
        else
          printf '%s\n' "$rest" >> "$tmp"
        fi ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$ak"
  mv "$tmp" "$ak"; chmod 600 "$ak"
  if [ -n "$newfrom" ]; then say "${G}已设置来源限制: from=\"$newfrom\"${N}"
  else say "${G}已移除来源限制(任意 IP 可用此钥)${N}"; fi
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
  return 0
}

# =============================================================
#  自更新
# =============================================================
self_path(){ readlink -f "$0" 2>/dev/null || echo "$PWD/$(basename "$0")"; }

do_update(){
  url="$REPO_RAW/$SELF_FILE"; self=$(self_path)
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    say "${R}需要 curl 或 wget 才能更新${N}"; return 1
  fi
  tmp=$(mktemp)
  say "${GR}下载: $url${N}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$url" -o "$tmp" || { say "${R}下载失败${N}"; rm -f "$tmp"; return 1; }
  else
    wget -qO "$tmp" "$url" || { say "${R}下载失败${N}"; rm -f "$tmp"; return 1; }
  fi
  head -1 "$tmp" | grep -q '^#!' || { say "${R}下载内容异常(非脚本),已放弃${N}"; rm -f "$tmp"; return 1; }
  sh -n "$tmp" 2>/dev/null || { say "${R}远程脚本语法检查未通过,已放弃${N}"; rm -f "$tmp"; return 1; }
  newver=$(sed -n 's/^VER="\([^"]*\)".*/\1/p' "$tmp" | head -1)
  [ -z "$newver" ] && { say "${R}无法识别远程版本,已放弃${N}"; rm -f "$tmp"; return 1; }
  say "  本地: ${C}v$VER${N}   远程: ${C}v$newver${N}"
  if [ "$newver" = "$VER" ]; then
    printf "已是最新,仍强制覆盖? [y/N]: "; read -r yn
    case "$yn" in y|Y) : ;; *) rm -f "$tmp"; say "已取消"; return ;; esac
  else
    printf "更新到 v%s? [Y/n]: " "$newver"; read -r yn
    case "$yn" in n|N) rm -f "$tmp"; say "已取消"; return ;; esac
  fi
  cp "$self" "$self.bak" 2>/dev/null && say "${GR}已备份旧版: $self.bak${N}"
  if cat "$tmp" > "$self" 2>/dev/null; then
    chmod +x "$self" 2>/dev/null; rm -f "$tmp"
    say "${G}已更新到 v$newver${N}"
    if [ -t 0 ] && [ -t 1 ]; then
      say "${GR}正在以新版本重新启动...${N}"; sleep 1
      exec "$self"
    fi
    say "${GR}请重新运行脚本${N}"; exit 0
  else
    say "${R}写入失败(可能无权限)。可手动: sudo cp $tmp $self${N}"; return 1
  fi
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
    say "  ${B}5${N}) 修改来源 IP 限制(from=)"
    say "  ${B}u${N}) 检查更新(从 GitHub)"
    say "  ${B}0${N}) 退出"
    echo
    printf "选择: "; read -r ch
    case "$ch" in
      1)
        say "${GR}粘贴主控的【公钥】单行内容(ssh-ed25519 AAAA... 形式):${N}"
        read -r pub
        [ -z "$pub" ] && { say "取消"; pause; continue; }
        printf "限制来源 IP(主控IP,可逗号分隔多个;留空=不限制): "; read -r fip
        install_pubkey "$pub" "$fip"; pause ;;
      2) gen_key; pause ;;
      3) do_local; pause ;;
      4) uninstall; pause ;;
      5)
        cur=$(current_from)
        say "当前来源限制: ${C}${cur:-无(任意IP)}${N}"
        printf "新的来源 IP(主控IP/CIDR/逗号列表;输入 no 取消限制;回车放弃修改): "; read -r nf
        case "$nf" in
          "") say "未修改" ;;
          no|NO|none) set_from "" ;;
          *) set_from "$nf" ;;
        esac
        pause ;;
      u|U) do_update; pause ;;
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
    # add "公钥" ["来源IP"]
    if [ -n "$2" ]; then install_pubkey "$2" "$3"
    else
      say "${GR}粘贴主控的公钥(单行)后回车:${N}"; read -r pub
      printf "限制来源 IP(主控IP,留空=不限制): "; read -r fip
      install_pubkey "$pub" "$fip"
    fi ;;
  gen|generate) gen_key ;;
  status|local) do_local ;;
  remove|uninstall) uninstall ;;
  setip|from)
    # setip [IP]  ;  setip no 取消限制
    case "${2:-}" in
      "") cur=$(current_from); printf "当前: %s\n新来源 IP(no=取消): " "${cur:-无}"; read -r nf
          case "$nf" in ""|no|NO|none) set_from "" ;; *) set_from "$nf" ;; esac ;;
      no|NO|none) set_from "" ;;
      *) set_from "$2" ;;
    esac ;;
  update|upgrade) do_update ;;
  ""|menu) menu ;;
  -h|--help|help)
    echo "用法: $0 [add [\"公钥\"] [\"来源IP\"]|gen|status|setip [IP]|remove|update|menu]"
    echo "  add [公钥] [IP]   安装受限公钥;给 IP 则用 from= 限制仅该 IP 可用"
    echo "  gen          本机生成密钥对并安装受限公钥,打印私钥给主控"
    echo "  status       查看本机状态"
    echo "  setip [IP]   修改来源 IP 限制(无参数交互;IP=no 取消限制)"
    echo "  remove       卸载受限公钥与采集脚本"
    echo "  update       从 GitHub 更新到最新版"
    echo "  无参数        进入交互菜单" ;;
  *) echo "未知命令: $1 (用 $0 --help)"; exit 1 ;;
esac
