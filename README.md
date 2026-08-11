# Golden Image Pipeline

CI/CD pipeline that builds, hardens, scans, and publishes a "golden"
OS image, using **Packer** for build automation, a shared **Kickstart**
file as the single source of truth for OS install + baseline config,
and **PXE** config so the same golden image definition can provision
baremetal hosts as well as cloud instances.

## Architecture

```
                 ┌────────────────────┐
                 │  kickstart/golden.ks│◄──────────────┐
                 └─────────┬──────────┘                │
                           │ used by                    │ used by
                           ▼                             │
        ┌──────────────────────────┐         ┌──────────┴─────────┐
        │  packer/image.pkr.hcl     │         │ pxe/pxelinux.cfg    │
        │  (cloud AMI build)        │         │ (baremetal boot)    │
        └─────────────┬─────────────┘         └──────────┬──────────┘
                       │                                  │
                       ▼                                  ▼
             scripts/harden.sh                    Baremetal fleet
             (CIS hardening,                       installs golden.ks
              mirrors ks %post)                     directly over network
                       │
                       ▼
          GitHub Actions: validate → build → scan → publish
```

## Pipeline stages (`.github/workflows/golden-image-pipeline.yml`)

1. **validate** — `packer validate`, `packer fmt`, Kickstart syntax
   check (`ksvalidator`), and `shellcheck` on the hardening script.
2. **build** — Packer builds the image, authenticating to the cloud
   provider via short-lived OIDC credentials (no static cloud keys
   stored in GitHub secrets). Runs `scripts/harden.sh` as a
   provisioner.
3. **scan** — Trivy for CVE scanning, OpenSCAP for CIS-benchmark
   compliance scoring. Pipeline fails on critical/high findings so
   nothing unhardened reaches "golden" status.
4. **publish** — tags/promotes the validated image in the image
   registry and syncs the PXE config + `golden.ks` to the on-prem
   boot server, so baremetal rebuilds stay in lockstep with the
   cloud image.

## Why Kickstart is the shared source of truth

Both paths install the same package baseline and apply the same
hardening logic:

- Packer path: base image → `scripts/harden.sh` provisioner (mirrors
  the Kickstart `%post` section) for environments where Kickstart
  itself isn't the install mechanism (e.g. rebuilding from a cloud
  base AMI).
- PXE path: `golden.ks` drives the actual unattended OS install on
  baremetal, including its own `%post` hardening block.

Keeping the hardening logic defined once (CIS controls: SSH config,
password policy, disabled filesystems/services, auditd rules, AIDE
integrity baseline, firewall default-deny) and mirrored between the
two paths avoids drift between how cloud and baremetal images are
secured.

## Security design choices worth calling out in interview

- **No long-lived secrets**: cloud auth uses GitHub OIDC → short-lived
  STS credentials rather than static access keys.
- **Fail-closed scanning**: the `scan` job's exit code gates
  `publish` — a critical CVE or CIS failure blocks promotion.
- **Secrets never committed**: `golden.ks` references
  `${ADMIN_PW_HASH}`, `${ADMIN_SSH_PUBKEY}`, `${LUKS_PASSPHRASE}` as
  placeholders injected at build time, not hardcoded.
- **Reproducible + scheduled rebuilds**: monthly cron trigger keeps
  the golden image current against newly disclosed CVEs, not just
  rebuilt on code change.
- **Encrypted root volume** via LUKS in the Kickstart `autopart` line,
  and locked root login with sudo-only admin access.
