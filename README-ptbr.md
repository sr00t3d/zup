# zup — ZoneUPdater: Atualizador em Lote de Zonas DNS BIND (`v2.0.0`)

Uma CLI moderna e independente em Bash + Python 3 para atualizar em lote **arquivos de zona DNS BIND** (`/var/named/*.db`) por domínio, usuário cPanel ou revenda — substituindo o legado em Perl `zup` (2012, 4.217 linhas) com backups automáticos `chmod 600`, rollback via `named-checkzone`, incremento automático de serial `YYYYMMDDnn` e saídas `table` / `json` / `csv`.

## Recursos

- **Zero Dependências Legadas**: Elimina `ZUP::RCS`, caminhos hardcoded (`/home/hgtransfer/zup-backups`) e interpolação insegura em `tar`/`rndc`.
- **Backup Automático e Rollback**: Cria backup `chmod 600` antes de cada alteração, valida com `named-checkzone` (quando disponível) e permite restauração rápida via `--restore <domínio>`.
- **Edição Completa de Registros**: SOA (`--set-soa-ns`, `--set-soa-email`, `-s/--bump-serial`), `--set-ns`, `--set-mx`, `--set-a`, `--replace-ip ANTIGO:NOVO`, `--set-cname`, `--set-spf` e `--set-dkim`.
- **Presets Modernos**: `--google-workspace` e `--microsoft365`.

## Exemplo de Saída Real

```text
$ ./zup.sh -d example.com --zone-dir /tmp/zup-e2e/named --backup-dir /tmp/zup-e2e/backups --replace-ip 192.0.2.10:198.51.100.25 --google-workspace --no-color
=== zup.sh v2.0.0 | DNS Zone Batch Update Report ===
STATUS       DOMAIN                       SERIAL                  ACTIONS
----------------------------------------------------------------------------------------
OK           example.com                  2026112001->2026112401  preset_google_workspace, replace_ip(192.0.2.10->198.51.100.25 x2)
```

## Licença

Apache-2.0 — veja [LICENSE](LICENSE).
