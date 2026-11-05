# Publication validation

Validated November 4, 2026 on this Mac.

- XcodeGen project generation: passed.
- Release build for generic iOS device, signing disabled: passed. Used the existing downloaded llama.cpp XCFramework, which is excluded from Git.
- Gitleaks scan: no detected secrets.
- Device IDs removed from build instructions; signing team left for the developer to configure.

No new physical-device installation, inference evaluation or permission-flow testing
was performed. Reports under `docs/` describe historical synthetic evaluations.
