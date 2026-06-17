#!/usr/bin/env bash
# =============================================================
#  nat-monitor.sh  —  零常驻 + 私有拉取式 NAT 监控
#  主控机定时 SSH 进被控机执行内嵌采集脚本,被控机不留任何进程/文件
#  被控离线(连续失败达阈值)发 Telegram 告警,恢复时发恢复通知
#  采集脚本走 sh -s 远程执行,兼容 Debian/Ubuntu/Alpine/OpenWrt
# =============================================================
VER="1.2.0"

# ---------- 路径 ----------
BASE_DIR="${NATMON_DIR:-$HOME/.nat-monitor}"
CONF="$BASE_DIR/config.conf"
NODES="$BASE_DIR/nodes.conf"
STATE_DIR="$BASE_DIR/state"
SNAP_DIR="$BASE_DIR/snap"
KEYS_DIR="$BASE_DIR/keys"
LOG="$BASE_DIR/monitor.log"

# ---------- 颜色 ----------
if [ -t 1 ]; then
  C0='\033[0m'; CB='\033[1m'; CR='\033[31m'; CG='\033[32m'
  CY='\033[33m'; CC='\033[36m'; CGRY='\033[90m'
else
  C0=''; CB=''; CR=''; CG=''; CY=''; CC=''; CGRY=''
fi

# =============================================================
#  内嵌采集脚本(在被控机上以 sh 执行,POSIX 兼容,无落地)
# =============================================================
read -r -d '' COLLECTOR <<'COLLECT'
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
: # 忽略 read 到 EOF 的非零返回

# =============================================================
#  基础函数
# =============================================================
load_conf(){
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$SNAP_DIR" "$KEYS_DIR"
  chmod 700 "$KEYS_DIR" 2>/dev/null
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOF
# ===== nat-monitor 配置 =====
TG_BOT_TOKEN=""           # Telegram Bot Token
TG_CHAT_ID=""             # 接收告警的 chat_id
FAIL_THRESHOLD=3          # 连续拉取失败几次判定离线
SSH_TIMEOUT=8             # SSH 连接超时(秒)
SSH_KEY="\$HOME/.ssh/id_ed25519"   # 默认 SSH 私钥(节点可单独覆盖)
ENABLE_METRIC_ALERTS=1    # 是否开启磁盘等指标告警
DISK_WARN=90              # 磁盘使用率告警阈值(%)
DAEMON_INTERVAL=60        # daemon 模式轮询间隔(秒)
EOF
    echo -e "${CY}已生成默认配置: $CONF${C0}"
  fi
  # shellcheck disable=SC1090
  . "$CONF"
  [ -f "$NODES" ] || : > "$NODES"
}

log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }

safe(){ printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'; }
st_file(){ echo "$STATE_DIR/$(safe "$1").state"; }
snap_file(){ echo "$SNAP_DIR/$(safe "$1").snap"; }

kv_get(){ local f=$1 k=$2; [ -f "$f" ] && sed -n "s/^$k=//p" "$f" | tail -1; }
kv_set(){
  local f=$1 k=$2 v=$3
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ] && grep -q "^$k=" "$f"; then
    sed -i "s|^$k=.*|$k=$v|" "$f"
  else
    echo "$k=$v" >> "$f"
  fi
}

field(){ printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
fmt_up(){ local s=$1; printf '%dd %02dh %02dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }
net_total(){ printf '%s\n' "$1" | awk -F'[= ]' '/^NET=/{rx+=$3;tx+=$4}END{printf "%.2f %.2f",rx/1073741824,tx/1073741824}'; }

# =============================================================
#  Telegram
# =============================================================
tg_send(){
  [ -z "$TG_BOT_TOKEN" ] && return 1
  [ -z "$TG_CHAT_ID" ] && return 1
  command -v curl >/dev/null 2>&1 || { log "curl 缺失,无法发送 TG"; return 1; }
  curl -fsS --max-time 15 \
    -d chat_id="$TG_CHAT_ID" \
    --data-urlencode "text=$1" \
    -d parse_mode="HTML" \
    -d disable_web_page_preview=true \
    "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" >/dev/null 2>&1
}

# =============================================================
#  SSH 拉取(主控 -> 被控,内嵌脚本不落地)
# =============================================================
do_ssh(){
  local host=$1 port=$2 user=$3 key=$4 kopt=""
  key="${key/#\~/$HOME}"
  if [ -n "$key" ]; then kopt="-i $key"
  elif [ -n "$SSH_KEY" ]; then
    local gk="${SSH_KEY/#\~/$HOME}"; kopt="-i $gk"
  fi
  printf '%s\n' "$COLLECTOR" | ssh $kopt -p "${port:-22}" \
    -o ConnectTimeout="${SSH_TIMEOUT:-8}" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ServerAliveInterval=4 -o ServerAliveCountMax=2 \
    "${user:-root}@$host" 'sh -s' 2>/dev/null
}

# =============================================================
#  指标告警(边沿触发,防刷屏)
# =============================================================
metric_alerts(){
  local name=$1 out=$2 f=$3
  [ "${ENABLE_METRIC_ALERTS:-1}" = "1" ] || return
  local dp; dp=$(field DISK_PCT "$out" | tr -d '%')
  [ -n "$dp" ] || return
  local flag; flag=$(kv_get "$f" DISK_ALERTED); [ -z "$flag" ] && flag=0
  if [ "$dp" -ge "${DISK_WARN:-90}" ] 2>/dev/null; then
    if [ "$flag" != "1" ]; then
      tg_send "$(printf '⚠️ <b>%s</b> 磁盘使用率 %s%%\n阈值: %s%%\n时间: %s' \
        "$name" "$dp" "${DISK_WARN:-90}" "$(date '+%F %T %Z')")"
      kv_set "$f" DISK_ALERTED 1
    fi
  else
    [ "$flag" = "1" ] && kv_set "$f" DISK_ALERTED 0
  fi
}

# =============================================================
#  渲染单节点状态
# =============================================================
render_one(){
  local name=$1 out=$2
  local up load cpu mu mt mp du dt dp est svcs rxg txg
  up=$(field UPTIME_S "$out"); load=$(field LOAD "$out"); cpu=$(field CPU "$out")
  mu=$(field MEM_USED_MB "$out"); mt=$(field MEM_TOTAL_MB "$out"); mp=$(field MEM_PCT "$out")
  du=$(field DISK_USED "$out"); dt=$(field DISK_TOTAL "$out"); dp=$(field DISK_PCT "$out")
  est=$(field TCP_EST "$out")
  svcs=$(printf '%s\n' "$out" | sed -n 's/^SVC=//p' | tr '\n' ' ')
  read -r rxg txg <<EOF
$(net_total "$out")
EOF
  [ -n "$up" ] && echo -e "  运行 ${CC}$(fmt_up "$up")${C0}  负载 ${CC}${load}${C0}  CPU ${cpu}核"
  [ -n "$mt" ] && echo -e "  内存 ${mu}/${mt} MB (${mp}%)   磁盘 ${du}/${dt} (${dp})"
  echo -e "  流量 ↓${rxg}G ↑${txg}G   TCP活动 ${est:-?}"
  [ -n "$svcs" ] && echo -e "  服务 ${CG}${svcs}${C0}"
}

# =============================================================
#  处理单节点:拉取 -> 判定 -> 告警
# =============================================================
process_node(){
  local name=$1 host=$2 port=$3 user=$4 key=$5 remark=$6
  [ -z "$remark" ] && remark="$name"
  local label="$remark"; [ "$remark" != "$name" ] && label="$remark ($name)"
  local f out rc prev fails
  f=$(st_file "$name")
  out=$(do_ssh "$host" "$port" "$user" "$key"); rc=$?
  kv_set "$f" LASTCHECK "$(date '+%F %T')"
  prev=$(kv_get "$f" STATUS); [ -z "$prev" ] && prev=UP
  fails=$(kv_get "$f" FAILS); [ -z "$fails" ] && fails=0

  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^HOST='; then
    kv_set "$f" FAILS 0
    kv_set "$f" LASTSEEN "$(date '+%F %T')"
    printf '%s\n' "$out" > "$(snap_file "$name")"
    if [ "$prev" = "DOWN" ]; then
      kv_set "$f" STATUS UP
      tg_send "$(printf '✅ <b>%s</b> 已恢复在线\n主机: %s\n时间: %s' \
        "$label" "$host:${port:-22}" "$(date '+%F %T %Z')")"
      log "RECOVER $name"
      [ "$VERBOSE" = "1" ] && echo -e "  ${CG}↑ 已恢复,发送恢复通知${C0}"
    fi
    metric_alerts "$label" "$out" "$f"
    [ "$VERBOSE" = "1" ] && { echo -e "${CB}● ${CG}$remark${C0} ${CGRY}[$name] ($host)${C0}"; render_one "$name" "$out"; }
  else
    fails=$((fails+1))
    kv_set "$f" FAILS "$fails"
    log "FAIL $name (#$fails) rc=$rc"
    if [ "$fails" -ge "${FAIL_THRESHOLD:-3}" ] && [ "$prev" != "DOWN" ]; then
      kv_set "$f" STATUS DOWN
      local last; last=$(kv_get "$f" LASTSEEN); [ -z "$last" ] && last="未知"
      tg_send "$(printf '🔴 <b>%s</b> 离线告警\n连续失败: %s 次\n最后在线: %s\n主机: %s\n时间: %s' \
        "$label" "$fails" "$last" "$host:${port:-22}" "$(date '+%F %T %Z')")"
      log "ALERT DOWN $name"
      [ "$VERBOSE" = "1" ] && echo -e "${CB}● ${CR}$remark${C0} ${CGRY}[$name] ($host)${C0}  ${CR}离线,已发送告警${C0}"
    else
      [ "$VERBOSE" = "1" ] && echo -e "${CB}● ${CY}$remark${C0} ${CGRY}[$name] ($host)${C0}  拉取失败 (#$fails)"
    fi
  fi
}

# =============================================================
#  遍历所有节点
# =============================================================
foreach_node(){
  local cb=$1
  [ -s "$NODES" ] || { echo -e "${CY}尚未添加任何节点,请先用菜单 3 添加${C0}"; return 1; }
  while IFS='|' read -r name host port user key remark; do
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    "$cb" "$name" "$host" "$port" "$user" "$key" "$remark"
  done < "$NODES"
}

do_run(){ VERBOSE="${VERBOSE:-0}"; load_conf; foreach_node process_node; }

# =============================================================
#  状态总览(读本地快照,不触发拉取)
# =============================================================
show_one_status(){
  local name=$1 host=$2 port=$3 user=$4 key=$5 remark=$6
  [ -z "$remark" ] && remark="$name"
  local f status fails last check snap
  f=$(st_file "$name")
  status=$(kv_get "$f" STATUS); fails=$(kv_get "$f" FAILS)
  last=$(kv_get "$f" LASTSEEN); check=$(kv_get "$f" LASTCHECK)
  local dot color
  if [ -z "$status" ]; then dot="○"; color=$CGRY; status="未检测"
  elif [ "$status" = "DOWN" ]; then dot="●"; color=$CR
  else dot="●"; color=$CG; fi
  echo -e "${color}${dot}${C0} ${CB}${remark}${C0} ${CGRY}[${name}] (${host}:${port:-22})${C0}  状态:${color}${status}${C0}"
  echo -e "   ${CGRY}最后检测:${check:-无}  |  最后在线:${last:-无}  |  连续失败:${fails:-0}${C0}"
  snap=$(snap_file "$name")
  if [ "$status" = "UP" ] || { [ -f "$snap" ] && [ "$status" != "DOWN" ]; }; then
    [ -f "$snap" ] && render_one "$name" "$(cat "$snap")"
  fi
  echo
}

do_status(){
  load_conf
  echo -e "${CB}════ 节点状态总览 ════${C0}  ${CGRY}(本地快照,刷新请运行 run)${C0}\n"
  foreach_node show_one_status
}

# =============================================================
#  本机状态(被控机本地手动查看)
# =============================================================
do_local(){
  local out; out=$(printf '%s\n' "$COLLECTOR" | sh)
  local host; host=$(field HOST "$out"); local t; t=$(field TIME "$out")
  echo -e "${CB}● 本机 ${CG}${host}${C0}  ${CGRY}${t}${C0}"
  render_one "$host" "$out"
}

# =============================================================
#  被控机:安装「受限监控公钥」
#  原理:authorized_keys 用 强制命令 + 禁用转发/pty,
#        该公钥只能触发只读采集脚本,无法取得 shell 或做任何其他操作。
#        兼容 OpenSSH 与 Dropbear(OpenWrt)。
# =============================================================
agent_collect_path(){
  local d
  for d in /usr/local/bin /usr/bin /opt; do
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then echo "$d/volmon-collect"; return; fi
  done
  echo "$HOME/.volmon-collect"
}

agent_write_collector(){
  local p=$1
  { echo '#!/bin/sh'; printf '%s\n' "$COLLECTOR"; } > "$p" || return 1
  chmod 755 "$p"
}

agent_install_pubkey(){
  local pub="$1"
  case "$pub" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *|sk-*\ *) : ;;
    *) echo -e "${CR}公钥格式不对,应以 ssh-ed25519 / ssh-rsa 等开头${C0}"; return 1 ;;
  esac
  local cp; cp=$(agent_collect_path)
  agent_write_collector "$cp" || { echo -e "${CR}无法写入采集脚本到 $cp${C0}"; return 1; }
  local sshdir="$HOME/.ssh" ak="$HOME/.ssh/authorized_keys"
  mkdir -p "$sshdir"; chmod 700 "$sshdir"
  touch "$ak"; chmod 600 "$ak"
  # 限制项:禁端口/agent/X11 转发、禁 pty,强制只跑采集脚本(OpenSSH+Dropbear 通用)
  local opts="command=\"$cp\",no-port-forwarding,no-agent-forwarding,no-x11-forwarding,no-pty"
  local body; body=$(echo "$pub" | awk '{print $2}')
  if [ -n "$body" ] && grep -qF "$body" "$ak" 2>/dev/null; then
    grep -vF "$body" "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"
  fi
  echo "$opts $pub" >> "$ak"
  chmod 600 "$ak"
  echo -e "${CG}已安装受限监控公钥${C0}"
  echo -e "  采集脚本: ${CC}$cp${C0}"
  echo -e "  authorized_keys: ${CC}$ak${C0}"
  echo -e "  ${CGRY}该公钥仅能执行只读采集,无 shell / 无转发 / 无 pty${C0}"
  echo -e "${CGRY}主控侧:用对应私钥添加节点即可拉取(host 填本机 DDNS 域名)${C0}"
}

agent_key_menu(){
  load_conf
  while true; do
    echo
    echo -e "${CB}被控机 · 受限监控公钥${C0}"
    echo -e "  ${CB}1${C0}) 粘贴主控公钥并安装(推荐,私钥不离开主控)"
    echo -e "  ${CB}2${C0}) 本机生成密钥对(打印私钥转交主控)"
    echo -e "  ${CB}u${C0}) 卸载受限公钥与采集脚本"
    echo -e "  ${CB}b${C0}) 返回"
    read -rp "选择: " s
    case "$s" in
      1)
        echo -e "${CGRY}粘贴主控的【公钥】单行内容(ssh-ed25519 AAAA... 形式):${C0}"
        read -r pub
        [ -z "$pub" ] && { echo "取消"; continue; }
        agent_install_pubkey "$pub" ;;
      2)
        if ! command -v ssh-keygen >/dev/null 2>&1; then
          echo -e "${CR}本机无 ssh-keygen(OpenWrt/Dropbear 常见)。请改用方式 1,在主控生成后粘贴公钥。${C0}"
          continue
        fi
        local tmp; tmp=$(mktemp -u "${TMPDIR:-/tmp}/volmon_key.XXXXXX")
        ssh-keygen -t ed25519 -N "" -C "volmon-monitor" -f "$tmp" -q || { echo -e "${CR}生成失败${C0}"; continue; }
        agent_install_pubkey "$(cat "$tmp.pub")"
        echo
        echo -e "${CY}===== 以下私钥请复制到【主控】(菜单9导入),然后从本机抹除 =====${C0}"
        cat "$tmp"
        echo -e "${CY}================================================================${C0}"
        shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
        rm -f "$tmp.pub"
        echo -e "${CGRY}本机私钥已删除,只保留受限公钥${C0}" ;;
      u)
        local ak="$HOME/.ssh/authorized_keys"
        [ -f "$ak" ] && { grep -v 'volmon-collect' "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"; }
        rm -f /usr/local/bin/volmon-collect /usr/bin/volmon-collect /opt/volmon-collect "$HOME/.volmon-collect" 2>/dev/null
        echo -e "${CG}已移除受限公钥行与采集脚本${C0}" ;;
      b|"") break ;;
    esac
  done
}

# =============================================================
#  密钥管理(导入 / 列出 / 删除)
# =============================================================
key_path(){ echo "$KEYS_DIR/$(safe "$1").key"; }

key_verify(){   # $1=文件,校验是否为可用私钥
  command -v ssh-keygen >/dev/null 2>&1 || return 0
  ssh-keygen -y -f "$1" >/dev/null 2>&1
}

key_import(){
  load_conf
  echo -e "${CB}导入私钥${C0}"
  echo "  1) 从本地文件路径复制"
  echo "  2) 直接粘贴密钥内容"
  read -rp "方式 [1/2]: " m
  read -rp "保存为名称(如 hk-nat): " kn
  [ -z "$kn" ] && { echo -e "${CR}名称不能为空${C0}"; return; }
  local dst; dst=$(key_path "$kn")
  if [ -f "$dst" ]; then
    read -rp "已存在同名密钥,覆盖? [y/N]: " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "取消"; return; }
  fi
  case "$m" in
    1)
      read -rp "私钥文件路径: " sp
      sp="${sp/#\~/$HOME}"
      [ -f "$sp" ] || { echo -e "${CR}文件不存在: $sp${C0}"; return; }
      cp "$sp" "$dst" || { echo -e "${CR}复制失败${C0}"; return; }
      ;;
    2)
      echo -e "${CGRY}粘贴完整私钥(含 BEGIN/END 行),结束后单独一行输入 ${CB}EOF${C0}${CGRY} 回车:${C0}"
      : > "$dst"
      while IFS= read -r line; do
        [ "$line" = "EOF" ] && break
        printf '%s\n' "$line" >> "$dst"
      done
      ;;
    *) echo "取消"; return ;;
  esac
  chmod 600 "$dst"
  if key_verify "$dst"; then
    echo -e "${CG}密钥有效,已保存: $dst${C0}"
  else
    echo -e "${CY}已保存但校验未通过(可能带密码短语或非标准格式,仍可使用): $dst${C0}"
  fi
}

key_list(){
  load_conf
  echo -e "${CB}已导入密钥:${C0}"
  if ls "$KEYS_DIR"/*.key >/dev/null 2>&1; then
    local i=0 k
    for k in "$KEYS_DIR"/*.key; do
      i=$((i+1))
      echo -e "  ${i}. ${CC}$(basename "$k" .key)${C0}  ${CGRY}${k}${C0}"
    done
  else
    echo "  (空)"
  fi
}

key_del(){
  load_conf
  key_list
  read -rp "输入要删除的密钥名称: " kn
  [ -z "$kn" ] && return
  local f; f=$(key_path "$kn")
  if [ -f "$f" ]; then rm -f "$f"; echo -e "${CG}已删除: $kn${C0}"
  else echo -e "${CR}未找到${C0}"; fi
}

key_menu(){
  while true; do
    echo; key_list; echo
    echo -e "  ${CB}i${C0}) 导入  ${CB}d${C0}) 删除  ${CB}g${C0}) 设为全局默认密钥  ${CB}b${C0}) 返回"
    read -rp "选择: " s
    case "$s" in
      i) key_import ;;
      d) key_del ;;
      g)
        key_list
        read -rp "设为全局默认的密钥名称: " kn
        [ -z "$kn" ] && continue
        local f; f=$(key_path "$kn")
        [ -f "$f" ] || { echo -e "${CR}未找到${C0}"; continue; }
        kv_set "$CONF" SSH_KEY "\"$f\""; . "$CONF"
        echo -e "${CG}全局默认密钥已设为: $f${C0}" ;;
      b|"") break ;;
    esac
  done
}

# 解析用户输入的密钥(名称 -> 路径;路径原样;空 -> 空)
resolve_key(){
  local k=$1
  [ -z "$k" ] && { echo ""; return; }
  local byname; byname=$(key_path "$k")
  if [ -f "$byname" ]; then echo "$byname"; else echo "${k/#\~/$HOME}"; fi
}

# =============================================================
#  节点管理
# =============================================================
node_add(){
  load_conf
  read -rp "节点名称(唯一标识,英文/数字): " n
  read -rp "备注名(中文友好名,推送显示,留空=同节点名): " rmk
  read -rp "DDNS 域名 / Tailscale IP / 主机: " h
  read -rp "SSH 端口 [22]: " p; p=${p:-22}
  read -rp "SSH 用户 [root]: " u; u=${u:-root}
  echo -e "${CGRY}SSH 私钥: 留空=用全局默认;或输入下方已导入的密钥名;或输入文件路径${C0}"
  key_list
  read -rp "密钥(名称/路径/空): " k
  k=$(resolve_key "$k")
  [ -z "$n" ] || [ -z "$h" ] && { echo -e "${CR}名称和主机不能为空${C0}"; return; }
  [ -z "$rmk" ] && rmk="$n"
  if grep -q "^$n|" "$NODES" 2>/dev/null; then echo -e "${CR}已存在同名节点${C0}"; return; fi
  echo "$n|$h|$p|$u|$k|$rmk" >> "$NODES"
  echo -e "${CG}已添加: ${rmk} [$n]  ($h:$p, key=${k:-全局默认})${C0}"
}

node_set_remark(){
  load_conf
  node_list
  read -rp "要修改备注的节点名称: " n
  [ -z "$n" ] && return
  grep -q "^$n|" "$NODES" || { echo -e "${CR}未找到${C0}"; return; }
  read -rp "新备注名: " rmk
  [ -z "$rmk" ] && { echo "取消"; return; }
  local tmp; tmp=$(mktemp)
  awk -F'|' -v n="$n" -v r="$rmk" 'BEGIN{OFS="|"}{ if($1==n){$6=r} print }' "$NODES" > "$tmp" && mv "$tmp" "$NODES"
  echo -e "${CG}已更新 [$n] 备注为: $rmk${C0}"
}

node_del(){
  load_conf
  node_list
  read -rp "输入要删除的节点名称: " n
  [ -z "$n" ] && return
  if grep -q "^$n|" "$NODES"; then
    sed -i "/^$(safe "$n")|/d;/^$n|/d" "$NODES"
    rm -f "$(st_file "$n")" "$(snap_file "$n")"
    echo -e "${CG}已删除: $n${C0}"
  else
    echo -e "${CR}未找到${C0}"
  fi
}

node_list(){
  load_conf
  echo -e "${CB}已配置节点:${C0}"
  if [ ! -s "$NODES" ]; then echo "  (空)"; return; fi
  local i=0
  while IFS='|' read -r name host port user key remark; do
    [ -z "$name" ] && continue
    [ -z "$remark" ] && remark="$name"
    i=$((i+1))
    echo -e "  ${i}. ${CC}${remark}${C0} ${CGRY}[${name}]${C0}  ${host}:${port:-22}  ${user:-root}  ${CGRY}${key:-默认密钥}${C0}"
  done < "$NODES"
}

# =============================================================
#  Telegram 配置
# =============================================================
tg_config(){
  load_conf
  echo -e "当前: TOKEN=${TG_BOT_TOKEN:-未设置}  CHAT_ID=${TG_CHAT_ID:-未设置}"
  read -rp "Bot Token (回车跳过): " t
  read -rp "Chat ID  (回车跳过): " c
  [ -n "$t" ] && kv_set "$CONF" TG_BOT_TOKEN "\"$t\""
  [ -n "$c" ] && kv_set "$CONF" TG_CHAT_ID "\"$c\""
  . "$CONF"
  echo -e "${CG}已保存${C0}"
}

tg_test(){
  load_conf
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo -e "${CR}请先配置 Token / Chat ID${C0}"; return
  fi
  echo -e "  ${CB}1${C0}) 普通测试消息"
  echo -e "  ${CB}2${C0}) 模拟「离线告警」推送样式"
  echo -e "  ${CB}3${C0}) 模拟「恢复通知」推送样式"
  read -rp "选择: " t
  local now; now=$(date '+%F %T %Z')
  local ok=1
  case "$t" in
    1) tg_send "🔔 nat-monitor 测试消息\n时间: $now"; ok=$? ;;
    2) tg_send "$(printf '🔴 <b>香港家宽 (nat-home)</b> 离线告警\n连续失败: 3 次\n最后在线: %s\n主机: nat.289599.xyz:2222\n时间: %s' "$(date '+%F %T')" "$now")"; ok=$? ;;
    3) tg_send "$(printf '✅ <b>香港家宽 (nat-home)</b> 已恢复在线\n主机: nat.289599.xyz:2222\n时间: %s' "$now")"; ok=$? ;;
    *) echo "取消"; return ;;
  esac
  if [ "$ok" = "0" ]; then echo -e "${CG}发送成功,检查 Telegram${C0}"
  else echo -e "${CR}发送失败,检查 Token/Chat ID/网络(主控需能访问 api.telegram.org)${C0}"; fi
}

tg_menu(){
  while true; do
    load_conf
    echo
    echo -e "${CB}Telegram${C0}  TOKEN:${TG_BOT_TOKEN:+已设置}${TG_BOT_TOKEN:-未设置}  CHAT_ID:${TG_CHAT_ID:-未设置}"
    echo -e "  ${CB}c${C0}) 配置 Token / Chat ID   ${CB}t${C0}) 测试推送   ${CB}b${C0}) 返回"
    read -rp "选择: " s
    case "$s" in c) tg_config ;; t) tg_test ;; b|"") break ;; esac
  done
}

# =============================================================
#  定时任务
# =============================================================
self_path(){ readlink -f "$0" 2>/dev/null || echo "$PWD/$(basename "$0")"; }

shortcut_install(){
  local self target="/usr/local/bin/volmon"
  self=$(self_path)
  chmod +x "$self" 2>/dev/null
  if ln -sf "$self" "$target" 2>/dev/null; then
    echo -e "${CG}已创建快捷命令: ${CB}volmon${C0}${CG} -> $self${C0}"
  elif command -v sudo >/dev/null 2>&1 && sudo ln -sf "$self" "$target" 2>/dev/null; then
    echo -e "${CG}已创建(sudo): ${CB}volmon${C0}"
  else
    local rc="$HOME/.bashrc"
    if ! grep -q "alias volmon=" "$rc" 2>/dev/null; then
      echo "alias volmon='$self'" >> "$rc"
      echo -e "${CY}无权限写 /usr/local/bin,已写入别名到 $rc${C0}"
      echo -e "${CGRY}执行 source $rc 后即可用 volmon${C0}"
    else
      echo -e "${CY}别名已存在于 $rc${C0}"
    fi
    return
  fi
  echo -e "${CGRY}之后任意目录输入 ${C0}${CB}volmon${C0}${CGRY} 即可启动${C0}"
}

shortcut_remove(){
  rm -f /usr/local/bin/volmon 2>/dev/null || sudo rm -f /usr/local/bin/volmon 2>/dev/null
  sed -i '/alias volmon=/d' "$HOME/.bashrc" 2>/dev/null
  echo -e "${CG}已移除快捷命令${C0}"
}

cron_install(){
  load_conf
  local self; self=$(self_path)
  read -rp "每隔几分钟拉取一次 [1]: " m; m=${m:-1}
  local expr="*/$m"; [ "$m" = "1" ] && expr="*"
  local line="$expr * * * * $self run >/dev/null 2>&1 # nat-monitor"
  ( crontab -l 2>/dev/null | grep -v '# nat-monitor'; echo "$line" ) | crontab -
  echo -e "${CG}已安装 cron: 每 ${m} 分钟拉取一次${C0}"
  echo -e "${CGRY}查看: crontab -l${C0}"
}

cron_remove(){
  ( crontab -l 2>/dev/null | grep -v '# nat-monitor' ) | crontab -
  echo -e "${CG}已移除 nat-monitor cron${C0}"
}

do_daemon(){
  load_conf
  echo -e "${CG}daemon 启动,每 ${DAEMON_INTERVAL:-60}s 轮询。Ctrl+C 退出${C0}"
  while true; do
    VERBOSE=0 do_run
    sleep "${DAEMON_INTERVAL:-60}"
  done
}

# =============================================================
#  菜单
# =============================================================
banner(){
  echo -e "${CB}${CC}"
  echo "  ╔══════════════════════════════════════╗"
  echo "  ║   NAT 零常驻拉取监控   v${VER}          ║"
  echo "  ╚══════════════════════════════════════╝"
  echo -e "${C0}${CGRY}  被控机零进程零落地 · 主控 SSH 拉取 · 离线 TG 告警${C0}"
}

menu(){
  load_conf
  while true; do
    echo
    banner
    echo
    echo -e "  ${CB}1${C0}) 拉取一次并显示所有节点状态"
    echo -e "  ${CB}2${C0}) 状态总览(最后检测 / 最后在线)"
    echo -e "  ${CB}3${C0}) 节点管理(增 / 删 / 改备注 / 列)"
    echo -e "  ${CB}4${C0}) Telegram 配置 + 测试推送"
    echo -e "  ${CB}5${C0}) 安装 cron 定时拉取"
    echo -e "  ${CB}6${C0}) 移除 cron"
    echo -e "  ${CB}7${C0}) 被控机功能(本机状态 / 安装受限公钥)"
    echo -e "  ${CB}8${C0}) 前台 daemon 轮询"
    echo -e "  ${CB}9${C0}) 密钥管理(导入 / 列出 / 删除)"
    echo -e "  ${CB}s${C0}) 安装启动快捷命令 volmon"
    echo -e "  ${CB}0${C0}) 退出"
    echo
    read -rp "选择: " ch
    case "$ch" in
      1) VERBOSE=1 do_run ;;
      2) do_status ;;
      3)
        while true; do
          echo; node_list; echo
          echo -e "  ${CB}a${C0}) 添加  ${CB}e${C0}) 改备注  ${CB}d${C0}) 删除  ${CB}b${C0}) 返回"
          read -rp "选择: " s
          case "$s" in a) node_add ;; e) node_set_remark ;; d) node_del ;; b|"") break ;; esac
        done ;;
      4) tg_menu ;;
      5) cron_install ;;
      6) cron_remove ;;
      7)
        while true; do
          echo
          echo -e "  ${CB}v${C0}) 查看本机状态  ${CB}k${C0}) 安装受限监控公钥  ${CB}b${C0}) 返回"
          read -rp "选择: " s
          case "$s" in v) do_local ;; k) agent_key_menu ;; b|"") break ;; esac
        done ;;
      8) do_daemon ;;
      9) key_menu ;;
      s|S) shortcut_install ;;
      0|q) exit 0 ;;
      *) echo -e "${CR}无效选择${C0}" ;;
    esac
  done
}

# =============================================================
#  入口
# =============================================================
case "${1:-}" in
  run)     do_run ;;
  status)  do_status ;;
  local)   do_local ;;
  key)     load_conf; key_menu ;;
  agent-key) load_conf; agent_key_menu ;;
  daemon)  do_daemon ;;
  shortcut) shortcut_install ;;
  test-tg) load_conf; tg_test ;;
  ""|menu) menu ;;
  -h|--help|help)
    echo "用法: $0 [run|status|local|daemon|test-tg|agent-key|shortcut|menu]"
    echo "  无参数        进入交互菜单"
    echo "  run           拉取一次所有节点(供 cron 调用)"
    echo "  status        显示本地快照状态总览(最后检测/在线)"
    echo "  local         显示本机状态(被控机本地查看)"
    echo "  daemon        前台循环轮询"
    echo "  test-tg       Telegram 推送测试"
    echo "  agent-key     被控机:安装受限监控公钥"
    echo "  shortcut      安装 volmon 快捷命令"
    ;;
  *) echo "未知命令: $1 (用 $0 --help)"; exit 1 ;;
esac
