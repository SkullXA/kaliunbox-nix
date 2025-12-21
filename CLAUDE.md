- don't add temporary comments in the code

## Connect API

- **Token lifetimes**: Access token 7 days, refresh token 90 days, rotation after 30 days
- **Bootstrap** (claiming): Fetch config WITHOUT bearer → gets tokens + config → DELETE /config to lock
- **Config sync** (ongoing): Fetch WITH bearer → returns config only (no new tokens)
- **Token refresh**: POST /token/refresh with refresh_token
- **Timers**: Token refresh daily, config sync hourly, health report every 15min

## Config format

`/var/lib/kaliun/config.json`:
- `auth.{access_token, refresh_token, access_expires_at, refresh_expires_at}`
- `customer.{name, email, address}`
- `pangolin.{newt_id, newt_secret, endpoint}`

## Logging

All services use journald (no file-based logging):
- `journalctl -u kaliun-auto-update.service`
- `journalctl -u kaliun-token-refresh.service`
- `journalctl -u kaliun-config-sync.service`
- `journalctl -u kaliun-health-reporter.service`

## Documentation

When adding or modifying maintenance commands (shell scripts, aliases, or CLI tools), update `docs/maintenance.md` to reflect the changes. Key commands to document:
- Home Assistant CLI access (`ha`, `homeassistant-status`, `homeassistant-console`)
- Snapshot management (`havm-snapshot-*`)
- Health checks (`havm-health-check`)
- Update commands (`kaliunbox-update`, `kaliunbox-rollback`)
- Boot health (`kaliunbox-boot-health`, `kaliunbox-mark-good`)