# SuguangWebGuard 网站防篡改系统

> 速光网络软件开发 · [suguang.cc](https://suguang.cc)

基于 Linux 内核原生能力的轻量级网站防篡改系统。不依赖任何商业软件，用
`chattr` + `inotify` + `AIDE` 三层组合，实现商业防篡改产品（阿里云网页防篡改、
ieGuard 等）的核心防护能力，并附带一套 Web 管理界面。

**核心语义**：受保护的网站文件**不能改内容、不能改文件名、不能删除**；
读取和执行完全不受影响；允许写入新文件（新出现的脚本会被实时隔离）。
连 root 也必须先显式解锁才能修改。

- **版本**：1.2.0
- **适用环境**：CentOS 7+ / RHEL / Debian / Ubuntu，ext2/3/4 或 xfs 文件系统
- **依赖**：`e2fsprogs`（系统自带）、`inotify-tools`、`aide`（可选）、`python3`（Web 界面，可选）

---

## 目录

- [防护原理](#防护原理)
- [能力边界](#能力边界)
- [安装](#安装)
- [目录结构](#目录结构)
- [文件清单](#文件清单)
- [快速上手](#快速上手)
- [配置说明](#配置说明)
- [维护模式](#维护模式)
- [加锁状态下的行为](#加锁状态下的行为)
- [新增站点](#新增站点)
- [Web 管理界面](#web-管理界面)
- [日志](#日志)
- [故障排查](#故障排查)
- [实测验证结果](#实测验证结果)
- [局限性](#局限性)
- [卸载](#卸载)
- [从旧版升级](#从旧版升级)

---



## 防护原理

### 第一层：chattr +i —— 阻止（内核强制）

给站点**已有文件**加文件系统的 immutable 标志。实测效果（以 `www` 用户身份，
即 PHP 被 RCE 后攻击者拥有的权限）：

| 操作 | 结果 |
|---|---|
| 读取文件 | 允许 |
| 执行文件（PHP 解析） | 允许 |
| 修改文件内容 | **拒绝 EPERM** |
| 修改文件名 | **拒绝 EPERM** |
| 删除文件 | **拒绝 EPERM** |
| 在目录中新建文件 | 允许 |

**目录不加锁**，所以允许写入新文件——这是刻意设计，因为 CMS 需要生成缓存、
接收上传。连 root 也必须先 `chattr -i` 才能修改，普通提权无法直接绕过。

### 第二层：实时监控守护 —— 隔离

第一层刻意放行了「新建文件」，这层补这个口子。守护进程有**两条独立防线**：

1. **inotify 实时监控** —— 毫秒级响应。但存在固有竞态：`mkdir` 与写文件在同一条
   命令里连续发生时，内核给新目录建立 watch 之前文件已写完，事件会丢失。
   **本次入侵正是这种手法**。
2. **每 60 秒全量扫描** —— 兜底捞回竞态窗口和 inotify 队列溢出的漏网文件。

一旦在**非白名单路径**出现新的 `.php` / `.phtml` / `.phar` 等脚本文件，立即移入
隔离区并写告警日志 + syslog。白名单在 `exclude.conf` 里用 `PHPOK=` 声明，用于
放行程序合法生成的 PHP（如模板编译缓存）。

### 第三层：AIDE —— 每日核查

每天 04:17 对保护范围内所有文件做 `md5 + sha256 + 权限 + 属主 + 大小 + inode +
mtime/ctime` 全量比对。**即使攻击者拿到 root 绕过了第一层，改动也会在次日报告
里暴露。**

---

## 能力边界

对标商业防篡改产品：

| 能力 | 商业产品（ieGuard / 阿里云） | SuguangWebGuard |
|---|---|---|
| 阻止写入 | 内核驱动 hook，**按进程授权** | `chattr +i`，一刀切 |
| 实时监控告警 | 自带 agent | inotify + 定期扫描 |
| 完整性核查 | 云端基线 | AIDE 本地基线 |
| 自动还原 | 备份目录自动回滚 | 隔离区一键恢复（Web 界面） |
| 输出时水印校验 | 内嵌 Web 服务器模块 | **无**（开源无对应品） |
| 管理界面 | 云端控制台 | 本地 Web 界面 |

**主要差距**：商业产品能「只允许发布程序写入、Web 进程不能写」，本系统无法按
进程区分，所以运维时必须显式 `unlock` / `lock`。开源里唯一能做进程级授权的是
SELinux，但启用需重启 + 全盘 relabel，多数生产环境不划算。

补充说明：ieGuard 主打的「核心内嵌数字水印」引擎**并不能阻止文件被篡改**，它只
保证被改过的内容不被发出去，属于检测 + 事后还原。真正起阻止作用的是它的写调用
拦截引擎，这一层与本系统的 `chattr` 层等价。

---

## 安装

### 一键安装（推荐）

服务器能访问 GitHub 时，一条命令直接装好，不用手工上传：

```bash
curl -fsSL https://raw.githubusercontent.com/suguangnet/SuguangWebGuard/main/quick-install.sh \
  | bash -s -- --site /www/wwwroot/你的站点
```

想连加锁一并完成（跳过人工核对，仅建议用于结构简单的站点）：

```bash
curl -fsSL https://raw.githubusercontent.com/suguangnet/SuguangWebGuard/main/quick-install.sh \
  | bash -s -- --site /www/wwwroot/你的站点 --port 19197 --lock --yes
```

`quick-install.sh` 只做四件事：下载源码 → 校验完整性 → 规范化换行符 →
调用 `install.sh`。真正的安装逻辑全在 `install.sh` 里，它自己的参数：

| 参数 | 作用 |
|---|---|
| `--ref <分支或标签>` | 指定版本，默认 `main`。**生产环境建议指定 tag** |
| `--mirror <前缀>` | 通过镜像下载，如 `--mirror https://ghfast.top/`；`--mirror auto` 依次尝试内置镜像 |
| `--src-dir <路径>` | 源码存放位置，默认 `/root/SuguangWebGuard-src` |
| `--download-only` | 只下载不安装 |
| `--help` | 显示帮助 |

其余参数原样透传给 `install.sh`（`--site` `--port` `--lock` `--yes` `--no-web` `--no-aide` 等）。

源码会保留在 `--src-dir` 指定的目录，以后升级、卸载都从那里执行。

#### 网络不通时

国内服务器有时连不上 GitHub。脚本会明确报错并给出两条出路：

```bash
# 走镜像
curl -fsSL <脚本URL> | bash -s -- --mirror auto --site /www/wwwroot/你的站点

# 或改用下面的「手工安装」
```

> **关于 `curl | bash` 的安全性**：对一个防篡改软件来说，用管道直接执行远程脚本
> 确实有点讽刺。脚本已做了完整性校验（16 个关键文件缺一即中止）和语法检查，
> 但这只能防传输截断，**防不住仓库或镜像被投毒**。
>
> 更稳妥的做法：
> - 用 `--ref <tag>` 锁定版本，而不是跟着 `main` 走
> - 先 `--download-only` 下载下来，人工看过 `install.sh` 再执行
> - 或者干脆用下面的手工安装方式
> - 走第三方镜像时脚本会明确提示「内容不受本项目控制」

### 手工安装

#### 一、准备安装包

把整个 `SuguangWebGuard` 目录传到服务器任意位置：

```bash
# 本地打包上传
tar czf SuguangWebGuard.tar.gz SuguangWebGuard/
scp SuguangWebGuard.tar.gz root@服务器IP:/root/
# 服务器上解压
ssh root@服务器IP
cd /root && tar xzf SuguangWebGuard.tar.gz && cd SuguangWebGuard
```

安装包必须包含以下文件，缺一不可（`install.sh` 会先做完整性检查）：

```
install.sh  uninstall.sh  detect.sh  common.sh
lock.sh  unlock.sh  status.sh  watch.sh
aide-init.sh  aide-check.sh  exclude.conf.example  README.md
dist/suguang-webguard-watch.service
dist/suguang-webguard-web.service
dist/cron.suguang-webguard
dist/logrotate.suguang-webguard
web/webui.py
web/index.html
```

#### 二、执行安装

**推荐用法**（自动探测该站点需要保持可写的目录）：

```bash
chmod +x install.sh
./install.sh --site /www/wwwroot/你的站点
```

多个站点一起装：

```bash
./install.sh --site /www/wwwroot/a.com --site /www/wwwroot/b.com
```

`install.sh` 参数：

| 参数 | 作用 |
|---|---|
| `--site <路径>` | 要保护的站点根目录，可重复指定 |
| `--days <N>` | 探测可写目录时回溯的天数，默认 90 |
| `--lock` | 安装完成后立即加锁（默认**不加锁**，留时间给你核对配置） |
| `--port <N>` | Web 管理界面端口，默认 19196 |
| `--no-web` | 不安装 Web 管理界面 |
| `--no-aide` | 不安装 AIDE 完整性核查 |
| `--yes` / `-y` | 全部自动确认，不交互 |
| `--help` | 显示帮助 |

安装流程会依次完成：

1. 前置检查（root 权限、必需命令、**实测文件系统是否支持 immutable 属性**、
   源文件完整性、python3 版本）
2. **检测旧版 `antitamper` 安装并询问是否自动迁移**
3. 安装依赖（`inotify-tools`、`aide`）
4. 创建目录
5. 复制程序文件并逐个做语法检查（含 `webui.py` 的 `py_compile`）
6. 生成 `exclude.conf`（指定了 `--site` 时自动探测）
7. 安装 systemd 服务、cron、logrotate
8. 启动实时监控守护
9. 安装并启动 Web 管理界面
10. 可选加锁 + 建立 AIDE 基线

#### 三、核对配置（这一步不能跳过）

安装脚本默认**不加锁**，因为自动探测出来的可写目录清单必须人工确认。

```bash
vi /www/SuguangWebGuard/exclude.conf
```

重点看两处：

- `EXCLUDE=` 开头的行 —— 这些目录将保持可写。确认没有多余的（多排 = 留下攻击面）。
- `# EXCLUDE=` 注释掉的「**需要你人工确认**」区块 —— 这些是探测程序拿不准的目录。
  确属程序需要持续写入的，去掉行首 `#`；不确定就保持注释（纳入保护，更安全）。

> 探测程序的判据是文件写入行为，它**分不清是程序在写、还是管理员手工改过、
> 还是入侵者留下的痕迹**。所以凡是只有少量代码文件（.php/.html/.js）被改动的
> 目录，一律列入待确认区，不会自动排除。这是刻意的保守设计。

单独重新探测某个站点：

```bash
/www/SuguangWebGuard/detect.sh /www/wwwroot/你的站点 90
```

#### 四、加锁启用

```bash
/www/SuguangWebGuard/lock.sh          # 加锁
/www/SuguangWebGuard/aide-init.sh     # 建立完整性基线
/www/SuguangWebGuard/status.sh        # 确认状态为"已保护"
```

#### 五、验证网站正常

```bash
curl -sk -o /dev/null -w '%{http_code}\n' -H 'Host: 你的域名' https://127.0.0.1/
```

再到前台点几个页面、进后台发一篇文章、传一张图，确认业务不受影响。
若出现 `Permission denied` 报错，说明有可写目录漏排，见[故障排查](#故障排查)。

#### 六、验证防护生效（建议做）

以 `www` 用户身份模拟攻击者，四条应全部被拒：

```bash
S=/www/wwwroot/你的站点
su -s /bin/bash www -c "echo x >> $S/index.php"        # 改内容 → 应拒绝
su -s /bin/bash www -c "mv $S/index.php $S/x.php"      # 改文件名 → 应拒绝
su -s /bin/bash www -c "rm -f $S/index.php"            # 删除 → 应拒绝
su -s /bin/bash www -c "echo '<?php' > $S/evil.php"    # 新建脚本 → 允许，但应被隔离
sleep 3; ls $S/evil.php 2>/dev/null || echo "已被隔离"
tail -3 /www/SuguangWebGuard/logs/alert.log
```

### 重新安装 / 升级

在安装包目录里再跑一次 `./install.sh` 即可。已存在的 `exclude.conf` 与
`web.conf` 会被保留；若带了 `--site`，旧配置会先备份为
`exclude.conf.bak.<时间戳>`。源目录若就是 `/www/SuguangWebGuard` 本身，
脚本会自动跳过复制步骤（原地重装）。

---

## 目录结构

**所有运行数据都在 `/www/SuguangWebGuard` 一个目录内**（程序、配置、日志、
隔离区、AIDE 基线），便于查找、备份和迁移。

```
/www/SuguangWebGuard/            权限 700，www 用户不可读
├── exclude.conf        站点清单 + 可写目录 + .php 白名单  ← 唯一需要你编辑的文件
├── exclude.conf.example 配置模板
├── web.conf            Web 界面配置（端口/账号/密码哈希，权限 600）
├── aide.conf           AIDE 配置（由 aide-init.sh 自动生成，勿手工改）
├── aide.db.gz          AIDE 完整性基线库
├── .maintenance        维护模式标记（unlock.sh 创建 / lock.sh 删除）
│
├── install.sh          安装脚本
├── uninstall.sh        卸载脚本
├── detect.sh           探测站点需要保持可写的目录
├── common.sh           公共库（配置解析、find 排除表达式、AIDE 配置生成）
├── lock.sh             加锁（并退出维护模式）
├── unlock.sh           解锁（并进入维护模式）
├── status.sh           状态总览
├── watch.sh            实时监控守护主体
├── aide-init.sh        建立/重建 AIDE 基线
├── aide-check.sh       AIDE 核查（由 cron 调用）
├── README.md           本文件
│
├── web/
│   ├── webui.py        Web 管理界面后端（Python3 纯标准库）
│   └── index.html      Web 管理界面前端
│
├── logs/               日志目录
│   ├── alert.log       拦截 / 告警 / 维护模式记录
│   ├── action.log      加锁解锁与 Web 操作记录
│   ├── aide-report.log 每日完整性核查报告
│   ├── watch.log       守护进程自身输出
│   └── web.log         Web 界面访问与操作
│
└── quarantine/         隔离区（被拦下的脚本文件）
```

只有下面三个文件因系统机制要求必须放在 `/etc` 下，它们都指向
`/www/SuguangWebGuard`：

```
/etc/systemd/system/suguang-webguard-watch.service   实时监控守护服务
/etc/systemd/system/suguang-webguard-web.service     Web 管理界面服务
/etc/cron.d/suguang-webguard                         每日核查定时任务
/etc/logrotate.d/suguang-webguard                    日志轮转（每周，保留 12 份）
```

### 为什么放在 /www 下是安全的

`/www/SuguangWebGuard` 与网站目录 `/www/wwwroot/*` 同级，但不会被 Web 访问到：

- `/www` 属主 `root:root 755`，`www` 用户**不可写**
- 程序目录权限 **700**，`www` 用户**连读都不行**（隔离区里存的是真实 webshell，
  这一点很关键）
- 没有任何 nginx vhost 以 `/www` 为站点根，全部指向 `/www/wwwroot/<域名>`
- 各站点 `.user.ini` 的 `open_basedir` 把 PHP 限制在自身目录 + `/tmp`，
  即使某个站点被 RCE 也读不到本目录

> 部署到新服务器时，建议用 `install.sh` 第 1 步的检查结果确认这几条同样成立。

---

## 文件清单

安装涉及的文件分三类，外加两处系统改动。

### 一、安装包必需文件

`install.sh` 第 1 步会逐个校验下表中标注为**必需**的文件，少任何一个直接退出。

| 文件 | 大致大小 | 必需 | 作用 |
|---|---|---|---|
| `quick-install.sh` | 7 K | 可选 | 一键安装引导：下载 + 校验 + 调用 install.sh。
手工安装时用不到 |
| `install.sh` | 15 K | 必需 | 安装脚本，入口 |
| `uninstall.sh` | 4 K | 建议 | 卸载脚本。缺失时装得上，但以后只能手工卸载 |
| `common.sh` | 3 K | 必需 | 公共库：配置解析、find 排除表达式、AIDE 配置生成 |
| `watch.sh` | 3 K | 必需 | 实时监控守护主体（inotify + 定期扫描） |
| `lock.sh` | 1 K | 必需 | 加锁 |
| `unlock.sh` | 1 K | 必需 | 解锁（并进入维护模式） |
| `status.sh` | 1 K | 必需 | 状态查看 |
| `detect.sh` | 5 K | 必需 | 探测站点需要保持可写的目录，`--site` 依赖它 |
| `aide-init.sh` | 1 K | 必需 | 建立 / 重建完整性基线 |
| `aide-check.sh` | 1 K | 必需 | 每日核查（由 cron 调用） |
| `exclude.conf.example` | 1 K | 可选 | 配置模板，不带 `--site` 安装时用作初始配置 |
| `README.md` | 33 K | 可选 | 本文档，会被复制到安装目录 |
| `LICENSE` | 1 K | 可选 | MIT 许可证 |
| `web/webui.py` | 24 K | 必需* | Web 管理界面后端 |
| `web/index.html` | 21 K | 必需* | Web 管理界面前端 |
| `dist/suguang-webguard-watch.service` | 271 B | 必需 | 守护服务单元模板 |
| `dist/suguang-webguard-web.service` | 262 B | 必需* | Web 服务单元模板 |
| `dist/cron.suguang-webguard` | 142 B | 必需 | 定时任务模板 |
| `dist/logrotate.suguang-webguard` | 147 B | 必需 | 日志轮转模板 |

标 **必需\*** 的三个文件只在安装 Web 管理界面时校验，加 `--no-web` 可跳过；
同理 `--no-aide` 会跳过 AIDE 相关步骤，但 `aide-init.sh` / `aide-check.sh` 仍需存在。

仓库里还有 `.gitattributes` 和 `.gitignore`，仅供版本控制使用，**安装不需要**。

> `.gitattributes` 对所有脚本强制 `eol=lf`。如果你不是用 git 克隆而是手工下载 zip
> 再上传，务必确认脚本没被转成 CRLF，否则会报
> `bad interpreter: /bin/bash^M`。`install.sh` 复制文件时也会做一次 `sed 's/\r$//'` 兜底。

### 二、安装后生成的文件

程序文件会被复制到 `/www/SuguangWebGuard`，此外**新产生**下列内容：

| 文件 / 目录 | 权限 | 说明 |
|---|---|---|
| `exclude.conf` | 644 | 站点配置，由 `detect.sh` 探测生成 ← **唯一需要你维护的文件** |
| `web.conf` | 600 | Web 界面配置：端口、账号、PBKDF2 密码哈希 |
| `web-initial-password.txt` | 600 | 初始密码，改密后可删除 |
| `aide.conf` | 600 | AIDE 配置，由 `aide-init.sh` 从 `exclude.conf` 自动生成，**勿手改** |
| `aide.db.gz` | 600 | 完整性基线库 |
| `logs/` | 700 | `alert.log` `action.log` `aide-report.log` `watch.log` `web.log` |
| `quarantine/` | 700 | 隔离区，存放被拦下的脚本文件 |
| `.maintenance` | 644 | 维护模式标记，解锁时出现、加锁时消失 |

整个 `/www/SuguangWebGuard` 目录权限为 **700**，`www` 用户连读都不行 ——
隔离区里存的是真实 webshell，这一点很关键。

### 三、系统集成文件

只有下面 4 个文件在 `/etc` 下，因为 systemd、cron、logrotate 只认各自的固定目录。
它们内容都只有几行，全部指向 `/www/SuguangWebGuard`：

| 文件 | 用途 |
|---|---|
| `/etc/systemd/system/suguang-webguard-watch.service` | 实时监控守护服务 |
| `/etc/systemd/system/suguang-webguard-web.service` | Web 管理界面服务 |
| `/etc/cron.d/suguang-webguard` | 每日 04:17 完整性核查 |
| `/etc/logrotate.d/suguang-webguard` | 日志轮转（每周，保留 12 份） |

### 四、对系统的其他改动（不是文件）

**1. 安装了三个依赖包**

| 包 | 用途 | 来源 |
|---|---|---|
| `inotify-tools` | 实时监控 | EPEL |
| `aide` | 完整性核查（`--no-aide` 可跳过） | base / updates |
| `python3` | Web 管理界面（`--no-web` 可跳过） | base / updates |

卸载脚本**不会**自动移除它们，因为可能有其他程序依赖。需要时手工
`yum remove -y aide inotify-tools`。

**2. 给站点文件打了 `chattr +i` 属性**

这不是文件，是打在文件 inode 上的标志位。所以移动程序目录、甚至卸载重装都不影响它，
但**卸载前必须先解锁**，否则那些文件会永久锁死（`uninstall.sh` 会自动处理这一步）。

### 备份建议

**只需打包 `/www/SuguangWebGuard` 一个目录**，程序、配置、日志、基线、隔离区全在里面：

```bash
tar czf swg-backup-$(date +%Y%m%d).tar.gz -C /www SuguangWebGuard
```

`/etc` 下那 4 个文件不用备份，重新执行 `install.sh` 会自动重建。

---

## 快速上手

```bash
# 看当前状态
/www/SuguangWebGuard/status.sh

# 要改网站了（改配置 / 传文件 / 升级插件 之前）
/www/SuguangWebGuard/unlock.sh

#   ... 在宝塔面板或命令行里正常操作 ...

# 改完锁回去
/www/SuguangWebGuard/lock.sh

# 如果确实修改了网站文件，重建 AIDE 基线（否则次日会收到告警）
/www/SuguangWebGuard/aide-init.sh
```

只操作单个站点时在命令后加站点路径：

```bash
/www/SuguangWebGuard/unlock.sh /www/wwwroot/suguang.cc
/www/SuguangWebGuard/lock.sh   /www/wwwroot/suguang.cc
```



状态字段含义：

- `已保护` —— 应锁文件全部已加锁
- `未保护` —— 一个都没锁，需运行 `lock.sh`
- `部分保护（有 N 个新增文件未锁）` —— 出现了新文件。确认是正常业务产生的就跑
  `lock.sh` 纳入保护；来源不明的先查 `alert.log` 和 AIDE 报告

---

## 配置说明

只需要编辑 `exclude.conf`。三种指令：

```conf
SITE=/www/wwwroot/suguang.cc       # 受保护站点根目录（绝对路径）
EXCLUDE=runtime                     # 保持可写、不加锁的目录（相对站点根）
PHPOK=runtime/complile              # 允许程序在此生成 .php，监控不告警（相对站点根）
```

- 以 `#` 开头为注释
- `EXCLUDE` / `PHPOK` 归属于它上方最近的那个 `SITE`
- 修改后需重新运行 `lock.sh`；改了 `PHPOK` 还要
  `systemctl restart suguang-webguard-watch`

### 各类 CMS 的典型配置

**PbootCMS**

```conf
SITE=/www/wwwroot/suguang.cc
EXCLUDE=runtime          # 模板编译缓存、session、配置缓存
EXCLUDE=data             # SQLite 数据库文件
EXCLUDE=static/upload    # 后台图片上传
EXCLUDE=static/backup    # 数据库备份 / 升级备份
EXCLUDE=.well-known      # SSL 证书自动续签验证目录
PHPOK=runtime/complile
PHPOK=runtime/config
PHPOK=runtime/data
PHPOK=runtime/archive
PHPOK=static/backup
```

**帝国 CMS**

```conf
SITE=/www/wwwroot/example2.com
EXCLUDE=e/data
EXCLUDE=d/file
EXCLUDE=.well-known
EXCLUDE=生成静态页的目录   # 如 yysuv/，这类目录会反复覆盖已有 html
PHPOK=e/data/tmp
```

> 排除清单应根据站点近 90 天实际写入行为统计得出，**不要照抄**。
> 用 `detect.sh` 自动探测，见[新增站点](#新增站点)。

---

## 维护模式

这是本系统最重要的一个机制，**必须理解**。

`unlock.sh` 会创建 `.maintenance` 标记文件，守护进程在该标记存在期间
**只写日志、不隔离文件**。`lock.sh` 会删除该标记，恢复自动隔离。

**为什么需要它**：解锁后你去改一个 PHP 文件，对守护来说这就是「非白名单路径出现
了一个未加锁的 PHP 文件」，会被当成 webshell 隔离掉。开发过程中实测出现过这个
问题——网站核心文件被隔离，直接 404。

> **改文件一定要走 `unlock.sh`，不要手动 `chattr -i`。**
> 手动解锁不会进入维护模式，守护会把你改的文件搬走。

维护模式下的日志：

```
2026-09-05 01:30:10 [维护模式-仅记录] 脚本文件变动(实时): /www/wwwroot/suguang.cc/core/basic/Check.php
```

---

## 加锁状态下的行为

### 会失败，需先 unlock.sh

- 宝塔面板修改网站配置、伪静态规则、SSL 设置
- 后台「模板管理」在线编辑模板文件
- 后台「网站配置」保存（会写 `config/config.php`）
- 覆盖任何已有文件、程序升级、插件安装

### 不受影响，可正常使用

- 后台发布 / 编辑 / 删除文章（数据在数据库里，已排除）
- 后台上传图片（上传目录已排除）
- 模板编译缓存生成（运行时目录已排除）
- 数据库备份
- SSL 证书自动续签
- 前台所有访问

---

## 新增站点

**不要直接照抄别的站点的排除清单**，不同 CMS 的可写目录差别很大。

**1. 探测该站点需要保持可写的目录**

```bash
/www/SuguangWebGuard/detect.sh /www/wwwroot/要加的站点 90
```

`detect.sh` 的判定证据（命中任一即「确定排除」）：

1. 整条路径命中常见可写目录白名单（`static/upload`、`e/data`、`runtime` 等）
2. 末级目录名明确是上传/附件目录
3. 近 N 天有 ≥3 个文件被写入（程序在持续写）
4. 近 N 天被写入的文件里有**非代码文件**（`.db` / `.log` / 图片 / 无扩展名等）
   —— 这是区分「程序在写数据」和「人工改了几个 .php」的关键判据

输出分两块：

- `EXCLUDE=` / `PHPOK=` 开头的是**确定项**
- `# EXCLUDE=` 注释掉的是**待人工确认项**——只有少量代码文件被改动、或仅目录名
  像运行时目录的，一律列到这里，不会自动排除

**2. 把结果追加到 exclude.conf**

```bash
/www/SuguangWebGuard/detect.sh /www/wwwroot/要加的站点 90 >> /www/SuguangWebGuard/exclude.conf
vi /www/SuguangWebGuard/exclude.conf     # 核对，处理待确认项
```

**3. 加锁 + 重启守护 + 重建基线**

```bash
/www/SuguangWebGuard/lock.sh /www/wwwroot/要加的站点
systemctl restart suguang-webguard-watch     # 让 PHPOK 白名单生效
/www/SuguangWebGuard/aide-init.sh           # 自动重新生成 AIDE 配置
```

> `/www/SuguangWebGuard/aide.conf` 由 `aide-init.sh` 根据 `exclude.conf`
> 自动生成，**不要手工编辑**，改了也会被覆盖。站点和排除项只需在
> `exclude.conf` 里维护一处。

**4. 观察 2 天**，确认业务无异常，再看 `status.sh` 和 `alert.log` 有无异常告警。

---

## Web 管理界面

用浏览器查看保护状态、管理隔离区、看日志、加解锁，功能与命令行等价。

### 技术选型说明

用 **Python 3（纯标准库，零第三方依赖）**，不是 PHP。原因：

- 管理界面必须能执行 `chattr`、`systemctl`、读日志目录，**全部需要 root**。
  而 php-fpm 跑在 `www` 用户下，用 PHP 就得给 `www` 配 sudo —— `www` 正是网站
  被 RCE 后攻击者获得的身份，等于把防篡改的钥匙交出去。
- PHP 页面得放在被保护的站点目录里，会被监控守护当成 webshell 隔离掉。
- 不用 Flask/Django，避免在老系统上引入 pip 依赖链。常驻内存约 15 MB。

服务以 root 独立运行（`suguang-webguard-web.service`），与 nginx / php-fpm
完全隔离，底层直接复用 `status.sh` / `lock.sh` / `detect.sh` 等脚本。

### 访问

```
http://服务器IP:19196
```

首次启动会自动生成随机密码，写在 `/www/SuguangWebGuard/web-initial-password.txt`
（权限 600），安装脚本也会打印一次。**登录后请立刻用右上角「改密码」修改。**

> **云服务器注意**：仅在系统防火墙放行不够，还要在云厂商控制台的**安全组**里放行
> 该端口的入方向。两层是独立的。阿里云：ECS → 安全组 → 配置规则 → 入方向 →
> 自定义 TCP → 端口 `19196/19196`。
>
> 授权对象**强烈建议填你自己的 IP 段而非 `0.0.0.0/0`** —— 这个页面能一键解除
> 全部防篡改保护，是最高价值的攻击目标。

若暂时不想开端口，可用 SSH 隧道访问（不经过安全组）：

```bash
ssh -L 19196:127.0.0.1:19196 root@服务器IP -N
# 然后浏览器打开 http://127.0.0.1:19196
```

### 功能

| 页签 | 内容 |
|---|---|
| **总览** | 守护状态、维护模式、隔离区数量、AIDE 基线时间；各站点保护状态、已锁/应锁进度、可写目录与 PHP 白名单；一键加锁/解锁（全部或单站）、启停守护 |
| **隔离区** | 被拦截文件列表，可查看内容、恢复到原路径（自动停守护→写回→加锁→重启守护）、删除 |
| **日志** | alert / action / aide-report / watch / web 五类日志，可选 200/500/2000 行 |
| **配置** | 在线编辑 `exclude.conf`，保存前自动备份原文件 |
| **工具** | 探测新站点可写目录、AIDE 立即核查、重建基线 |

所有写操作走后台任务 + 前端轮询进度，重建基线等长耗时操作不会卡住页面。

### 安全机制

| 项 | 实现 |
|---|---|
| 密码存储 | PBKDF2-HMAC-SHA256，12 万次迭代，随机 salt；`web.conf` 权限 600 |
| 会话 | Cookie `HttpOnly` + `SameSite=Strict`，8 小时过期 |
| CSRF | 所有写操作校验 `X-CSRF-Token`，令牌随会话生成 |
| 登录限速 | 同一 IP 连续 5 次失败封禁 10 分钟 |
| 路径穿越 | 隔离区文件名拒绝 `/` 与 `..`；恢复目标强制限定在 `/www/` 下 |
| 审计 | 登录、加锁、解锁、改配置全部写入 `action.log`，与命令行操作合并为同一条时间线 |

### 配置文件 web.conf

```json
{
  "bind": "0.0.0.0",
  "port": 19196,
  "user": "admin",
  "salt": "...",
  "pwhash": "...",
  "allow_cidr": []
}
```

改端口或改为只监听本机（`"bind": "127.0.0.1"`）后需重启：

```bash
systemctl restart suguang-webguard-web
```

忘记密码时，删掉 `pwhash` 字段再重启服务，会重新生成随机密码。

### 常用命令

```bash
systemctl status suguang-webguard-web      # 状态
systemctl restart suguang-webguard-web     # 重启
journalctl -u suguang-webguard-web -n 50   # 排错
tail -f /www/SuguangWebGuard/logs/web.log  # 访问与操作日志
```

---

## 日志

```
/www/SuguangWebGuard/logs/
├── alert.log         拦截 / 告警 / 维护模式记录     ← 平时主要看这个
├── action.log        加锁解锁与 Web 操作记录
├── aide-report.log   每日完整性核查报告
├── watch.log         守护进程自身输出
└── web.log           Web 界面访问与操作
```

轮转策略：每周一次，保留 12 份，压缩。
同时写 syslog，可用 `grep suguang-webguard /var/log/messages` 查看。

`alert.log` 的记录类型：

```
[拦截](实时)          inotify 实时发现并已隔离
[拦截](定期扫描)      每 60 秒兜底扫描发现并已隔离
[告警]                发现新增脚本但隔离失败（检查权限）
[维护模式-仅记录]      解锁期间的文件变动，未做处理
[AIDE告警]            每日核查发现变更
```

---

## 故障排查

### 网站报错 / 白屏，怀疑是加锁导致

```bash
tail -50 /www/wwwlogs/站点域名.error.log      # 看是不是 Permission denied
/www/SuguangWebGuard/unlock.sh                # 先解锁排除嫌疑
```

解锁后恢复正常，说明有目录漏加进 `EXCLUDE`。用 `detect.sh` 重新探测，
补进 `exclude.conf` 再重新 `lock.sh`。

### 正常文件被误隔离了

**推荐**：Web 界面 → 隔离区 → 找到文件 → 「恢复」，填原路径即可，
系统会自动停守护、写回、加锁、重启守护。

命令行方式：

```bash
ls -la /www/SuguangWebGuard/quarantine/
systemctl stop suguang-webguard-watch          # 先停守护，否则拷回去又被搬走
cp /www/SuguangWebGuard/quarantine/时间戳-文件名.php /原路径/文件名.php
chown www:www /原路径/文件名.php
chattr +i /原路径/文件名.php                   # 加锁后守护就不会再动它
systemctl start suguang-webguard-watch
```

隔离区文件名格式：`YYYYMMDD-HHMMSS-PID-原文件名`，原路径见 `alert.log`。

### 守护没在跑

```bash
systemctl status suguang-webguard-watch
journalctl -u suguang-webguard-watch -n 50 --no-pager
tail -50 /www/SuguangWebGuard/logs/watch.log
systemctl restart suguang-webguard-watch
```

### 告警日志里出现「inotify 监视数不足」

内核为**每个被监视的目录**占用一个 inotify watch，而 `fs.inotify.max_user_watches`
默认只有 **8192**。站点目录上万时（多站点服务器很容易超），`inotifywait` 会直接
启动失败，实时监控起不来。

先看差多少：

```bash
cat /proc/sys/fs/inotify/max_user_watches      # 当前上限
find /www/wwwroot -type d | wc -l              # 实际需要的数量
```

`install.sh` 会自动把上限抬到 524288。若是手工部署或容器环境没生效，手动执行：

```bash
cat > /etc/sysctl.d/99-suguang-webguard.conf <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sysctl -p /etc/sysctl.d/99-suguang-webguard.conf
systemctl restart suguang-webguard-watch
```

watch 是按需分配的，抬高上限本身不占内存（满配约 1KB/watch）。

**这种情况下防护不会中断**：实时监控起不来时守护会自动降级，保留每 60 秒的
全量扫描继续拦截，并每 5 分钟重试恢复实时监控。降级只是把响应延迟从毫秒级
变成约 1 分钟，日志里会明确写出当前处于降级状态。

### AIDE 每天都报变更

说明保护范围内有文件在持续变动，两种可能：

1. 有可写目录没排除 —— 看报告里是哪些文件，补进 `exclude.conf` 的 `EXCLUDE`，
   然后重跑 `aide-init.sh`（会自动重新生成 AIDE 配置）
2. 你自己改过文件但没重建基线 —— 跑 `aide-init.sh`

### lock.sh 提示有文件未能加锁

```bash
cd /www/SuguangWebGuard && . ./common.sh
S=/www/wwwroot/suguang.cc; build_prune $S
find $S "${FIND_PRUNE[@]}" -type f -print0 | while IFS= read -r -d '' f; do
  lsattr -d "$f" 2>/dev/null | grep -q '^....i' || echo "未锁: $f"
done
```

常见原因：文件系统不支持 immutable、文件正被占用、特殊文件类型。

### Web 界面打不开

按顺序排查：

```bash
systemctl is-active suguang-webguard-web        # 1. 服务是否在跑
ss -lntp | grep 19196                            # 2. 是否在监听
curl -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19196/   # 3. 本机能否访问
```

本机能访问但外网不行 —— 依次检查系统防火墙和**云服务器安全组**。
判断方法：从服务器上访问自己的公网 IP，若不通而访问 127.0.0.1 通，就是安全组拦的。

```bash
timeout 5 bash -c "echo > /dev/tcp/你的公网IP/19196" && echo 通 || echo 不通
```

---

## 实测验证结果

以下均为在生产服务器上实际执行的对抗测试。

### 场景 A：攻击者行为（以 www 用户执行，即 PHP 被 RCE 后的权限）

| 动作 | 结果 |
|---|---|
| 篡改 `core/basic/Check.php`（真实事件的核心动作） | 已阻止 |
| 覆盖首页模板 `template/default/index.html` | 已阻止 |
| 删除 `index.php` | 已阻止 |
| 重命名 `admin.php` | 已阻止 |
| 读取 / 执行 PHP 文件 | 正常允许 |
| 投放 webshell 到 `runtime/upgrade/`（真实事件的落地路径） | 已隔离 |

### 场景 B：root 绕过

先 `chattr -i` 再篡改 —— chattr 层被绕过（预期内），但 AIDE 当场报出
`changed` / `removed`，守护也把被改的文件隔离了。

### 场景 C：管理员正常运维

`unlock.sh` → 修改核心文件、上传新 PHP → 全部允许，**未被误隔离**，
日志只记录不动手。

### 场景 D：无误伤

清空编译缓存后所有页面正常重新生成，HTTP 200，程序自身写入
`runtime/complile/*.php` 不触发告警。

### 场景 E：inotify 竞态与定期扫描兜底

连续 10 次「建目录 + 立刻写马」压力测试：

- 实时防线拦下 9 个，**漏掉 1 个**（竞态复现）
- 42 秒后定期扫描把漏网的 `sh4.php` 补捞，**10/10 全部清除**
- 告警日志标注来源：`(实时)` / `(定期扫描)`

这就是 `watch.sh` 里第二条防线存在的原因。

### 场景 F：Web 界面鉴权

| 测试 | 结果 |
|---|---|
| 未登录调 `/api/status` | 401 |
| 未登录调解锁接口 | 401 |
| 错误密码登录 | 拒绝 |
| 已登录但不带 CSRF 令牌解锁 | 拒绝 |
| `?name=../../etc/passwd` 读隔离文件 | 拒绝 |
| 恢复隔离文件到 `/etc/evil.php` | 拒绝（强制 `/www/` 前缀） |
| 网页触发解锁 → `index.php` 的 `i` 属性 | 确实消失，维护模式自动开启 |
| 网页触发加锁 → 恢复 745/745 | 维护模式自动关闭 |

### 场景 G：宝塔面板侧验证

通过宝塔文件管理器（以 root 身份）操作受保护站点：

| 操作 | 结果 |
|---|---|
| 重命名 `nginx.txt` | **原文件保住** —— 宝塔走「先复制后删除」，复制成功、删原件被内核拒绝 |
| 删除文件 | 已阻止 |
| 新建文件并写入 | 允许（新建文件是设计上放行的） |

> 面板日志里这些请求都返回 HTTP 200，那只是接口调用成功，**实际文件操作被内核挡掉了**。

---

## 局限性

必须清楚知道这套方案做不到什么：

1. **不阻止新建文件。** 这是刻意放行的设计。攻击者仍可写入新的 webshell，靠第
   二层隔离兜底。
   > 建议补做：给可写目录加 nginx `location ~ \.php$ { deny all; }`，
   > 让新落地的 PHP 根本无法执行。

2. **拿到 root 就能绕过第一层。** `chattr -i` 需 root 权限，只能靠 AIDE 事后发现。

3. **不按进程授权。** 无法做到「只有发布程序能写」，所以运维必须手动 unlock/lock。

4. **不保护数据库内容。** 排除目录不在保护范围内，SQL 注入改数据库、往上传目录
   传图片马都不受本方案约束。

5. **inotify 有队列上限。** 极端高频写入可能丢事件，定期扫描兜底，可调
   `/proc/sys/fs/inotify/max_queued_events`。

6. **隔离层只认扩展名。** 只拦 `.php` `.php5` `.php7` `.phtml` `.phar` `.pht`
   `.phps`。若 nginx 配置了其他后缀解析 PHP，需同步修改 `watch.sh` 的匹配列表。

7. **定期扫描有最长 60 秒的窗口。** 竞态漏网的文件最多存活 60 秒。可通过
   `SWEEP_INTERVAL` 环境变量调小，代价是 IO 开销上升。

---

## 卸载

```bash
/www/SuguangWebGuard/uninstall.sh
```

会依次完成：

1. 停止并移除 `suguang-webguard-watch` 与 `suguang-webguard-web` 服务
2. 移除 cron / logrotate 配置
3. **解锁所有受保护站点的文件**（关键步骤）
4. 复查是否还有残留的 immutable 文件并报告
5. 删除程序目录、Web 配置、AIDE 配置与基线库（隔离区非空时自动保留到
   `/www/SuguangWebGuard-quarantine-<时间戳>`）
6. 删除日志（加 `--keep-logs` 可保留）

参数：

| 参数 | 作用 |
|---|---|
| `--keep-logs` | 保留 `/www/SuguangWebGuard/logs/` |
| `--yes` / `-y` | 不交互确认 |

> 卸载**必须**通过 `uninstall.sh`，因为它会先解锁文件。
> 如果已经手工删掉了程序目录，被锁的文件需要这样手工解锁：
>
> ```bash
> find /www/wwwroot/站点 -type f -print0 | xargs -0 chattr -i
> find /www/wwwroot/站点 -type d -print0 | xargs -0 chattr -a
> ```

Web 端口的防火墙 / 安全组放行规则需自行撤销。
`aide` 与 `inotify-tools` 两个软件包不会被卸载（可能有其他用途）。



## 从旧版升级

本系统前身为 `antitamper`，1.1.0 起更名为 SuguangWebGuard；1.2.0 起所有文件
统一存放到 `/www/SuguangWebGuard` 一个目录内，便于查找与备份。

| 项 | v1.0（antitamper） | v1.1 | **v1.2（当前）** |
|---|---|---|---|
| 程序目录 | `/root/antitamper` | `/root/SuguangWebGuard` | `/www/SuguangWebGuard` |
| 日志 | `/var/log/antitamper` | `/var/log/suguang-webguard` | `/www/SuguangWebGuard/logs` |
| AIDE 配置 | `/etc/aide/aide-web.conf` | `/etc/suguang-webguard/aide.conf` | `/www/SuguangWebGuard/aide.conf` |
| AIDE 基线 | `/var/lib/aide/aide-web.db.gz` | `/var/lib/suguang-webguard/aide.db.gz` | `/www/SuguangWebGuard/aide.db.gz` |
| 守护服务 | `antitamper-watch` | `suguang-webguard-watch` | 同 v1.1 |
| Web 服务 | `antitamper-web` | `suguang-webguard-web` | 同 v1.1 |

只有 systemd 单元、cron、logrotate 三个文件因系统要求仍在 `/etc` 下，
它们全部指向 `/www/SuguangWebGuard`。

直接运行新版 `install.sh` 即可，它会**自动检测旧版（v1.0 / v1.1 均支持）并询问
是否迁移**。迁移动作：

- 停用并移除旧服务、旧 cron / logrotate
- 沿用旧的 `exclude.conf`、`web.conf`（账号密码不变）、隔离区、历史日志
- 删除旧目录、旧 AIDE 基线与残留的空配置目录

> 站点文件上的 `chattr +i` 锁打在文件 inode 上，与工具安装路径无关，
> **迁移过程中保护不会中断**，也不需要先解锁。
> 迁移后需重建一次 AIDE 基线（安装脚本最后一步会询问）。

---

## 关于

**SuguangWebGuard 网站防篡改系统**

速光网络软件开发 · [suguang.cc](https://suguang.cc)
