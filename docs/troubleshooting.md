# Troubleshooting

## Service didn't start

Check the setup service logs:
```bash
sudo journalctl -u <service>-setup -n 50
```

To re-run a service setup:
```bash
sudo rm /var/lib/<service>-setup-done
sudo systemctl restart <service>-setup
```

## K3s not starting

```bash
sudo journalctl -u k3s -n 100
sudo systemctl status k3s
```

Common causes:
- Network not ready (check `ip a`)
- DNS not resolving (check `/etc/resolv.conf`)
- Flannel CNI issues (check `ip link show cni0`)

## Pod stuck in Pending

```bash
kubectl describe pod <pod-name> -n <namespace>
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
```

Common causes:
- PVC not bound (check `kubectl get pvc -A`)
- Node resources exhausted (check `kubectl describe node`)

## Certificate not issued

```bash
kubectl get certificate -A
kubectl describe certificate <name> -n traefik-system
kubectl get challenges -A
```

Common causes:
- Cloudflare API token expired or invalid
- DNS propagation delay (wait 5 minutes)
- Rate limit hit (check cert-manager logs)

## NFS mount failed

```bash
sudo mount -v -t nfs4 <nas-ip>:/ /mnt/test
sudo systemctl status rpcbind
```

Make sure:
- `rpcbind` is enabled
- NAS exports are configured for your subnet
- Firewall allows NFS traffic (ports 111, 2049)

## Arr services can't connect

Check credentials:
```bash
cat /var/lib/<service>-credentials
```

Re-run credential setup:
```bash
sudo rm /var/lib/arr-credentials-setup-done
sudo systemctl restart arr-credentials-setup
```

## Authentik not ready

Authentik needs PostgreSQL and Redis. Check all pods:
```bash
kubectl get pods -n authentik
kubectl logs -n authentik deploy/authentik-server
```

## Reset everything

To re-run all setup services:
```bash
sudo rm -f /var/lib/*-setup-done /var/lib/*-config-done
sudo reboot
```

## Useful commands

```bash
kubectl get pods -A                    # All pods
kubectl get svc -A                     # All services
kubectl top pods -A                    # Resource usage
kubectl logs -n <ns> deploy/<name>     # Pod logs
k9s                                    # Interactive TUI
```
