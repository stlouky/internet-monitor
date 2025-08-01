
# internet-monitor

Robustní skript pro dlouhodobý **monitoring výpadků internetu** na Linuxu (testováno zejména na Void Linux s runit). Skript loguje všechny změny stavu připojení, ukládá výsledky do CSV a automaticky je zálohuje do cloudu přes [rclone](https://rclone.org/) (Proton Drive, Google Drive…). Ideální jako důkaz pro poskytovatele nebo ČTÚ.

---

## 🚀 Funkce

* **Monitorování více cílů najednou (ping)**
* **Rozpoznání různých chybových stavů (DNS fail, timeout, unreachable...)**
* **Podrobný CSV log, připravený pro důkazní účely**
* **Automatický upload logu do cloudu (Proton Drive/Google Drive...)**
* **Automatická rotace logu**
* **Běh jako runit služba**
* (volitelně) Emailové notifikace při výpadku/obnovení

---

## 📦 Instalace

### 1. Klonování repozitáře

```bash
git clone https://github.com/yourusername/internet-monitor.git
cd internet-monitor
chmod +x internet_monitor.sh
```

### 2. Instalace závislostí

* **rclone**
* **mailx** *(volitelné, jen pokud chceš e-mail notifikace)*

Na Void Linux:

```bash
sudo xbps-install -S rclone mailx
```

### 3. Nastavení rclone

Nastav cloud (např. Proton Drive):

```bash
rclone config
rclone lsd protondrive:
```

---

## ⚠️ Důležitá úprava před použitím!

> **Po stažení skriptu z GitHubu je nutné upravit některé proměnné v souboru `internet_monitor.sh`, aby skript správně fungoval v tvém prostředí. Pokud toto neupravíš, nebude logování nebo zálohování fungovat správně!**

**V souboru `internet_monitor.sh` nastav zejména:**

```bash
# Cesty k logům a stavovým souborům:
LOG_FILE="$HOME/inet_monitor_log.csv"      # Doporučeno: použij např. /home/tvůj_user/inet_monitor_log.csv
TEMP_STATE="$HOME/.inet_monitor.state"
LOCK_FILE="$HOME/.inet_monitor.lock"

# Nastavení cloudu (dle tvého rclone configu):
RCLONE_REMOTE="protondrive"                # Název remotu podle rclone config (např. 'protondrive', 'gdrive', ...)
RCLONE_PATH="monitoring/"                  # Složka v cloudu

# Email (jen pokud chceš emaily):
SEND_EMAIL=false                           # true/false – pokud chceš e-mail notifikace
EMAIL_RECIPIENT="admin@example.com"        # Tvoje adresa (pokud používáš e-mail notifikace)
```

**Uprav také případné cesty v runit službě a logování – viz další sekce!**

---

## 🛠️ Spuštění

### Rychlé spuštění v terminálu

```bash
./internet_monitor.sh
```

### Na pozadí (background/nohup)

```bash
nohup ./internet_monitor.sh > /dev/null 2>&1 &
```

### Automaticky jako služba (runit)

> **Při nastavování služby nezapomeň upravit uživatele a cesty v run skriptu podle svého prostředí!**

**Vytvoření runit služby:**

```bash
sudo mkdir -p /etc/sv/internet-monitor
sudo tee /etc/sv/internet-monitor/run << 'EOF'
#!/bin/sh
exec chpst -u yourusername /home/yourusername/internet_monitor.sh 2>&1
EOF
sudo chmod +x /etc/sv/internet-monitor/run
```

**(Volitelné) Logování:**

```bash
sudo mkdir -p /etc/sv/internet-monitor/log
sudo tee /etc/sv/internet-monitor/log/run << 'EOF'
#!/bin/sh
exec chpst -u yourusername svlogd -tt /var/log/internet-monitor/
EOF
sudo chmod +x /etc/sv/internet-monitor/log/run
sudo mkdir -p /var/log/internet-monitor
sudo chown yourusername /var/log/internet-monitor
```

**Aktivace služby:**

```bash
sudo ln -s /etc/sv/internet-monitor /var/service/
```

---

## 🔍 Ověření funkčnosti

* **Stav služby:**
  `sudo sv status internet-monitor`

* **Log služby:**
  `sudo tail -f /var/log/internet-monitor/current`

* **CSV log:**
  `tail -f /cesta/k/inet_monitor_log.csv` *(dle tvého LOG\_FILE!)*

* **Cloud upload:**
  `rclone ls protondrive:monitoring/`

---

## 📊 Příklad logu

### Systémový log (`/var/log/internet-monitor/current`)

```
2025-08-01 12:45:10 - Status change: UP -> DOWN
2025-08-01 12:45:10 - Connection DOWN - all targets failed: TIMEOUT;NET_UNREACHABLE;
2025-08-01 12:46:12 - Status change: DOWN -> UP
2025-08-01 12:46:12 - Connection restored (4ms avg) - outage duration: 00:01:02 (3/3)
```

### CSV log (`inet_monitor_log.csv`)

```
timestamp,status,latency_ms,outage_duration,target_tested,error_details,script_version
2025-08-01 12:45:10,DOWN,N/A,N/A,8.8.8.8;1.1.1.1;8.8.4.4;,TIMEOUT;NET_UNREACHABLE;v2.0
2025-08-01 12:46:12,UP,4,00:01:02,8.8.8.8;1.1.1.1;8.8.4.4,3/3,v2.0
```

---

## 🚨 Chybové stavy – kompletní výpis

| Kód/hláška                | Význam / Příčina                                                    | Řešení / Reakce                           |
| ------------------------- | ------------------------------------------------------------------- | ----------------------------------------- |
| **TIMEOUT**               | Ping neodpověděl včas, cíl je nedostupný                            | Zkontroluj síť, zkus ručně pingnout       |
| **NET\_UNREACHABLE**      | Síť není dosažitelná, OS hlásí chybu                                | Ověř kabel, Wi-Fi, router                 |
| **HOST\_UNREACHABLE**     | Koncový bod (gateway/server) není dosažitelný                       | Restart router, zkontroluj nastavení sítě |
| **DNS\_FAIL**             | Chyba DNS překladu jména                                            | Nastav funkční DNS, restartuj router      |
| **PERMISSION\_DENIED**    | Skript nemá práva pro zápis do logu nebo souboru                    | Uprav práva, spusť jako správný uživatel  |
| **DIRECTORY\_NOT\_FOUND** | Cílová složka neexistuje (pro log/cloud upload)                     | Vytvoř složku ručně                       |
| **UPLOAD\_FAILED**        | Cloud upload neproběhl (rclone chyba, síť nedostupná, špatná cesta) | Ověř rclone config, zkontroluj síť        |
| **RCLONE\_NOT\_FOUND**    | rclone není nainstalováno                                           | `sudo xbps-install -S rclone`             |
| **EMAIL\_FAILED**         | Nepodařilo se poslat email (mailx nebo SMTP konfigurace)            | Ověř App Password/SMTP/mailx              |
| **LOW\_DISK\_SPACE**      | Nedostatek místa na disku                                           | Uvolni místo, nastav rotaci logu          |
| **HEALTH\_CHECK\_FAIL**   | Kritická chyba při kontrole služby                                  | Proveď základní HW a síťový audit         |

---

## ℹ️ FAQ

**Q:** Skript nezapisuje log, co s tím?
**A:** Zkontroluj oprávnění a cestu k souboru (`LOG_FILE`). Pokud běží jako služba, použij absolutní cestu!

**Q:** Upload do cloudu nefunguje?
**A:** Ověř rclone config, existenci remotu a cestu k logu.

**Q:** Co znamená "TIMEOUT" nebo "DNS\_FAIL" v logu?
**A:** Viz tabulka výše – typická síťová chyba, často stačí změnit DNS nebo zkontrolovat připojení.

**Q:** Musí být počítač stále zapnutý?
**A:** Ne, skript loguje jen pokud běží. Dlouhodobý důkaz poskytne nejlépe server/trvale běžící stroj.

**Q:** Je možné používat jiné cloudy než Proton Drive?
**A:** Ano, stačí nastavit jiný remote v rclone.

---

## 💬 Podpora & rozšíření

Chceš analyzovat CSV, generovat grafy nebo rozšířit o notifikace na mobil/Telegram?
Napiš issue nebo pull request – projekt je otevřený pro další nápady a vylepšení.

---

**Happy monitoring! Ať máš konečně důkaz místo dohadů.**

---

> **Shrnutí:**
> Po stažení zkontroluj a uprav ve skriptu cesty (LOG\_FILE, TEMP\_STATE, LOCK\_FILE), cloud remote a email, podle svého systému a účtu.
