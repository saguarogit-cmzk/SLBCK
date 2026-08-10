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
5. **Backup foldera**: mali folderi (npr. `/etc`) kao dnevni tar.gz uz baze,
   veliki folderi (npr. `/var/www`) kao rsync mirror **direktno na remote**
   bez lokalne kopije, s kontrolom veličine u mailu
6. **Restore** bilo koje baze iz lokalnih backupa ili povlačenjem s remote servera
7. **Tjedni restore test s potvrdom** — stvarno restora jednu bazu u privremenu
   DB, prebroji tablice, obriše je i rezultat pošalje mailom
8. Opcionalna **GPG AES256 enkripcija** dumpova (lokalno i na remoteu)
9. Šalje **mail obavijest** o uspjehu ili grešci — ako server nema mail sustav,
   setup ga sam instalira i podesi (msmtp SMTP relay)
10. Vrti se kao **cron job** u fiksno vrijeme (izbor 01:00–06:00), log se
    rotira kroz logrotate, disk se provjerava prije svakog backupa

## Dokumentacija

| Dokument | Za što |
|---|---|
| [docs/INSTALACIJA.md](docs/INSTALACIJA.md) | Onboarding novog servera (Robot + quick setup, checklist) |
| [docs/RESTORE.md](docs/RESTORE.md) | Svi restore scenariji — od jedne tablice do potpunog DR-a |
| [docs/BORG-MIGRACIJA.md](docs/BORG-MIGRACIJA.md) | Umirovljenje starog borg+S3 sustava po serveru |

## Instalacija

```bash
git clone https://github.com/saguarogit-cmzk/SLBCK.git
cd SLBCK
sudo ./install.sh
sudo slbck quick       # CLOUD profil: ~6 pitanja, standardi flote automatski
```

(`sudo slbck-setup` otvara puni izbornik; `slbck setup` je detaljni wizard
sa svim opcijama — za nestandardne servere.)

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
| `slbck verify` | Restore test odmah: integritet svih dumpova + stvarni restore jedne baze u temp DB, s potvrdom mailom |
| `slbck health` | Health check odmah: DB + web servisi + aplikacijski URL-ovi (mail samo kod greške) |
| `slbck update` | Povuci novu verziju SLBCK-a s gita i reinstaliraj |
| `slbck send` | (Ponovno) pošalji lokalne backupe na remote server |
| `slbck pull` | Povuci backupe s remote servera u lokalni folder |
| `slbck check` | Samo provjera database servisa |
| `slbck status` | Stanje: config, cron, zauzeće diska, zadnji logovi |
| `slbck guide` | Upute za instalaciju i postavljanje (korak po korak) |
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

### Direktan pristup dumpovima (bez SLBCK-a)

Po defaultu (enkripcija isključena) dumpovi su **običan gzipani SQL** — do
svake baze dolaziš standardnim alatima, SLBCK ti uopće ne treba:

```bash
zcat /var/backups/slbck/2026-08-09/webshop.sql.gz | less        # pogledaj
gunzip -k /var/backups/slbck/2026-08-09/webshop.sql.gz          # dobij .sql
zcat webshop.sql.gz | grep 'INSERT INTO `orders`'               # jedna tablica
zcat webshop.sql.gz | mysql                                     # puni restore
zcat webshop.sql.gz | sudo -u postgres psql -d postgres         # PostgreSQL
```

Ako je GPG enkripcija uključena, isti pristup radi uz jedan korak više
(i passphrase): `gpg -d baza.sql.gz.gpg | gunzip | less`.

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
- `MAIL_ON="always"` šalje mail nakon svakog backupa, `"error"` samo kod greške
  (upozorenja se uvijek šalju).
- Izvještaj je **na hrvatskom i prikladan za slanje klijentu na znanje**:
  subject `[SLBCK] <server> backup OK - datum`, tijelo s sekcijama Klijent/
  Server/trajanje, Baze, Konfiguracija, Podaci, Pohrana i Provjera servisa.
  Tehnički detalji vanjskog servera (host/user) ne prikazuju se u mailu —
  ostaju samo u logu na serveru. `OWNER="ime-klijenta"` u configu puni polje
  "Klijent:".
- Test: `slbck test-mail`.

## Health check (jutarnji mail = mali monitoring)

Nakon svakog backupa SLBCK provjeri **jesu li servisi zbog kojih server
postoji i dalje živi**: database engine, web server (apache2/nginx —
auto-detekcija ili lista u `HEALTH_SERVICES`) i opcionalno aplikacijski
URL-ovi (`HEALTH_URLS`, očekuje HTTP 2xx/3xx). Pad bilo čega = ERROR mail u
istom trenutku — u 02:05, ne kad se korisnici jave ujutro. Ručno bilo kada:
`slbck health`.

Rsync prijenosi koriste najbrži SSH cipher (aes128-gcm s fallbackom), a po
serveru se mogu dodati opcije kroz `RSYNC_EXTRA_OPTS` (npr. `--bwlimit=20M`).

## Restore test (verify)

Backup koji nikad nisi restorao nije backup. SLBCK zato jednom tjedno (dan
podesiv u setupu, default nedjelja) automatski:

1. provjeri integritet **svih** dumpova zadnjeg backupa (gzip/gpg test),
2. **stvarno restora** jednu bazu u privremenu DB `slbck_verify`,
3. prebroji tablice, obriše privremenu bazu,
4. rezultat upiše u backup mail — potvrda da je backup zaista upotrebljiv.

Ručno bilo kada: `slbck verify` (uvijek šalje mail potvrdu, OK ili ERROR).

## GPG enkripcija (opcionalno)

- U setupu odgovoriš `yes` i uneseš passphrase (**min 12 znakova**, dvaput).
- Dumpovi postaju `baza.sql.gz.gpg` (AES256) — enkriptirani i lokalno i na
  remote serveru. Restore i verify rade transparentno.
- **VAŽNO**: passphrase spremi i u password manager. Bez nje restore ne
  postoji — pogotovo u disaster scenariju kad server (i config) više nema.
- Ručni restore enkriptiranog dumpa:
  `gpg -d baza.sql.gz.gpg | gunzip | mysql`

## Backup foldera (uz baze)

Dva načina, oba se uključuju u setupu — **kako složiti foldere:**

### 1. ARCHIVE — mali folderi (configi, npr. `/etc`)

U setupu na pitanje *"Folders to archive daily"* upišeš popis odvojen
razmakom, npr. `/etc /root` (ili kasnije u `/etc/slbck/slbck.conf`:
`ARCHIVE_DIRS="/etc /root"`). Svaki dan nastaje `_files-etc.tar.gz` u
dnevnom folderu **uz dumpove baza** — dobiva istu retenciju, isti mirror na
remote, istu enkripciju i ulazi u tjedni verify. Drži ovo malim (MB, ne GB).

Restore: `tar xzf _files-etc.tar.gz -C /tmp/restore-etc` pa ručno vrati što
treba (nikad tar direktno preko živog `/etc`).

### 2. MIRROR — veliki folderi (`/var/www`, dokumenti...)

**Nikad se ne spremaju lokalno** — rsync ide direktno s diska na remote u
`<path>/<server>/folders/var-www/`. Povijest verzija daju **snapshotovi
Storage Boxa** (obavezno ih uključi u Robot panelu).

Popis foldera: `/etc/slbck/folders.conf` — jedan apsolutni path po retku:

```
# /etc/slbck/folders.conf
/var/www
/home/data/dokumenti
```

Excludovi (vrijede za sve foldere): `/etc/slbck/folder-excludes.conf` —
rsync patterni, po defaultu već isključuje `node_modules/`, `cache/`,
`*.tmp`. Nakon uređivanja testiraj s `sudo slbck backup`.

**Sigurnost synca**: izvorni folderi na serveru se samo **čitaju** — SLBCK u
njih nikad ne piše. Na remoteu se po defaultu **ništa ne briše**
(`FOLDERS_DELETE="no"`): fajlovi se samo dodaju i ažuriraju, pa i lokalno
obrisani fajl ostaje na boxu. Pravi mirror s brisanjem je svjesni opt-in
(`FOLDERS_DELETE="yes"`), a povijest verzija u oba slučaja čuvaju snapshotovi.

Kontrola veličine: mail javlja veličinu svakog foldera, a preko
`FOLDERS_MAX_GB` (default 50) dobiješ WARNING — odmah vidiš kad nešto
naraste. Mirror = na remoteu je uvijek 1× stvarna veličina foldera, prijenos
je inkrementalan (samo promjene).

Restore foldera (ručno, natrag s remotea):

```bash
rsync -az -e "ssh -p23" uXXXXX@uXXXXX.your-storagebox.de:backup/srv01/folders/var-www/ /var/www/
```

Starija verzija fajla → uzmi je iz snapshot direktorija Storage Boxa.

## Remote kopija

- **rsync**: mirrora cijeli lokalni backup folder → remote ima istu retenciju
  kao lokalno, bez ručnog čišćenja.
- **sftp**: uploada samo današnji folder.
- `REMOTE_SUBDIR="auto"` (default): svaki server piše u svoj podfolder
  (hostname) — više servera može dijeliti isti target.
- SSH key auth mora raditi bez lozinke (`ssh-copy-id user@backupserver`).
  SLBCK ne sprema SSH lozinke.

### Hetzner Storage Box

U Robot panelu uključi **SSH support**, pa u setupu:
`rsync`, host `uXXXXX.your-storagebox.de`, **port 23**, user `uXXXXX`
(najbolje sub-account po serveru), path npr. `/home/backup`, subdir `auto`.
Ključ: `ssh-copy-id -p 23 uXXXXX@uXXXXX.your-storagebox.de`.
Preporuka: uključi i **automatske snapshotove** Storage Boxa — server tada ne
može uništiti vlastite remote backupe (zaštita od ransomwarea i grešaka).

## Sigurnost i higijena

- Config `/etc/slbck/slbck.conf` je `chmod 600` (može sadržavati MySQL lozinku
  i GPG passphrase)
- Backup folder je `chmod 700`
- Restore traži utipkavanje imena baze kao potvrdu prije prepisivanja
- Prije backupa se provjerava slobodan disk (min 2× zadnji backup ili
  `MIN_FREE_MB`) — backup se ne pokreće na pun disk
- Dump manji od 50% jučerašnjeg ili gotovo prazan → WARNING u mailu
- Log `/var/log/slbck.log` se rotira kroz `/etc/logrotate.d/slbck`
  (weekly, 8 rotacija, max 20 MB)
- Održavanje flote: `slbck update` povuče novu verziju s gita i reinstalira
