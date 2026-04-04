# 🌐 DNS Tunnel Kit

Bypass DNS-based internet censorship using **four independent DNS tunnel methods** — MasterDnsVPN, Slipstream, dnstt, and VayDNS — all managed by a single setup script.

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
                            │    └─ d.yourdomain.com → VayDNS       :5314 │
                            └─────────────────────────────────────────────┘
```

| Tunnel | Default Domain | Protocol | Encryption | SOCKS5 |
|---|---|---|---|---|
| **MasterDnsVPN** | `a.yourdomain.com` | Custom DNS + ARQ | ChaCha20 | built-in |
| **Slipstream** | `b.yourdomain.com` | DNS → SOCKS5 | TLS passthrough | microsocks |
| **dnstt** | `c.yourdomain.com` | DNS TXT encoding | Noise protocol | microsocks (no-auth) |
| **VayDNS** | `d.yourdomain.com` | DNS TXT + KCP + smux | Noise + uTLS | microsocks |

All four run simultaneously on the same server, each on a different subdomain.

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

---

## 🚀 Quick Start

### Full Server Setup

```bash
git clone https://github.com/BarzinJarvis/dns-tunnel-kit
cd dns-tunnel-kit

# Install everything: MasterDnsVPN + Slipstream + dnstt + VayDNS + dnstm router
sudo bash setup.sh install
```

### Individual Tunnels

```bash
sudo bash setup.sh masterdnsvpn   # MasterDnsVPN only
sudo bash setup.sh slipstream     # Slipstream only
sudo bash setup.sh dnstt          # dnstt only
sudo bash setup.sh vaydns         # VayDNS only
sudo bash setup.sh dnstm          # dnstm DNS router only
```

### Custom Domains

Override domains via environment variables:

```bash
sudo MDNS_DOMAIN=tunnel1.example.com \
     SLIP_DOMAIN=tunnel2.example.com \
     DNSTT_DOMAIN=tunnel3.example.com \
     VAYDNS_DOMAIN=tunnel4.example.com \
     bash setup.sh install
```

---

## 🛠 All Modes

```
setup.sh install         Full setup (all four tunnels + dnstm router)
setup.sh masterdnsvpn    Install / update MasterDnsVPN only
setup.sh slipstream      Install Slipstream only
setup.sh dnstt           Install dnstt only
setup.sh vaydns          Install VayDNS only
setup.sh dnstm           Install dnstm DNS router only
setup.sh client-config   Print client configs for all tunnels
setup.sh status          Show all service status
setup.sh middle-proxy    Set up Iranian VPS DNS multiplexer (dnsmasq)
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

Use [SlipNet Android app](https://github.com/BarzinJarvis/SlipNet) with profile:

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

Compatible clients: [SlipNet Android app](https://github.com/BarzinJarvis/SlipNet) (VayDNS profile), `vaydns-client` CLI.

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
curl -L https://github.com/BarzinJarvis/dns-tunnel-kit/releases/latest/download/vaydns-client-linux-amd64 \
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

> **Note:** VayDNS uses the same authenticated microsocks backend as Slipstream on the server side. The Noise encryption + uTLS fingerprinting makes it resistant to deep packet inspection.

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

Installs `dnsmasq` rules forwarding all four tunnel domains to public DNS resolvers. Point clients' DNS to this VPS IP.

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
```

---

## 🆚 Tunnel Comparison

| | MasterDnsVPN | Slipstream | dnstt | VayDNS |
|---|---|---|---|---|
| **Encryption** | ChaCha20 | TLS | Noise | Noise + uTLS |
| **Transport** | ARQ/UDP | TCP-over-DNS | KCP+smux | KCP+smux |
| **DPI resistance** | Medium | Medium | Medium | High (uTLS Chrome fingerprint) |
| **Speed** | Fast | Medium | Medium | Medium-Fast |
| **Client** | MasterDnsVPN | SlipNet | dnstt-client / SlipNet | SlipNet / vaydns-client |
| **SOCKS5 auth** | Optional | Passthrough | No | Optional |

---

## 📄 License

MIT
