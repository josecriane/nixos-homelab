{
  config,
  lib,
  pkgs,
  serverConfig,
  secretsPath,
  ...
}:

let
  # Certificate backup configuration
  certBackupDir = "/var/lib/cert-backup";
  nasBackupDir = "/mnt/nas1/backups";
  certName = "wildcard-${serverConfig.subdomain}-${serverConfig.domain}";
  secretName = "${certName}-tls";

  # Option to restore from backup (defaults to true if backup exists)
  restoreFromBackup = serverConfig.certificates.restoreFromBackup or true;

  # NAS backup available if NFS is enabled (mount managed by nfs-storage.nix)
  nasConfig = serverConfig.nas.nas1 or null;
  nasEnabled = nasConfig != null && (nasConfig.enabled or false);
in
{
  # Secret for Cloudflare API token
  age.secrets.cloudflare-api-token = {
    file = "${secretsPath}/cloudflare-api-token.age";
  };

  # Service to install and configure cert-manager automatically
  systemd.services.cert-manager-setup = {
    description = "Setup cert-manager with Cloudflare DNS-01 and wildcard certificate";
    after = [
      "k3s.service"
      "traefik-setup.service"
    ];
    wants = [
      "k3s.service"
      "traefik-setup.service"
    ];
    # TIER 1: Infrastructure
    wantedBy = [ "k3s-infrastructure.target" ];
    before = [ "k3s-infrastructure.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cert-manager-setup" ''
        set -e

        # Marker file to run only once
        MARKER_FILE="/var/lib/cert-manager-setup-done"
        CERT_BACKUP_DIR="${certBackupDir}"
        SECRET_NAME="${secretName}"
        RESTORE_FROM_BACKUP="${if restoreFromBackup then "true" else "false"}"

        # NAS backup configuration (/mnt/nas1 mounted by nfs-storage.nix)
        NAS_ENABLED="${if nasEnabled then "true" else "false"}"
        NAS_BACKUP_DIR="${nasBackupDir}"

        if [ -f "$MARKER_FILE" ]; then
          echo "cert-manager already installed (marker file exists)"
          exit 0
        fi

        # Create local backup directory
        mkdir -p "$CERT_BACKUP_DIR"

        # Try to recover backup from NAS at startup
        if [ "$RESTORE_FROM_BACKUP" = "true" ] && [ "$NAS_ENABLED" = "true" ]; then
          echo "Looking for certificate backup on NAS..."
          NAS_BACKUP_FILE="$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
          if [ -f "$NAS_BACKUP_FILE" ]; then
            echo "Backup found on NAS, copying to local..."
            cp "$NAS_BACKUP_FILE" "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
            chmod 600 "$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
            echo "Backup copied from NAS"
          else
            echo "No backup on NAS ($NAS_BACKUP_FILE)"
          fi
        fi

        echo "Waiting for K3s and Traefik to be fully ready..."
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        # Wait for k3s to be ready (max 5 minutes)
        for i in $(seq 1 60); do
          if ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; then
            echo "K3s is ready"
            break
          fi
          echo "Waiting for K3s... ($i/60)"
          sleep 5
        done

        # Verify that k3s is actually ready
        if ! ${pkgs.kubectl}/bin/kubectl get nodes &>/dev/null; then
          echo "ERROR: K3s not available after 5 minutes"
          exit 1
        fi

        echo "Waiting for node to be Ready (Flannel CNI)..."
        if ! ${pkgs.kubectl}/bin/kubectl wait --for=condition=Ready node --all --timeout=300s; then
          echo "ERROR: Node did not reach Ready state in 5 minutes"
          exit 1
        fi
        echo "K3s node is Ready (Flannel CNI initialized)"

        # Wait for Traefik to be ready (max 3 minutes)
        echo "Waiting for Traefik to be ready..."
        for i in $(seq 1 36); do
          if ${pkgs.kubectl}/bin/kubectl get namespace traefik-system &>/dev/null && \
             ${pkgs.kubectl}/bin/kubectl get svc -n traefik-system traefik &>/dev/null; then
            echo "Traefik is ready"
            break
          fi
          echo "Waiting for Traefik... ($i/36)"
          sleep 5
        done

        # Verify that Traefik is actually ready
        if ! ${pkgs.kubectl}/bin/kubectl get svc -n traefik-system traefik &>/dev/null; then
          echo "ERROR: Traefik not available after 3 minutes"
          exit 1
        fi

        echo "Installing cert-manager with Helm..."

        # Add cert-manager repository
        ${pkgs.kubernetes-helm}/bin/helm repo add jetstack https://charts.jetstack.io || true
        ${pkgs.kubernetes-helm}/bin/helm repo update

        # Create namespace
        ${pkgs.kubectl}/bin/kubectl create namespace cert-manager --dry-run=client -o yaml | \
          ${pkgs.kubectl}/bin/kubectl apply -f -

        # Install or upgrade cert-manager with CRDs
        ${pkgs.kubernetes-helm}/bin/helm upgrade --install cert-manager jetstack/cert-manager \
          --namespace cert-manager \
          --set crds.enabled=true \
          --set crds.keep=true \
          --wait \
          --timeout 5m

        echo "Waiting for cert-manager pods to be ready..."
        ${pkgs.kubectl}/bin/kubectl wait --namespace cert-manager \
          --for=condition=ready pod \
          --selector=app.kubernetes.io/instance=cert-manager \
          --timeout=300s

        echo "Waiting for cert-manager CRDs to be registered..."
        ${pkgs.kubectl}/bin/kubectl wait --for=condition=Established \
          --timeout=60s \
          crd/certificates.cert-manager.io \
          crd/certificaterequests.cert-manager.io \
          crd/issuers.cert-manager.io \
          crd/clusterissuers.cert-manager.io

        echo "Reading Cloudflare API token from agenix..."
        if [ ! -f "${config.age.secrets.cloudflare-api-token.path}" ]; then
          echo "ERROR: Cloudflare secret not found at ${config.age.secrets.cloudflare-api-token.path}"
          echo "Make sure cloudflare-api-token.age is encrypted and configured in agenix"
          exit 1
        fi

        CLOUDFLARE_TOKEN=$(cat ${config.age.secrets.cloudflare-api-token.path})

        if [ -z "$CLOUDFLARE_TOKEN" ]; then
          echo "ERROR: Cloudflare token is empty"
          exit 1
        fi

        echo "Creating Cloudflare secret in cert-manager namespace..."
        ${pkgs.kubectl}/bin/kubectl create secret generic cloudflare-api-token-secret \
          --namespace cert-manager \
          --from-literal=api-token="$CLOUDFLARE_TOKEN" \
          --dry-run=client -o yaml | ${pkgs.kubectl}/bin/kubectl apply -f -

        echo "Creating ClusterIssuer for Let's Encrypt with Cloudflare DNS-01..."
        cat <<EOF | ${pkgs.kubectl}/bin/kubectl apply -f -
        apiVersion: cert-manager.io/v1
        kind: ClusterIssuer
        metadata:
          name: letsencrypt-prod
        spec:
          acme:
            server: https://acme-v02.api.letsencrypt.org/directory
            email: ${serverConfig.acmeEmail}
            privateKeySecretRef:
              name: letsencrypt-prod-key
            solvers:
            - dns01:
                cloudflare:
                  apiTokenSecretRef:
                    name: cloudflare-api-token-secret
                    key: api-token
        EOF

        echo "Waiting for ClusterIssuer to be ready..."
        sleep 5

        # Verify the ClusterIssuer was created
        if ! ${pkgs.kubectl}/bin/kubectl get clusterissuer letsencrypt-prod &>/dev/null; then
          echo "ERROR: Could not create ClusterIssuer"
          exit 1
        fi

        # ============================================
        # CERTIFICATE BACKUP/RESTORE
        # ============================================
        BACKUP_FILE="$CERT_BACKUP_DIR/$SECRET_NAME.yaml"
        CERT_RESTORED=false

        # Helper: save backup locally and to NAS
        save_backup() {
          echo "Saving certificate backup..."
          ${pkgs.kubectl}/bin/kubectl get secret -n traefik-system $SECRET_NAME -o yaml > "$BACKUP_FILE"
          chmod 600 "$BACKUP_FILE"
          echo "Local backup saved at $BACKUP_FILE"

          if [ "$NAS_ENABLED" = "true" ]; then
            mkdir -p "$NAS_BACKUP_DIR"
            cp "$BACKUP_FILE" "$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
            chmod 600 "$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
            echo "Backup saved to NAS: $NAS_BACKUP_DIR/$SECRET_NAME.yaml"
          fi
        }

        # Helper: restore from local backup
        restore_backup() {
          if [ ! -f "$BACKUP_FILE" ]; then
            return 1
          fi
          echo "Restoring certificate from backup: $BACKUP_FILE"
          if ${pkgs.kubectl}/bin/kubectl apply -f "$BACKUP_FILE"; then
            echo "Certificate restored successfully"
            return 0
          fi
          return 1
        }

        # Step 1: Try to restore from backup
        if [ -f "$BACKUP_FILE" ] && [ "$RESTORE_FROM_BACKUP" = "true" ]; then
          if restore_backup; then
            CERT_RESTORED=true
          fi
        fi

        # Step 2: Create Certificate resource (always needed for cert-manager to manage renewals)
        echo "Creating Certificate resource..."
        cat <<EOF | ${pkgs.kubectl}/bin/kubectl apply -f -
        apiVersion: cert-manager.io/v1
        kind: Certificate
        metadata:
          name: wildcard-${serverConfig.subdomain}-${serverConfig.domain}
          namespace: traefik-system
        spec:
          secretName: $SECRET_NAME
          issuerRef:
            name: letsencrypt-prod
            kind: ClusterIssuer
          dnsNames:
          - "*.${serverConfig.subdomain}.${serverConfig.domain}"
          - "${serverConfig.subdomain}.${serverConfig.domain}"
        EOF

        # Step 3: If backup was not restored, wait for ACME to issue the cert
        if [ "$CERT_RESTORED" = "false" ]; then
          echo "No backup, waiting for Let's Encrypt to issue certificate..."

          for i in $(seq 1 60); do
            CERT_STATUS=$(${pkgs.kubectl}/bin/kubectl get certificate -n traefik-system wildcard-${serverConfig.subdomain}-${serverConfig.domain} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")

            if [ "$CERT_STATUS" = "True" ]; then
              echo "Certificate issued successfully"
              save_backup
              CERT_RESTORED=true
              break
            fi

            # Detect rate limit and abort the loop early
            ORDER_STATE=$(${pkgs.kubectl}/bin/kubectl get orders -n traefik-system -o jsonpath='{.items[0].status.state}' 2>/dev/null || true)
            if [ "$ORDER_STATE" = "errored" ]; then
              ORDER_REASON=$(${pkgs.kubectl}/bin/kubectl get orders -n traefik-system -o jsonpath='{.items[0].status.reason}' 2>/dev/null || true)
              echo "ACME order error: $ORDER_REASON"

              if echo "$ORDER_REASON" | grep -q "rateLimited"; then
                echo "Rate limit detected, trying to restore from backup..."

                # Try backup from NAS if no local backup
                if [ ! -f "$BACKUP_FILE" ] && [ "$NAS_ENABLED" = "true" ]; then
                  echo "Looking for backup on NAS..."
                  NAS_BACKUP_FILE="$NAS_BACKUP_DIR/$SECRET_NAME.yaml"
                  if [ -f "$NAS_BACKUP_FILE" ]; then
                    cp "$NAS_BACKUP_FILE" "$BACKUP_FILE"
                    chmod 600 "$BACKUP_FILE"
                    echo "Backup copied from NAS"
                  fi
                fi

                # Restore backup if it exists
                if restore_backup; then
                  CERT_RESTORED=true
                else
                  echo "WARN: No backup available, services will use self-signed cert until rate limit expires"
                fi
                break
              fi
            fi

            echo "Waiting for certificate issuance... ($i/60) Status: $CERT_STATUS"
            sleep 5
          done
        fi

        # Final status
        FINAL_STATUS="Unknown"
        if [ "$CERT_RESTORED" = "true" ]; then
          # Verify the secret exists
          if ${pkgs.kubectl}/bin/kubectl get secret -n traefik-system $SECRET_NAME &>/dev/null; then
            FINAL_STATUS="True"
          fi
        else
          FINAL_STATUS=$(${pkgs.kubectl}/bin/kubectl get certificate -n traefik-system wildcard-${serverConfig.subdomain}-${serverConfig.domain} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        fi

        # Save backup if we have a new cert and didn't have a backup
        if [ "$FINAL_STATUS" = "True" ] && [ ! -f "$BACKUP_FILE" ]; then
          save_backup
        fi

        echo ""
        echo "========================================="
        echo "cert-manager installed and configured successfully"
        echo "ClusterIssuer: letsencrypt-prod"
        echo "Wildcard certificate: *.${serverConfig.subdomain}.${serverConfig.domain}"
        echo "Secret: $SECRET_NAME"
        echo "Status: $FINAL_STATUS ($([ "$CERT_RESTORED" = "true" ] && echo "from backup" || echo "ACME"))"
        echo "========================================="
        echo ""

        # Create marker file
        touch "$MARKER_FILE"
        echo "Installation completed"
      '';
    };
  };
}
