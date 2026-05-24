# 🌐 DNS Tunnel Kit

Bypass DNS-based internet censorship using **five independent DNS tunnel methods** — MasterDnsVPN, Slipstream, dnstt, VayDNS, and StormDNS — all managed by a single setup script.

> **Credits:** [github.com/mrvcoder](https://github.com/mrvcoder)

---

## 🏗 Architecture

```
                            ┌─────────────────────────────────────────────┐
  Client (Iran)             │  Frankfurt Server :53                       │
  ─────────────             │                                             │
  MasterDnsVPN client  ───▶ │  dnstm DNS Router                           │
  SlipNet (Slipstream) ───▶ │    ├─ a.yourdomain.com → MasterDnsVPN :5312 │
  dnstt-client         ───▶ │    ├─ b.yourdomain.com → Slipstream   :5310 │
  VayDNS client        ───▶ │    ├─ c.yourdomain.com → dnstt        :5313 │
  StormDNS client      ───▶ │    ├─ d.yourdomain.com → VayDNS       :5314 │
                            │    └─ e.yourdomain.com → StormDNS     :5315 │
                            └─────────────────────────────────────────────┘
```

| Tunnel | Default Domain | Protocol | Encryption | SOCKS5 |
|---|---|---|---|---|
| **MasterDnsVPN** | `a.yourdomain.com` | Custom DNS + ARQ | ChaCha20 | built-in |
| **Slipstream** | `b.yourdomain.com` | DNS → SOCKS5 | TLS passthrough | microsocks |
| **dnstt** | `c.yourdomain.com` | DNS TXT encoding | Noise protocol | microsocks (no-auth) |
| **VayDNS** | `d.yourdomain.com` | DNS TXT + KCP + smux | Noise + uTLS | microsocks |
| **StormDNS** | `e.yourdomain.com` | DNS + ARQ + multi-resolver | ChaCha20 (default) | built-in |

All five run simultaneously on the same server, each on a different subdomain.

---

## 📦 Included Binaries (`bin/`)

| Binary | Purpose |
|---|---|
| `dnstm` | DNS traffic multiplexer — routes per-domain to the right tunnel |
| `slipstream-server` | Slipstream DNS tunnel server |
| `dnstt-server` | dnstt DNS tunnel server (bundled, standard) |
| `dnstt-server-noizdns` | NoizDNS-compatible dnstt server (auto-detects dnstt + NoizDNS clients) |
| `microsocks` | Lightweight SOCKS5 server (all tunnel backends) |
| `vaydns-server` | VayDNS server — Noise-encrypted DNS tunnel with KCP/smux transport |

> **MasterDnsVPN** is not bundled — `setup.sh` downloads the latest release automatically from  
> [github.com/masterking32/MasterDnsVPN/releases](https://github.com/masterking32/MasterDnsVPN/releases/latest)

> **dnstt-server-noizdns** is not bundled — `setup.sh` downloads it automatically from  
> [github.com/anonvector/noizdns-deploy/releases](https://github.com/anonvector/noizdns-deploy/releases/latest)

> **StormDNS** is not bundled — `setup.sh` downloads the latest release automatically from  
> [github.com/nullroute1970/StormDNS/releases](https://github.com/nullroute1970/StormDNS/releases/latest)

---

## 🚀 Quick Start

### Full Server Setup

```bash
git clone https://github.com/mrvcoder/dns-tunnel-kit
cd dns-tunnel-kit

# Install everything: MasterDnsVPN + Slipstream + dnstt + VayDNS + StormDNS + dnstm router
sudo bash setup.sh install
```

### Individual Tunnels

```bash
sudo bash setup.sh masterdnsvpn   # MasterDnsVPN only
sudo bash setup.sh slipstream     # Slipstream only
sudo bash setup.sh dnstt          # dnstt only
sudo bash setup.sh vaydns         # VayDNS only
sudo bash setup.sh stormdns       # StormDNS only
sudo bash setup.sh dnstm          # dnstm DNS router only
```

### Custom Domains

Override domains via environment variables:

```bash
sudo MDNS_DOMAIN=tunnel1.example.com \
     SLIP_DOMAIN=tunnel2.example.com \
     DNSTT_DOMAIN=tunnel3.example.com \
     VAYDNS_DOMAIN=tunnel4.example.com \
     STORMDNS_DOMAIN=tunnel5.example.com \
     bash setup.sh install
```

### Cloudflare DNS auto-provisioning

If your tunnel domains are on a Cloudflare-managed zone, the installer can
create the NS delegations for you. Provide credentials and the wizard will
ask whether to enable it; the `cloudflare-dns` mode can also be run on its
own at any time.

```bash
# Scoped API token (preferred — Zone:DNS:Edit + Zone:Zone:Read on the zone)
sudo CF_API_TOKEN=cf_xxx bash setup.sh install

# Or the legacy global API key + account email
sudo CF_EMAIL=you@example.com CF_API_KEY=xxxxxxxx bash setup.sh install

# Provision DNS only (idempotent — safe to re-run)
sudo CF_API_TOKEN=cf_xxx bash setup.sh cloudflare-dns \
     a.example.com b.example.com c.example.com
```

For every tunnel subdomain, the script creates:

```
<CF_NS_GLUE_LABEL>.<apex>   A   <SERVER_IP>          # one shared NS glue per zone
<tunnel-subdomain>          NS  <CF_NS_GLUE_LABEL>.<apex>
```

`CF_NS_GLUE_LABEL` defaults to `dns` (so `dns.example.com`), `CF_RECORD_TTL`
defaults to `60`. Tunnel domains across multiple Cloudflare zones are handled
in one pass.

---

## 🛠 All Modes

```
setup.sh install         Full setup (all five tunnels + dnstm router)
setup.sh masterdnsvpn    Install / update MasterDnsVPN only
setup.sh slipstream      Install Slipstream only
setup.sh dnstt           Install dnstt only
setup.sh vaydns          Install VayDNS only
setup.sh stormdns        Install StormDNS only
setup.sh dnstm           Install dnstm DNS router only
setup.sh client-config   Print client configs for all tunnels
setup.sh status          Show all service status
setup.sh middle-proxy    Set up Iranian VPS DNS multiplexer (dnsmasq)
setup.sh cloudflare-dns  Provision NS delegations on Cloudflare
```

---

## 📱 Client Setup

### 🔵 MasterDnsVPN (`a.yourdomain.com`)

1. Download client: [MasterDnsVPN Releases](https://github.com/masterking32/MasterDnsVPN/releases/latest)
2. Get your encryption key from the server: `cat /opt/masterdnsvpn/encrypt_key.txt`
3. Create `client_config.toml`:

```toml
SOCKS5_HOST = "127.0.0.1"
SOCKS5_PORT = 1080

DOMAINS = ["a.yourdomain.com"]
DATA_ENCRYPTION_METHOD = 2   # 2 = ChaCha20
ENCRYPT_KEY = "<your-key>"

ARQ_WINDOW_SIZE = 256
ARQ_INITIAL_RTO = 0.4
ARQ_MAX_RTO     = 1.2

PROTOCOL_TYPE = "SOCKS5"
LOG_LEVEL     = "INFO"
```

4. Scan for best DNS resolvers, then start:
```bash
./MasterDnsVPN_Client --scan
./MasterDnsVPN_Client
```

5. SOCKS5 proxy at `127.0.0.1:1080`

---

### 🟢 Slipstream (`b.yourdomain.com`)

Use [SlipNet Android app](https://github.com/mrvcoder/SlipNet) with profile:

| Setting | Value |
|---|---|
| Type | `SLIPSTREAM_SOCKS` |
| Domain | `b.yourdomain.com` |
| Cert | copy `/etc/dnstm/tunnels/slip-socks/cert.pem` from server |

> **Note:** Slipstream runs in pure SOCKS passthrough mode — no SSH credentials are needed.

---

### 🟡 dnstt (`c.yourdomain.com`)

Compatible clients: `dnstt-client`, NoizDNS client, SlipNet (NoizDNS profile type).

> The server runs `dnstt-server-noizdns` which supports both standard `dnstt-client` connections AND NoizDNS-obfuscated clients simultaneously.

1. Get pubkey from server: `cat /opt/dnstt/server.pub`
2. Run dnstt-client:

```bash
./dnstt-client \
  -doh https://dns.google/dns-query \
  -pubkey-file server.pub \
  c.yourdomain.com 127.0.0.1:1080
```

3. SOCKS5 proxy at `127.0.0.1:1080`

---

### 🔴 VayDNS (`d.yourdomain.com`)

VayDNS is a modern DNS tunnel using **Noise protocol encryption** + **KCP/smux transport** + **uTLS fingerprinting** (Chrome 120 by default). It provides better performance and obfuscation than standard dnstt.

Compatible clients: [SlipNet Android app](https://github.com/mrvcoder/SlipNet) (VayDNS profile), `vaydns-client` CLI.

1. Get pubkey from server:
```bash
cat /opt/vaydns/server.pub
```

2. **SlipNet (Android)** — create a new profile:

| Setting | Value |
|---|---|
| Type | `VAYDNS` |
| Domain | `d.yourdomain.com` |
| Public Key | `<pubkey from server.pub>` |

3. **CLI client** (Linux x86_64 or ARM64):
```bash
# Download pre-built binary (Linux x86_64)
curl -L https://github.com/mrvcoder/dns-tunnel-kit/releases/latest/download/vaydns-client-linux-amd64 \
  -o vaydns-client && chmod +x vaydns-client

./vaydns-client \
  -udp YOUR_SERVER_IP:53 \
  -pubkey <pubkey> \
  -domain d.yourdomain.com \
  -listen 127.0.0.1:1080
```

4. Test:
```bash
curl -x socks5://127.0.0.1:1080 https://ifconfig.me
```

Should return your server's IP if the tunnel is working.

> **Note:** VayDNS uses the same authenticated microsocks backend as Slipstream on the server side. The Noise encryption + uTLS fingerprinting makes it resistant to deep packet inspection. The server is started with `-dnstt-compat` so SlipNet's DNSTT/NoizDNS clients can connect directly.

> **SlipNet share URI:** `setup.sh client-config` prints a ready-to-paste `slipnet://…` URI for dnstt, NoizDNS, and VayDNS profiles (v24 schema).

---

### ⚡ StormDNS (`e.yourdomain.com`)

StormDNS is a DNS-over-UDP/53 tunnel tuned for **hostile, lossy networks** — ARQ + multi-resolver load-balancing + MTU discovery + packet packing. Encryption is ChaCha20 (default; XOR/AES-GCM available) with auto-generated server key. In **SOCKS5 mode** (the kit's default) the server picks the destination per client request — no backend microsocks needed.

Compatible clients: StormDNS client CLI ([releases](https://github.com/nullroute1970/StormDNS/releases/latest)), [WhiteDNS Android app](https://github.com/iampedii/WhiteDNS) (StormDNS backend).

1. Get the auto-generated encryption key from the server (created on first run):
```bash
cat /opt/stormdns/encrypt_key.txt
```

2. **CLI client** — edit `client_config.toml`:
```toml
DOMAINS = ["e.yourdomain.com"]
PROTOCOL_TYPE = "SOCKS5"
DATA_ENCRYPTION_METHOD = 2   # ChaCha20 — match server
ENCRYPT_KEY = "<key from encrypt_key.txt>"
SOCKS5_HOST = "127.0.0.1"
SOCKS5_PORT = 1080
# RESOLVERS: any open public resolvers, e.g. 1.1.1.1, 8.8.8.8
```

3. Run the client, then point your app at `socks5://127.0.0.1:1080`. Test:
```bash
curl -x socks5://127.0.0.1:1080 https://ifconfig.me
```

> **Note:** StormDNS treats packet loss, rate limits, and resolver flapping as normal operating conditions — better than dnstt for marginal Iranian links.

---

## 🔧 Services

| Service | Tunnel | Internal Port |
|---|---|---|
| `masterdnsvpn.service` | MasterDnsVPN | UDP 5312 |
| `dnstm-slip-socks.service` | Slipstream | UDP 5310 |
| `microsocks-slip-public.service` | Slipstream SOCKS5 backend | TCP 58077 |
| `microsocks.service` | Private SOCKS5 backend | TCP 58076 |
| `dnstm-dnstt.service` | dnstt | UDP 5313 |
| `microsocks-noauth.service` | dnstt SOCKS5 backend (no-auth) | TCP 58078 |
| `vaydns-server.service` | VayDNS | UDP 5314 |
| `stormdns.service` | StormDNS | UDP 5315 |
| `dnstm-dnsrouter.service` | DNS Router (all tunnels) | UDP 53 |

---

## ✅ Check Status

```bash
sudo bash setup.sh status
```

---

## 🌍 Middle Proxy (Iranian VPS)

For users inside Iran who need a local DNS relay:

```bash
sudo bash setup.sh middle-proxy
```

Installs `dnsmasq` rules forwarding all five tunnel domains to public DNS resolvers. Point clients' DNS to this VPS IP.

---

## 📋 DNS Delegation

Each tunnel domain needs NS records pointing to the server.  
Add these DNS records at your registrar / Cloudflare:

```
a.yourdomain.com  NS  ns1.a.yourdomain.com
ns1.a.yourdomain.com  A  YOUR_SERVER_IP

b.yourdomain.com  NS  ns1.b.yourdomain.com
ns1.b.yourdomain.com  A  YOUR_SERVER_IP

c.yourdomain.com  NS  ns1.c.yourdomain.com
ns1.c.yourdomain.com  A  YOUR_SERVER_IP

d.yourdomain.com  NS  ns1.d.yourdomain.com
ns1.d.yourdomain.com  A  YOUR_SERVER_IP

e.yourdomain.com  NS  ns1.e.yourdomain.com
ns1.e.yourdomain.com  A  YOUR_SERVER_IP
```

---

## 🆚 Tunnel Comparison

| | MasterDnsVPN | Slipstream | dnstt | VayDNS | StormDNS |
|---|---|---|---|---|---|
| **Encryption** | ChaCha20 | TLS | Noise | Noise + uTLS | ChaCha20 / AES-GCM |
| **Transport** | ARQ/UDP | TCP-over-DNS | KCP+smux | KCP+smux | ARQ + multi-resolver |
| **DPI resistance** | Medium | Medium | Medium | High (uTLS Chrome fingerprint) | Medium (plain UDP/53) |
| **Speed** | Fast | Medium | Medium | Medium-Fast | Tuned for lossy links |
| **Client** | MasterDnsVPN | SlipNet | dnstt-client / SlipNet | SlipNet / vaydns-client | StormDNS CLI / WhiteDNS |
| **SOCKS5 auth** | Optional | Passthrough | No | Optional | No (client picks dest) |

---

## 📄 License

MIT
