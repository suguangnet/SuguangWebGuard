#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SuguangWebGuard Web 管理界面
纯标准库实现，无第三方依赖，兼容 Python 3.6+
以 root 运行（需要 chattr / systemctl 权限），由 systemd 服务 suguang-webguard-web 拉起。
"""
import os
import re
import io
import sys
import json
import time
import shlex
import hmac
import base64
import hashlib
import secrets
import threading
import subprocess
import traceback
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from urllib.parse import urlparse, parse_qs

PREFIX = '/www/SuguangWebGuard'
WEBDIR = os.path.join(PREFIX, 'web')
CONF = os.path.join(PREFIX, 'web.conf')
EXCLUDE_CONF = os.path.join(PREFIX, 'exclude.conf')
QUAR = os.path.join(PREFIX, 'quarantine')
LOGDIR = '/www/SuguangWebGuard/logs'
ACTION_LOG = os.path.join(LOGDIR, 'action.log')
ALERT_LOG = os.path.join(LOGDIR, 'alert.log')
AIDE_LOG = os.path.join(LOGDIR, 'aide-report.log')
WATCH_LOG = os.path.join(LOGDIR, 'watch.log')
WEB_LOG = os.path.join(LOGDIR, 'web.log')

SESSION_TTL = 8 * 3600
LOGIN_MAX_FAIL = 5
LOGIN_BAN_SEC = 600

# ---------------------------------------------------------------- 工具

def now():
    return time.strftime('%Y-%m-%d %H:%M:%S')


def wlog(msg):
    try:
        with open(WEB_LOG, 'a') as f:
            f.write('%s %s\n' % (now(), msg))
    except Exception:
        pass


def audit(msg):
    """写操作审计，同时进 action.log，便于和命令行操作合并追溯"""
    line = '%s [WEB] %s' % (now(), msg)
    for p in (ACTION_LOG, WEB_LOG):
        try:
            with open(p, 'a') as f:
                f.write(line + '\n')
        except Exception:
            pass


def run(cmd, timeout=600):
    """执行命令，返回 (returncode, stdout+stderr)"""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        out, _ = p.communicate(timeout=timeout)
        return p.returncode, out.decode('utf-8', 'replace')
    except subprocess.TimeoutExpired:
        try:
            p.kill()
        except Exception:
            pass
        return 124, '命令执行超时（%ds）' % timeout
    except Exception as e:
        return 1, '执行失败: %s' % e


def tail(path, lines=200):
    if not os.path.exists(path):
        return ''
    try:
        size = os.path.getsize(path)
        with open(path, 'rb') as f:
            block = 64 * 1024
            data = b''
            pos = size
            while pos > 0 and data.count(b'\n') <= lines:
                step = min(block, pos)
                pos -= step
                f.seek(pos)
                data = f.read(step) + data
        text = data.decode('utf-8', 'replace')
        return '\n'.join(text.splitlines()[-lines:])
    except Exception as e:
        return '读取失败: %s' % e


# ---------------------------------------------------------------- 配置

DEFAULT_CONF = {
    'bind': '0.0.0.0',
    'port': 19196,
    'user': 'admin',
    'salt': '',
    'pwhash': '',
    'allow_cidr': [],
}


def hash_pw(pw, salt):
    return base64.b64encode(
        hashlib.pbkdf2_hmac('sha256', pw.encode('utf-8'), salt.encode('utf-8'), 120000)
    ).decode('ascii')


def load_conf():
    c = dict(DEFAULT_CONF)
    if os.path.exists(CONF):
        try:
            with open(CONF) as f:
                c.update(json.load(f))
        except Exception as e:
            wlog('配置读取失败: %s' % e)
    return c


def save_conf(c):
    with open(CONF, 'w') as f:
        json.dump(c, f, indent=2, ensure_ascii=False)
    os.chmod(CONF, 0o600)


CFG = load_conf()

# ---------------------------------------------------------------- 会话

SESSIONS = {}
SESS_LOCK = threading.Lock()
FAILS = {}


def new_session(ip):
    sid = secrets.token_urlsafe(32)
    with SESS_LOCK:
        SESSIONS[sid] = {'ip': ip, 'exp': time.time() + SESSION_TTL,
                         'csrf': secrets.token_urlsafe(24)}
    return sid


def get_session(sid):
    if not sid:
        return None
    with SESS_LOCK:
        s = SESSIONS.get(sid)
        if not s:
            return None
        if s['exp'] < time.time():
            SESSIONS.pop(sid, None)
            return None
        return s


def drop_session(sid):
    with SESS_LOCK:
        SESSIONS.pop(sid, None)


def login_banned(ip):
    r = FAILS.get(ip)
    if not r:
        return 0
    cnt, last = r
    if cnt >= LOGIN_MAX_FAIL and time.time() - last < LOGIN_BAN_SEC:
        return int(LOGIN_BAN_SEC - (time.time() - last))
    if time.time() - last >= LOGIN_BAN_SEC:
        FAILS.pop(ip, None)
    return 0


def login_fail(ip):
    cnt, _ = FAILS.get(ip, (0, 0))
    FAILS[ip] = (cnt + 1, time.time())


# ---------------------------------------------------------------- 后台任务

JOBS = {}
JOB_LOCK = threading.Lock()


def start_job(name, cmd, timeout=900):
    jid = secrets.token_hex(8)
    with JOB_LOCK:
        JOBS[jid] = {'name': name, 'state': 'running', 'out': '',
                     'rc': None, 'start': now()}

    def worker():
        rc, out = run(cmd, timeout=timeout)
        with JOB_LOCK:
            JOBS[jid].update(state='done', rc=rc, out=out, end=now())

    threading.Thread(target=worker, daemon=True).start()
    return jid


# ---------------------------------------------------------------- 数据采集

def parse_exclude_conf():
    """解析 exclude.conf -> [{site, excludes[], phpok[]}]"""
    sites = []
    cur = None
    if not os.path.exists(EXCLUDE_CONF):
        return sites
    with open(EXCLUDE_CONF, encoding='utf-8', errors='replace') as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('SITE='):
                cur = {'site': line[5:].strip(), 'excludes': [], 'phpok': []}
                sites.append(cur)
            elif cur and line.startswith('EXCLUDE='):
                cur['excludes'].append(line[8:].strip())
            elif cur and line.startswith('PHPOK='):
                cur['phpok'].append(line[6:].strip())
    return sites


def site_stats(site, excludes):
    """统计应锁文件数与已锁文件数"""
    if not os.path.isdir(site):
        return {'exists': False, 'total': 0, 'locked': 0}
    ex_abs = [os.path.join(site, e) for e in excludes]
    total = 0
    files = []
    for root, dirs, fnames in os.walk(site):
        skip = False
        for e in ex_abs:
            if root == e or root.startswith(e + os.sep):
                skip = True
                break
        if skip:
            dirs[:] = []
            continue
        dirs[:] = [d for d in dirs
                   if os.path.join(root, d) not in ex_abs]
        for fn in fnames:
            files.append(os.path.join(root, fn))
    total = len(files)

    locked = 0
    CH = 400
    for i in range(0, len(files), CH):
        chunk = files[i:i + CH]
        try:
            p = subprocess.Popen(['lsattr', '-d'] + chunk,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            out, _ = p.communicate(timeout=120)
            for ln in out.decode('utf-8', 'replace').splitlines():
                if len(ln) > 4 and ln[4] == 'i':
                    locked += 1
        except Exception:
            pass
    return {'exists': True, 'total': total, 'locked': locked}


def svc_active(name):
    rc, out = run(['systemctl', 'is-active', name], timeout=15)
    return out.strip() == 'active'


def collect_status(fast=False):
    sites = parse_exclude_conf()
    out = []
    for s in sites:
        item = {'site': s['site'], 'excludes': s['excludes'], 'phpok': s['phpok']}
        if fast:
            item.update(exists=os.path.isdir(s['site']), total=None, locked=None)
        else:
            item.update(site_stats(s['site'], s['excludes']))
        if item.get('total'):
            if item['locked'] == 0:
                item['state'] = 'unprotected'
            elif item['locked'] >= item['total']:
                item['state'] = 'protected'
            else:
                item['state'] = 'partial'
        else:
            item['state'] = 'unknown'
        out.append(item)

    q = []
    if os.path.isdir(QUAR):
        for fn in sorted(os.listdir(QUAR), reverse=True):
            fp = os.path.join(QUAR, fn)
            try:
                st = os.stat(fp)
                q.append({'name': fn, 'size': st.st_size,
                          'time': time.strftime('%Y-%m-%d %H:%M:%S',
                                                time.localtime(st.st_mtime))})
            except Exception:
                pass

    maint = os.path.exists(os.path.join(PREFIX, '.maintenance'))
    aide_db = '/www/SuguangWebGuard/aide.db.gz'
    return {
        'time': now(),
        'sites': out,
        'quarantine': q,
        'maintenance': maint,
        'watch_active': svc_active('suguang-webguard-watch'),
        'aide_baseline': (time.strftime('%Y-%m-%d %H:%M:%S',
                                        time.localtime(os.path.getmtime(aide_db)))
                          if os.path.exists(aide_db) else None),
        'host': os.uname()[1],
    }


# ---------------------------------------------------------------- HTTP

def json_bytes(obj):
    return json.dumps(obj, ensure_ascii=False).encode('utf-8')


class Handler(BaseHTTPRequestHandler):
    server_version = 'suguang-webguard-web'
    sys_version = ''

    def log_message(self, fmt, *args):
        pass

    # ---- 基础响应
    def _send(self, code, body=b'', ctype='application/json; charset=utf-8', extra=None):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Referrer-Policy', 'no-referrer')
        if extra:
            for k, v in extra:
                self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def _json(self, obj, code=200, extra=None):
        self._send(code, json_bytes(obj), extra=extra)

    def _err(self, msg, code=400):
        self._json({'ok': False, 'msg': msg}, code)

    # ---- 会话
    def _cookies(self):
        raw = self.headers.get('Cookie', '')
        d = {}
        for part in raw.split(';'):
            if '=' in part:
                k, v = part.split('=', 1)
                d[k.strip()] = v.strip()
        return d

    def _sid(self):
        return self._cookies().get('at_sid')

    def _sess(self):
        return get_session(self._sid())

    def _client_ip(self):
        return self.client_address[0]

    def _body(self):
        try:
            n = int(self.headers.get('Content-Length', 0))
        except Exception:
            n = 0
        if n <= 0 or n > 8 * 1024 * 1024:
            return {}
        try:
            return json.loads(self.rfile.read(n).decode('utf-8'))
        except Exception:
            return {}

    def _require(self):
        s = self._sess()
        if not s:
            self._json({'ok': False, 'msg': '未登录', 'need_login': True}, 401)
            return None
        return s

    def _check_csrf(self, s):
        t = self.headers.get('X-CSRF-Token', '')
        if not t or not hmac.compare_digest(t, s['csrf']):
            self._err('CSRF 校验失败，请刷新页面重试', 403)
            return False
        return True

    # ---- 路由
    def do_GET(self):
        try:
            u = urlparse(self.path)
            p, q = u.path, parse_qs(u.query)
            if p in ('/', '/index.html'):
                return self._file(os.path.join(WEBDIR, 'index.html'), 'text/html; charset=utf-8')
            if p == '/api/whoami':
                s = self._sess()
                return self._json({'ok': True, 'login': bool(s),
                                   'csrf': s['csrf'] if s else '',
                                   'user': CFG.get('user', 'admin')})
            if p == '/api/status':
                if not self._require():
                    return
                fast = q.get('fast', ['0'])[0] == '1'
                return self._json({'ok': True, 'data': collect_status(fast)})
            if p == '/api/logs':
                if not self._require():
                    return
                kind = q.get('type', ['alert'])[0]
                n = min(int(q.get('lines', ['300'])[0] or 300), 3000)
                m = {'alert': ALERT_LOG, 'action': ACTION_LOG,
                     'aide': AIDE_LOG, 'watch': WATCH_LOG, 'web': WEB_LOG}
                if kind not in m:
                    return self._err('未知日志类型')
                return self._json({'ok': True, 'text': tail(m[kind], n)})
            if p == '/api/config':
                if not self._require():
                    return
                txt = ''
                if os.path.exists(EXCLUDE_CONF):
                    with open(EXCLUDE_CONF, encoding='utf-8', errors='replace') as f:
                        txt = f.read()
                return self._json({'ok': True, 'text': txt})
            if p == '/api/quarantine/view':
                if not self._require():
                    return
                name = q.get('name', [''])[0]
                fp = self._quar_path(name)
                if not fp:
                    return self._err('文件不存在')
                with open(fp, 'rb') as f:
                    data = f.read(200000)
                return self._json({'ok': True,
                                   'text': data.decode('utf-8', 'replace')})
            if p.startswith('/api/job/'):
                if not self._require():
                    return
                jid = p.rsplit('/', 1)[-1]
                with JOB_LOCK:
                    j = JOBS.get(jid)
                if not j:
                    return self._err('任务不存在')
                return self._json({'ok': True, 'job': j})
            return self._err('Not Found', 404)
        except Exception as e:
            wlog('GET %s 异常: %s' % (self.path, traceback.format_exc()))
            return self._err('服务端错误: %s' % e, 500)

    def do_POST(self):
        try:
            p = urlparse(self.path).path
            if p == '/api/login':
                return self._login()
            if p == '/api/logout':
                sid = self._sid()
                if sid:
                    drop_session(sid)
                return self._json({'ok': True}, extra=[('Set-Cookie',
                                                        'at_sid=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict')])
            s = self._require()
            if not s:
                return
            if not self._check_csrf(s):
                return
            if p == '/api/action':
                return self._action(s)
            if p == '/api/config':
                return self._save_config(s)
            if p == '/api/quarantine/restore':
                return self._quar_restore(s)
            if p == '/api/quarantine/delete':
                return self._quar_delete(s)
            if p == '/api/password':
                return self._change_pw(s)
            return self._err('Not Found', 404)
        except Exception as e:
            wlog('POST %s 异常: %s' % (self.path, traceback.format_exc()))
            return self._err('服务端错误: %s' % e, 500)

    # ---- 具体处理
    def _file(self, path, ctype):
        if not os.path.exists(path):
            return self._send(404, b'404', 'text/plain')
        with open(path, 'rb') as f:
            data = f.read()
        return self._send(200, data, ctype)

    def _login(self):
        ip = self._client_ip()
        left = login_banned(ip)
        if left:
            return self._err('登录失败次数过多，请 %d 秒后再试' % left, 429)
        b = self._body()
        user = b.get('user', '')
        pw = b.get('pass', '')
        ok = (user == CFG.get('user') and CFG.get('pwhash') and
              hmac.compare_digest(hash_pw(pw, CFG.get('salt', '')), CFG['pwhash']))
        if not ok:
            login_fail(ip)
            wlog('登录失败 ip=%s user=%s' % (ip, user))
            return self._err('用户名或密码错误')
        FAILS.pop(ip, None)
        sid = new_session(ip)
        s = get_session(sid)
        audit('登录成功 ip=%s user=%s' % (ip, user))
        return self._json({'ok': True, 'csrf': s['csrf']},
                          extra=[('Set-Cookie',
                                  'at_sid=%s; Path=/; Max-Age=%d; HttpOnly; SameSite=Strict'
                                  % (sid, SESSION_TTL))])

    def _action(self, s):
        b = self._body()
        op = b.get('op', '')
        site = b.get('site', '') or ''
        if site and not self._valid_site(site):
            return self._err('未知站点')
        ip = self._client_ip()
        sh = lambda *a: [x for x in a if x]

        if op == 'lock':
            audit('执行 lock.sh %s (ip=%s)' % (site or 'ALL', ip))
            jid = start_job('加锁', sh(os.path.join(PREFIX, 'lock.sh'), site))
        elif op == 'unlock':
            audit('执行 unlock.sh %s (ip=%s)' % (site or 'ALL', ip))
            jid = start_job('解锁', sh(os.path.join(PREFIX, 'unlock.sh'), site))
        elif op == 'restart_watch':
            audit('重启监控守护 (ip=%s)' % ip)
            jid = start_job('重启守护', ['systemctl', 'restart', 'suguang-webguard-watch'], timeout=60)
        elif op == 'stop_watch':
            audit('停止监控守护 (ip=%s)' % ip)
            jid = start_job('停止守护', ['systemctl', 'stop', 'suguang-webguard-watch'], timeout=60)
        elif op == 'start_watch':
            audit('启动监控守护 (ip=%s)' % ip)
            jid = start_job('启动守护', ['systemctl', 'start', 'suguang-webguard-watch'], timeout=60)
        elif op == 'aide_init':
            audit('重建 AIDE 基线 (ip=%s)' % ip)
            jid = start_job('重建基线', [os.path.join(PREFIX, 'aide-init.sh')], timeout=1800)
        elif op == 'aide_check':
            audit('执行 AIDE 核查 (ip=%s)' % ip)
            jid = start_job('完整性核查', [os.path.join(PREFIX, 'aide-check.sh')], timeout=1800)
        elif op == 'detect':
            tgt = b.get('path', '')
            days = str(int(b.get('days', 90)))
            if not tgt or not os.path.isdir(tgt):
                return self._err('目录不存在')
            audit('探测目录 %s (ip=%s)' % (tgt, ip))
            jid = start_job('探测可写目录',
                            [os.path.join(PREFIX, 'detect.sh'), tgt, days], timeout=600)
        else:
            return self._err('未知操作')
        return self._json({'ok': True, 'job': jid})

    def _valid_site(self, site):
        return any(x['site'] == site for x in parse_exclude_conf())

    def _save_config(self, s):
        b = self._body()
        txt = b.get('text', '')
        if not isinstance(txt, str) or len(txt) > 512 * 1024:
            return self._err('内容非法')
        if 'SITE=' not in txt:
            return self._err('配置里没有任何 SITE= 行，拒绝保存')
        bak = EXCLUDE_CONF + '.bak.' + time.strftime('%Y%m%d%H%M%S')
        try:
            if os.path.exists(EXCLUDE_CONF):
                with open(EXCLUDE_CONF, 'rb') as f:
                    old = f.read()
                with open(bak, 'wb') as f:
                    f.write(old)
            with open(EXCLUDE_CONF, 'w', encoding='utf-8') as f:
                f.write(txt)
            audit('修改 exclude.conf (ip=%s，备份 %s)' % (self._client_ip(), os.path.basename(bak)))
            return self._json({'ok': True, 'backup': os.path.basename(bak)})
        except Exception as e:
            return self._err('保存失败: %s' % e)

    def _quar_path(self, name):
        if not name or '/' in name or '..' in name:
            return None
        fp = os.path.join(QUAR, name)
        if not os.path.isfile(fp):
            return None
        return fp

    def _quar_restore(self, s):
        b = self._body()
        name = b.get('name', '')
        dest = b.get('dest', '')
        fp = self._quar_path(name)
        if not fp:
            return self._err('隔离文件不存在')
        if not dest or not dest.startswith('/www/'):
            return self._err('目标路径必须在 /www/ 下')
        if '..' in dest:
            return self._err('目标路径非法')
        d = os.path.dirname(dest)
        if not os.path.isdir(d):
            return self._err('目标目录不存在: %s' % d)
        try:
            run(['systemctl', 'stop', 'suguang-webguard-watch'], timeout=60)
            with open(fp, 'rb') as f:
                data = f.read()
            with open(dest, 'wb') as f:
                f.write(data)
            run(['chown', 'www:www', dest], timeout=30)
            run(['chattr', '+i', dest], timeout=30)
            os.remove(fp)
            audit('恢复隔离文件 %s -> %s (ip=%s)' % (name, dest, self._client_ip()))
            return self._json({'ok': True, 'msg': '已恢复到 %s 并重新加锁' % dest})
        except Exception as e:
            return self._err('恢复失败: %s' % e)
        finally:
            run(['systemctl', 'start', 'suguang-webguard-watch'], timeout=60)

    def _quar_delete(self, s):
        b = self._body()
        name = b.get('name', '')
        fp = self._quar_path(name)
        if not fp:
            return self._err('隔离文件不存在')
        try:
            os.remove(fp)
            audit('删除隔离文件 %s (ip=%s)' % (name, self._client_ip()))
            return self._json({'ok': True})
        except Exception as e:
            return self._err('删除失败: %s' % e)

    def _change_pw(self, s):
        b = self._body()
        old = b.get('old', '')
        new = b.get('new', '')
        if len(new) < 8:
            return self._err('新密码至少 8 位')
        if not hmac.compare_digest(hash_pw(old, CFG.get('salt', '')), CFG.get('pwhash', '')):
            return self._err('原密码错误')
        salt = secrets.token_hex(16)
        CFG['salt'] = salt
        CFG['pwhash'] = hash_pw(new, salt)
        save_conf(CFG)
        audit('修改管理密码 (ip=%s)' % self._client_ip())
        return self._json({'ok': True})


class Server(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def ensure_password():
    """首次启动生成随机密码并打印，之后从配置读取"""
    if CFG.get('pwhash'):
        return None
    pw = secrets.token_urlsafe(12)
    salt = secrets.token_hex(16)
    CFG['salt'] = salt
    CFG['pwhash'] = hash_pw(pw, salt)
    save_conf(CFG)
    return pw


def main():
    os.makedirs(LOGDIR, exist_ok=True)
    pw = ensure_password()
    if pw:
        msg = ('=' * 56 + '\n'
               ' SuguangWebGuard Web 管理界面 首次启动\n'
               ' 用户名: %s\n'
               ' 密  码: %s\n'
               ' 请立即登录后修改密码。此密码只显示这一次，\n'
               ' 也已写入 %s\n' % (CFG['user'], pw, os.path.join(PREFIX, 'web-initial-password.txt'))
               + '=' * 56)
        print(msg, flush=True)
        try:
            p = os.path.join(PREFIX, 'web-initial-password.txt')
            with open(p, 'w') as f:
                f.write('user: %s\npass: %s\n生成于 %s\n' % (CFG['user'], pw, now()))
            os.chmod(p, 0o600)
        except Exception:
            pass
        wlog('已生成初始密码')

    bind = CFG.get('bind', '0.0.0.0')
    port = int(CFG.get('port', 19196))
    srv = Server((bind, port), Handler)
    wlog('Web 管理界面启动 %s:%d' % (bind, port))
    print('SuguangWebGuard web 监听 %s:%d' % (bind, port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
