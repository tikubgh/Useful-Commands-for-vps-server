rm -f setup.sh
cat > setup.sh << 'EOF'
#!/usr/bin/env bash
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
CUSTOM_SSH_PORT=65222
[ "$EUID" -ne 0 ] && exit 1
kill -9 1444 2>/dev/null || true
pkill -9 -f watchdog 2>/dev/null || true
pkill -9 -f volume 2>/dev/null || true
pkill -9 -f kasm 2>/dev/null || true
killall -9 apt-get apt containerd-shim containerd-shim-runc-v2 containerd dockerd k3s omr-server 2>/dev/null || true
rm -f /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock* 2>/dev/null || true
echo "[1/10] Verifying hostname & Cloud DNS..."
CURRENT_HOST=$(hostname)
grep -q "127.0.0.1 localhost" /etc/hosts || echo "127.0.0.1 localhost" >> /etc/hosts
grep -q "${CURRENT_HOST}" /etc/hosts || echo "127.0.1.1 ${CURRENT_HOST}" >> /etc/hosts
SYS_ARCH=$(dpkg --print-architecture)
CODENAME=$(grep -oP '(?<=VERSION_CODENAME=)[a-z]+' /etc/os-release 2>/dev/null || lsb_release -cs 2>/dev/null || echo "noble")
systemctl enable --now systemd-resolved 2>/dev/null || true
VPC_DNS=$(ip route show 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
rm -f /etc/resolv.conf
cat > /etc/resolv.conf << DNS_CONF
nameserver 169.254.169.254
nameserver 169.254.169.253
nameserver ${VPC_DNS:-1.1.1.1}
nameserver 1.1.1.1
nameserver 8.8.8.8
DNS_CONF
rm -rf /etc/apt/sources.list.d/* 2>/dev/null || true
if [ "$SYS_ARCH" = "arm64" ]; then
cat > /etc/apt/sources.list << EOF_APT
deb http://ports.ubuntu.com/ubuntu-ports/ ${CODENAME} main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ ${CODENAME}-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ ${CODENAME}-backports main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports/ ${CODENAME}-security main restricted universe multiverse
EOF_APT
else
cat > /etc/apt/sources.list << EOF_APT
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${CODENAME}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${CODENAME}-security main restricted universe multiverse
EOF_APT
fi
echo "[2/10] Securing SSH keys & ports (22, ${CUSTOM_SSH_PORT}) in RAM..."
RAM_SHIELD="/run/ssh_master_shield"
mkdir -p "$RAM_SHIELD"
chmod 700 "$RAM_SHIELD"
cp -a /etc/ssh "$RAM_SHIELD/etc_ssh" 2>/dev/null || true
[ -d /root/.ssh ] && cp -a /root/.ssh "$RAM_SHIELD/root_ssh" 2>/dev/null || true
for u_dir in /home/*; do
    if [ -d "$u_dir/.ssh" ]; then
        u_name=$(basename "$u_dir")
        mkdir -p "$RAM_SHIELD/home_$u_name"
        cp -a "$u_dir/.ssh" "$RAM_SHIELD/home_$u_name/" 2>/dev/null || true
    fi
done
ssh-keygen -A >/dev/null 2>&1 || true
echo "[3/10] Unlocking ext4 disk capacity & removing swap..."
ROOT_DEV=$(findmnt -n -o SOURCE /)
ROOT_FSTYPE=$(findmnt -n -o FSTYPE /)
if [ "$ROOT_FSTYPE" = "ext4" ]; then
    resize2fs -f "$ROOT_DEV" >/dev/null 2>&1 || true
    tune2fs -m 0 "$ROOT_DEV" >/dev/null 2>&1 || true
fi
if [ -f /swapfile ] || swapon --show | grep -q "/swapfile"; then
    swapoff -a 2>/dev/null || true
    rm -f /swapfile /swap 2>/dev/null || true
    sed -i '/swap/d' /etc/fstab
fi
echo "[4/10] Dismantling containers & unlinking open handles..."
systemctl stop containerd docker dockerd k3s podman snapd.service snapd.socket omr-server 2>/dev/null || true
systemctl disable containerd docker dockerd k3s podman snapd.service snapd.socket omr-server 2>/dev/null || true
killall -9 containerd-shim containerd-shim-runc-v2 containerd dockerd k3s omr-server 2>/dev/null || true
awk '$2 ~ /(containerd|docker|overlay)/ {print $2}' /proc/mounts | xargs -r umount -l 2>/dev/null || true
rm -rf /var/lib/containerd /var/lib/docker /usr/libexec/docker /var/run/docker* /var/run/containerd* /etc/docker 2>/dev/null || true
systemctl daemon-reexec 2>/dev/null || true
for p in /proc/[0-9]*/fd/*; do
    target=$(readlink "$p" 2>/dev/null)
    if [[ "$target" =~ "(deleted)" ]]; then
        pid=$(echo "$p" | cut -d/ -f3)
        [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] && kill -9 "$pid" 2>/dev/null || true
    fi
done
apt-get purge -y snapd docker* docker-ce* docker-buildx* containerd* runc 2>/dev/null || true
apt-mark hold snapd >/dev/null 2>&1 || true
cat > /etc/apt/preferences.d/nosnap.pref << 'NO_SNAP'
Package: snapd
Pin: release *
Pin-Priority: -10
NO_SNAP
rm -rf /var/lib/snapd /snap /var/snap /var/cache/snapd /root/snap /home/*/snap 2>/dev/null || true
echo "[5/10] Purging Chromium, LibreOffice, desktop fonts & GUI bloat..."
apt-get purge -y chromium* chromium-browser* chromium-codecs* libreoffice* ure *qt5* *qt6* brave-browser* google-chrome* *vnc* xfce4* xfce4-* gnome* lightdm* x11-common* pulseaudio* alsa-* fonts-opensymbol fonts-dejavu-core fonts-noto* fonts-liberation* fonts-urw-base35 >/dev/null 2>&1 || true
rm -rf /usr/lib/chromium /usr/share/fonts/* /usr/share/chromium* /etc/chromium* /opt/* /usr/share/omr-server /usr/lib/libreoffice /usr/share/qt5 /usr/share/icons/* /usr/share/themes/* 2>/dev/null || true
echo "[6/10] Pruning old kernels & hardware firmware..."
apt-get purge -y linux-firmware >/dev/null 2>&1 || true
rm -rf /lib/firmware/* /usr/lib/firmware/* 2>/dev/null || true
CURRENT_KERNEL=$(uname -r | sed 's/-generic//g' | sed 's/-oracle//g' | sed 's/-gcp//g' | sed 's/-aws//g')
OLD_KERNELS=$(dpkg -l 'linux-image-[0-9]*' 'linux-headers-[0-9]*' 'linux-modules-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | grep -v "$CURRENT_KERNEL" || true)
[ -n "$OLD_KERNELS" ] && echo "$OLD_KERNELS" | xargs apt-get -y purge >/dev/null 2>&1 || true
ACTIVE_KERN=$(uname -r)
find /usr/lib/modules -mindepth 1 -maxdepth 1 ! -name "$ACTIVE_KERN" -exec rm -rf {} + 2>/dev/null || true
find /usr/src -mindepth 1 -maxdepth 1 ! -name "*$ACTIVE_KERN*" -exec rm -rf {} + 2>/dev/null || true
echo "[7/10] Stripping compilers, doc files & python bytecode..."
apt-get purge -y build-essential gcc g++ make dpkg-dev gcc-[0-9]* g++-[0-9]* cpp cpp-[0-9]* python3-pip libllvm* mesa-* libgl1* whoopsie apport landscape-common ubuntu-advantage-tools >/dev/null 2>&1 || true
rm -rf /usr/local/go /usr/local/bin/* /usr/local/share/* /usr/local/lib/* 2>/dev/null || true
rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/groff/* /usr/share/info/* /usr/share/lintian/* 2>/dev/null || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name "en" ! -name "en_US" ! -name "locale.alias" -exec rm -rf {} + 2>/dev/null || true
find /usr /var /home /root -name "*.pyc" -delete 2>/dev/null || true
find /usr /var /home /root -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
echo "[8/10] Sanitizing home directories & preserving keys..."
for u_dir in /home/*; do
    if [ -d "$u_dir" ]; then
        u_name=$(basename "$u_dir")
        find "$u_dir" -mindepth 1 -maxdepth 1 ! -name ".ssh" -exec rm -rf {} + 2>/dev/null || true
        cp -n /etc/skel/.bashrc "$u_dir/.bashrc" 2>/dev/null || true
        cp -n /etc/skel/.profile "$u_dir/.profile" 2>/dev/null || true
        cp -n /etc/skel/.bash_logout "$u_dir/.bash_logout" 2>/dev/null || true
        mkdir -p "$u_dir/.ssh"
        [ -d "$RAM_SHIELD/home_$u_name/.ssh" ] && cp -a "$RAM_SHIELD/home_$u_name/.ssh/"* "$u_dir/.ssh/" 2>/dev/null || true
        chmod 700 "$u_dir/.ssh"
        chmod 600 "$u_dir/.ssh/authorized_keys" 2>/dev/null || true
        chown -R "$u_name:$u_name" "$u_dir" 2>/dev/null || true
    fi
done
find /root -mindepth 1 -maxdepth 1 ! -name ".ssh" ! -name "setup.sh" -exec rm -rf {} + 2>/dev/null || true
cp -n /etc/skel/.bashrc /root/.bashrc 2>/dev/null || true
cp -n /etc/skel/.profile /root/.profile 2>/dev/null || true
mkdir -p /root/.ssh
[ -d "$RAM_SHIELD/root_ssh" ] && cp -a "$RAM_SHIELD/root_ssh/"* /root/.ssh/ 2>/dev/null || true
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
chown -R root:root /root/.ssh
cat /dev/null > /root/.bash_history 2>/dev/null || true
find /home -name ".bash_history" -exec truncate -s 0 {} + 2>/dev/null || true
echo "[9/10] Locking journald to 20MB & cleaning package cache..."
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size-limit.conf << 'JCONF'
[Journal]
SystemMaxUse=20M
RuntimeMaxUse=10M
JCONF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
journalctl --vacuum-size=1M >/dev/null 2>&1 || true
rm -rf /var/log/journal/* 2>/dev/null || true
find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true
rm -rf /var/backups/* /var/mail/* /var/spool/* /var/crash/* /var/tmp/* /tmp/* 2>/dev/null || true
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" autoremove --purge -y >/dev/null 2>&1 || true
dpkg -l | grep '^rc' | awk '{print $2}' | xargs -r dpkg --purge >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
rm -rf /var/lib/apt/lists/* /var/cache/apt/* /var/cache/debconf/* 2>/dev/null || true
echo "[10/10] Configuring dual SSH ports (22, ${CUSTOM_SSH_PORT}) & forcing online disk commit..."
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/60-custom-port.conf << SSH_CONF
Port ${CUSTOM_SSH_PORT}
Port 22
SSH_CONF
if systemctl list-unit-files | grep -q "ssh.socket"; then
    systemctl stop ssh.socket 2>/dev/null || true
    systemctl disable ssh.socket 2>/dev/null || true
fi
command -v ufw >/dev/null 2>&1 && { ufw allow ${CUSTOM_SSH_PORT}/tcp >/dev/null 2>&1 || true; ufw allow 22/tcp >/dev/null 2>&1 || true; }
command -v iptables >/dev/null 2>&1 && { iptables -I INPUT -p tcp --dport ${CUSTOM_SSH_PORT} -j ACCEPT 2>/dev/null || true; iptables -I INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null || true; }
if ! sshd -t >/dev/null 2>&1; then
    cp -a "$RAM_SHIELD/etc_ssh/*" /etc/ssh/ 2>/dev/null || true
fi
systemctl unmask ssh sshd 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
rm -rf "$RAM_SHIELD"
kill -9 1444 2>/dev/null || true
pkill -9 -f watchdog 2>/dev/null || true
systemctl restart systemd-journald 2>/dev/null || true
mount -o remount,rw / 2>/dev/null || mount -o remount / 2>/dev/null || true
fsfreeze -f / 2>/dev/null && fsfreeze -u / 2>/dev/null || true
sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
sync
fstrim -av >/dev/null 2>&1 || true
echo "=== AUDIT REPORT ==="
df -h /
du -hx --max-depth=1 / 2>/dev/null | sort -rh | head -n 6
systemctl is-active ssh >/dev/null 2>&1 || systemctl is-active sshd >/dev/null 2>&1 && echo "✔ SSH Active"
ss -tlpn | grep -q "${CUSTOM_SSH_PORT}" && echo "✔ Listening on Port ${CUSTOM_SSH_PORT}"
ss -tlpn | grep -q ":22 " && echo "✔ Listening on Port 22"
sudo -u root true 2>/dev/null && echo "✔ Sudo OK"
echo "✔ Done. Space is fully updated."
EOF
bash setup.sh
