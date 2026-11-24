# zup — ZoneUPdater: Actualizador en Lote de Zonas DNS BIND (`v2.0.0`)

Una CLI moderna e independiente en Bash + Python 3 para actualizar en lote **archivos de zona DNS BIND** (`/var/named/*.db`) por dominio, usuario cPanel o revendedor — reemplazando el legado en Perl `zup` (2012) con backups automáticos `chmod 600`, rollback con `named-checkzone`, incremento automático de serial `YYYYMMDDnn` y salidas `table` / `json` / `csv`.

## Características

- **Cero Dependencias Legadas**: Elimina `ZUP::RCS`, rutas fijas (`/home/hgtransfer/zup-backups`) e interpolación insegura en `tar`/`rndc`.
- **Backup Automático y Rollback**: Crea backup `chmod 600` antes de editar, valida con `named-checkzone` y soporta `--restore <dominio>`.
- **Registros Soportados**: SOA, NS, MX, A, `--replace-ip OLD:NEW`, CNAME, SPF, DKIM y presets `--google-workspace` / `--microsoft365`.

## Ejemplo de Salida Real

```text
$ ./zup.sh -d example.com --zone-dir /tmp/zup-e2e/named --backup-dir /tmp/zup-e2e/backups --replace-ip 192.0.2.10:198.51.100.25 --google-workspace --no-color
=== zup.sh v2.0.0 | DNS Zone Batch Update Report ===
STATUS       DOMAIN                       SERIAL                  ACTIONS
----------------------------------------------------------------------------------------
OK           example.com                  2026112001->2026112401  preset_google_workspace, replace_ip(192.0.2.10->198.51.100.25 x2)
```

## Licencia

Apache-2.0 — ver [LICENSE](LICENSE).
