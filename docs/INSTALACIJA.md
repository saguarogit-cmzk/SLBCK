# SLBCK — Instalacija novog servera (CLOUD profil)

Postupak za onboarding jednog servera na SLBCK backup, od nule do prvog
uspješnog backupa. Vrijeme: ~10 minuta. Za lokalne servere (NAS) vidjeti
napomenu na dnu.

## Model flote

- **Jedan Storage Box po klijentu** (BX11/BX21 prema količini podataka,
  trošak se prefakturira klijentu)
- **Jedan subaccount po serveru** unutar klijentovog boxa, base dir
  `/<klijent>/<server>/` — server svojim ključem vidi SAMO svoj folder
- Standardi flote: backup **02:00**, retencija **3 dana** lokalno, box
  **snapshotovi daily / keep 7 / 04:00 UTC**, mail izvještaj nakon svakog
  backupa, restore test nedjeljom

## 1. Hetzner Robot (jednom po klijentu / serveru)

1. **Novi klijent** → naruči Storage Box, nazovi ga `<klijent>-backup`
2. **Snapshots tab** → automatic: **Daily, max 7, 04:00** (vrijeme je UTC!
   04:00 UTC = 06:00 ljetno — backup u 02:00 je odavno gotov)
3. **Subaccounts tab → Create subaccount** za novi server:
   - Base directory: `/<klijent>/<server>` (npr. `/hkoig/ssu`)
   - Description: `<klijent> <server> backup`
   - **SSH ✓**, SMB ✗, WebDAV ✗, read-only ✗
   - **External reachability ✓** ako je server izvan Hetznera (naši jesu)
   - Postavi lozinku (treba samo jednom, za instalaciju ključa)

## 2. Na serveru

```bash
git clone https://github.com/saguarogit-cmzk/SLBCK.git
cd SLBCK
sudo ./install.sh
sudo slbck quick
```

`slbck quick` pita samo ono što se razlikuje po serveru:

| Pitanje | Primjer |
|---|---|
| Owner/klijent | `hkoig` |
| Storage Box host | `u646563.your-storagebox.de` |
| Subaccount user | `u646563-sub1` |
| Mail za izvještaje | `log.si@outlook.com` (može više, zarezom) |
| Health URL-ovi | `https://app.klijent.hr https://api.klijent.hr` |
| Folderi za sync | `/var/www` (Enter za default) |

Sve ostalo su standardi flote i postavljaju se sami.

Quick setup na kraju **sam testira vezu na box** — ako ključ još nije
instaliran, ispiše točnu komandu (`ssh-copy-id -p 23 -s ...`, uz varijantu
za starije servere) i čeka da je pokreneš, pa ponovi test. Na kraju nudi
prvi backup odmah.

## 3. Checklist prije proglašenja gotovim

```bash
sudo slbck backup     # mora završiti: STATUS: OK
sudo slbck verify     # integritet + stvarni restore u testnu bazu
sudo slbck test-mail  # mail mora stići
sudo slbck status     # pregled konfiguracije i crona
```

Provjeri i na boxu (s glavnog accounta ili subaccounta) da postoje:
`YYYY-MM-DD/` s dumpovima i `folders/` sa sync folderima.

- [ ] backup OK, verify OK, mail stigao
- [ ] health sekcija u izvještaju zelena (servisi + URL-ovi)
- [ ] snapshotovi uključeni na boxu
- [ ] lozinka subaccounta spremljena u password manager (ili poništena)

## Napomene

- **MySQL/MariaDB na Ubuntuu**: radi odmah preko socket autha, bez unosa
  lozinke. Za druge distribucije vidi `slbck.conf.example` (backup user).
- **Mail transport**: ako server nema ništa za mail, puni `slbck setup`
  nudi instalaciju msmtp-a (SMTP relay). Naši serveri već imaju msmtp.
- **Excludovi za sync**: `/etc/slbck/folder-excludes.conf` — default već
  isključuje `node_modules/`, `cache/`, Laravel `storage/logs` i
  `storage/framework` cache.
- **Lokalni serveri (NAS profil)**: u pripremi (Faza 2). Do tada lokalni
  serveri mogu koristiti puni `slbck setup` s NAS-om kao rsync/SSH targetom.
- Ažuriranje SLBCK-a na serveru: `sudo slbck update`
- Sva pomoć u alatu: `slbck guide` (upute), `slbck help` (naredbe),
  restore scenariji: [RESTORE.md](RESTORE.md)
