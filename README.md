# SLBCK — SaguaroLocalBackup

Mala, jednostavna i robusna backup aplikacija za **MySQL / MariaDB / PostgreSQL**
baze na Linux serverima. Jedna bash skripta, bez dependencija — radi na Debianu,
Ubuntuu, RHEL/Alma/Rocky i sličnima.

**Što radi:**

1. Provjeri radi li database servis (MySQL, MariaDB ili PostgreSQL — auto-detekcija)
2. Napravi dump **svake baze zasebno**, gzipano, u lokalni backup folder
   (`/var/backups/slbck/YYYY-MM-DD/baza.sql.gz`)
3. Drži zadnja **3 dana** lokalno (podesivo), starije automatski briše
4. Opcionalno šalje backup na vanjski server (**rsync** ili **sftp** preko SSH ključa)
5. **Restore** bilo koje baze iz lokalnih backupa ili povlačenjem s remote servera
6. Šalje **mail obavijest** o uspjehu ili grešci — ako server nema mail sustav,
   setup ga sam instalira i podesi (msmtp SMTP relay)
7. Vrti se kao **cron job** u fiksno vrijeme (izbor 01:00–06:00)

## Instalacija

```bash
git clone https://github.com/saguarogit-cmzk/SLBCK.git
cd SLBCK
sudo ./install.sh
sudo slbck-setup
```

## Izbornik

Sve se pokreće kroz jednu komandu — `slbck-setup` otvara glavni izbornik:

```
==============================================
 SLBCK - SaguaroLocalBackup v1.1.0
 srv01.example.com | engine: mysql
==============================================
  1) Setup / configuration (config + cron)
  2) Backup now
  3) Restore a database
  4) Send backups to remote server
  5) Status
  6) Service check
  7) Test mail
  q) Quit
Choose:
```

Opcija **1 (Setup)** je čarobnjak koji pita redom: engine, MySQL/MariaDB auth,
sat backupa (**1–6 = 01:00–06:00**), retenciju, backup folder, mail (uz
automatsku instalaciju msmtp-a ako nema mail sustava), remote server — i zatim
sam zapiše `/etc/slbck/slbck.conf` i `/etc/cron.d/slbck`.

Sve opcije rade i direktno iz CLI-ja (za skriptiranje):

| Naredba | Opis |
|---|---|
| `slbck-setup` ili `slbck` | Interaktivni glavni izbornik |
| `slbck setup` | Samo setup čarobnjak (config + cron) |
| `slbck backup` | Backup odmah (check → dump → retencija → remote → mail) |
| `slbck restore` | Interaktivni restore jedne baze (izbor dana → izbor baze) |
| `slbck send` | (Ponovno) pošalji lokalne backupe na remote server |
| `slbck pull` | Povuci backupe s remote servera u lokalni folder |
| `slbck check` | Samo provjera database servisa |
| `slbck status` | Stanje: config, cron, zauzeće diska, zadnji logovi |
| `slbck test-mail` | Pošalji testni mail |

## Restore

`slbck restore` (ili opcija 3 u izborniku) vodi kroz proces:

1. Ako je remote konfiguriran, nudi **povlačenje backupa s remote servera**
2. Izbor **dana** (lista dostupnih backup dana)
3. Izbor **baze** (lista dumpova s veličinama)
4. Provjera gzip integriteta arhive
5. Sigurnosna potvrda — moraš **utipkati ime baze** prije nego išta prepiše

- **MySQL/MariaDB** dumpovi sadrže `CREATE DATABASE IF NOT EXISTS` + `DROP TABLE
  IF EXISTS` → restore preko postojeće baze radi direktno.
- **PostgreSQL** dumpovi su rađeni s `--create --clean --if-exists` → restore
  sam dropne i ponovno kreira bazu (aktivne konekcije se prije toga prekidaju).
  Za role/tablespaceove postoji poseban `_globals` dump.

Ručni restore (bez SLBCK-a) uvijek radi jer su dumpovi običan gzipani SQL:

```bash
zcat baza.sql.gz | mysql                      # MySQL/MariaDB
zcat baza.sql.gz | sudo -u postgres psql -d postgres   # PostgreSQL
```

## Kako radi backup

- **MySQL/MariaDB**: `mysqldump --single-transaction --routines --triggers --events`
  po bazi (konzistentno za InnoDB, bez lockanja). Sistemske sheme
  (`information_schema`, `performance_schema`, `sys`) se preskaču; baza `mysql`
  (korisnici/grantovi) se backupira. Na Debian/Ubuntu/MariaDB radi odmah preko
  socket autha kao root, inače se u setupu unese backup user.
- **PostgreSQL**: `pg_dump --create --clean --if-exists` po bazi kao `postgres`
  user + `_globals.sql.gz` (role i tablespaceovi preko `pg_dumpall --globals-only`).
- Svaki dump se piše u `.tmp`, provjeri se **gzip integritet** (`gzip -t`) i tek
  onda preimenuje — nikad ne ostaje polovičan backup pod pravim imenom.
- `flock` sprječava preklapanje dva backupa istovremeno.
- Log: `/var/log/slbck.log`.

## Mail obavijesti

- Ako na serveru već postoji `sendmail`/`mailx`/MTA, koristi se postojeći.
- Ako **ne postoji ništa**, setup nudi instalaciju **msmtp-a** i pita za SMTP
  relay (host, port, user, pass, from) te sam zapiše `/etc/msmtprc` (chmod 600).
- `MAIL_ON="always"` šalje mail nakon svakog backupa, `"error"` samo kod greške.
- Test: `slbck test-mail`.

## Remote kopija

- **rsync**: mirrora cijeli lokalni backup folder → remote ima istu retenciju
  kao lokalno, bez ručnog čišćenja.
- **sftp**: uploada samo današnji folder.
- SSH key auth mora raditi bez lozinke (`ssh-copy-id user@backupserver`).
  SLBCK ne sprema SSH lozinke.

## Sigurnost

- Config `/etc/slbck/slbck.conf` je `chmod 600` (može sadržavati MySQL lozinku)
- Backup folder je `chmod 700`
- Restore traži utipkavanje imena baze kao potvrdu prije prepisivanja
