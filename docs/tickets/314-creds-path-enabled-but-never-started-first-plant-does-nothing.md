# 314 — guarden-creds.path is enabled but never started: the first credential plant triggers nothing

Blockers: none. Found 2026-10-19 measured in a VM during the 295/302 fix
(instance-start-path report: "no podman secret exists at all because
guarden-creds.path is enabled but never started").

## What happens
`systemctl list-unit-files` shows guarden-creds.path ENABLED, yet on a freshly
converged box it is not running until reboot, so a first `weedr secret set` does not
fire the materialiser and no podman secret appears — start then dies at podman (see
313's observed 125). The runbook compensates by `systemctl start
guarden-creds-boot.service` by hand (docs/sysadmin.md:326-328, the acceptance run's
step 4) — the automation the .path unit exists for does not engage on first use.

## What to build
Make the installed state consistent: either install/start the .path unit so the first
plant materialises, or refuse the plant with the gate one-liner telling the operator
the materialiser is not active (read spec's gate/creds section for which is
contractual). Red-first: fresh converge → `weedr secret set` → podman secret exists
without a manual creds-boot start (or the refusal names the missing step exactly).
