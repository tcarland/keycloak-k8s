Keycloak Kubernetes Deployment
===============================

Kustomize manifests for deploying [Keycloak](https://www.keycloak.org) on Kubernetes.

- keycloak:v26.7.1

## Directory Structure

```
keycloak-k8s/
├── env/
│   └── env.template                # Environment config template (copy to env/env)
├── base/
│   ├── kustomization.yaml
│   ├── keycloak-deployment.yaml
│   ├── keycloak-service.yaml
│   ├── keycloak-pvc.yaml
│   ├── realm.template.json          # Template for realm config
│   ├── secrets.template.env         # Template for admin credentials
│   ├── db.template.env              # Template for database credentials
├── postgres/                       # PostgreSQL deployment (applied before keycloak)
│   └── base/
│       ├── kustomization.yaml
│       ├── statefulset.yaml
│       ├── service.yaml
│       ├── postgres.template.env       # Template for postgres credentials
├── overlays/
│   ├── dev/                         # Development (embedded H2, minimal resources)
│   │   └── kustomization.yaml
│   └── prod/                        # Production (PostgreSQL, TLS via ingress)
│       ├── kustomization.yaml
│       ├── keycloak-ingress.yaml
├── kc-setup.sh                     # Generate secrets, realm config, ensure namespace
└── README.md
```

## Prerequisites

- `kubectl` configured for a cluster
- [Kustomize](https://kustomize.io/) (also built into `kubectl` via `kubectl apply -k`)
- `envsubst` (from `gettext` — `apt install gettext` / `brew install gettext`)

## Quick Start — Development

The dev overlay runs Keycloak in dev mode (`start-dev`) with the embedded H2
database and reduced resource requests. This is suitable for local clusters
(kind, minikube, k3d, etc.).

```bash
# 1. Generate configuration with development defaults (admin/admin)
./kc-setup.sh

# 2. Deploy
kubectl apply -k overlays/dev

# 3. Wait for Keycloak to start
kubectl rollout status deployment/keycloak -n keycloak

# 4. Port-forward for local access
kubectl port-forward -n keycloak svc/keycloak 8080:8080
```

Keycloak is now available at `http://localhost:8080`.

Log in with `admin` / `admin` (the defaults). The pre-configured `app` realm
includes:

| Object | Value |
|--------|-------|
| Realm | `app` |
| Admin user | `admin` (configurable) |
| Client | `app-client` / `app-client-secret` |
| Roles | `admin`, `user` |

### Get a Token

```bash
curl -X POST "http://localhost:8080/realms/app/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=app-client" \
  -d "client_secret=app-client-secret" \
  -d "username=admin&password=admin"
```

## Production Deployment

The prod overlay switches Keycloak to production mode (`start`) with PostgreSQL,
larger resource allocations, and an ingress with TLS.

### 1. Create a Production Env File

Copy the template and fill in production values:

```bash
cp env/env.template env/env
```

Edit `env/env` with secure credentials:

```bash
KEYCLOAK_ADMIN_USER=admin
KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -base64 32)
APP_CLIENT_ID=app-client
APP_CLIENT_SECRET=$(openssl rand -base64 32)
KEYCLOAK_DB_URL=jdbc:postgresql://postgres:5432/keycloak
KEYCLOAK_DB_USERNAME=keycloak
KEYCLOAK_DB_PASSWORD=$(openssl rand -base64 32)
KEYCLOAK_DB_NAME=keycloak
```

### 2. Generate Production Configuration

```bash
./kc-setup.sh env/env overlays/prod
```

This generates `overlays/prod/secrets.env`, `overlays/prod/realm.json`,
`overlays/prod/db.env`, and `postgres/postgres.env` from the templates. It also
creates the `keycloak` namespace if it does not already exist.

### 3. Deploy PostgreSQL

The prod overlay expects a PostgreSQL service named `postgres` on port 5432 in
the `keycloak` namespace. A ready-to-use PostgreSQL StatefulSet is included in
`postgres/`. The `kc-setup.sh` script generates `postgres/postgres.env` from the
same env variables, so credentials stay in sync.

```bash
kubectl apply -k postgres
kubectl rollout status statefulset/postgres -n keycloak
```

The PostgreSQL credentials come from the `KEYCLOAK_DB_USERNAME`,
`KEYCLOAK_DB_PASSWORD`, and `KEYCLOAK_DB_NAME` variables in `env/env`.

### 4. Configure Ingress

Edit `overlays/prod/keycloak-ingress.yaml`:

- Set `ingressClassName` to your ingress controller
- Set the hostname (`keycloak.example.com`)
- Configure TLS (create a `keycloak-tls` secret or use cert-manager)

### 5. Deploy

```bash
kubectl apply -k overlays/prod
kubectl rollout status deployment/keycloak -n keycloak
```

## Keycloak 26 Notes

This deployment targets Keycloak 26.7.1. The manifests account for several
changes from older Keycloak versions:

### Management Port (9000)

Keycloak 26 serves health checks and metrics on a dedicated **management port**
(9000) rather than the main HTTP port (8080). The deployment exposes port 9000
as `management`, and all probes (`liveness`, `readiness`, `startup`) target it.

| Endpoint | Port | Path |
|----------|------|------|
| Liveness | 9000 | `/health/live` |
| Readiness | 9000 | `/health/ready` |
| Startup | 9000 | `/health/started` |
| Metrics | 9000 | `/metrics` |

### Proxy Headers

Keycloak 26 removed the `--proxy` option (`edge`, `reencrypt`, etc.) in favor of
`--proxy-headers`. The prod overlay uses `--proxy-headers=forwarded` to trust
`X-Forwarded-*` headers from the ingress controller.

### HTTP in Production Mode

In production mode (`start`), Keycloak only enables HTTPS by default. To accept
HTTP traffic (with TLS termination at the ingress), the prod overlay sets
`--http-enabled=true` and `--hostname-strict-https=false`.

## Connecting Applications

### In-Cluster (Same Namespace)

```
http://keycloak:8080/realms/app
```

### In-Cluster (Different Namespace)

```
http://keycloak.keycloak.svc.cluster.local:8080/realms/app
```

### External

```
https://keycloak.example.com/realms/app
```

## Configuration

### Realm

The realm is defined in `base/realm.template.json` and imported on first startup
via `--import-realm`. The template uses `$VARIABLE` placeholders that are
substituted by `kc-setup.sh`.

To customize the realm (add roles, users, clients, identity providers, etc.),
edit `base/realm.template.json` and re-run `kc-setup.sh`, or edit the generated
`realm.json` directly.

After changing the realm secret, restart Keycloak:

```bash
kubectl rollout restart deployment/keycloak -n keycloak
```

> **Note:** Realm import only happens on first startup. To re-import, delete the
> `keycloak-data` PVC or use the Keycloak admin API/CLI to apply changes.

### Admin Credentials

Admin credentials are stored in the `keycloak-admin` secret, generated from
`secrets.env`. Change them by re-running `kc-setup.sh` with new values and
re-applying.

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
" `KEYCLOAK_REALM_NAME` | `app` | Name of the application realm to configure |
| `KEYCLOAK_ADMIN_USER` | `admin` | Master realm admin username |
| `KEYCLOAK_ADMIN_PASSWORD` | `admin` | Master realm admin password |
| `APP_CLIENT_ID` | `app-client` | OIDC client ID for the imported realm |
| `APP_CLIENT_SECRET` | `app-client-secret` | Secret for the OIDC client |
| `KEYCLOAK_DB_URL` | `jdbc:postgresql://postgres:5432/keycloak` | Database JDBC URL (prod only) |
| `KEYCLOAK_DB_USERNAME` | `keycloak` | Database username (prod only) |
| `KEYCLOAK_DB_PASSWORD` | `CHANGE_ME_IN_PRODUCTION` | Database password (prod only) |
| `KEYCLOAK_DB_NAME` | `keycloak` | PostgreSQL database name (prod only) |

See `env/env.template` for a ready-to-copy starting point.

## Troubleshooting

### Keycloak not starting

```bash
kubectl logs -n keycloak deployment/keycloak
```

Common issues:
- **Secret not found** — run `./kc-setup.sh` first
- **Database connection failed (prod)** — verify PostgreSQL is running and
  `keycloak-db-credentials` is correct
- **Out of memory** — increase resource limits in the overlay

### Realm not imported

```bash
# Verify the secret exists
kubectl get secret keycloak-realm -n keycloak

# Inspect the realm JSON
kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 -d | jq .

# Restart to re-import (only works if the realm doesn't already exist)
kubectl rollout restart deployment/keycloak -n keycloak
```

### Health checks failing

Health endpoints are on port 9000, not 8080. Verify:

```bash
kubectl exec -n keycloak deployment/keycloak -- \
  curl -s http://localhost:9000/health/ready
```

### Build and validate manifests locally

```bash
# Render the dev overlay
kubectl kustomize overlays/dev

# Render the prod overlay
kubectl kustomize overlays/prod
```


## TLS Configuration (Future)

This section documents TLS configuration options for Keycloak within Kubernetes.
This is not currently implemented but may be required for:

- Security policies requiring encryption for all in-cluster traffic
- Service mesh integration (Istio, Linkerd) with strict mTLS
- Compliance requirements (PCI-DSS, HIPAA, etc.)
- Zero-trust network architectures

### TLS Termination Options

| Approach | Where TLS Terminates | Use Case |
|----------|---------------------|----------|
| **Ingress** | At ingress controller | External traffic only; in-cluster is HTTP |
| **Pod-level** | At Keycloak container | End-to-end encryption; required for strict mTLS |
| **Service Mesh** | Sidecar proxy | Transparent mTLS; no app changes needed |

#### Certificate Requirements

- TLS certificate and private key
- Certificate must include SANs for:
  - Service DNS: `keycloak.scire.svc.cluster.local`
  - Service name: `keycloak`
  - Pod DNS (if using headless service)

#### Generate Certificates (cert-manager)

```yaml
# keycloak-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: scire
spec:
  secretName: keycloak-tls
  duration: 8760h  # 1 year
  renewBefore: 720h  # 30 days
  issuerRef:
    name: cluster-ca-issuer  # Your CA issuer
    kind: ClusterIssuer
  commonName: keycloak.scire.svc.cluster.local
  dnsNames:
    - keycloak
    - keycloak.scire
    - keycloak.scire.svc
    - keycloak.scire.svc.cluster.local
```

#### Deployment Changes

Patch the deployment to enable HTTPS:

```yaml
# overlays/prod/keycloak-tls-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  template:
    spec:
      containers:
        - name: keycloak
          args:
            - start
            - --import-realm
            - --https-port=8443
            - --https-certificate-file=/etc/keycloak/tls/tls.crt
            - --https-certificate-key-file=/etc/keycloak/tls/tls.key
            - --hostname-strict=false
          ports:
            - containerPort: 8443
              name: https
              protocol: TCP
          volumeMounts:
            - name: tls-certs
              mountPath: /etc/keycloak/tls
              readOnly: true
          livenessProbe:
            httpGet:
              path: /health/live
              port: https
              scheme: HTTPS
          readinessProbe:
            httpGet:
              path: /health/ready
              port: https
              scheme: HTTPS
      volumes:
        - name: tls-certs
          secret:
            secretName: keycloak-tls
```

#### Service Changes

```yaml
# Update service to expose HTTPS
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  ports:
    - port: 8443
      targetPort: https
      protocol: TCP
      name: https
```

#### Update Scire Configuration

When Keycloak uses TLS, update Scire to use HTTPS and trust the CA:

```yaml
# In scire configmap
SCIRE_OIDC_URL: https://keycloak.scire.svc.cluster.local:8443/realms/scire
SCIRE_OIDC_TLS_VERIFY: required

# Mount CA certificate
volumes:
  - name: keycloak-ca
    configMap:
      name: keycloak-ca
volumeMounts:
  - name: keycloak-ca
    mountPath: /etc/ssl/certs/keycloak-ca.crt
    subPath: ca.crt
```

Or disable verification (development only):
```yaml
SCIRE_OIDC_TLS_VERIFY: none
```

### Realm SSL Configuration

Regardless of transport encryption, configure the realm's SSL requirements:

```json
{
  "realm": "scire",
  "sslRequired": "external",  // or "all" for strictest
  ...
}
```

| Value | Behavior |
|-------|----------|
| `none` | SSL not required (development only) |
| `external` | SSL required for external requests; internal OK |
| `all` | SSL required for all requests |

### Implementation Checklist

When implementing TLS for Keycloak:

- [ ] Choose TLS termination approach based on requirements
- [ ] Set up certificate management (cert-manager recommended)
- [ ] Generate certificates with correct SANs
- [ ] Update deployment with TLS configuration
- [ ] Update service to expose HTTPS port
- [ ] Update Scire OIDC configuration
- [ ] Distribute CA certificate to clients (if using internal CA)
- [ ] Update realm `sslRequired` setting
- [ ] Test token acquisition over HTTPS
- [ ] Update health check endpoints to use HTTPS
- [ ] Document certificate rotation procedures
