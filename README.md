# Vibe NetMon

Monitor di connettivita' Internet nativo **macOS (Cocoa/AppKit)** scritto in **Objective-C / C11**.

Autori: **Sandro Borioni**, **ChatGPT**, **Claude**
Versione: **1.0** -- Licenza: **MIT**

> *not a single line of code is crafted by a human*

---

## Descrizione

Vibe NetMon misura la qualita' della connessione Internet a intervalli regolari (default 10 s)
eseguendo quattro tipi di probe in sequenza:

| Probe | Cosa misura |
|---|---|
| **Gateway** | Ping ICMP al default gateway (rilevato automaticamente via `route -n get default`) |
| **ICMP** | Ping a target pubblici (default: `1.1.1.1`, `8.8.8.8`) |
| **DNS** | Risoluzione `www.google.com` via `getaddrinfo()` |
| **HTTP** | GET a `google.com/generate_204` e `cloudflare.com/cdn-cgi/trace` |

Internet e' considerato **UP** se gateway risponde E almeno un ICMP o HTTP risponde.

---

## Funzionalita'

- **Disponibilita' oraria** con barra colorata (verde >= 99.9%, arancio >= 99%, rosso < 99%)
- **Statistiche latenza**: mediana e p95 per GW / ICMP / DNS / HTTP
- **Grafico traffico** RX/TX in tempo reale (ring buffer 60 campioni, scala automatica)
- **Rilevamento disconnessioni**: evento DOWN con diagnostica automatica (ping x3, traceroute a 1.1.1.1)
- **Report orario** con disponibilita', downtime, contatori disconnessioni/riconnessioni
- **Log CSV** per analisi successiva con pandas, Excel, ecc.
- **Rotazione giornaliera** dei file di log (tag `YYYYMMDD`)
- Intervallo di campionamento configurabile a runtime senza riavvio

---

## Requisiti

- macOS 12+
- CMake >= 3.16
- Clang con supporto Objective-C ARC

---

## Build

```bash
cd netmon
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --target netmon_client
./build/Vibe\ NetMon.app/Contents/MacOS/Vibe\ NetMon
```

---

## Interfaccia

```
+------------------------------------------+------------------+
|  Header: gateway | intervallo | Avvia     |                  |
+------------------------------------------+                  |
|                                          |   Pannello       |
|   Log campioni (monospace, colorato)     |   statistiche    |
|   [HH:mm:ss] GW=OK(3ms) ICMP=2/2 ...   |                  |
|                                          |   - stato UP/DOWN|
|------------------------------------------|   - disponib. %  |
|   EVENTI CONNESSIONE                     |   - latenze      |
|   [12:34:56] *** DOWN rilevato ***       |   - traffico     |
|   [12:35:18] *** RIPRISTINATA (22s) ***  |     RX/TX graph  |
+------------------------------------------+------------------+
```

- **Colonna sinistra** (ridimensionabile): log campioni + pannello eventi
- **Colonna destra** (ridimensionabile): statistiche orarie + grafico traffico
- **Header**: campo gateway (autodetect), intervallo, pulsante Avvia/Ferma

---

## File di output

Tutti i file vengono scritti in `~/internet_monitor_logs/` con suffisso `_YYYYMMDD`.

| File | Contenuto |
|---|---|
| `samples_YYYYMMDD.csv` | Un record per campione: timestamp, gateway, ICMP, DNS, HTTP, note |
| `events_YYYYMMDD.log` | Solo eventi DOWN/UP con diagnostica (ping, traceroute) |
| `hourly_YYYYMMDD.log` | Report testuale ogni ora con statistiche aggregate |

### Formato CSV

```
timestamp,gateway_ok,gateway_rtt_ms,icmp_ok,icmp_total,icmp_median_ms,
dns_ok,dns_ms,http_ok,http_total,http_median_ms,internet_up,notes
2026-04-20T18:00:10,1,2.3,2,2,4.1,1,18.5,2,2,122.3,1,
2026-04-20T18:00:20,1,2.1,2,2,3.9,1,17.2,2,2,118.7,1,
2026-04-20T18:05:40,0,-1,0,2,-1,0,-1,0,2,-1,0,GW_FAIL|DNS_FAIL|ICMP_0/2|HTTP_0/2
```

---

## Configurazione (nel sorgente)

I target di default sono definiti in `main()` in `tools/netmon_cocoa.m`:

```objc
kICMPTargets  = @[@"1.1.1.1", @"8.8.8.8"];
kDNSTestHost  = @"www.google.com";
kHTTPTestURLs = @[@"https://www.google.com/generate_204",
                  @"https://www.cloudflare.com/cdn-cgi/trace"];
kOutputDir    = @"~/internet_monitor_logs";
```

L'intervallo di campionamento (default `10 s`) e il gateway sono modificabili
direttamente dall'interfaccia senza ricompilare.

---

## Struttura directory

```
tools/
  netmon_cocoa.m    unico sorgente: monitor + UI Cocoa
CMakeLists.txt
build/              out-of-source (non tracciato)
```
