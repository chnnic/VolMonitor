#!/usr/bin/env bash
# =============================================================
#  VolMon.sh  —  零常驻 + 私有拉取式 NAT 监控
#  主控机定时 SSH 进被控机执行内嵌采集脚本,被控机不留任何进程/文件
#  被控离线(连续失败达阈值)发 Telegram 告警,恢复时发恢复通知
#  采集脚本走 sh -s 远程执行,兼容 Debian/Ubuntu/Alpine/OpenWrt
# =============================================================
VER="1.4.14"

# ---------- 更新源 ----------
REPO_RAW="${VOLMON_REPO:-https://raw.githubusercontent.com/chnnic/VolMonitor/main}"
SELF_FILE="VolMon.sh"

# ---------- 路径 ----------
BASE_DIR="${VOLMON_DIR:-${NATMON_DIR:-$HOME/.vol-monitor}}"
OLD_BASE_DIR="$HOME/.nat-monitor"
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

cls(){ [ -t 1 ] && { clear 2>/dev/null || printf '\033[2J\033[3J\033[H'; }; }
pause(){ [ -t 0 ] && { printf '\n%b按回车返回...%b' "$CGRY" "$C0"; read -r _; }; }

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
migrate_dir(){
  # 仅当使用默认新目录、旧目录存在且新目录尚未建立时,自动迁移
  [ "$BASE_DIR" = "$HOME/.vol-monitor" ] || return 0
  [ -d "$OLD_BASE_DIR" ] || return 0
  [ -e "$BASE_DIR" ] && return 0
  if mv "$OLD_BASE_DIR" "$BASE_DIR" 2>/dev/null || { cp -a "$OLD_BASE_DIR" "$BASE_DIR" 2>/dev/null && rm -rf "$OLD_BASE_DIR"; }; then
    # 重写内部存储的绝对路径引用(导入密钥路径等)
    for f in "$BASE_DIR/config.conf" "$BASE_DIR/nodes.conf"; do
      [ -f "$f" ] && sed -i 's#/\.nat-monitor/#/.vol-monitor/#g' "$f"
    done
    echo -e "${CY}已将配置目录迁移: $OLD_BASE_DIR -> $BASE_DIR${C0}"
  fi
}

load_conf(){
  migrate_dir
  mkdir -p "$BASE_DIR" "$STATE_DIR" "$SNAP_DIR" "$KEYS_DIR"
  chmod 700 "$KEYS_DIR" 2>/dev/null
  if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<EOF
# ===== vol-monitor 配置 =====
TG_BOT_TOKEN=""           # Telegram Bot Token
TG_CHAT_ID=""             # 接收告警的 chat_id
FAIL_THRESHOLD=3          # 连续拉取失败几次判定离线
SSH_TIMEOUT=8             # SSH 连接超时(秒)
SSH_KEY="\$HOME/.ssh/id_ed25519"   # 默认 SSH 私钥(节点可单独覆盖)
ENABLE_METRIC_ALERTS=1    # 是否开启磁盘等指标告警
DISK_WARN=90              # 磁盘使用率告警阈值(%)
DAEMON_INTERVAL=30        # daemon 模式轮询间隔(秒)
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

state_migrate_name(){
  local old=$1 new=$2 old_state new_state old_snap new_snap
  [ -z "$old" ] || [ -z "$new" ] || [ "$old" = "$new" ] && return 0
  old_state=$(st_file "$old"); new_state=$(st_file "$new")
  old_snap=$(snap_file "$old"); new_snap=$(snap_file "$new")
  if [ -f "$old_state" ] && [ ! -f "$new_state" ]; then
    mv "$old_state" "$new_state" 2>/dev/null || cp "$old_state" "$new_state" 2>/dev/null || true
  fi
  if [ -f "$old_snap" ] && [ ! -f "$new_snap" ]; then
    mv "$old_snap" "$new_snap" 2>/dev/null || cp "$old_snap" "$new_snap" 2>/dev/null || true
  fi
}

kv_get(){ local f=$1 k=$2; [ -f "$f" ] && sed -n "s/^$k=//p" "$f" | tail -1; }
kv_set(){
  local f=$1 k=$2 v=$3
  local tmp line found=0
  mkdir -p "$(dirname "$f")"
  if [ -f "$f" ]; then
    tmp=$(mktemp) || return 1
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        "$k="*) printf '%s=%s\n' "$k" "$v"; found=1 ;;
        *) printf '%s\n' "$line" ;;
      esac
    done < "$f" > "$tmp" || { rm -f "$tmp"; return 1; }
    [ "$found" = "1" ] || printf '%s=%s\n' "$k" "$v" >> "$tmp"
    mv "$tmp" "$f"
  else
    echo "$k=$v" >> "$f"
  fi
}

state_record_node_meta(){
  local name=$1 host=$2 port=$3 user=$4 key=$5 f
  f=$(st_file "$name")
  kv_set "$f" NODE_HOST "$host"
  kv_set "$f" NODE_PORT "${port:-22}"
  kv_set "$f" NODE_USER "${user:-root}"
  kv_set "$f" NODE_KEY "$key"
}

state_reset_usage(){
  local name=$1 dom=$2 day=$3 cur_rx=$4 cur_tx=$5 cycle_rx=$6 cycle_tx=$7 cycle_rx_used=$8 cycle_tx_used=$9 f
  f=$(st_file "$name")
  [ -n "$dom" ] && kv_set "$f" RESET_DOM "$dom"
  [ -n "$day" ] && kv_set "$f" RESET_DAY "$day"
  [ -n "$day" ] && kv_set "$f" DAY "$day"
  [ -n "$cur_rx" ] && kv_set "$f" RX_BASE "$cur_rx"
  [ -n "$cur_tx" ] && kv_set "$f" TX_BASE "$cur_tx"
  [ -n "$cycle_rx" ] && kv_set "$f" CYCLE_RX_BASE "$cycle_rx"
  [ -n "$cycle_tx" ] && kv_set "$f" CYCLE_TX_BASE "$cycle_tx"
  [ -n "$cycle_rx_used" ] && kv_set "$f" CYCLE_RX_USED "$cycle_rx_used"
  [ -n "$cycle_tx_used" ] && kv_set "$f" CYCLE_TX_USED "$cycle_tx_used"
}

state_adopt_by_endpoint(){
  local name=$1 host=$2 port=$3 user=$4 key=$5 f cur_state cand stem
  cur_state=$(st_file "$name")
  [ -f "$cur_state" ] && return 0
  [ -d "$STATE_DIR" ] || return 0
  port=${port:-22}; user=${user:-root}
  for cand in "$STATE_DIR"/*.state; do
    [ -f "$cand" ] || continue
    [ "$cand" = "$cur_state" ] && continue
    [ "$(kv_get "$cand" NODE_HOST)" = "$host" ] || continue
    [ "$(kv_get "$cand" NODE_PORT)" = "$port" ] || continue
    [ "$(kv_get "$cand" NODE_USER)" = "$user" ] || continue
    [ "$(kv_get "$cand" NODE_KEY)" = "$key" ] || continue
    stem=$(basename "$cand" .state)
    mv "$cand" "$cur_state" 2>/dev/null || cp "$cand" "$cur_state" 2>/dev/null || true
    [ -f "$SNAP_DIR/$stem.snap" ] && mv "$SNAP_DIR/$stem.snap" "$(snap_file "$name")" 2>/dev/null || true
    log "ADOPT_STATE $stem -> $name endpoint=$host:$port"
    break
  done
  f=$(st_file "$name")
  [ -f "$f" ] && state_record_node_meta "$name" "$host" "$port" "$user" "$key"
}

conf_quote(){
  awk -v s="$1" 'BEGIN{gsub(/\047/, "\047\\\047\047", s); printf "\047%s\047", s}'
}

field(){ printf '%s\n' "$2" | sed -n "s/^$1=//p" | head -1; }
date_to_epoch(){ date -d "$1" +%s 2>/dev/null; }
valid_decimal(){ awk -v v="${1:-}" 'BEGIN{exit (v ~ /^([0-9]+([.][0-9]+)?|[.][0-9]+)$/) ? 0 : 1 }'; }
gib_to_bytes(){ awk -v v="${1:-0}" 'BEGIN{if(v=="")v=0; printf "%.0f", v*1073741824}'; }
days_in_month(){
  local ym=$1
  date -d "${ym}-01 +1 month -1 day" '+%d' 2>/dev/null | sed 's/^0*//'
}
monthly_cycle_start(){
  local dom=$1 ref=${2:-$(date '+%F')} y m d dim this prev
  d=${ref##*-}; d=$((10#$d))
  y=${ref%%-*}; m=${ref#*-}; m=${m%%-*}
  dim=$(days_in_month "${y}-${m}"); [ -n "$dim" ] || return 1
  [ "$dom" -gt "$dim" ] && dom=$dim
  this=$(printf '%04d-%02d-%02d' "$y" "$m" "$dom")
  if [ "$d" -lt "$dom" ]; then
    prev=$(date -d "$this -1 month" '+%F' 2>/dev/null) || return 1
    y=${prev%%-*}; m=${prev#*-}; m=${m%%-*}
    dim=$(days_in_month "${y}-${m}"); [ -n "$dim" ] || return 1
    [ "$dom" -gt "$dim" ] && dom=$dim
    printf '%04d-%02d-%02d' "$y" "$m" "$dom"
  else
    printf '%s\n' "$this"
  fi
}
monthly_next_reset(){
  local last=$1 dom=$2 base ny nm dim
  [ -n "$last" ] && [ -n "$dom" ] || return 1
  base=$(date -d "$(date -d "$last" '+%Y-%m-01') +1 month" '+%F' 2>/dev/null) || return 1
  ny=${base%%-*}; nm=${base#*-}; nm=${nm%%-*}
  dim=$(days_in_month "${ny}-${nm}"); [ -n "$dim" ] || return 1
  [ "$dom" -gt "$dim" ] && dom=$dim
  printf '%04d-%02d-%02d' "$ny" "$nm" "$dom"
}
traffic_gb(){
  local rxn=$1 rxb=$2 txn=$3 txb=$4 drx=0 dtx=0
  [ -n "$rxn" ] && [ -n "$rxb" ] && { drx=$((rxn-rxb)); [ "$drx" -lt 0 ] && drx=$rxn; }
  [ -n "$txn" ] && [ -n "$txb" ] && { dtx=$((txn-txb)); [ "$dtx" -lt 0 ] && dtx=$txn; }
  awk -v r="$drx" -v t="$dtx" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}'
}
cycle_usage_gb(){
  local rxn=$1 rxb=$2 rxu=${3:-0} txn=$4 txb=$5 txu=${6:-0} drx=0 dtx=0
  [ -n "$rxn" ] && [ -n "$rxb" ] && drx=$((rxn-rxb))
  [ -n "$txn" ] && [ -n "$txb" ] && dtx=$((txn-txb))
  drx=$((drx + rxu)); dtx=$((dtx + txu))
  [ "$drx" -lt 0 ] && drx=0
  [ "$dtx" -lt 0 ] && dtx=0
  awk -v r="$drx" -v t="$dtx" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}'
}
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
  local host=$1 port=$2 user=$3 key=$4
  local ssh_key=""
  local ssh_args=()
  key="${key/#\~/$HOME}"
  if [ -n "$key" ]; then ssh_key=$key
  elif [ -n "$SSH_KEY" ]; then
    ssh_key="${SSH_KEY/#\~/$HOME}"
  fi
  [ -n "$ssh_key" ] && ssh_args=(-i "$ssh_key")
  printf '%s\n' "$COLLECTOR" | ssh "${ssh_args[@]}" -p "${port:-22}" \
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
  echo -e "  总流量 ↓${rxg}G ↑${txg}G   TCP活动 ${est:-?}"
  [ -n "$svcs" ] && echo -e "  服务 ${CG}${svcs}${C0}"
  return 0
}

# =============================================================
#  处理单节点:拉取 -> 判定 -> 告警
# =============================================================
process_node(){
  local name=$1 host=$2 port=$3 user=$4 key=$5 remark=$6
  [ -z "$remark" ] && remark="$name"
  local label="$remark"; [ "$remark" != "$name" ] && label="$remark ($name)"
  local f out rc prev fails
  state_adopt_by_endpoint "$name" "$host" "$port" "$user" "$key"
  state_record_node_meta "$name" "$host" "$port" "$user" "$key"
  f=$(st_file "$name")
  out=$(do_ssh "$host" "$port" "$user" "$key"); rc=$?
  kv_set "$f" LASTCHECK "$(date '+%F %T')"
  prev=$(kv_get "$f" STATUS); [ -z "$prev" ] && prev=UP
  fails=$(kv_get "$f" FAILS); [ -z "$fails" ] && fails=0
  # 日切:跨天则重置当日失败计数与流量基线
  local today; today=$(date '+%F')
  if [ "$(kv_get "$f" DAY)" != "$today" ]; then
    kv_set "$f" DAY "$today"; kv_set "$f" DFAILS 0
    kv_set "$f" RX_BASE ""; kv_set "$f" TX_BASE ""
  fi

  if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q '^HOST='; then
    kv_set "$f" FAILS 0
    kv_set "$f" LASTSEEN "$(date '+%F %T')"
    printf '%s\n' "$out" > "$(snap_file "$name")"
    # 记录当日流量(累计字节;基线为当天首次成功值)
    local curx cutx
    read -r curx cutx <<EOF
$(printf '%s\n' "$out" | awk -F'[= ]' '/^NET=/{rx+=$3;tx+=$4} END{printf "%.0f %.0f",rx,tx}')
EOF
    # Repair baselines previously saturated by awk's 32-bit %d conversion.
    [ "$(kv_get "$f" RX_BASE)" = "2147483647" ] && kv_set "$f" RX_BASE "$curx"
    [ "$(kv_get "$f" TX_BASE)" = "2147483647" ] && kv_set "$f" TX_BASE "$cutx"
    [ -z "$(kv_get "$f" RX_BASE)" ] && { kv_set "$f" RX_BASE "$curx"; kv_set "$f" TX_BASE "$cutx"; }
    [ -z "$(kv_get "$f" RESET_DAY)" ] && kv_set "$f" RESET_DAY "$(date '+%F')"
    kv_set "$f" RX_NOW "$curx"; kv_set "$f" TX_NOW "$cutx"
    if [ "$prev" = "DOWN" ]; then
      tg_send "$(printf '✅ <b>%s</b> 已恢复在线\n主机: %s\n时间: %s' \
        "$label" "$host:${port:-22}" "$(date '+%F %T %Z')")"
      log "RECOVER $name"
      [ "$VERBOSE" = "1" ] && echo -e "  ${CG}↑ 已恢复,发送恢复通知${C0}"
    fi
    kv_set "$f" STATUS UP
    metric_alerts "$label" "$out" "$f"
    [ "$VERBOSE" = "1" ] && { echo -e "${CB}● ${CG}$remark${C0} ${CGRY}[$name] ($host)${C0}"; render_one "$name" "$out"; }
  else
    fails=$((fails+1))
    kv_set "$f" FAILS "$fails"
    local dfails; dfails=$(kv_get "$f" DFAILS); [ -z "$dfails" ] && dfails=0
    kv_set "$f" DFAILS "$((dfails+1))"
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
  local f status fails last check snap cycle_rx cycle_tx rxn txn cycle_rx_used cycle_tx_used cycle_line
  state_adopt_by_endpoint "$name" "$host" "$port" "$user" "$key"
  f=$(st_file "$name")
  status=$(kv_get "$f" STATUS); fails=$(kv_get "$f" FAILS)
  last=$(kv_get "$f" LASTSEEN); check=$(kv_get "$f" LASTCHECK)
  # 兼容旧状态文件:STATUS 为空时,凭最近一次成功记录推断
  if [ -z "$status" ]; then
    if [ -n "$last" ] && [ "${fails:-0}" = "0" ]; then status="UP"
    elif [ -z "$check" ]; then status="未检测"
    else status="未知"; fi
  fi
  local dot color
  case "$status" in
    UP)     dot="●"; color=$CG ;;
    DOWN)   dot="●"; color=$CR ;;
    未检测) dot="○"; color=$CGRY ;;
    *)      dot="○"; color=$CY ;;
  esac
  echo -e "${color}${dot}${C0} ${CB}${remark}${C0} ${CGRY}[${name}] (${host}:${port:-22})${C0}  状态:${color}${status}${C0}"
  echo -e "   ${CGRY}最后检测:${check:-无}  |  最后在线:${last:-无}  |  连续失败:${fails:-0}${C0}"
  rxn=$(kv_get "$f" RX_NOW); txn=$(kv_get "$f" TX_NOW)
  cycle_rx=$(kv_get "$f" CYCLE_RX_BASE); [ -z "$cycle_rx" ] && cycle_rx=$(kv_get "$f" RX_BASE)
  cycle_tx=$(kv_get "$f" CYCLE_TX_BASE); [ -z "$cycle_tx" ] && cycle_tx=$(kv_get "$f" TX_BASE)
  cycle_rx_used=$(kv_get "$f" CYCLE_RX_USED); [ -z "$cycle_rx_used" ] && cycle_rx_used=0
  cycle_tx_used=$(kv_get "$f" CYCLE_TX_USED); [ -z "$cycle_tx_used" ] && cycle_tx_used=0
  local reset_dom reset_day next_reset due_days
  reset_dom=$(kv_get "$f" RESET_DOM)
  reset_day=$(kv_get "$f" RESET_DAY)
  [ -z "$reset_dom" ] && [ -n "$reset_day" ] && reset_dom=$(date -d "$reset_day" '+%-d' 2>/dev/null)
  if [ -n "$rxn" ] && [ -n "$txn" ]; then
    cycle_line=$(cycle_usage_gb "$rxn" "$cycle_rx" "$cycle_rx_used" "$txn" "$cycle_tx" "$cycle_tx_used")
    if [ -n "$reset_dom" ] && [ -n "$reset_day" ] && [ -n "$next_reset" ]; then :; fi
    if [ -n "$reset_dom" ] && [ -n "$reset_day" ]; then
      next_reset=$(monthly_next_reset "$reset_day" "$reset_dom")
      [ -n "$next_reset" ] && due_days=$(( ( $(date_to_epoch "$next_reset") - $(date '+%s') ) / 86400 )) || due_days=""
      [ -n "$due_days" ] && [ "$due_days" -lt 0 ] && due_days=0
      [ -n "$due_days" ] && echo -e "   ${CGRY}重置周期内已用:${C0} ${cycle_line}   ${CGRY}距重置:${C0} ${due_days}天"
    else
      echo -e "   ${CGRY}重置周期内已用:${C0} ${cycle_line}"
    fi
  fi
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
  return 0
}

# =============================================================
#  被控机:安装「受限监控公钥」
#  原理:authorized_keys 用 强制命令 + 禁用转发/pty,
#        该公钥只能触发只读采集脚本,无法取得 shell 或做任何其他操作。
#        兼容 OpenSSH 与 Dropbear(OpenWrt)。
# =============================================================
node_collect_path(){
  local d
  for d in /usr/local/bin /usr/bin /opt; do
    if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then echo "$d/volmon-collect"; return; fi
  done
  echo "$HOME/.volmon-collect"
}

node_write_collector(){
  local p=$1
  { echo '#!/bin/sh'; printf '%s\n' "$COLLECTOR"; } > "$p" || return 1
  chmod 755 "$p"
}

node_install_pubkey(){
  local pub="$1"
  case "$pub" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-*\ *|sk-*\ *) : ;;
    *) echo -e "${CR}公钥格式不对,应以 ssh-ed25519 / ssh-rsa 等开头${C0}"; return 1 ;;
  esac
  local cp; cp=$(node_collect_path)
  node_write_collector "$cp" || { echo -e "${CR}无法写入采集脚本到 $cp${C0}"; return 1; }
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

node_key_menu(){
  load_conf
  while true; do
    cls; banner "被控机 · 受限监控公钥"; echo
    menu_group "安装"
    menu_item "1/a" "粘贴主控公钥并安装" "推荐,私钥不离开主控"
    menu_item "2/g" "本机生成密钥对" "打印私钥转交主控"
    menu_group "维护"
    menu_item "3/u" "卸载受限公钥与采集脚本"
    menu_item "0/b" "返回"
    echo
    menu_prompt; read -r s || break
    case "$s" in
      1|a|A)
        echo -e "${CGRY}粘贴主控的【公钥】单行内容(ssh-ed25519 AAAA... 形式):${C0}"
        read -r pub
        [ -z "$pub" ] && { echo "取消"; pause; continue; }
        node_install_pubkey "$pub"; pause ;;
      2|g|G)
        if ! command -v ssh-keygen >/dev/null 2>&1; then
          echo -e "${CR}本机无 ssh-keygen(OpenWrt/Dropbear 常见)。请改用方式 1,在主控生成后粘贴公钥。${C0}"
          pause; continue
        fi
        local tmpdir tmp; tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/volmon_key.XXXXXX") || { echo -e "${CR}创建临时目录失败${C0}"; pause; continue; }
        chmod 700 "$tmpdir" 2>/dev/null
        tmp="$tmpdir/key"
        ssh-keygen -t ed25519 -N "" -C "volmon-monitor" -f "$tmp" -q || { echo -e "${CR}生成失败${C0}"; rm -rf "$tmpdir"; pause; continue; }
        node_install_pubkey "$(cat "$tmp.pub")"
        echo
        echo -e "${CY}===== 以下私钥请复制到【主控】(菜单9导入),然后从本机抹除 =====${C0}"
        cat "$tmp"
        echo -e "${CY}================================================================${C0}"
        shred -u "$tmp" 2>/dev/null || rm -f "$tmp"
        rm -f "$tmp.pub"; rmdir "$tmpdir" 2>/dev/null
        echo -e "${CGRY}本机私钥已删除,只保留受限公钥${C0}"; pause ;;
      3|u|U)
        local ak="$HOME/.ssh/authorized_keys"
        [ -f "$ak" ] && { grep -v 'volmon-collect' "$ak" > "$ak.tmp" 2>/dev/null; mv "$ak.tmp" "$ak"; chmod 600 "$ak"; }
        rm -f /usr/local/bin/volmon-collect /usr/bin/volmon-collect /opt/volmon-collect "$HOME/.volmon-collect" 2>/dev/null
        echo -e "${CG}已移除受限公钥行与采集脚本${C0}"; pause ;;
      0|b|B|"") break ;;
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

# 探测主控公网 IP(被控将看到的来源 IP)
detect_pub_ip(){
  local u ip
  for u in https://api.ipify.org https://ifconfig.me/ip https://ip.sb https://ipinfo.io/ip; do
    if command -v curl >/dev/null 2>&1; then
      ip=$(curl -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget >/dev/null 2>&1; then
      ip=$(wget -qO- "$u" 2>/dev/null | tr -d '[:space:]')
    fi
    case "$ip" in
      *.*.*.*|*:*:*) echo "$ip"; return 0 ;;
    esac
  done
  return 1
}

# 由密钥路径取公钥:优先 .pub,否则用 ssh-keygen -y 从私钥派生
pubkey_of(){
  local kf=$1
  [ -z "$kf" ] && return 1
  if [ -f "$kf.pub" ]; then cat "$kf.pub"; return 0; fi
  if command -v ssh-keygen >/dev/null 2>&1 && [ -f "$kf" ]; then
    ssh-keygen -y -f "$kf" 2>/dev/null && return 0
  fi
  return 1
}

# 询问来源 IP 限制(探测+确认),结果存全局 FROM_IP
ask_from_ip(){
  FROM_IP=""
  echo -e "${CGRY}探测主控公网 IP...${C0}"
  local detected; detected=$(detect_pub_ip)
  echo -e "  主控公网 IP: ${CC}${detected:-未检测到}${C0}"
  local ans
  read -rp "限制被控仅此 IP 访问(回车=检测值;输入 IP/CIDR/逗号列表;no=不限制): " ans
  case "$ans" in
    no|NO|n|N) FROM_IP="" ;;
    "") FROM_IP="$detected" ;;
    *) FROM_IP="$ans" ;;
  esac
}

# 打印被控一键安装命令($1=公钥 $2=来源IP $3=节点名(给出则存盘))
print_node_install(){
  local pub=$1 fromip=$2 name=$3 fromarg=""
  [ -n "$fromip" ] && fromarg=" \"$fromip\""
  echo -e "${CB}被控机安装(任选其一,直接在被控机执行):${C0}"
  echo -e "${CY}① 一键拉取并安装(curl):${C0}"
  echo -e "   curl -fsSL $REPO_RAW/volmon-node.sh | sh -s -- add \"$pub\"$fromarg"
  echo -e "${CY}② 一键拉取并安装(wget):${C0}"
  echo -e "   wget -qO- $REPO_RAW/volmon-node.sh | sh -s -- add \"$pub\"$fromarg"
  echo -e "${CY}③ 已有 volmon-node.sh 时:${C0}"
  echo -e "   ./volmon-node.sh add \"$pub\"$fromarg"
  if [ -n "$name" ]; then
    local cmdf="$BASE_DIR/install-$name.txt"
    {
      echo "# 被控机安装命令(任选其一)"
      echo "curl -fsSL $REPO_RAW/volmon-node.sh | sh -s -- add \"$pub\"$fromarg"
      echo "wget -qO- $REPO_RAW/volmon-node.sh | sh -s -- add \"$pub\"$fromarg"
    } > "$cmdf" 2>/dev/null && echo -e "${CGRY}(命令已存到 $cmdf)${C0}"
  fi
}

# 新建密钥对(私钥存 keys/,打印公钥+一键命令);成功经 GEN_KEY_PATH 返回路径
key_generate(){
  load_conf
  GEN_KEY_PATH=""
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo -e "${CR}本机无 ssh-keygen,无法生成密钥${C0}"; return 1
  fi
  local kn=$1
  [ -z "$kn" ] && { read -rp "新密钥名称: " kn; }
  [ -z "$kn" ] && { echo -e "${CR}名称不能为空${C0}"; return 1; }
  kn=$(safe "$kn")
  local f; f=$(key_path "$kn")
  if [ -f "$f" ]; then
    read -rp "已存在同名密钥 $kn,覆盖? [y/N]: " yn
    case "$yn" in y|Y) rm -f "$f" "$f.pub" ;; *) echo "取消"; return 1 ;; esac
  fi
  ssh-keygen -t ed25519 -N "" -C "volmon-$kn" -f "$f" -q || { echo -e "${CR}生成失败${C0}"; return 1; }
  chmod 600 "$f"
  GEN_KEY_PATH="$f"
  local pub; pub=$(cat "$f.pub")
  ask_from_ip
  echo -e "${CG}已生成密钥对: $f${C0}"
  echo -e "${CGRY}私钥留在主控用于拉取;被控机装下面这把公钥即可。${C0}"
  echo -e "${CC}公钥:${C0} $pub"
  [ -n "$FROM_IP" ] && echo -e "${CC}来源限制:${C0} from=\"$FROM_IP\"  ${CGRY}(仅此 IP 能用此钥)${C0}"
  echo
  print_node_install "$pub" "$FROM_IP" "$kn"
  return 0
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
    cls; banner "密钥管理"; echo; key_list; echo
    menu_group "操作"
    menu_item "1/i" "导入私钥"
    menu_item "2/n" "新建密钥对"
    menu_item "3/d" "删除密钥"
    menu_item "4/g" "设为全局默认密钥"
    menu_item "0/b" "返回"
    echo
    menu_prompt; read -r s || break
    case "$s" in
      1|i|I) key_import; pause ;;
      2|n|N) key_generate; pause ;;
      3|d|D) key_del; pause ;;
      4|g|G)
        key_list
        read -rp "设为全局默认的密钥名称: " kn
        [ -z "$kn" ] && continue
        local f; f=$(key_path "$kn")
        [ -f "$f" ] || { echo -e "${CR}未找到${C0}"; pause; continue; }
        kv_set "$CONF" SSH_KEY "$(conf_quote "$f")"
        # shellcheck disable=SC1090
        . "$CONF"
        echo -e "${CG}全局默认密钥已设为: $f${C0}"; pause ;;
      0|b|B|"") break ;;
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
  GEN_KEY_PATH=""
  read -rp "节点名称(唯一标识,英文/数字): " n
  read -rp "备注名(中文友好名,推送显示,留空=同节点名): " rmk
  read -rp "DDNS 域名 / Tailscale IP / 主机: " h
  read -rp "SSH 端口 [22]: " p; p=${p:-22}
  read -rp "SSH 用户 [root]: " u; u=${u:-root}
  echo -e "${CGRY}SSH 私钥: 留空=用全局默认;或输入密钥名 / 文件路径;或输入 ${C0}${CB}new${C0}${CGRY} 新建密钥对${C0}"
  key_list
  if ! ls "$KEYS_DIR"/*.key >/dev/null 2>&1; then
    local gk="${SSH_KEY/#\~/$HOME}"
    [ -n "$gk" ] && [ -f "$gk" ] \
      && echo -e "${CGRY}  (尚未导入密钥;留空将使用全局默认 ${gk};或输入 new 新建)${C0}" \
      || echo -e "${CY}  尚未导入任何密钥。可输入 ${CB}new${C0}${CY} 现场新建密钥对,或填私钥文件路径。${C0}"
  fi
  read -rp "密钥(名称/路径/new/空): " k
  case "$k" in
    new|NEW|新建|n|N)
      key_generate "$n"
      if [ -n "$GEN_KEY_PATH" ]; then k="$GEN_KEY_PATH"; else k=""; fi
      ;;
    *) k=$(resolve_key "$k") ;;
  esac
  [ -z "$n" ] || [ -z "$h" ] && { echo -e "${CR}名称和主机不能为空${C0}"; return; }
  [ -z "$rmk" ] && rmk="$n"
  if grep -q "^$n|" "$NODES" 2>/dev/null; then echo -e "${CR}已存在同名节点${C0}"; return; fi
  echo "$n|$h|$p|$u|$k|$rmk" >> "$NODES"
  echo -e "${CG}已添加: ${rmk} [$n]  ($h:$p, key=${k:-全局默认})${C0}"
  # 校验该节点实际使用的密钥是否存在,不存在则提醒
  local eff="$k"
  [ -z "$eff" ] && eff="${SSH_KEY/#\~/$HOME}"
  if [ -z "$eff" ]; then
    echo -e "${CY}⚠ 未指定密钥且无全局默认密钥。请到菜单 9 导入主控私钥,或为本节点指定密钥。${C0}"
  elif [ ! -f "$eff" ]; then
    echo -e "${CY}⚠ 密钥文件不存在: ${eff}${C0}"
    echo -e "${CGRY}  → 到菜单 9「密钥管理」导入私钥(导入后可在此填密钥名或设为全局默认),否则拉取会失败。${C0}"
  fi
  # 若用的是「已存在的密钥」(非刚 new 生成,key_generate 已自带提示),也给出被控一键安装命令
  if [ -n "$eff" ] && [ -f "$eff" ] && [ "$k" != "$GEN_KEY_PATH" ]; then
    local pub; pub=$(pubkey_of "$eff")
    if [ -n "$pub" ]; then
      echo
      ask_from_ip
      echo
      print_node_install "$pub" "$FROM_IP" "$n"
    else
      echo -e "${CGRY}(无法从该密钥导出公钥,跳过被控一键命令;.pub 缺失且 ssh-keygen 不可用)${C0}"
    fi
  fi
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

node_rename(){
  load_conf
  node_list
  read -rp "要重命名的节点名称: " old
  [ -z "$old" ] && return
  grep -q "^$old|" "$NODES" || { echo -e "${CR}未找到${C0}"; return; }
  read -rp "新节点名称(唯一标识,英文/数字): " new
  [ -z "$new" ] && { echo "取消"; return; }
  case "$new" in *'|'*|*' '*)
    echo -e "${CR}节点名称不能包含空格或 |${C0}"
    return
    ;;
  esac
  if grep -q "^$new|" "$NODES" 2>/dev/null; then
    echo -e "${CR}已存在同名节点${C0}"
    return
  fi
  read -rp "新备注名(留空=保持原备注): " new_remark
  local tmp; tmp=$(mktemp)
  awk -F'|' -v old="$old" -v new="$new" -v r="$new_remark" 'BEGIN{OFS="|"}{
    if($1==old){$1=new; if(r!=""){$6=r}}
    print
  }' "$NODES" > "$tmp" && mv "$tmp" "$NODES"
  state_migrate_name "$old" "$new"
  [ -f "$BASE_DIR/install-$old.txt" ] && [ ! -f "$BASE_DIR/install-$new.txt" ] \
    && mv "$BASE_DIR/install-$old.txt" "$BASE_DIR/install-$new.txt" 2>/dev/null || true
  log "RENAME $old -> $new"
  echo -e "${CG}已重命名: $old -> $new，并迁移状态/快照${C0}"
}

node_migrate_state(){
  load_conf
  node_list
  echo
  echo -e "${CB}已有状态文件:${C0}"
  if ls "$STATE_DIR"/*.state >/dev/null 2>&1; then
    local sf
    for sf in "$STATE_DIR"/*.state; do
      echo -e "  ${CC}$(basename "$sf" .state)${C0}"
    done
  else
    echo "  (空)"
  fi
  read -rp "旧状态名称: " old
  read -rp "迁移到当前节点名称: " target
  [ -z "$old" ] || [ -z "$target" ] && { echo "取消"; return; }
  [ -f "$(st_file "$old")" ] || { echo -e "${CR}未找到旧状态: $old${C0}"; return; }
  grep -q "^$target|" "$NODES" || { echo -e "${CR}未找到当前节点: $target${C0}"; return; }
  state_migrate_name "$old" "$target"
  local line host port user key
  line=$(grep "^$target|" "$NODES" | head -1)
  IFS='|' read -r _ host port user key _ <<< "$line"
  state_record_node_meta "$target" "$host" "$port" "$user" "$key"
  log "MIGRATE_STATE $old -> $target"
  echo -e "${CG}已迁移旧状态: $old -> $target${C0}"
}

node_reset_usage(){
  load_conf
  node_list
  read -rp "要重置流量基准的节点名称: " n
  [ -z "$n" ] && return
  grep -q "^$n|" "$NODES" || { echo -e "${CR}未找到${C0}"; return; }
  local f dom day cur_rx cur_tx cycle_rx_used cycle_tx_used next reset_day
  f=$(st_file "$n")
  local dom_default
  local existing_reset_day
  dom_default=$(kv_get "$f" RESET_DOM)
  existing_reset_day=$(kv_get "$f" RESET_DAY)
  if [ -z "$dom_default" ] && [ -n "$existing_reset_day" ]; then
    dom_default=$(date -d "$existing_reset_day" '+%-d' 2>/dev/null)
  fi
  [ -z "$dom_default" ] && dom_default=$(date '+%-d')
  read -rp "每月重置日 [1-31, 默认 ${dom_default}]: " dom
  dom=${dom:-$dom_default}
  case "$dom" in ''|*[!0-9]*|0) echo -e "${CR}重置日需为 1-31${C0}"; return ;; esac
  [ "$dom" -gt 31 ] && { echo -e "${CR}重置日需为 1-31${C0}"; return; }
  cur_rx=$(kv_get "$f" RX_NOW); cur_tx=$(kv_get "$f" TX_NOW)
  read -rp "重置起算日已用下行流量 [GiB, 默认 0]: " cycle_rx_used
  read -rp "重置起算日已用上行流量 [GiB, 默认 0]: " cycle_tx_used
  [ -z "$cycle_rx_used" ] && cycle_rx_used=0
  [ -z "$cycle_tx_used" ] && cycle_tx_used=0
  valid_decimal "$cycle_rx_used" || { echo -e "${CR}下行流量需为数字${C0}"; return; }
  valid_decimal "$cycle_tx_used" || { echo -e "${CR}上行流量需为数字${C0}"; return; }
  cycle_rx_used=$(gib_to_bytes "$cycle_rx_used")
  cycle_tx_used=$(gib_to_bytes "$cycle_tx_used")
  reset_day=$(monthly_cycle_start "$dom")
  [ -z "$reset_day" ] && { echo -e "${CR}无法计算当前周期起算日${C0}"; return; }
  state_reset_usage "$n" "$dom" "$reset_day" "$cur_rx" "$cur_tx" "" "" "$cycle_rx_used" "$cycle_tx_used"
  next=$(monthly_next_reset "$reset_day" "$dom")
  log "RESET_USAGE $n dom=$dom day=$reset_day next=${next:-unknown}"
  echo -e "${CG}已重置 [$n] 流量基准，每月重置日: $(printf '%02d' "$dom") 号${C0}"
  echo -e "${CGRY}当前周期起算日: $reset_day${C0}"
  echo -e "${CGRY}起算时已用: ↓$(awk -v v="$cycle_rx_used" 'BEGIN{printf "%.2fG",v/1073741824}') ↑$(awk -v v="$cycle_tx_used" 'BEGIN{printf "%.2fG",v/1073741824}')${C0}"
  [ -n "$next" ] && echo -e "${CGRY}下次重置: $next${C0}"
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
  [ -n "$t" ] && kv_set "$CONF" TG_BOT_TOKEN "$(conf_quote "$t")"
  [ -n "$c" ] && kv_set "$CONF" TG_CHAT_ID "$(conf_quote "$c")"
  # shellcheck disable=SC1090
  . "$CONF"
  echo -e "${CG}已保存${C0}"
}

tg_test(){
  load_conf
  if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    echo -e "${CR}请先配置 Token / Chat ID${C0}"; return
  fi
  menu_group "测试消息"
  menu_item "1/n" "普通测试消息"
  menu_item "2/d" "模拟离线告警"
  menu_item "3/r" "模拟恢复通知"
  echo
  menu_prompt; read -r t
  local now; now=$(date '+%F %T %Z')
  local ok=1
  case "$t" in
    1|n|N) tg_send "🔔 VolMonitor 测试消息\n时间: $now"; ok=$? ;;
    2|d|D) tg_send "$(printf '🔴 <b>香港家宽 (nat-home)</b> 离线告警\n连续失败: 3 次\n最后在线: %s\n主机: nat.example.xyz:2222\n时间: %s' "$(date '+%F %T')" "$now")"; ok=$? ;;
    3|r|R) tg_send "$(printf '✅ <b>香港家宽 (nat-home)</b> 已恢复在线\n主机: nat.example.xyz:2222\n时间: %s' "$now")"; ok=$? ;;
    *) echo "取消"; return ;;
  esac
  if [ "$ok" = "0" ]; then echo -e "${CG}发送成功,检查 Telegram${C0}"
  else echo -e "${CR}发送失败,检查 Token/Chat ID/网络(主控需能访问 api.telegram.org)${C0}"; fi
}

tg_menu(){
  while true; do
    load_conf
    cls; banner "Telegram 配置 + 测试"; echo
    echo -e "  ${CGRY}Token:${C0} ${TG_BOT_TOKEN:+已设置}${TG_BOT_TOKEN:-未设置}   ${CGRY}Chat ID:${C0} ${TG_CHAT_ID:-未设置}"
    menu_group "Telegram"
    menu_item "1/c" "配置 Token / Chat ID"
    menu_item "2/t" "测试推送"
    menu_item "3/r" "每日日报"
    menu_item "0/b" "返回"
    echo
    menu_prompt; read -r s || break
    case "$s" in
      1|c|C) tg_config; pause ;;
      2|t|T) tg_test; pause ;;
      3|r|R) report_menu ;;
      0|b|B|"") break ;;
    esac
  done
}

# =============================================================
#  定时任务
# =============================================================
self_path(){ readlink -f "$0" 2>/dev/null || echo "$PWD/$(basename "$0")"; }

do_update(){
  local url="$REPO_RAW/$SELF_FILE" self tmp newver
  self=$(self_path)
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo -e "${CR}需要 curl 或 wget 才能更新${C0}"; return 1
  fi
  tmp=$(mktemp)
  echo -e "${CGRY}下载: $url${C0}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 30 "$url" -o "$tmp" || { echo -e "${CR}下载失败${C0}"; rm -f "$tmp"; return 1; }
  else
    wget -qO "$tmp" "$url" || { echo -e "${CR}下载失败${C0}"; rm -f "$tmp"; return 1; }
  fi
  # 完整性校验:必须是脚本且语法正确
  head -1 "$tmp" | grep -q '^#!' || { echo -e "${CR}下载内容异常(非脚本),已放弃${C0}"; rm -f "$tmp"; return 1; }
  bash -n "$tmp" 2>/dev/null || { echo -e "${CR}远程脚本语法检查未通过,已放弃${C0}"; rm -f "$tmp"; return 1; }
  newver=$(sed -n 's/^VER="\([^"]*\)".*/\1/p' "$tmp" | head -1)
  [ -z "$newver" ] || ! grep -q 'VolMonitor\|nat-monitor\|零常驻' "$tmp" \
    && { [ -z "$newver" ] && { echo -e "${CR}无法识别远程版本,已放弃${C0}"; rm -f "$tmp"; return 1; }; }
  echo -e "  本地: ${CC}v$VER${C0}   远程: ${CC}v$newver${C0}"
  if [ "$newver" = "$VER" ]; then
    read -rp "已是最新,仍强制覆盖? [y/N]: " yn
    case "$yn" in y|Y) : ;; *) rm -f "$tmp"; echo "已取消"; return ;; esac
  else
    read -rp "更新到 v$newver? [Y/n]: " yn
    case "$yn" in n|N) rm -f "$tmp"; echo "已取消"; return ;; esac
  fi
  cp "$self" "$self.bak" 2>/dev/null && echo -e "${CGRY}已备份旧版: $self.bak${C0}"
  if cat "$tmp" > "$self" 2>/dev/null; then
    chmod +x "$self" 2>/dev/null; rm -f "$tmp"
    echo -e "${CG}已更新到 v$newver${C0}"
    if [ -t 0 ] && [ -t 1 ]; then
      echo -e "${CGRY}正在以新版本重新启动...${C0}"; sleep 1
      exec "$self"
    fi
    echo -e "${CGRY}请重新运行脚本${C0}"; exit 0
  else
    echo -e "${CR}写入失败(可能无权限)。可手动: sudo cp $tmp $self${C0}"
    return 1
  fi
}

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
  local line="$expr * * * * $self run >/dev/null 2>&1 # vol-monitor"
  ( crontab -l 2>/dev/null | grep -v '# nat-monitor' | grep -v '# vol-monitor'; echo "$line" ) | crontab -
  echo -e "${CG}已安装 cron: 每 ${m} 分钟拉取一次${C0}"
  echo -e "${CGRY}查看: crontab -l${C0}"
}

cron_remove(){
  ( crontab -l 2>/dev/null | grep -v '# nat-monitor' | grep -v '# vol-monitor' ) | crontab -
  echo -e "${CG}已移除 vol-monitor cron${C0}"
}

do_daemon(){
  load_conf
  local cyc=0 iv="${DAEMON_INTERVAL:-30}"
  while true; do
    cyc=$((cyc+1))
    cls
    banner "daemon 实时轮询"
    echo -e "${CGRY}第 ${cyc} 轮 · $(date '+%F %T') · 间隔 ${iv}s · Ctrl+C 退出${C0}"
    echo
    VERBOSE=1 do_run
    # 汇总在线/离线
    local up=0 down=0 other=0 name rest st
    while IFS='|' read -r name rest; do
      [ -z "$name" ] && continue
      [ "${name#\#}" = "$name" ] || continue
      st=$(kv_get "$(st_file "$name")" STATUS)
    case "$st" in
      UP) up=$((up+1)) ;;
      DOWN) down=$((down+1)) ;;
      *) other=$((other+1)) ;;
    esac
    done < "$NODES"
    local nxt; nxt=$(date '+%H:%M:%S' -d "+${iv} sec" 2>/dev/null)
    echo
    echo -e "${CC}────────────────────────────────────────${C0}"
    echo -e "汇总: ${CG}在线 ${up}${C0}  ${CR}离线 ${down}${C0}  其他 ${other}${nxt:+   下次轮询 $nxt}"
    sleep "$iv"
  done
}

# =============================================================
#  每日日报:汇总当日流量 / 失败次数等并推送 TG
# =============================================================
do_report(){
  load_conf
  [ -s "$NODES" ] || { echo "无节点"; return; }
  # 发送前实时刷新各节点(更新最新流量/状态,基线不变)
  [ -t 1 ] && echo -e "${CGRY}正在刷新各节点最新数据...${C0}"
  VERBOSE=0 do_run
  local today now_epoch; today=$(date '+%F'); now_epoch=$(date '+%s')
  local nodes=0 up=0 down=0 trx=0 ttx=0 cycle_trx=0 cycle_ttx=0 tdf=0 lines="" name host port user key remark
  while IFS='|' read -r name host port user key remark; do
    [ -z "$name" ] && continue
    [ "${name#\#}" = "$name" ] || continue
    [ -z "$remark" ] && remark="$name"
    nodes=$((nodes+1))
    local f st df rxb txb rxn txn drx dtx rxu txu emoji gline cycle_line reset_dom reset_day next_reset due_days due_txt
    f=$(st_file "$name")
    st=$(kv_get "$f" STATUS)
    df=$(kv_get "$f" DFAILS); [ -z "$df" ] && df=0
    rxb=$(kv_get "$f" RX_BASE); txb=$(kv_get "$f" TX_BASE)
    rxn=$(kv_get "$f" RX_NOW);  txn=$(kv_get "$f" TX_NOW)
    rxu=$(kv_get "$f" CYCLE_RX_USED); [ -z "$rxu" ] && rxu=0
    txu=$(kv_get "$f" CYCLE_TX_USED); [ -z "$txu" ] && txu=0
    reset_dom=$(kv_get "$f" RESET_DOM)
    reset_day=$(kv_get "$f" RESET_DAY)
    [ -z "$reset_dom" ] && [ -n "$reset_day" ] && reset_dom=$(date -d "$reset_day" '+%-d' 2>/dev/null)
    drx=0; dtx=0
    if [ -n "$rxn" ] && [ -n "$rxb" ]; then drx=$((rxn-rxb)); [ "$drx" -lt 0 ] && drx=$rxn; fi
    if [ -n "$txn" ] && [ -n "$txb" ]; then dtx=$((txn-txb)); [ "$dtx" -lt 0 ] && dtx=$txn; fi
    cycle_trx=$((cycle_trx + drx + rxu))
    cycle_ttx=$((cycle_ttx + dtx + txu))
    due_txt=""
    if [ -n "$reset_dom" ] && [ -n "$reset_day" ]; then
      next_reset=$(monthly_next_reset "$reset_day" "$reset_dom")
      if [ -n "$next_reset" ]; then
        due_days=$(( ( $(date_to_epoch "$next_reset") - now_epoch ) / 86400 ))
        [ "$due_days" -lt 0 ] && due_days=0
        due_txt=" · 距重置 ${due_days}天"
      fi
    fi
    trx=$((trx+drx)); ttx=$((ttx+dtx)); tdf=$((tdf+df))
    case "$st" in
      DOWN) emoji="🔴"; down=$((down+1)) ;;
      UP)   emoji="🟢"; up=$((up+1)) ;;
      *)    emoji="⚪" ;;
    esac
    gline=$(awk -v r="$drx" -v t="$dtx" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}')
    cycle_line=$(awk -v r="$rxu" -v t="$txu" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}')
    lines="$lines
$emoji <b>$remark</b>  今日 $gline  周期已用 $cycle_line  失败 ${df}次${due_txt}"
  done < "$NODES"
  local tot; tot=$(awk -v r="$trx" -v t="$ttx" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}')
  local cycle_tot; cycle_tot=$(awk -v r="$cycle_trx" -v t="$cycle_ttx" 'BEGIN{printf "↓%.2fG ↑%.2fG",r/1073741824,t/1073741824}')
  local msg
  msg=$(printf '📊 <b>VolMonitor 日报</b>  %s\n节点 %d · 在线 %d · 离线 %d\n合计今日流量 %s · 重置周期内已用 %s · 失败 %d次\n————————————%s' \
    "$today" "$nodes" "$up" "$down" "$tot" "$cycle_tot" "$tdf" "$lines")
  [ -t 1 ] && printf '%s\n' "$msg" | sed 's/<[^>]*>//g'
  if tg_send "$msg"; then log "REPORT sent"; [ -t 1 ] && echo -e "${CG}日报已推送${C0}"
  else log "REPORT send failed"; [ -t 1 ] && echo -e "${CR}推送失败(检查 TG 配置/网络)${C0}"; fi
}

report_install(){
  load_conf
  local self; self=$(self_path)
  read -rp "每日日报时间 HH:MM [23:59]: " t; t=${t:-23:59}
  case "$t" in
    [0-9]*:[0-9]*) : ;;
    *) echo -e "${CR}时间格式应为 HH:MM${C0}"; return ;;
  esac
  local hh=${t%%:*} mm=${t##*:}
  hh=$((10#$hh)); mm=$((10#$mm))
  local line="$mm $hh * * * $self report >/dev/null 2>&1 # volmon-report"
  ( crontab -l 2>/dev/null | grep -v '# volmon-report'; echo "$line" ) | crontab -
  kv_set "$CONF" DAILY_REPORT 1
  echo -e "${CG}已启用每日日报: 每天 $(printf '%02d:%02d' "$hh" "$mm") 推送${C0}"
  echo -e "${CGRY}(依赖 cron 与已配置的 Telegram)${C0}"
}

report_remove(){
  ( crontab -l 2>/dev/null | grep -v '# volmon-report' ) | crontab -
  kv_set "$CONF" DAILY_REPORT 0
  echo -e "${CG}已关闭每日日报${C0}"
}

report_menu(){
  while true; do
    load_conf
    cls; banner "每日日报"
    local cur; cur=$(crontab -l 2>/dev/null | grep '# volmon-report')
    echo -e "  当前状态: ${cur:+${CG}已启用${C0}}${cur:-${CGRY}未启用${C0}}"
    [ -n "$cur" ] && echo -e "  ${CGRY}$(echo "$cur" | awk '{print $2":"$1}' | sed 's/:/ 时 /;s/$/ 分/')${C0}"
    menu_group "日报"
    menu_item "1/e" "启用 / 设置时间"
    menu_item "2/x" "关闭日报"
    menu_item "3/t" "立即发送一次"
    menu_item "0/b" "返回"
    echo
    menu_prompt; read -r s || break
    case "$s" in
      1|e|E) report_install; pause ;;
      2|x|X) report_remove; pause ;;
      3|t|T) do_report; pause ;;
      0|b|B|"") break ;;
    esac
  done
}

# =============================================================
#  菜单
# =============================================================
banner(){   # $1 = 可选副标题(子菜单名)
  echo
  echo -e "${CC}  ────────────────────────────────────────${C0}"
  echo -e "${CB}${CC}  VolMonitor 零常驻拉取监控${C0}   ${CGRY}v${VER}${C0}"
  if [ -n "$1" ]; then
    echo -e "${CB}  › $1${C0}"
  else
    echo -e "${CGRY}  被控零落地 · 主控 SSH 拉取 · 离线 TG 告警${C0}"
  fi
  echo -e "${CC}  ────────────────────────────────────────${C0}"
}

menu_group(){ echo -e "\n  ${CGRY}── $1${C0}"; }
menu_item(){
  local key=$1 label=$2 hint=${3:-}
  printf '  %b%-6s%b %s' "$CB$CC" "$key" "$C0" "$label"
  [ -n "$hint" ] && printf ' %b- %s%b' "$CGRY" "$hint" "$C0"
  printf '\n'
}
menu_prompt(){ printf '%b选择命令%b > ' "$CB" "$C0"; }

is_int(){ case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

config_menu(){
  while true; do
    load_conf
    cls; banner "设置 config"
    echo -e "  ${CGRY}配置文件: $CONF${C0}"
    menu_group "运行参数"
    menu_item "1/f" "连续失败判离线阈值" "FAIL_THRESHOLD=$FAIL_THRESHOLD"
    menu_item "2/t" "SSH 连接超时" "SSH_TIMEOUT=${SSH_TIMEOUT}s"
    menu_item "3/k" "全局默认私钥" "SSH_KEY=$SSH_KEY"
    menu_item "4/a" "磁盘告警开关" "ENABLE_METRIC_ALERTS=$ENABLE_METRIC_ALERTS"
    menu_item "5/d" "磁盘告警阈值" "DISK_WARN=${DISK_WARN}%"
    menu_item "6/i" "daemon 轮询间隔" "DAEMON_INTERVAL=${DAEMON_INTERVAL}s"
    menu_group "文件"
    menu_item "7/e" "用编辑器打开配置"
    menu_item "8/r" "恢复操作类设置为默认" "不影响 Telegram"
    menu_item "0/b" "返回"
    echo
    menu_prompt; read -r s || break
    case "$s" in
      1|f|F) read -rp "新阈值(正整数): " v; is_int "$v" && kv_set "$CONF" FAIL_THRESHOLD "$v" || echo -e "${CR}需正整数${C0}"; pause ;;
      2|t|T) read -rp "新超时秒数(正整数): " v; is_int "$v" && kv_set "$CONF" SSH_TIMEOUT "$v" || echo -e "${CR}需正整数${C0}"; pause ;;
      3|k|K) read -rp "私钥路径(可填密钥名/路径,留空跳过): " v
         [ -n "$v" ] && { v=$(resolve_key "$v"); kv_set "$CONF" SSH_KEY "$(conf_quote "$v")"; echo -e "${CG}已设为 $v${C0}"; }
         pause ;;
      4|a|A) read -rp "磁盘告警开关 1=开 0=关: " v
         case "$v" in 0|1) kv_set "$CONF" ENABLE_METRIC_ALERTS "$v" ;; *) echo -e "${CR}只能 0 或 1${C0}" ;; esac; pause ;;
      5|d|D) read -rp "磁盘告警阈值 %(正整数): " v; is_int "$v" && kv_set "$CONF" DISK_WARN "$v" || echo -e "${CR}需正整数${C0}"; pause ;;
      6|i|I) read -rp "daemon 轮询间隔秒(正整数): " v; is_int "$v" && kv_set "$CONF" DAEMON_INTERVAL "$v" || echo -e "${CR}需正整数${C0}"; pause ;;
      7|e|E) "${EDITOR:-vi}" "$CONF" ;;
      8|r|R)
        read -rp "恢复操作类设置为默认?(不影响 Telegram)[y/N]: " yn
        case "$yn" in y|Y)
          kv_set "$CONF" FAIL_THRESHOLD 3
          kv_set "$CONF" SSH_TIMEOUT 8
          kv_set "$CONF" SSH_KEY "'$HOME/.ssh/id_ed25519'"
          kv_set "$CONF" ENABLE_METRIC_ALERTS 1
          kv_set "$CONF" DISK_WARN 90
          kv_set "$CONF" DAEMON_INTERVAL 30
          echo -e "${CG}已恢复默认${C0}" ;;
        esac; pause ;;
      0|b|B|"") break ;;
    esac
  done
}

menu(){
  load_conf
  while true; do
    cls
    banner
    menu_group "监控"
    menu_item "1/r" "立即拉取并显示所有节点"
    menu_item "2/v" "查看本地状态总览" "最后检测 / 最后在线"
    menu_item "8/d" "前台 daemon 轮询"
    menu_group "配置"
    menu_item "3/n" "节点管理" "添加 / 删除 / 备注"
    menu_item "4/t" "Telegram 与日报"
    menu_item "9/k" "密钥管理" "导入 / 新建 / 删除"
    menu_item "10/c" "设置 config"
    menu_group "系统"
    menu_item "5/i" "安装 cron 定时拉取"
    menu_item "6/x" "移除 cron"
    menu_item "7/h" "被控机功能"
    menu_item "11/s" "安装启动快捷命令 volmon"
    menu_item "12/u" "检查更新"
    menu_item "0/q" "退出"
    echo
    menu_prompt; read -r ch || exit 0
    case "$ch" in
      1|r|R) VERBOSE=1 do_run; pause ;;
      2|v|V) do_status; pause ;;
      3|n|N)
        while true; do
          cls; banner "节点管理"; echo; node_list; echo
          menu_group "节点"
          menu_item "1/a" "添加节点"
          menu_item "2/e" "修改备注"
          menu_item "3/r" "重命名节点" "迁移日报基线/状态"
          menu_item "4/m" "迁移旧状态到当前节点" "修复手动改名后的基线"
          menu_item "5/u" "重置流量基准" "作为月付续费倒计时起点"
          menu_item "6/d" "删除节点"
          menu_item "0/b" "返回"
          echo
          menu_prompt; read -r s || break
          case "$s" in
            1|a|A) node_add; pause ;;
            2|e|E) node_set_remark; pause ;;
            3|r|R) node_rename; pause ;;
            4|m|M) node_migrate_state; pause ;;
            5|u|U) node_reset_usage; pause ;;
            6|d|D) node_del; pause ;;
            0|b|B|"") break ;;
          esac
        done ;;
      4|t|T) tg_menu ;;
      5|i|I) cron_install; pause ;;
      6|x|X) cron_remove; pause ;;
      7|h|H)
        while true; do
          cls; banner "被控机功能"; echo
          menu_group "被控机"
          menu_item "1/v" "查看本机状态"
          menu_item "2/k" "安装受限监控公钥"
          menu_item "0/b" "返回"
          echo
          menu_prompt; read -r s || break
          case "$s" in
            1|v|V) do_local; pause ;;
            2|k|K) node_key_menu ;;
            0|b|B|"") break ;;
          esac
        done ;;
      8|d|D) do_daemon ;;
      9|k|K) key_menu ;;
      10|c|C) config_menu ;;
      11|s|S) shortcut_install; pause ;;
      12|u|U) do_update; pause ;;
      0|q|Q) exit 0 ;;
      *) echo -e "${CR}无效选择${C0}"; pause ;;
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
  node-key) load_conf; node_key_menu ;;
  daemon)  do_daemon ;;
  shortcut) shortcut_install ;;
  update|upgrade) do_update ;;
  report) do_report ;;
  test-tg) load_conf; tg_test ;;
  ""|menu) menu ;;
  -h|--help|help)
    echo "用法: $0 [run|status|local|daemon|test-tg|report|node-key|shortcut|update|menu]"
    echo "  无参数        进入交互菜单"
    echo "  run           拉取一次所有节点(供 cron 调用)"
    echo "  status        显示本地快照状态总览(最后检测/在线)"
    echo "  local         显示本机状态(被控机本地查看)"
    echo "  daemon        前台循环轮询"
    echo "  test-tg       Telegram 推送测试"
    echo "  report        生成并推送当日汇总日报"
    echo "  node-key     被控机:安装受限监控公钥"
    echo "  shortcut      安装 volmon 快捷命令"
    echo "  update        从 GitHub 更新到最新版"
    ;;
  *) echo "未知命令: $1 (用 $0 --help)"; exit 1 ;;
esac
