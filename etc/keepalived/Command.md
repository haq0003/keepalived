# CHECK EACH SERVER IN WHICH STATE WE ARE
journalctl -u keepalived -f | grep "STATE"
# RELOAD, CHECK FIREWALL
systemctl start keepalived
# CHECK IPFAILOVER ASSIGNATION IN SCALEWAY
/etc/keepalived/failover_script.sh MASTER
