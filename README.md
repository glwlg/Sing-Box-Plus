# 🚀 Sing-Box-Plus 一键管理脚本（可选协议：直连 + WARP）

开箱即用多协议节点，安装时可选择启用协议、配置 REALITY SNI、区域标识、Web 伪装站点、HTTPS 订阅与端口轮换。

* ✅ 已适配 **sing-box v1.13.x**（已固定为 v1.13.7）
* ✅ 支持 **WARP 出站**（官方 warp-cli，更高兼容性，非 wgcf）
* ✅ 一键生成证书（自签或 Let's Encrypt），一键 systemd 托管
* ✅ **更换端口**后自动重写配置、放行新端口并清理旧端口
* ✅ 分享链接分组打印，节点名称可带区域标识，例如 `🇯🇵日本`
* ✅ 可选 nginx Web 伪装页，自动生成 64 位订阅密码并提供订阅地址
* ✅ WARP 节点，将服务器 IP "变身" 为 Cloudflare 的中性出口，Gemini/Netflix/Disney+/YouTube 等流媒体解锁
* ✅ **新增 AnyTLS 协议**（直连 + WARP 各一个），抗流量分析能力更强

**🔔 2026年6月17日更新提醒：** 搭建好后最下面的hysteria2 节点改用 pinnedPeerCertSha256，适配 Xray-core v26.2.6+ 移除 allowInsecure 后旧节点无法启动的问题（自 2026-06-01 起生效）。若新节点在 v2rayN  下仍连不上，可在 v2rayN 中把该节点内核切回 sing-box / 原生 Hysteria2。

---

## ✨ 默认部署内容

安装时可以选择启用哪些协议；直接回车会启用全部协议。

**直连 10：**

* VLESS Reality（Vision 流）
* VLESS gRPC Reality
* Trojan Reality
* VMess WS
* Hysteria2（直连证书）
* Hysteria2 + OBFS(salamander)
* Shadowsocks 2022（2022-blake3-aes-256-gcm）
* Shadowsocks（aes-256-gcm）
* TUIC v5（ALPN h3，自签证书）
* **AnyTLS**（自签证书，sing-box v1.12+ 引入的新协议，抗流量分析）

**WARP：** 默认生成与直连相同协议的 WARP 副本，出站经 Cloudflare WARP；安装时可关闭。

> WARP 出站更利于流媒体解锁与回程质量。

**注意：Shadowsocks 2022 和 Shadowsocks 协议可能容易被封，不推荐使用。**

**关于 AnyTLS：** 这是 sing-box v1.12 起加入的新协议，使用标准 TLS 流量伪装，并通过 Padding 抵抗流量分析。客户端需要 sing-box 1.12+、Mihomo (Clash.Meta) 较新版本、Hiddify 较新版本，老版本 v2rayN/Shadowrocket 可能不支持。

---

## ✅ 支持系统

 - Debian 11+ ✅
 - Ubuntu 20.04+ ✅
 - CentOS Stream 9+ ✅
 - Rocky 9+ ✅
 - AlmaLinux 9+ ✅
 - Fedora 38+ ✅（dnf 分支覆盖）

已在 [Vultr](https://www.vultr.com/?ref=7048874) 上测试通过。

---

## 📥 一键安装 / 更新脚本

```bash
wget -O sing-box-plus.sh https://raw.githubusercontent.com/Alvin9999-newpac/Sing-Box-Plus/main/sing-box-plus.sh && chmod +x sing-box-plus.sh && bash sing-box-plus.sh
```

或者

```bash
curl -fsSL -o sing-box-plus.sh https://raw.githubusercontent.com/Alvin9999-newpac/Sing-Box-Plus/main/sing-box-plus.sh && chmod +x sing-box-plus.sh && bash sing-box-plus.sh
```

安装完成后，输入 `bash sing-box-plus.sh` 可进入管理页面。

---

## 🧭 功能菜单

```text
 🚀 Sing-Box-Plus 管理脚本 v4.7.0 🚀
 脚本更新地址: https://github.com/Alvin9999-newpac/Sing-Box-Plus
=============================================================
系统加速状态：已启用 / 未启用 BBR
Sing-Box 启动状态：运行中 / 未运行 / 未安装
=============================================================
  1) 安装/部署
  2) 查看分享链接（IPv4）
  6) 查看分享链接（IPv6）
  3) 重启服务
  4) 一键更换所有端口
  5) 一键开启 BBR
  7) 配置 SNI / 协议 / 域名订阅
  8) 卸载
  0) 退出
=============================================================
```

---

## 🧩 版本更新日志

| 版本    | 日期     | 变更 |
|--------|----------|------|
| v4.7.0 | 2026-06  | 安装时可配置 SNI/协议/区域标识，新增 nginx 伪装页、HTTPS 订阅、旧端口清理 |
| v4.6.0 | 2026-05  | 新增 AnyTLS 协议节点（直连 + WARP），节点总数 18 → 20 |
| v4.5.0 | 2026-05  | 固定 sing-box 版本为 v1.13.7 |
| v4.4.0 | 2026-03  | 支持 sing-box 1.13.x |

---

## 📂 文件与目录

| 路径                                             | 说明                                   |
| -------------------------------------------------- | ---------------------------------------- |
| `/usr/local/bin/sing-box`                    | sing-box 二进制                        |
| `/opt/sing-box/config.json`                  | 主配置（自动生成）                     |
| `/opt/sing-box/data/`                        | sing-box 数据目录                      |
| `/opt/sing-box/cert/{fullchain.pem,key.pem}` | 自签证书（未配置域名证书时使用）       |
| `/opt/sing-box/ports.env`                    | 节点端口持久化                        |
| `/opt/sing-box/env.conf`                     | 全局环境配置                           |
| `/opt/sing-box/creds.env`                    | 凭据（UUID、Reality Keypair、SS、AnyTLS 等）   |
| `/opt/sing-box/warp.env`                     | WARP 关键参数（规范化后）              |
| `/opt/sing-box/firewall.rules`               | 脚本放行过的端口记录，用于清理旧端口   |
| `/var/www/sing-box-plus/`                    | nginx 伪装站点与订阅文件               |
| `/opt/sing-box/wgcf/`                        | `wgcf` 账号与 profile（历史保留）      |

---

## 🚦 使用步骤

1. **首次运行脚本** → 选择 `1) 安装/部署`
   * 自动安装 sing-box / jq / curl 等依赖
   * 可配置 REALITY SNI、启用协议、WARP 副本、区域标识、Web 订阅域名
   * 自动生成凭据与证书、WARP 出站、写入 `config.json`
   * 自动注册 systemd 并启动
2. **查看分享链接** → `2) 查看分享链接`
   * 直连与 WARP **分组输出**
   * 可直接导入到 v2rayN / sing-box / Shadowrocket / Mihomo 等
3. **更换端口** → `4) 一键更换所有端口`
   * 已启用协议的端口全部生成不冲突的新端口
   * 自动重写 `config.json` + 放行新端口 + 清理旧端口 + 重启服务
   * （已修复）**一次回车即可返回主菜单**
4. **重新配置** → `7) 配置 SNI / 协议 / 域名订阅`
   * 修改后会重写配置、刷新订阅并重启服务
5. **开启 BBR** → `5) 一键开启 BBR`
   * 自动检测并设置 `fq + bbr`，提高拥塞控制与队列质量
6. **重启服务** → `3) 重启服务`
7. **卸载** → `8) 卸载`
   * 停止服务、移除 systemd、保留数据目录（如需全清自行删除 `/opt/sing-box`）

---

## 🔗 分享链接示例（片段）

脚本会为每个入站生成标准导入链接，例如：

```text
# 直连（示例）
vless://<UUID>@<HOST>:<PORT>?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.tesla.com&fp=chrome&pbk=<REALITY_PUB>&sid=<SID>&type=tcp#🇯🇵日本-vless-reality
vmess://<Base64(JSON)>
hy2://<pwd_b64url>@<HOST>:<PORT>?insecure=1&allowInsecure=1&sni=<TLS_SERVER>#🇯🇵日本-hysteria2
ss://<base64(method:password)>@<HOST>:<PORT>#🇯🇵日本-ss / #🇯🇵日本-ss2022
tuic://<uuid>:<uuid>@<HOST>:<PORT>?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=<TLS_SERVER>#🇯🇵日本-tuic-v5
anytls://<pwd_b64url>@<HOST>:<PORT>?insecure=1&sni=<TLS_SERVER>#🇯🇵日本-anytls
```

> **提示**
> 
> * VMess 采用 `ws + path=/vm`；
> * Hysteria2-OBFS：`obfs=salamander`，`alpn=h3`；
> * TUIC v5：默认 `insecure=1`，便于客户端快速导入（可自行改为严格证书校验）；
> * AnyTLS：使用标准 TLS 1.3 + Padding，需要 sing-box 1.12+ 或 Mihomo 较新版本支持；
> * 配置 Web/订阅域名并成功申请证书后，Hysteria2 / TUIC / AnyTLS 的 SNI 会使用该域名。

---

## 🌐 Web 伪装与订阅

安装或菜单 `7)` 可配置 Web/订阅域名。请先在 DNS 中把域名的 A/AAAA 记录指向服务器公网 IP，并在云防火墙放行 80/443。

配置成功后脚本会：

* 安装并配置 nginx
* 在 `/var/www/sing-box-plus/` 生成演示站点
* 使用 certbot 申请 Let's Encrypt 证书
* 生成 64 位订阅密码，订阅路径为 `/sub/<SUB_TOKEN>`
* 在查看分享链接时输出订阅地址

订阅内容会在安装、重新配置和更换端口后自动刷新。

---

## 🔧 端口放行（云防火墙）

脚本会自动尝试使用 `ufw / firewalld / iptables` 放行本机端口，并记录自己放行过的端口。更换端口或禁用协议后，脚本会清理上一次记录的旧端口。

若你的云提供商**额外有"安全组/云防火墙"**，请把**下方命令打印出来的端口**放行到公网；云安全组不属于本机防火墙，脚本无法自动修改：

```bash
echo "=== 必须放行到云防火墙的端口 ==="
echo "[TCP]"
jq -r '.inbounds[]|[.listen_port, (if .type|test("hysteria2|tuic") then "" else "tcp" end)]|@tsv' /opt/sing-box/config.json \
| awk -F'\t' '$2=="tcp"{print $1}' | sort -n | uniq | paste -sd',' -
echo "[UDP]"
jq -r '.inbounds[]|[.listen_port, (if .type|test("hysteria2|tuic") then "udp" else (if .type=="shadowsocks" then "both" else "" end) end)]|@tsv' /opt/sing-box/config.json \
| awk -F'\t' '$2=="udp"{print $1} $2=="both"{print $1}' | sort -n | uniq | paste -sd',' -
```

> AnyTLS 走 TCP，命令会自动包含。

---

## 🛠 常见问题（FAQ）

### 1）WARP 报错：`illegal base64 data at input byte 40`

**原因**：旧版 wgcf profile 中 `PublicKey/PrivateKey/Reserved` 含引号/回车/空格或缺失。
**脚本处理**：自动**去引号/去 CR/去空格**，Reserved 缺失回退 `0,0,0`。
**仍有旧坏值**？可一键重置：

```bash
rm -f /opt/sing-box/warp.env
rm -f /opt/sing-box/wgcf/wgcf-profile.conf   # 可选
bash sing-box-plus.sh     # 重新选择 1) 安装/部署
```

> v4.5.0+ 已默认使用 warp-cli 模式，wgcf 仅为历史兼容保留，新部署一般不会触发此问题。

### 2）更换端口后节点无法使用

* 请先确认**云防火墙**已放行新端口（见上节命令）
* 如果已配置订阅，请在客户端更新订阅
* 执行：

```bash
ss -lntup | grep -E 'sing-box|LISTEN'
journalctl -u sing-box.service --no-pager -n 100
```

若日志中出现 `bind: address already in use`，说明新端口与其他进程冲突 → 再次 `4) 一键更换所有端口`。

### 3）菜单"更换端口"需要按两次回车

已在 v2.1.6 内修复：现在**一次回车**即可返回主菜单。

### 4）`curl: (22) 404` 下载 sing-box 失败

* 多因 GitHub API 变更或网络不可达；脚本内已做架构/版本回退逻辑。
* v4.5.0+ 已固定 sing-box 版本为 v1.13.7，如需切换可设置环境变量：`SINGBOX_TAG=v1.13.x bash sing-box-plus.sh`
* 可稍后重试或手动上传二进制到 `/usr/local/bin/sing-box` 并赋权 `0755`。

### 5）"legacy wireguard outbound is deprecated" 的警告

* 来自 sing-box 1.12.x 的**提示**，不影响当前用法；v4.5.0+ 已迁移到 warp-cli 模式，新部署不会再出现。

### 6）AnyTLS 节点导入客户端报错或无法识别

* AnyTLS 是较新协议（sing-box v1.12 引入），需要客户端支持：
  * **sing-box** 1.12+（含 SFA / SFI / SFM 客户端 1.12+）
  * **Mihomo (Clash.Meta)** 较新版本
  * **Hiddify** 较新版本
* 老版本 **v2rayN / Shadowrocket** 不支持 AnyTLS，请更新客户端到最新版本，或手动添加节点（密码、地址、端口、SNI、insecure 这几项手填即可）。

---

## 🧹 卸载

在菜单选择 `8) 卸载`。若需**彻底清理**：

```bash
systemctl stop sing-box.service
systemctl disable sing-box.service
rm -f /etc/systemd/system/sing-box.service
systemctl daemon-reload
rm -rf /opt/sing-box
rm -f /usr/local/bin/sing-box
```

---

## ⚙️ 进阶：自定义（可选）

* `REALITY_SERVER` / `REALITY_SERVER_PORT` / `REGION_TAG` / `WEB_DOMAIN` / `SUB_TOKEN` / `GRPC_SERVICE` / `VMESS_WS_PATH` / `ENABLE_ANYTLS` 等可在 `/opt/sing-box/env.conf` 中修改，然后：

```bash
bash sing-box-plus.sh   # 执行 3) 重启服务 或 1) 重新部署
```

* 修改证书
  配置 `WEB_DOMAIN` 并成功申请 Let's Encrypt 后，Hysteria2 / TUIC / AnyTLS 会优先使用 `/etc/letsencrypt/live/<WEB_DOMAIN>/` 下的证书；未配置域名时使用 `/opt/sing-box/cert/` 下的自签证书。

* 切换 sing-box 版本：

```bash
SINGBOX_TAG=v1.13.7 bash sing-box-plus.sh   # 或其他你想固定的版本
```

***

有问题可以[发帖](https://github.com/Alvin9999-newpac/Sing-Box-Plus/issues)反馈，或者发邮件到海外邮箱 rebeccalane27@gmail.com 进行反馈。
