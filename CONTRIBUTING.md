# Development

Tool versions and commands live in `mise.toml`; fast checks live in `hk.pkl`.
`mise run test` runs deterministic unit and local boundary tests without a provider.
Build and release scripts run with Bun; the packaged adapter has no Bun dependency.

`mise run test:e2e -- --provider docker` runs the provider suite. The provider is
required and may be `docker`, `podman`, `microsandbox` or `apple`. Install and start
the selected runtime first. Linux requires the Electron libraries and a display;
CI uses Xvfb. Apple requires a Mac with Apple Silicon and virtualization support.

E2E uses the Orca release pinned by `e2e_orca_version` in `mise.toml` for both
the desktop and fixture server. It drives the desktop preload IPC bridge in an
isolated profile. Four workspaces share one host Git helper/store and one
SSH agent. A local authenticated Git server and synthetic Codex refresh RPC keep
real account credentials out of the fixture. Sanitized results, versions and
operation durations are written under `.e2e/`; private runtime state is temporary.
Timing targets and their five-second acceptance buffer are defined in
`tests/e2e/timing.ts`; the buffer does not change the performance targets.

CI runs Linux x64 Docker, rootless Podman and Microsandbox, and Linux arm64 Docker
and rootless Podman. Apple arm64 and Microsandbox arm64 are manual lanes; they
require hosts with the corresponding virtualization support.

The IPC suite covers recipe execution, receipt persistence, connection registration
and saved-state lifecycle handling. Renderer workspace/terminal routing and the
VS Code/JetBrains remote UIs require manual checks. The fixture does not authenticate
to external Git services or perform Codex login or inference.
