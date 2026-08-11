#!/bin/bash
# InsForge project-instance AMI bake script — Ubuntu 24.04 LTS (arm64)
#
# Run against a fresh Canonical Ubuntu 24.04 arm64 instance, then create-image.
# Every step here is derived from a spike finding; see the comments for which.
# Base AMI: resolve per region from
#   /aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

log() { echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# 1. SSM agent: snap -> deb.  MUST happen at bake time.
#
# Canonical's AMI ships the agent as a snap. Swapping it on a *running* fleet
# instance is impossible: the deb's preinst aborts while the snap is present,
# and removing the snap kills the agent executing the script (verified twice,
# two different failure modes). At bake time we can sequence it safely because
# losing the management channel mid-bake is recoverable.
# Payoff: snapd (~18MB) + snap wrapper overhead gone; deb agent is ~6MB
# lighter than the snap build.
# ---------------------------------------------------------------------------
log "SSM agent: snap -> deb"
snap remove amazon-ssm-agent || true
apt-get purge -y snapd
apt-get autoremove -y
curl -fsSLo /tmp/ssm.deb \
  "https://amazon-ssm-${AWS_REGION:-us-east-2}.s3.${AWS_REGION:-us-east-2}.amazonaws.com/latest/debian_arm64/amazon-ssm-agent.deb"
dpkg -i /tmp/ssm.deb
systemctl enable --now amazon-ssm-agent
systemctl is-active --quiet amazon-ssm-agent || { echo "FATAL: deb SSM agent not active"; exit 1; }
rm -f /tmp/ssm.deb

# ---------------------------------------------------------------------------
# 2. Runtime + tooling
#
# postgresql-client-16: the control plane's backup/restore/branch commands run
# psql/pg_dump on the HOST against 127.0.0.1 instead of `exec`ing into a
# container. Keep the client major at 16 against a 15 server (pg_dump 17+
# emits settings a 15 server rejects).
# ---------------------------------------------------------------------------
# awscli: the control plane's backup/restore/branch helpers shell out to
# `aws s3 cp`, and the user-data SSM-association wait calls `aws ssm`. AL2023
# ships the CLI preinstalled; Ubuntu does not, and its absence is quiet — the
# wait loop just burns its full 120s timeout logging "aws: command not found"
# and backups fail later, at the worst possible moment.
#
# The CLI cannot come from apt: `awscli` has no candidate on 24.04 even with
# universe enabled (verified — Candidate: (none)). Use the vendor installer,
# which needs unzip, and install unzip from apt here so the provisioning script
# never has to: this image ships with /var/lib/apt/lists emptied by the cleanup
# below, so any apt-get install at provisioning time fails with "Unable to
# locate package" unless it runs apt-get update first.
log "Installing podman + tooling"
apt-get update -qq
apt-get install -y -qq \
  podman \
  postgresql-client-16 \
  systemd-zram-generator \
  unzip \
  git curl jq zstd

log "Installing AWS CLI v2 (vendor installer)"
cd /tmp
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o awscliv2.zip
unzip -q -o awscliv2.zip
./aws/install --update >/dev/null
rm -rf awscliv2.zip aws
aws --version || { echo "FATAL: aws cli missing after install"; exit 1; }

# fluent-bit from the vendor's official Ubuntu repo (journald -> CloudWatch;
# podman has no awslogs driver, so this replaces dockerd's built-in shipping).
log "Installing fluent-bit"
curl -fsSL https://packages.fluentbit.io/fluentbit.key | gpg --dearmor \
  > /usr/share/keyrings/fluent-bit.gpg
echo 'deb [signed-by=/usr/share/keyrings/fluent-bit.gpg] https://packages.fluentbit.io/ubuntu/noble noble main' \
  > /etc/apt/sources.list.d/fluent-bit.list
apt-get update -qq
apt-get install -y -qq fluent-bit
systemctl disable fluent-bit   # provisioning enables it after writing the config

# node_exporter: fleet metrics (Prometheus scrapes project_id-labelled host
# metrics; nothing container-aware, so this is unchanged from AL2023).
log "Installing node_exporter"
NE_VER=1.8.2
curl -fsSL "https://github.com/prometheus/node_exporter/releases/download/v${NE_VER}/node_exporter-${NE_VER}.linux-arm64.tar.gz" \
  | tar -xz -C /tmp
install -m 0755 "/tmp/node_exporter-${NE_VER}.linux-arm64/node_exporter" /usr/local/bin/node_exporter
rm -rf "/tmp/node_exporter-${NE_VER}.linux-arm64"
cat > /etc/systemd/system/node_exporter.service <<'UNIT'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
ExecStart=/usr/local/bin/node_exporter --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($|/) --web.listen-address=:9100
Restart=always
Environment=GOMEMLIMIT=24MiB

[Install]
WantedBy=multi-user.target
UNIT
systemctl enable node_exporter

# ---------------------------------------------------------------------------
# 3. zram — REQUIRED, and verify the effective size.
#
# Ubuntu ships no zram by default; a 418MB nano cannot survive without it.
# Gotcha: installing systemd-zram-generator creates zram0 immediately with
# package defaults (ram/2 = ~204MB). Writing the config afterwards does NOT
# resize a live device — only the next boot picks it up. Always assert the
# post-reboot size (AL2023 gives zram == full RAM; match that).
# ---------------------------------------------------------------------------
log "Configuring zram"
cat > /etc/systemd/zram-generator.conf <<'ZRAM'
[zram0]
zram-size = ram
compression-algorithm = lzo-rle
ZRAM

# ---------------------------------------------------------------------------
# 4. Service trim — the Ubuntu equivalent of the AL2023 audit.
#
# Measured on a spike instance: an untrimmed Ubuntu base runs ~40-50MB heavier
# than a trimmed AL2023 one, which swallows podman's entire runtime saving
# (untrimmed Ubuntu+podman measured WORSE than AL2023+podman). This step is
# not optional cleanup — it is what makes the distro switch break even.
#
#   multipathd (~25MB)          multipath SAN I/O; EBS-only instances have none
#   ModemManager                cellular modems; obviously absent
#   networkd-dispatcher (~9MB)  hook runner for netplan events; we have no hooks
#   udisks2 (~8MB)              desktop removable-media daemon
#   unattended-upgrades (~8MB)  we control patching via AMI rebake
#   packagekitd (~10MB)         desktop package-management D-Bus service
# ---------------------------------------------------------------------------
log "Trimming unused services"
for u in multipathd multipathd.socket ModemManager networkd-dispatcher \
         udisks2 unattended-upgrades packagekit packagekit-offline-update; do
  systemctl disable --now "$u" 2>/dev/null || true
done
# Mask the two that get pulled back in by dependencies.
systemctl mask multipathd multipathd.socket ModemManager 2>/dev/null || true
apt-get purge -y unattended-upgrades packagekit 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Cleanup so the image ships small and without instance identity
# ---------------------------------------------------------------------------
log "Cleaning up"
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/* /var/log/cloud-init*.log /var/log/syslog* \
       /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys 2>/dev/null || true
cloud-init clean --logs 2>/dev/null || true
rm -f /etc/machine-id && touch /etc/machine-id   # regenerated at first boot

log "Bake complete. Verify after create-image + first boot:"
cat <<'CHECKS'
  systemctl is-active amazon-ssm-agent      # deb agent, must be active
  which snap                                # must be absent
  zramctl                                   # DISKSIZE must equal total RAM
  podman info --format '{{.Store.GraphDriverName}}'   # must be "overlay", not fuse
  podman run --rm --log-driver=journald alpine echo ok   # journald driver works
  systemctl list-units --type=service --state=running | wc -l   # expect ~14-16
  aws --version                             # must print aws-cli/2.x
  command -v unzip                          # must exist; apt lists are empty here
CHECKS

# The last two checks exist because the first baked image shipped without the
# AWS CLI and without unzip, and nothing noticed: provisioning "succeeded",
# the SSM wait loop logged "aws: command not found" for its whole timeout, and
# the first backup produced a 20-byte empty gzip that the control plane
# recorded as a completed restore point. A post-boot check for every binary the
# control plane shells out to is cheaper than finding it that way.
