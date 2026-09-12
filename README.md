# Useful-Commands-for-vps-server
Useful Commands for vps server


-- Command to check folders depth:
- ls -lh /swapfile 2>/dev/null
- du -hx --max-depth=2 /home /opt /usr/local 2>/dev/null | sort -rh | head -n 15
- du -hx --max-depth=2 /var /usr 2>/dev/null | sort -rh | head -n 15

-- After cleanup check space:
- df -h /
