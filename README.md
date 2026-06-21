# VolMonitor

**零常驻 · 私有拉取式 VPS / NAT 监控**

主控机定时 SSH 进被控机执行一段内嵌的只读采集脚本,被控机**不留任何常驻进程、不监听端口、不主动外联**。被控离线时通过 Telegram 推送告警,恢复时推送恢复通知。

专为「禁止安装哪吒 / Komari 等探针」的 NAT、家宽、受限 VPS 设计 —— 因为被控端没有 agent、没有守护进程、没有上报连接,常规探针检测无从识别。

> 主控脚本 `VolMon.sh` 为单文件 Bash;被控助手 `volmon-node.sh` 为纯 POSIX `sh`。兼容 Debian / Ubuntu / Alpine / OpenWrt。

---

## 仓库文件

| 文件 | 跑在 | 作用 |
|------|------|------|
| `VolMon.sh` | 主控机 | 节点管理、定时拉取、状态总览、Telegram 告警、密钥管理(单文件含全部功能) |
| `volmon-node.sh` | 被控机 | 轻量助手:安装 / 生成「受限监控公钥」、本机看状态(纯 POSIX sh,适合 OpenWrt) |

当前版本:`VolMon.sh` v1.4.15;`volmon-node.sh` v1.1.0。

被控机**默认无需任何脚本**;`volmon-node.sh` 仅在你想加固登录方式(受限公钥)时使用。

---

## 为什么这样设计

传统探针(哪吒、Komari 等)的本质是「**被控端常驻 agent + 持续对外上报**」。VPS 商可以靠进程特征或这条长连接识别它,很多 NAT / 受限套餐因此明确禁止。

VolMonitor 把方向反过来:

- 被控端**什么都不跑**,只在主控来拉取的瞬间执行一次只读采集,立即返回并断开。
- 采集脚本通过 `ssh ... 'sh -s'` 用标准输入喂进去执行,**默认连脚本文件都不落地**。
- 所有图表 / 状态 / 告警逻辑都在主控侧完成。
- SSH 拉取失败本身就是「机器掉线」信号,因此连宕机都能告警。

```
┌─────────────┐   SSH (cron 每分钟)   ┌──────────────┐
│   主控机     │ ───────────────────▶ │   被控机 NAT  │
│  VolMon.sh  │   sh -s 执行只读采集    │  无常驻进程    │
│  存储/告警   │ ◀─────────────────── │  无监听端口    │
└──────┬──────┘      返回状态文本        └──────────────┘
       │
       ▼ 离线 / 恢复 / 磁盘告警
   Telegram
```

---

## 功能特性

- **零常驻被控端**:默认不在被控机留任何文件或进程。
- **离线 / 恢复告警**:连续拉取失败达阈值判定离线并推送,恢复时推送恢复通知,边沿触发不刷屏。
- **磁盘告警**:磁盘使用率超阈值推送(可关闭)。
- **状态总览**:每节点显示「最后检测 / 最后在线 / 连续失败」及运行时长、负载、内存、磁盘、累计流量、TCP 连接数、运行中的代理服务。
- **节点备注名**:中文友好名,推送与列表中以「备注名 [节点名]」显示,一眼识别是哪台。
- **密钥管理**:导入(文件 / 粘贴)、**现场新建密钥对**、列出、删除、设为全局默认,自动 `chmod 600`。
- **受限监控公钥**:在被控端安装「强制命令 + 禁用所有转发 / pty」的公钥,该钥匙只能触发只读采集,拿不到 shell,泄露也基本无害。兼容 OpenSSH 与 Dropbear。
- **一键被控部署**:添加节点 / 生成密钥后,自动给出被控机 `curl|sh` / `wget|sh` 一键安装命令(直接拉 `volmon-node.sh` 并装上公钥)。
- **来源 IP 限制**:可加 `from="主控IP"`,使该钥匙仅主控 IP 可用,私钥泄露也无法他用;生成时自动探测主控公网 IP。
- **DDNS 友好**:节点主机字段可直接填 DDNS 域名,后端 IP 变化无影响。
- **Telegram 测试**:普通 / 模拟离线 / 模拟恢复 三种推送预览。
- **快捷命令**:一键安装 `volmon` 全局命令。
- **自更新**:从 GitHub 一键拉取最新版,自动校验 + 备份旧版。
- **跨平台采集**:Debian / Ubuntu / Alpine / OpenWrt 通用。
- **安全加固**:配置写入会安全转义字符串;SSH 私钥参数按独立参数传递;临时密钥在私有临时目录中生成。

---

## 环境要求

| 角色 | 要求 |
|------|------|
| 主控机 | `bash`、`ssh` 客户端;告警需 `curl` 且能访问 `api.telegram.org` |
| 被控机 | `sshd`(OpenSSH 或 Dropbear)、可被主控 SSH 访问;采集仅用 POSIX `sh` + 常见工具 |

主控机需能**免密 SSH** 登录各被控机(密钥认证)。

---

## 安装

**主控机:**

```bash
curl -fsSLO https://raw.githubusercontent.com/chnnic/VolMonitor/main/VolMon.sh
chmod +x VolMon.sh
./VolMon.sh
```

**被控机(可选,仅在使用受限公钥时):**

```bash
curl -fsSLO https://raw.githubusercontent.com/chnnic/VolMonitor/main/volmon-node.sh
chmod +x volmon-node.sh
./volmon-node.sh
```

首次运行主控会在 `~/.vol-monitor/` 下生成配置目录。

---

## 快速开始

### 主控机

```bash
./VolMon.sh            # 进入交互菜单
```

1. **菜单 `s`** — 安装快捷命令 `volmon`,之后任意目录可直接敲 `volmon`。
2. **菜单 `9`** — 密钥管理:导入已有私钥,或 `n` 现场新建密钥对。
3. **菜单 `4` → `c`** — 配置 Telegram Bot Token 与 Chat ID;`t` 发送测试推送。
4. **菜单 `3` → `a`** — 添加节点:主机填被控的 DDNS 域名 / IP;密钥处填已有密钥名,或输入 `new` 现场生成。添加后会给出被控机的一键安装命令(含来源 IP 限制),复制到被控执行即可。
5. **菜单 `5`** — 安装 cron 定时拉取(默认每分钟一次)。

### 被控机

被控机**默认无需安装任何东西**。若希望使用「受限监控公钥」加固登录,见下一节。只想本地手动看状态可直接:

```bash
./volmon-node.sh status
```

---

## 受限监控公钥(推荐用于被控端加固)

让主控拉取时用的那把钥匙**权限降到最低**:它只能执行一个只读采集脚本,无法获得 shell、无法做任何端口 / agent / X11 转发、不分配 pty。即使私钥泄露,也只能看到监控数据。

被控的 `~/.ssh/authorized_keys` 中该行形如:

```
command="/usr/local/bin/volmon-collect",no-port-forwarding,no-agent-forwarding,no-x11-forwarding,no-pty ssh-ed25519 AAAA... volmon-master
```

采集脚本落地到 `/usr/local/bin/volmon-collect`(不可写则退到 `~/.volmon-collect`),仅为按需运行的只读脚本 —— 无常驻进程、无监听端口、无外联,不触发探针检测。

加上**来源 IP 限制**后(推荐),该行形如:

```
from="主控IP",command="/usr/local/bin/volmon-collect",no-port-forwarding,no-agent-forwarding,no-x11-forwarding,no-pty ssh-ed25519 AAAA...
```

`from=` 使这把钥匙**仅主控 IP 可用**,私钥即便泄露,从其他 IP 也无法通过认证。

### 推荐流程:主控生成 + 一键部署到被控

在主控 `VolMon.sh` 添加节点时,密钥处输入 `new` 现场生成密钥对(或菜单 9 → `n`);也可直接选用已有密钥。主控会:

1. 生成 / 选用密钥(私钥留主控),自动探测主控公网 IP(可改 / 可填 CIDR / 可跳过);
2. 打印被控机一键安装命令,直接复制到**被控机**执行其一即可:

```bash
# ① curl 一键
curl -fsSL https://raw.githubusercontent.com/chnnic/VolMonitor/main/volmon-node.sh | sh -s -- add "ssh-ed25519 AAAA..." "主控IP"
# ② wget 一键
wget -qO- https://raw.githubusercontent.com/chnnic/VolMonitor/main/volmon-node.sh | sh -s -- add "ssh-ed25519 AAAA..." "主控IP"
```

命令同时会存到 `~/.vol-monitor/install-<节点名>.txt` 便于复制。`"主控IP"` 省略则不加来源限制。

### 在被控机上直接用 volmon-node.sh

```bash
./volmon-node.sh add "ssh-ed25519 AAAA... 主控公钥" "主控IP"   # 装公钥;给 IP 则加 from= 限制
./volmon-node.sh gen                                          # 本机生成密钥对,打印私钥转交主控
./volmon-node.sh status                                       # 看本机状态
./volmon-node.sh remove                                       # 卸载
./volmon-node.sh                                               # 无参数进菜单
```

- **方式 1(推荐)**:在主控生成密钥对,把**公钥**粘到被控 `add` —— 私钥永不离开主控。
- **方式 2**:被控 `gen` 生成,脚本打印**私钥**供你转交主控,随后本机自动抹除私钥,只留受限公钥。

> 动态 IP 的主控慎用 `from=` 锁单一 IP(换 IP 会连不上),可改用运营商 CIDR 或不加限制。

### 用 VolMon.sh(若主控脚本也在被控上)

```bash
./VolMon.sh node-key      # 菜单 7 → k 亦可
```

> 启用受限公钥后主控侧无需任何改动,照常拉取即可。

---

## 菜单 / 命令参考

### VolMon.sh(主控)

```
VolMon.sh [run|status|local|daemon|test-tg|report|node-key|shortcut|update|menu]
```

| 命令 | 说明 |
|------|------|
| *(无参数)* | 进入交互菜单 |
| `run` | 拉取一次所有节点(供 cron 调用) |
| `status` | 显示本地快照状态总览(最后检测 / 在线) |
| `local` | 显示本机状态 |
| `daemon` | 前台循环轮询 |
| `test-tg` | Telegram 推送测试 |
| `report` | 生成并推送当日汇总日报(先刷新再发送) |
| `node-key` | 被控机:安装 / 卸载受限监控公钥 |
| `shortcut` | 安装 `volmon` 快捷命令 |
| `update` | 从 GitHub 更新到最新版 |

交互菜单支持数字/字母双键位,例如 `1/r` 拉取并显示、`3/n` 节点管理、`4/t` Telegram、`10/c` 设置、`0/q` 退出;按数字或字母任一键都可执行。

### volmon-node.sh(被控)

```
volmon-node.sh [add ["公钥"] ["来源IP"]|gen|status|setip [IP]|remove|update|menu]
```

| 命令 | 说明 |
|------|------|
| `add [公钥] [IP]` | 安装受限公钥;给 IP 则加 `from=` 限制仅该 IP 可用 |
| `gen` | 本机生成密钥对并安装受限公钥,打印私钥给主控 |
| `status` | 查看本机状态 |
| `setip [IP]` | 修改已安装受限公钥的 `from=` 来源限制;`IP=no` 取消限制 |
| `remove` | 卸载受限公钥与采集脚本 |
| `update` | 从 GitHub 更新到最新版 |
| *(无参数)* | 进入交互菜单 |

---

## 配置文件

路径:`~/.vol-monitor/config.conf`(可用环境变量 `VOLMON_DIR` 覆盖整个目录)。

| 项 | 默认 | 说明 |
|------|------|------|
| `TG_BOT_TOKEN` | *(空)* | Telegram Bot Token |
| `TG_CHAT_ID` | *(空)* | 接收告警的 chat_id |
| `FAIL_THRESHOLD` | `3` | 连续拉取失败几次判定离线 |
| `SSH_TIMEOUT` | `8` | SSH 连接超时(秒) |
| `SSH_KEY` | `$HOME/.ssh/id_ed25519` | 默认 SSH 私钥(节点可单独覆盖) |
| `ENABLE_METRIC_ALERTS` | `1` | 是否开启磁盘等指标告警 |
| `DISK_WARN` | `90` | 磁盘使用率告警阈值(%) |
| `DAEMON_INTERVAL` | `30` | daemon 模式轮询间隔(秒) |

### 手动修改已生成的配置

配置改动**无需重启任何服务**——脚本每次运行都会重新读取该文件。用编辑器改对应行保存即可:

```bash
nano ~/.vol-monitor/config.conf      # 或 vi
```

也可用一条命令修改(以轮询间隔为例):

```bash
sed -i 's/^DAEMON_INTERVAL=.*/DAEMON_INTERVAL=30/' ~/.vol-monitor/config.conf
```

或删掉某行,让它走脚本内置默认:

```bash
sed -i '/^DAEMON_INTERVAL=/d' ~/.vol-monitor/config.conf
```

注意:等号两边不要加空格(`KEY=VALUE`);字符串值建议保留引号(如 `SSH_KEY="/root/.vol-monitor/keys/x.key"`);`TG_BOT_TOKEN` / `TG_CHAT_ID` 等也可直接用菜单 `4` 修改,免得手输出错。

> 升级脚本不会覆盖你的 `config.conf`;新版调整的只是「全新安装」的默认值,已有配置需按上述方法手动改。

---

## 节点配置格式

路径:`~/.vol-monitor/nodes.conf`,每行一个节点,字段以 `|` 分隔:

```
名称|主机|端口|用户|密钥|备注
```

示例:

```
nat-home|nat.example.xyz|2222|root|/root/.vol-monitor/keys/hk.key|香港家宽
```

- **名称**:唯一标识(英文 / 数字),用于状态文件和日报基线;需要改显示名时优先改“备注”。
- **主机**:DDNS 域名 / Tailscale IP / 公网 IP 均可。
- **密钥**:留空则用全局默认 `SSH_KEY`。
- **备注**:推送与列表中的友好显示名,留空回退为名称;修改备注不会影响日报基线。确实需要修改“名称”时,请用节点管理里的“重命名节点”,脚本会迁移状态和快照。若已经手动改名导致基线断开,可用“迁移旧状态到当前节点”补救。

> 旧版 5 字段(无备注)格式自动兼容。建议通过菜单管理而非手改。

---

## Telegram 告警

1. 找 [@BotFather](https://t.me/BotFather) 创建 Bot,拿到 Token。
2. 给 Bot 发一条消息,然后访问 `https://api.telegram.org/bot<TOKEN>/getUpdates` 取到你的 `chat_id`。
3. 菜单 `4 → c` 填入,`t` 发送测试推送验证。

推送样例:

```
🔴 香港家宽 (nat-home) 离线告警
连续失败: 3 次
最后在线: 2026-01-01 09:00:00
主机: nat.example.xyz:2222
时间: 2026-01-01 09:03:00
```

---

## 每日日报

每天定时推送一条汇总:各节点当日流量、重置周期内已用流量、连续失败次数、在线 / 离线统计;若节点设置了重置周期,还会显示距离重置日还有多少天。

入口:菜单 `4`(Telegram)→ `r`(每日日报),或命令行 `./VolMon.sh report`。

- `e` 启用 / 设置时间(默认 `23:59`),写入一条独立 cron(标记 `# volmon-report`,与拉取 cron 互不影响)
- `x` 关闭
- `t` 立即发送一次
- 节点管理里可执行 `u` 重置流量基准,可手动填写重置起算日、周期天数,以及起算时已用的上下行流量;日报会显示 `距重置 X天` 与 `重置周期内已用流量`。

推送样例:

```
📊 VolMonitor 日报  2026-06-18
节点 2 · 在线 1 · 离线 1
合计今日流量 ↓3.73G ↑1.40G · 重置周期内已用 ↓12.00G ↑5.00G · 失败 287次
————————————
🟢 香港家宽  今日 ↓3.73G ↑1.40G  周期已用 ↓12.00G ↑5.00G  失败 0次 · 距重置 12天
🔴 死机     今日 ↓0.00G ↑0.00G  周期已用 ↓0.50G ↑0.20G  失败 287次 · 距重置 12天
```

**流量是怎么算的**:被控采集脚本读取 `/proc/net/dev`(网卡自开机的累计收发字节)。`run` 每次成功拉取记录当前累计值;**当天首次成功**时存为基线;日报取「最新值 − 当天基线」即当日消耗。跨天自动重置基线与当日失败计数;机器重启计数器归零时做兜底,不出负数。你也可以手动把某节点的当天累计值重置成新起点,作为月付 VPS 的续费倒计时基准。

**发送前自动刷新**:无论手动 `t` 立即发送还是定时触发,都会先静默拉取一遍所有节点,用此刻最新的流量 / 状态生成日报(只更新最新值,不改当天基线)。

> 依赖:① 已配置 Telegram;② 已装拉取 cron(菜单 `5`)——日报只是汇总 `run` 攒下的数据,没有定时拉取就没有数据。
> 口径:流量按 1024 进制(GiB)显示;「当日」从当天第一次成功拉取算起。

---

## 定时任务

菜单 `5` 安装 cron(默认每分钟拉取一次),等价于:

```cron
* * * * * /path/to/VolMon.sh run >/dev/null 2>&1 # vol-monitor
```

也可用 `daemon` 模式在前台循环(间隔由 `DAEMON_INTERVAL` 控制):

```bash
./VolMon.sh daemon
```

---

## 更新

从 GitHub 拉取最新版,自动校验(脚本 + 语法)、比对版本、备份旧版后原地替换:

```bash
./VolMon.sh update          # 主控
./volmon-node.sh update     # 被控;菜单内选 u 亦可
```

- 远程版本不同 → 显示 `本地 vX → 远程 vY`,确认后更新;已是最新则默认跳过。
- 更新前自动备份为 `脚本名.bak`;写入需要对脚本文件有写权限(必要时用 `sudo`)。
- 旧版配置目录 `~/.nat-monitor/` 会在更新后首次运行时**自动迁移**到 `~/.vol-monitor/`(含密钥与内部路径引用),无需手动处理。
- 更新源可用环境变量覆盖(换分支 / 镜像):

```bash
VOLMON_REPO="https://raw.githubusercontent.com/chnnic/VolMonitor/main" ./VolMon.sh update
```

### 版本记录

- `VolMon.sh` v1.4.14:重置日改为每月固定日期,到期后自动滚动到下一个同日;状态总览与日报继续展示重置周期内已用流量。
- `VolMon.sh` v1.4.15:节点管理列表显示每个节点的重置日与下次重置,状态总览补充今日实时用量。
- `VolMon.sh` v1.4.13:重置流量基准时可回填起算日已用的上下行流量,状态总览与日报新增重置周期内已用流量展示。
- `VolMon.sh` v1.4.12:重置流量基准时可手动指定起算日,方便对齐月初 / 续费日。
- `VolMon.sh` v1.4.11:状态总览新增「计费周期内流量」一行,下方继续显示总流量。
- `VolMon.sh` v1.4.9:新增流量基准重置与续费倒计时显示;日报可展示距离重置日还有多少天,节点菜单可手动重置基准。
- `VolMon.sh` v1.4.8:修复部分 Linux `awk` 使用 `%d` 汇总累计流量时被截断为 `2147483647`，导致大流量节点日报始终显示 `0.00G` 的问题；首次正确采集时自动重置已截顶的旧基准线。
- `VolMon.sh` v1.4.7:新增节点重命名并迁移 state/snap,避免改节点名称后每日日报流量基线归零;新增旧状态迁移入口,可补救手动改名后的基线断开;状态文件记录连接信息,后续手动改名也可自动认回同一节点基线。
- `VolMon.sh` v1.4.6 / `volmon-node.sh` v1.1.0:交互菜单改为数字/字母双键位,按任一键都可执行同一操作。
- `VolMon.sh` v1.4.5 / `volmon-node.sh` v1.0.9:优化交互菜单排版,增加分组标题、对齐菜单项和统一输入提示。
- `VolMon.sh` v1.4.4 / `volmon-node.sh` v1.0.8:按 ShellCheck 建议清理 `printf`、动态配置加载注释与 POSIX `read -r`。
- `VolMon.sh` v1.4.3 / `volmon-node.sh` v1.0.7:修复 `local` / `status` 成功输出后退出码为 1 的问题;加固配置写入、SSH 私钥参数传递与临时密钥生成;仓库脚本文件设置为可执行。
- `VolMon.sh` v1.4.2:完善每日日报说明与更新流程。

---

## 文件布局

主控端:

```
~/.vol-monitor/
├── config.conf        # 全局配置
├── nodes.conf         # 节点列表
├── monitor.log        # 拉取 / 告警日志
├── keys/              # 导入的 SSH 私钥 (700)
├── state/             # 每节点状态 (失败计数 / 在线状态 / 时间戳)
└── snap/              # 每节点最近一次采集快照
```

被控端(仅在启用受限公钥时):

```
/usr/local/bin/volmon-collect   # 只读采集脚本 (按需运行,非常驻)
~/.ssh/authorized_keys          # 受限公钥行
```

---

## 常见问题

**被控是 OpenWrt,TCP 连接数显示不准 / 为空?**
busybox 的 `ss` 对部分参数支持有限,会影响该项,但**不影响离线判定**——核心只看 SSH 是否连通。

**DDNS 的 IP 变了会怎样?**
没影响。SSH 主机密钥按域名缓存,首次以 `accept-new` 自动接受。

**这算探针吗,会被 VPS 商封吗?**
被控端默认零落地、无常驻进程、无监听端口、无主动外联;启用受限公钥后落地的也只是个按需运行的只读脚本。它不具备探针的 agent / 上报特征。请自行评估并遵守你的服务商条款。

**Telegram 发送失败?**
检查 Token / Chat ID 是否正确,以及主控机能否访问 `api.telegram.org`(部分被墙环境需代理出口)。

---

## License

MIT(可按需修改)。
