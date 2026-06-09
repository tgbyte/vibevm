#!/usr/bin/env bash
# Keep the VM clock correct WITHOUT any network egress (runs as ROOT; re-runnable).
#
# Why this exists: the egress firewall is default-DROP and has no rule for NTP
# (UDP 123), so systemd-timesyncd can never reach a time server and the system
# clock drifts freely. Instead of poking an NTP hole in the firewall, we read the
# host's clock directly through the KVM virtual PTP device (/dev/ptp0) and let
# chrony discipline the system clock to it. Zero packets leave the VM.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "== Loading the KVM PTP clock (host time source, no network) =="
echo ptp_kvm >/etc/modules-load.d/ptp_kvm.conf
modprobe ptp_kvm || true

echo "== Installing chrony (replaces systemd-timesyncd) =="
apt-get install -y --no-install-recommends chrony

echo "== Pointing chrony at the KVM PTP device instead of NTP pools =="
# The default Ubuntu sources are public NTP pools the firewall blocks; drop them
# so chrony doesn't waste time polling unreachable servers.
rm -f /etc/chrony/sources.d/ubuntu-ntp-pools.sources /etc/chrony/conf.d/ubuntu-nts.conf
cat >/etc/chrony/conf.d/ptp-kvm.conf <<'EOF'
# vibevm: sync from the host clock via the KVM virtual PTP device.
# The egress firewall blocks NTP (UDP 123); the PHC needs no network.
refclock PHC /dev/ptp0 poll 2 dpoll -1 offset 0 stratum 1
EOF

systemctl enable chrony
systemctl restart chrony

echo "== Time sync status =="
sleep 5
chronyc tracking 2>&1 | grep -E 'Reference ID|Leap status' || true
