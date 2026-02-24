# PMP Container Isolation Law v1

This repository MUST run isolated from every other project.

## Ports
- PMP MUST use dedicated host ports.
- The reserved defaults are:
  - DB: 55432 -> container 5432
  - API: 58080 -> container 8080
- It is a hard failure to start if any reserved port is already in use.

## Containers
- PMP MUST NOT share containers with any other project.
- All PMP containers MUST be prefixed and pinned:
  - pmp_db
  - pmp_api

## Compose project + network + volumes
- Compose project name MUST be `pmp` (compose file uses `name: pmp`).
- Network MUST be dedicated: `pmp_net` (not external/shared).
- Volumes MUST be dedicated: `pmp_db_data`.

## Enforcement
- `scripts\check_ports_pmp_v1.ps1` MUST be run before `docker compose up`.
- If ports are in use: FAIL with `PORT_IN_USE`.
