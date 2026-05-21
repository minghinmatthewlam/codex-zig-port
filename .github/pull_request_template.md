## Summary

-

## Parity Surface

-

## Verification

- [ ] `zig fmt --check build.zig build.zig.zon src/*.zig`
- [ ] `python3 -m py_compile scripts/app_server_stdio_smoke.py scripts/cli_smoke.py scripts/oss_secret_scan.py scripts/real_computer_use_mcp_smoke.py scripts/tui_e2e.py`
- [ ] `python3 scripts/oss_secret_scan.py`
- [ ] `zig build`
- [ ] `zig build test`
- [ ] `zig build e2e`
- [ ] Optional local computer-use proof: `python3 scripts/real_computer_use_mcp_smoke.py zig-out/bin/codex-zig`

## Notes

-
