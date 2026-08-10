# SLBCK — Restore priručnik

Svi scenariji povrata, od jedne tablice do potpuno mrtvog servera.
Pisano da se može slijediti i u panici — redoslijedom od najčešćeg.

**Gdje su backupi:**

| Što | Gdje |
|---|---|
| Lokalni dumpovi baza | na serveru: `/var/backups/slbck/YYYY-MM-DD/baza.sql.gz` (zadnja 3 dana) |
| Arhive konfiguracije | isti folder: `_files-etc.tar.gz`, `_files-var-spool-cron.tar.gz`, ... |
| Kopija svega gore | Storage Box: `<subaccount home>/YYYY-MM-DD/` |
| Sync podataka (npr. /var/www) | Storage Box: `<subaccount home>/folders/var-www/` |
| Starije verzije (do 7 dana) | Storage Box **snapshotovi** (Robot, glavni account) |

---

## 1. Jedna baza (najčešći slučaj)

Na serveru, interaktivno — vodi kroz izbor dana i baze, traži potvrdu
(utipkati ime baze) prije prepisivanja:

```bash
sudo slbck restore
```

Ručno, bez SLBCK-a (dump je običan gzipani SQL):

```bash
zcat /var/backups/slbck/2026-08-10/izzy_edu.sql.gz | mysql          # MariaDB/MySQL
zcat baza.sql.gz | sudo -u postgres psql -d postgres                # PostgreSQL
```

Dump sadrži `CREATE DATABASE IF NOT EXISTS` + `DROP TABLE IF EXISTS`,
pa restore preko postojeće baze radi direktno.

## 2. Jedna tablica ili dio podataka

```bash
zcat baza.sql.gz | less                                   # pogledaj sadržaj
zcat baza.sql.gz | sed -n '/-- Table structure for table `orders`/,/-- Table structure/p' > orders.sql
# ili samo podaci:
zcat baza.sql.gz | grep 'INSERT INTO `orders`' > orders-data.sql
```

Pa restore u privremenu bazu i prebaci što treba:

```bash
mysql -e "CREATE DATABASE tmp_restore"
mysql tmp_restore < orders.sql
```

## 3. Backup nije lokalno (stariji od 3 dana ili server bez diska)

Povuci s boxa pa nastavi kao pod 1:

```bash
sudo slbck pull          # povuče backupe s boxa u /var/backups/slbck
sudo slbck restore
```

## 4. Fajl ili folder iz sync podataka (npr. /var/www)

Sync na boxu je živa kopija (bez brisanja). Vraćanje jednog foldera/fajla:

```bash
rsync -az -e "ssh -p 23" \
  uXXXXXX-subN@uXXXXXX.your-storagebox.de:folders/var-www/izzyedu.hkoig.hr/ \
  /var/www/izzyedu.hkoig.hr/
```

**Starija verzija fajla** (npr. prije jučerašnje promjene): Storage Box
snapshotovi — spoji se **glavnim accountom** boxa (sftp port 23), snapshot
direktorij je `/.zfs/snapshot/<datum>/...`, unutra je stanje cijelog boxa
u tom trenutku. Kopiraj fajl van i vrati ga na server.

> Puni restore snapshota kroz Robot briše sve novije snapshote — za
> pojedinačne fajlove UVIJEK koristiti snapshot direktorij, ne restore.

## 5. Konfiguracija servera (`/etc`, cron, skripte)

```bash
mkdir /tmp/restore-etc
tar xzf /var/backups/slbck/2026-08-10/_files-etc.tar.gz -C /tmp/restore-etc
# pa ručno vrati što treba, npr:
cp /tmp/restore-etc/etc/apache2/sites-available/app.conf /etc/apache2/sites-available/
```

**Nikad ne raspakiravati tar direktno preko živog `/etc`** — uvijek u
privremeni folder pa selektivno kopirati.

## 6. Potpuni disaster recovery (server je mrtav / novi server)

Scenarij: podignut je novi prazan Ubuntu server, sve treba vratiti.

```bash
# 1. Osnovni paketi + SLBCK
apt-get install -y mariadb-server apache2 rsync git    # što je server imao
git clone https://github.com/saguarogit-cmzk/SLBCK.git && cd SLBCK && sudo ./install.sh

# 2. Konfiguriraj pristup boxu
sudo slbck quick        # isti odgovori kao originalni server (isti subaccount!)
# ključ na box: quick ispiše komandu; treba lozinka subaccounta (password manager
# ili reset u Robotu)

# 3. Povuci sve backupe s boxa
sudo slbck pull

# 4. Vrati konfiguraciju (selektivno! — vidi točku 5)
mkdir /tmp/dr && tar xzf /var/backups/slbck/<zadnji-dan>/_files-etc.tar.gz -C /tmp/dr
# apache vhostovi, php config, /etc/hosts, cron unosi:
tar xzf /var/backups/slbck/<zadnji-dan>/_files-var-spool-cron.tar.gz -C /tmp/dr
tar xzf /var/backups/slbck/<zadnji-dan>/_files-usr-local-bin.tar.gz -C /tmp/dr

# 5. Vrati sve baze
for f in /var/backups/slbck/<zadnji-dan>/*.sql.gz; do zcat "$f" | mysql; done
# (PostgreSQL: prvo _globals.sql.gz, pa baze, sve u psql -d postgres)

# 6. Vrati podatke
rsync -az -e "ssh -p 23" uXXXXXX-subN@uXXXXXX...:folders/var-www/ /var/www/

# 7. Servisi + provjera
systemctl restart apache2 mariadb
sudo slbck health       # svi servisi i URL-ovi moraju biti OK
sudo slbck backup       # novi ciklus backupa odmah
```

## 7. Enkriptirani dumpovi (`.sql.gz.gpg`)

Ako je na serveru bila uključena GPG enkripcija, za SVE gornje postupke
treba passphrase (password manager!). `slbck restore` i `slbck verify`
dekriptiraju sami; ručno:

```bash
gpg -d baza.sql.gz.gpg | gunzip | mysql
```

**Bez passphrase enkriptirani backup je nepovratno nečitljiv.**

---

## Kontrole nakon svakog restora

```bash
sudo slbck health     # servisi + aplikacijski URL-ovi
mysql -e "SHOW DATABASES"
sudo slbck backup     # odmah novi backup vraćenog stanja
```
