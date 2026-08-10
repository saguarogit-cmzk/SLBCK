# SLBCK — Migracija s borga (umirovljenje starog sustava)

Postupak za gašenje borg+S3 (mega.io) backupa na serveru koji je prešao na
SLBCK. Ponovljiv za svaki server. **Razlog migracije: mega.io S3 je skup —
nakon migracije se ukida u cijelosti.**

## Preduvjeti (NE preskakati!)

- [ ] SLBCK na serveru radi **minimalno 2 noći zaredom** (mail `backup OK`
      u ~02:05 oba jutra)
- [ ] `sudo slbck verify` prošao (integritet + restore test)
- [ ] Backup vidljiv na Storage Boxu (`YYYY-MM-DD/` + `folders/`)
- [ ] Snapshotovi uključeni na boxu (daily / keep 7)

## VAŽNO: gubitak duboke povijesti

Borg/S3 je čuvao mjesece povijesti. Nakon ukidanja, povijest je:
**3–7 dana lokalno + 7 dana box snapshotova**. Kompenzacija (napraviti PRIJE
gašenja borga):

1. Na serveru digni lokalnu retenciju: u `/etc/slbck/slbck.conf` postavi
   `RETENTION_DAYS="7"` (dumpovi su maleni, disk to ne osjeti)
2. Na boxu digni snapshotove na **keep 10** (maksimum za BX11) ako želiš
   dodatna 3 dana

Ako neki klijent treba dugu povijest (npr. mjesečni arhivski backup),
to je posebna tema — javi se prije gašenja njegovog borga.

## Postupak po serveru

```bash
# 1. Oprosti se od borga - jednokratna arhiva njegovog configa na box
#    (repo ključevi, postavke - za svaki slučaj, sitno je)
tar czf /var/backups/slbck/borg-final-config-$(hostname -s).tar.gz /opt/saguaro-backup 2>/dev/null
sudo slbck send        # gurni na box odmah

# 2. Makni borg cronove (artisan/aplikacijski cronovi se NE diraju!)
rm -f /etc/cron.d/saguaro*          # ili zakomentiraj saguaro-borg linije
crontab -l | grep -v saguaro | crontab -    # ako je nešto u root crontabu

# 3. Provjeri da NIŠTA saguaro/borg više nije u cronu
grep -r saguaro /etc/cron.d/ /var/spool/cron/ 2>/dev/null || echo "cisto"

# 4. Ukloni borg alat i skripte
rm -rf /opt/saguaro-backup
rm -f /usr/local/sbin/saguaro-borg-run.sh /usr/local/bin/borg /usr/bin/borg 2>/dev/null

# 5. Stari lokalni mysql dumpovi od borg sustava (SLBCK ima svoje)
rm -rf /var/backups/mysql
```

## Nakon svih servera

- [ ] mega.io S3: provjeri da NIJEDAN server više ne piše u repo
      (mega.io panel → zadnje aktivnosti), pa **ukini pretplatu**
- [ ] Sljedeće jutro: mailovi `backup OK` sa svih migriranih servera
- [ ] Tjedan kasnije: nedjeljni restore test prošao na svima

## Rollback (ako nešto krene po zlu unutar prvih dana)

Borg cronove smo obrisali, ali dok mega.io pretplata još traje, repo na
S3 je netaknut — reinstalacija borg paketa + `borg-final-config` arhiva
s boxa (repo ključevi/config) vraća pristup stampanoj povijesti. Zato:
**mega.io ukinuti tek kad su SVI serveri migrirani i stabilni**, ne po
serveru.
