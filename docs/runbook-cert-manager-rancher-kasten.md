# Runbook: cert-manager → Rancher (vcluster) → Kasten

This runbook installs, in order, the `*.ct.local` PKI (cert-manager), Rancher in the `rancher-vcluster` add-on using that certificate, Rancher's OIDC provider, and Kasten on the **Harvester** cluster logging in through Rancher.

Every step ends with a **Validate** block. Don't continue until it shows the expected result.

| Phase | Cluster | What |
|---|---|---|
| 0 | your WSL | tools, kubeconfig switching, IP and ingress check, clean-up of earlier attempts |
| 1 | Harvester | cert-manager, root CA, `*.ct.local` certificates, CA publishing |
| 2 | Harvester | CoreDNS entries so pods can resolve `rancher.ct.local` |
| 3 | Harvester, then Rancher | Rancher add-on on the new certificate |
| 4 | Rancher | OIDC provider and Kasten OIDC client |
| 5 | Rancher, then Harvester | Kasten OIDC secret, Kasten install, first login |

Run everything from the repo root in WSL (`/mnt/c/Users/Samuel/git/notion`) on branch `claude/cert-manager-rancher-oidc-kasten`.

**Status:** tested end to end in the ct.local lab in November 2026: Rancher on the ct.local certificate, and Kasten login through Rancher's OIDC provider working.

| Component | Version in the test | Where |
|---|---|---|
| Harvester | built-in ingress controller is **Traefik** (`rancher-expose` class `traefik`) on VIP 192.168.1.60 | host cluster |
| cert-manager | v1.18.2 | Harvester, namespace `cert-manager` |
| vcluster add-on | chart v0.30.0, k3s v1.35.4 | Harvester, namespace `rancher-vcluster` |
| Rancher | v2.14.0 (community chart) | inside the vcluster |
| Kasten | chart 9.0.8 | Harvester, namespace `kasten-io` |

Read **Lessons from the first test run** at the end before starting: it lists the mistakes that cost the most time.

---

## 0. Preparation

### 0.1 Tools and repo

```bash
sudo dnf install -y jq openssl
kubectl version --client
git switch claude/cert-manager-rancher-oidc-kasten && git pull
git config core.autocrlf input
sed -i 's/\r$//' scripts/*.sh            # Windows checkouts add CR characters to scripts
```

**Validate:** `git log --oneline -1` shows the latest branch commit, and `head -1 scripts/publish-ct-local-ca.sh | od -c | head -1` shows no `\r`.

### 0.2 One kubeconfig file per cluster, switched with a command

Keep each cluster in its own file and switch with `use-harvester` / `use-rancher`, instead of putting `--context` in every command. The prompt shows which cluster is active, so a command can't silently land in the wrong one.

**Harvester kubeconfig.** Copy RKE2's admin kubeconfig from a Harvester **management** node and point it at that node's IP:

```bash
mkdir -p ~/.kube && chmod 700 ~/.kube
NODE_IP=<harvester-management-node-ip>
ssh rancher@$NODE_IP 'sudo cat /etc/rancher/rke2/rke2.yaml' > ~/.kube/harvester.yaml
sed -i "s#https://127.0.0.1:6443#https://$NODE_IP:6443#" ~/.kube/harvester.yaml
chmod 600 ~/.kube/harvester.yaml
```

This is a full cluster-admin credential with no expiry. Keep it in `~/.kube`, never in the repo, and delete it when testing is done. If kubectl later reports `x509: certificate is valid for ..., not <ip>`, use a different management node's IP.

**Rancher kubeconfig.** For now, copy the Rancher kubeconfig you already use (the one behind your earlier `rancher` context) to `~/.kube/rancher.yaml`. Re-download it in step 3.4, because the certificate and CA change in phase 3.

```bash
cp <your-current-rancher-kubeconfig> ~/.kube/rancher.yaml && chmod 600 ~/.kube/rancher.yaml
```

**Switch commands.** Add to `~/.bashrc`, then run `source ~/.bashrc`:

```bash
use-harvester() { export KUBECONFIG=~/.kube/harvester.yaml; KCLUSTER=HARVESTER; }
use-rancher()   { export KUBECONFIG=~/.kube/rancher.yaml;   KCLUSTER=RANCHER; }
whereami() {
  echo "KUBECONFIG=$KUBECONFIG"
  if kubectl get settings.harvesterhci.io server-version >/dev/null 2>&1; then
    echo "-> HARVESTER $(kubectl get settings.harvesterhci.io server-version -o jsonpath='{.value}')"
  elif kubectl get settings.management.cattle.io server-version >/dev/null 2>&1; then
    echo "-> RANCHER $(kubectl get settings.management.cattle.io server-version -o jsonpath='{.value}')"
  else echo "-> UNKNOWN cluster - stop"; fi
}
PS1='[${KCLUSTER:-no-cluster}] \w\$ '
```

**Validate:**
```bash
use-harvester
whereami        # -> HARVESTER v1.x
```

From here, each block starts with `use-harvester` or `use-rancher`. Run `whereami` whenever you're unsure.

### 0.3 Decide Kasten's ingress class and find the IPs

Kasten must use the same ingress controller as Harvester's own UI. Which one that is depends on the Harvester release: newer ones use Traefik, older ones rke2-ingress-nginx.

```bash
use-harvester
kubectl get ingress -A
```

Look at the `CLASS` and `ADDRESS` of `cattle-system/rancher-expose` (Harvester's own UI):

| `rancher-expose` CLASS | `ingress.class` for Kasten | `kasten.ct.local` must resolve to |
|---|---|---|
| `traefik` (your lab, Harvester at 192.168.1.60) | `traefik` (as committed) | its ADDRESS, the same IP as `rancher.ct.local` |
| `nginx` | `nginx` | its ADDRESS |

Rancher and Kasten then share port 443 on one IP, routed by hostname.

Write down the two IPs. In the tested lab both are `192.168.1.60`, because Rancher and Kasten share Harvester's Traefik:
- **`RANCHER_IP`:** the ADDRESS of the `rancher-x-cattle-system-x-rancher-vcluster` ingress.
- **`KASTEN_IP`:** the ADDRESS of `rancher-expose` (Kasten's ingress will get the same one).

If `rancher-expose` uses `nginx` on a different Harvester, step 5.2 says how to override the class.

### 0.4 Clean up earlier Kasten attempts

Earlier attempts left Kasten in the vcluster and conflicting objects in `kasten-io`. Remove them **before** phase 1, because step 1.3 creates certificates inside `kasten-io`.

```bash
use-rancher
whereami                                            # -> RANCHER (if not, fix ~/.kube/rancher.yaml first)
kubectl -n kube-system get helmchart k10 && kubectl -n kube-system delete helmchart k10
kubectl get ns kasten-io && kubectl delete ns kasten-io

use-harvester
kubectl -n kube-system get helmchart k10 && kubectl -n kube-system delete helmchart k10
kubectl get ns kasten-io && kubectl delete ns kasten-io
```

Nothing from those attempts is worth keeping: no Kasten backups exist yet. Each `get` that returns `NotFound` means there's nothing to clean.

**Validate:** in both clusters, `kubectl get ns kasten-io` returns `NotFound` (namespace deletion can take a minute).

---

## 1. cert-manager and the ct.local PKI (Harvester)

### 1.1 Install cert-manager

```bash
use-harvester
kubectl apply -f 11-cert-manager/cert-manager-helmchart.yaml
```

**Validate:**
```bash
kubectl -n kube-system logs job/helm-install-cert-manager | tail -3     # STATUS: deployed
kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
kubectl -n cert-manager get pods                                        # 3 pods Running
kubectl get crd certificates.cert-manager.io clusterissuers.cert-manager.io
```

### 1.2 Root CA and issuer

```bash
kubectl apply -f 11-cert-manager/ct-local-ca.yaml
```

**Validate:**
```bash
kubectl wait --for=condition=Ready clusterissuer/ct-local-ca --timeout=120s
kubectl -n cert-manager get certificate ct-local-root-ca                # READY True
kubectl -n cert-manager get secret ct-local-root-ca -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -enddate -ext basicConstraints
# subject=O = ct.local, CN = ct.local Root CA ; notAfter about 10 years out ; CA:TRUE
```

### 1.3 Namespaces and `*.ct.local` certificates

The add-on file also declares `rancher-vcluster`; creating it here first is harmless.

```bash
kubectl create namespace rancher-vcluster --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace kasten-io        --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 11-cert-manager/wildcard-ct-local-certificates.yaml
```

**Validate:**
```bash
kubectl get certificate -A -l app.kubernetes.io/part-of=ct-local-pki    # both READY True
for ns in rancher-vcluster kasten-io; do
  kubectl -n $ns get secret wildcard-ct-local-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -issuer -enddate -ext subjectAltName
done
# issuer = ct.local Root CA ; DNS:*.ct.local, DNS:ct.local ; notAfter about 10 years out
```

### 1.4 Publish the CA (Rancher `tls-ca`, Kasten trust bundle)

```bash
./scripts/publish-ct-local-ca.sh
```

**Validate:**
```bash
kubectl -n rancher-vcluster get secret tls-ca -o jsonpath='{.data.cacerts\.pem}' | base64 -d | openssl x509 -noout -subject
kubectl -n kasten-io get configmap custom-ca-bundle-store -o jsonpath='{.data.custom-ca-bundle\.pem}' | openssl x509 -noout -subject
# both: subject=O = ct.local, CN = ct.local Root CA
ls -l ct-local-root-ca.crt
```

**Trust it on your workstation:** in Windows, double-click `ct-local-root-ca.crt` → Install Certificate → Local Machine → *Trusted Root Certification Authorities*. In WSL Fedora:

```bash
sudo cp ct-local-root-ca.crt /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust
```

---

## 2. DNS

### 2.1 Pods on Harvester resolve `rancher.ct.local`

Kasten's `auth-svc` calls `https://rancher.ct.local/oidc` from inside Harvester. `06-rancher/vcluster-addon/coredns.yaml` maps both names to `192.168.1.60`. If `RANCHER_IP` from step 0.3 differs, change the `rancher.ct.local` line in that file first.

Applying it replaces Harvester's `rke2-coredns` HelmChartConfig. Check what's there before overwriting:

```bash
use-harvester
kubectl -n kube-system get helmchartconfig rke2-coredns -o jsonpath='{.spec.valuesContent}' ; echo
```

If that prints settings other than your own `zoneFiles`/`extraConfig`, merge them into the file before applying.

```bash
kubectl apply -f 06-rancher/vcluster-addon/coredns.yaml
```

**Validate:**
```bash
kubectl -n kube-system rollout status deploy/rke2-coredns-rke2-coredns --timeout=180s
kubectl run dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup rancher.ct.local
# Address: <RANCHER_IP>
```

### 2.2 Your workstation resolves both names

Add to `C:\Windows\System32\drivers\etc\hosts` (as Administrator). WSL copies it into `/etc/hosts` on its next restart.

```
<RANCHER_IP>   rancher.ct.local
<KASTEN_IP>    kasten.ct.local
```

**Validate (WSL):** `getent hosts rancher.ct.local kasten.ct.local` shows both IPs. Restart WSL (`wsl --shutdown` from Windows) if they don't appear.

---

## 3. Rancher on the ct.local certificate

### 3.1 Apply the add-on without committing the password

The password is filled in through a pipe, so the repo file keeps `<CHANGE_ME>`. Avoid `|`, `&` and `\` in the password, because `sed` treats them specially.

On an existing Rancher, `bootstrapPassword` is ignored: it only applies to a first install.

```bash
use-harvester
read -rsp 'Rancher bootstrap password: ' RB; echo
sed "s|bootstrapPassword: \"<CHANGE_ME>\"|bootstrapPassword: \"$RB\"|" 06-rancher/vcluster-addon/rancher-addon.yaml | kubectl apply -f -
unset RB
```

**Validate (Harvester side):**
```bash
# Use the full name: on Harvester, plain "addon" resolves to RKE2's addons.k3s.cattle.io.
kubectl -n rancher-vcluster get addons.harvesterhci.io rancher-vcluster -o jsonpath='{.spec.enabled} {.status.status}{"\n"}'
# The new values must be in the cluster (expect 3 matches: fromHost, tls.source: secret, privateCA):
kubectl -n rancher-vcluster get addons.harvesterhci.io rancher-vcluster -o jsonpath='{.spec.valuesContent}' \
  | grep -cE 'fromHost:|ingress.tls.source: secret|privateCA: "true"'
# On a first apply or a values change, a NEW install job runs (AGE in minutes). Re-applying the same values
# starts no job; old pods are then expected, and step 3.2 is the real check:
kubectl -n rancher-vcluster get pods | grep -E 'helm-install-rancher|rancher-vcluster-0'
kubectl -n rancher-vcluster get pods                 # rancher-vcluster-0 Running; rancher-*-x-cattle-system-x-* pods Running
kubectl -n rancher-vcluster logs statefulset/rancher-vcluster -c syncer --tail=50 | grep -i -E 'secret|error' | tail -10
```

### 3.2 Rancher serves the ct.local certificate

The add-on upgrade restarts the vcluster, and Rancher then upgrades inside it. Allow 5–10 minutes.

**Validate (WSL):**
```bash
curl -sS --cacert ct-local-root-ca.crt https://rancher.ct.local/ping ; echo        # pong
echo | openssl s_client -connect rancher.ct.local:443 -servername rancher.ct.local -CAfile ct-local-root-ca.crt 2>/dev/null \
  | grep -E 'issuer=|Verify return code'
# issuer=O = ct.local, CN = ct.local Root CA ; Verify return code: 0 (ok)
```

Then open `https://rancher.ct.local` in a browser: no certificate warning, and the padlock shows `ct.local Root CA`.

### 3.3 Optional: remove the old cert-manager inside the vcluster

The old add-on version installed cert-manager v1.5.1 inside the vcluster. Rancher no longer needs it. Do this after 3.4, once you have the Rancher kubeconfig:

```bash
use-rancher
kubectl -n kube-system get helmchart cert-manager && kubectl -n kube-system delete helmchart cert-manager
```

### 3.4 Download Rancher's kubeconfig

In Rancher: **☰ → Cluster Management → `local` → ⋮ → Download KubeConfig**. Save it as `~/.kube/rancher.yaml` in WSL, then `chmod 600 ~/.kube/rancher.yaml`.

**Validate:**
```bash
use-rancher
whereami                                                        # -> RANCHER v2.14.x
kubectl -n cattle-system get secret tls-rancher-ingress tls-ca   # both exist (synced from Harvester)
kubectl get setting server-url -o jsonpath='{.value}{"\n"}'      # https://rancher.ct.local
```

If `server-url` isn't exactly `https://rancher.ct.local`, fix it in Rancher (Global Settings → server-url) before phase 4. The OIDC issuer is built from it.

---

## 4. Rancher OIDC provider and Kasten client (Rancher)

### 4.1 Enable the OIDC provider

```bash
use-rancher
kubectl apply -f 09-rancher-sso/oidc-provider-feature.yaml
kubectl -n cattle-system rollout restart deploy/rancher          # not a dynamic feature
kubectl -n cattle-system rollout status deploy/rancher --timeout=600s
```

**Validate (WSL):**
```bash
kubectl get feature oidc-provider -o jsonpath='{.spec.value} {.status}{"\n"}'
curl -sS --cacert ct-local-root-ca.crt https://rancher.ct.local/oidc/.well-known/openid-configuration \
  | jq '{issuer, scopes_supported, code_challenge_methods_supported}'
# issuer: https://rancher.ct.local/oidc ; scopes include openid, profile ; methods: ["S256"]
```

### 4.2 Register Kasten as an OIDC client

```bash
kubectl apply -f 09-rancher-sso/oidc-client-kasten.yaml
```

**Validate:**
```bash
kubectl get oidcclient kasten                                   # CLIENT ID column filled
ID=$(kubectl get oidcclient kasten -o jsonpath='{.status.clientID}')
kubectl -n cattle-oidc-client-secrets get secret "$ID" -o json | jq '.data | keys'   # ["client-secret-..."]
kubectl get oidcclient kasten -o jsonpath='{.spec.redirectURIs}{"\n"}'
# ["https://kasten.ct.local/k10/auth-svc/v0/oidc/redirect"]
```

### 4.3 Your Rancher user ID (Kasten admin)

Kasten receives the Rancher user ID as the `sub` claim and prefixes it with `rancher:`.

```bash
kubectl get users.management.cattle.io -o custom-columns=ID:.metadata.name,NAME:.displayName,USERNAME:.username,PRINCIPALS:.principalIds
```

Note the `ID` of the account that should administer Kasten (`u-xxxxx` for Entra ID users, `user-xxxxx` for local ones). Log in to Rancher once with that account first, so the user object exists.

---

## 5. Kasten (Harvester)

### 5.1 Copy the OIDC client credentials from Rancher to Harvester

Read from Rancher into a git-ignored file (`*.secret.yaml`), apply it on Harvester, then delete the file.

```bash
use-rancher
ID=$(kubectl get oidcclient kasten -o jsonpath='{.status.clientID}')
KEY=$(kubectl -n cattle-oidc-client-secrets get secret "$ID" -o json | jq -r '.data | keys[] | select(startswith("client-secret"))' | head -1)
SECRET=$(kubectl -n cattle-oidc-client-secrets get secret "$ID" -o jsonpath="{.data.$KEY}" | base64 -d)
kubectl create secret generic kasten-oidc-client -n kasten-io \
  --from-literal=client-id="$ID" --from-literal=client-secret="$SECRET" \
  --dry-run=client -o yaml > kasten-oidc-client.secret.yaml
unset SECRET

use-harvester
kubectl apply -f kasten-oidc-client.secret.yaml && rm kasten-oidc-client.secret.yaml
```

**Validate:**
```bash
kubectl -n kasten-io describe secret kasten-oidc-client          # Data: client-id, client-secret
kubectl -n kasten-io get secret kasten-oidc-client -o jsonpath='{.data.client-id}' | base64 -d ; echo   # = $ID
```

### 5.2 Install Kasten

Fill in the admin user through the pipe, so the repo file keeps `<CHANGE_ME>`. The file already has `class: traefik`, which matches this Harvester (step 0.3). Only on a Harvester whose `rancher-expose` uses `nginx`, add `-e "s|class: traefik|class: nginx|"` to the `sed`.

```bash
use-harvester
whereami                                             # -> HARVESTER  (Kasten must NOT go into the vcluster)
ADMIN=<rancher-user-id-from-4.3>                     # e.g. u-abc12
sed -e "s|rancher:<CHANGE_ME>|rancher:$ADMIN|" 05-kasten/k10-helmchart.yaml | kubectl apply -f -
```

**Validate:**
```bash
kubectl -n kube-system get helmchart k10 -o jsonpath='{.spec.valuesContent}' | grep -E 'clientSecretName|class:|rancher:'
# clientSecretName: kasten-oidc-client ; class: traefik ; - "rancher:<ADMIN>"
kubectl -n kube-system logs -f job/helm-install-k10 | tail -5       # STATUS: deployed
kubectl -n kasten-io get pods                                        # all Running, auth-svc 1/1
kubectl -n kasten-io get deploy auth-svc \
  -o jsonpath='{.spec.template.spec.volumes[?(@.name=="k10-oidc-auth-creds")].secret.secretName}{"\n"}'   # kasten-oidc-client
kubectl -n kasten-io logs deploy/auth-svc --tail=20 | grep -i -E 'error|panic' || echo "auth-svc: no errors"
kubectl -n kasten-io get ingress -o wide                             # CLASS traefik, HOSTS kasten.ct.local, ADDRESS 192.168.1.60
kubectl get clusterrolebinding -o json \
  | jq -r '.items[] | select(.roleRef.name=="k10-admin") | .metadata.name + " -> " + ([.subjects[]?.name] | join(","))'
# ... -> rancher:<ADMIN>
```

**Validate (WSL):**
```bash
curl -sS --cacert ct-local-root-ca.crt -o /dev/null -w '%{http_code}\n' https://kasten.ct.local/k10/   # 200 or 302
echo | openssl s_client -connect kasten.ct.local:443 -servername kasten.ct.local -CAfile ct-local-root-ca.crt 2>/dev/null \
  | grep -E 'issuer=|Verify return code'                                                           # ct.local Root CA ; 0 (ok)
```

### 5.3 First login

1. Open `https://kasten.ct.local/k10/`. You're redirected to `https://rancher.ct.local/...` to log in.
2. Log in with the Rancher account from 4.3 (via Entra ID if that's how it logs in to Rancher).
3. You land back on Kasten. **Accept the EULA** in the dashboard; it's no longer set at install time.
4. The dashboard shows full admin access, because that account is the `k10-admin` user.

### 5.4 Snapshot class for Longhorn, then profiles and policies

Kasten only snapshots a PVC through a VolumeSnapshotClass that has the annotation `k10.kasten.io/is-snapshot-class: "true"` for the PVC's CSI driver. Without one, every backup fails with *Failed to find VolumeSnapshotClass with annotation in the cluster*. Harvester VM disks use Longhorn (`driver.longhorn.io`). Harvester's built-in classes stay unannotated, because Harvester's own VM snapshots use them.

```bash
use-harvester
# Which CSI driver do the protected PVCs use? (expect driver.longhorn.io)
kubectl -n test-vm get pvc -o custom-columns=PVC:.metadata.name,SC:.spec.storageClassName
kubectl get sc -o custom-columns=SC:.metadata.name,PROVISIONER:.provisioner

kubectl apply -f 05-kasten/k10-volumesnapshotclass-longhorn.yaml
```

**Validate:** exactly one annotated class per driver.
```bash
kubectl get volumesnapshotclass -o custom-columns=NAME:.metadata.name,DRIVER:.driver,K10:.metadata.annotations.k10\.kasten\.io/is-snapshot-class
# k10-longhorn-snap   driver.longhorn.io   true
# longhorn-snapshot   driver.longhorn.io   <none>     (Harvester built-in, must stay <none>)
# longhorn            driver.longhorn.io   <none>
```

If a PVC uses another driver (e.g. NetApp `csi.trident.netapp.io`), apply its class from `03-storage-classes/volume-snapshot-classes.yaml`. Then re-run the backup from the Kasten dashboard; the precheck passes.

Profiles and policies:

After the location-profile secrets exist (from `05-kasten/secrets/*.example.yaml`):

```bash
use-harvester
kubectl apply -k 05-kasten
kubectl -n kasten-io get profiles.config.kio.kasten.io,policies.config.kio.kasten.io
```

### 5.5 Let a Kasten admin manage Kasten RBAC from the dashboard

`k10-admin` has no permissions on Kubernetes RBAC, so the dashboard's roles and bindings pages are read-only or refused for it. The files in `05-kasten/rbac/` add, on Harvester:
- **`k10-rbac-manager` ClusterRole:** view and manage roles and bindings; `bind` only Kasten's built-in roles; no `escalate`.
- **`k10-rbac-managers` ClusterRoleBinding** for the Kasten user `rancher:user-6hc67` (Rancher local user `user-6hc67`).
- **`k10-rbac-guardrail` ValidatingAdmissionPolicy:** Kasten dashboard users (`rancher:*`) may only change `k10-*` roles and bindings to `k10-*` roles.

```bash
use-harvester
kubectl api-resources | grep -c validatingadmissionpolicies     # >= 1 (Kubernetes 1.30+)
ADMIN=user-6hc67                                 # used by the checks below
kubectl apply -k 05-kasten/rbac                  # policy, ClusterRole and binding
```

**Validate (RBAC):**
```bash
kubectl auth can-i list clusterrolebindings --as "rancher:$ADMIN"            # yes
kubectl auth can-i bind clusterroles/k10-basic --as "rancher:$ADMIN"         # yes
kubectl auth can-i bind clusterroles/cluster-admin --as "rancher:$ADMIN"     # no
kubectl auth can-i escalate clusterroles --as "rancher:$ADMIN"               # no
```

**Validate (guardrail; dry-run, changes nothing):**
```bash
kubectl delete clusterrolebinding cluster-admin --dry-run=server --as "rancher:$ADMIN"
# Error ... denied request: ValidatingAdmissionPolicy 'k10-rbac-guardrail' ... only manage bindings to k10-* roles
kubectl create rolebinding k10-test --clusterrole=k10-basic --user=rancher:test -n default --dry-run=server --as "rancher:$ADMIN"
# rolebinding.rbac.authorization.k8s.io/k10-test created (server dry run)
```

**Validate (dashboard):** log in to Kasten as `$ADMIN`. Open the RBAC pages under Settings, and create, then delete, a test binding of `k10-basic` to a test user in an application namespace. Then confirm who made the change:

```bash
kubectl get validatingadmissionpolicy k10-rbac-guardrail
kubectl get rolebinding -A -o json | jq -r '.items[] | select(.roleRef.name=="k10-basic") | .metadata.namespace + "/" + .metadata.name'
```

The guardrail only applies if the dashboard makes changes **as the logged-in user**. To confirm, try to bind a non-Kasten role, such as `view`, from the dashboard. It must be refused, by either Kubernetes RBAC or the guardrail. If it succeeds, the dashboard is acting as Kasten's own service account; stop and report it.

### 5.6 Let test-vm users delete and expire their own restore points

`k10-basic` can delete the namespaced `RestorePoint`, but that leaves the backup data in place. Deleting or expiring the backup acts on the cluster-scoped `RestorePointContent`, which a namespace RoleBinding can't grant, and Kasten's aggregated API ignores Kubernetes admission policies. `05-kasten/rbac/test-vm-restorepoints/` therefore grants it **by name**:
- **`k10-rpc-test-vm` ClusterRole:** get/update/patch/delete on `restorepointcontents`, limited to `resourceNames`.
- **`k10-rpc-sync` CronJob** (kasten-io, every 5 min): writes the names of all `RestorePointContent`s labelled `k10.kasten.io/appNamespace=test-vm` into that role.
- **`k10-rpc-test-vm` ClusterRoleBinding** for the test-vm user `rancher:m-66rfb` (the same user that has `k10-basic` in `test-vm`, file `05-kasten/rbac/k10-basic-test-vm-binding.yaml`).

**Pick the image tag:** the job uses `rancher/shell` (kubectl + sh), which Rancher and Harvester already use. Find a tag present in your environment:

```bash
use-harvester
kubectl get pods,jobs -A -o jsonpath='{..image}' | tr ' ' '\n' | grep rancher/shell | sort -u
# or on a Harvester node:  sudo crictl images | grep rancher/shell
```

**Apply:**
```bash
TAG=<tag-from-above>                         # e.g. v0.x.y
VMTEST_USER=m-66rfb                          # the test-vm user, used by the checks below
kubectl apply -f 05-kasten/rbac/test-vm-restorepoints/k10-rpc-test-vm-clusterrole.yaml
kubectl apply -f 05-kasten/rbac/test-vm-restorepoints/k10-rpc-test-vm-binding.yaml
sed "s|rancher/shell:<CHANGE_ME>|rancher/shell:$TAG|" 05-kasten/rbac/test-vm-restorepoints/k10-rpc-sync.yaml | kubectl apply -f -
kubectl -n kasten-io create job k10-rpc-sync-now --from=cronjob/k10-rpc-sync
kubectl -n kasten-io logs -f job/k10-rpc-sync-now
# synced N RestorePointContents of test-vm into clusterrole k10-rpc-test-vm
```

**Validate:**
```bash
kubectl get clusterrole k10-rpc-test-vm -o jsonpath='{.rules[0].resourceNames}{"\n"}'
# ["k10-rpc-sync-placeholder", "<test-vm rpc names>..."]  - the placeholder must ALWAYS be there
RPC_VMTEST=$(kubectl get restorepointcontents.apps.kio.kasten.io -l k10.kasten.io/appNamespace=test-vm -o jsonpath='{.items[0].metadata.name}')
RPC_OTHER=$(kubectl get restorepointcontents.apps.kio.kasten.io -l 'k10.kasten.io/appNamespace!=test-vm' -o jsonpath='{.items[0].metadata.name}')
kubectl auth can-i delete restorepointcontents.apps.kio.kasten.io/$RPC_VMTEST --as rancher:$VMTEST_USER   # yes
kubectl auth can-i delete restorepointcontents.apps.kio.kasten.io/$RPC_OTHER  --as rancher:$VMTEST_USER   # no
kubectl auth can-i delete restorepointcontents.apps.kio.kasten.io             --as rancher:$VMTEST_USER   # no (no blanket grant)
```

**Validate (dashboard):** log in as the test-vm user. On a test-vm restore point, set an expiry, then delete a test restore point; both must succeed. On another namespace's restore point (if visible), both must be refused. If expiry is still refused, the dashboard needs something beyond `restorepointcontents`. Copy the exact error (it names the verb and resource), plus `kubectl -n kasten-io logs deploy/aggregatedapis-svc --since=10m | grep -i forbidden`, and the role can be extended.

### 5.7 Read-only role for the Kasten namespace

`k10-ns-view` is a read-only copy of Kasten's `k10-ns-admin` Role in `kasten-io`: same resources, only `get`/`list`/`watch`, and **no secrets**. It's applied with `kubectl apply -k 05-kasten/rbac`. Grant it either from the Kasten dashboard as `user-6hc67`, or with:

```bash
use-harvester
VIEW_USER=<rancher-user-id>
sed "s|rancher:<CHANGE_ME>|rancher:$VIEW_USER|" 05-kasten/rbac/k10-ns-view-binding.yaml | kubectl apply -f -
```

**Validate:**
```bash
kubectl auth can-i list pods        -n kasten-io --as rancher:$VIEW_USER   # yes
kubectl auth can-i delete pods      -n kasten-io --as rancher:$VIEW_USER   # no
kubectl auth can-i get secrets      -n kasten-io --as rancher:$VIEW_USER   # no
kubectl auth can-i update configmaps -n kasten-io --as rancher:$VIEW_USER  # no
```

For a read-only view of Kasten's configuration (profiles, policies) in the dashboard, also bind Kasten's built-in `k10-config-view` ClusterRole.

---

## Lessons from the first test run

These cost the most time in the first run. Each is now built into the steps above.

1. **Check which cluster you're on, every time.** All the downloaded kubeconfigs named their context `local` and pointed at Rancher's vcluster, not Harvester, so Kasten was first installed in the wrong cluster. Use the per-cluster files and `whereami` (step 0.2). Never trust a context name.
2. **Kasten belongs on Harvester, not in the vcluster.** In the vcluster it can't resolve `rancher.ct.local` (vcluster pods use the vcluster's own CoreDNS, not Harvester's), and it can't see the VMs it should protect.
3. **Match Harvester's own ingress controller.** This Harvester runs Traefik, not rke2-ingress-nginx. With `class: nginx`, the Kasten ingress had no ADDRESS and `kasten.ct.local` didn't load. Check `rancher-expose` (step 0.3).
4. **Don't name the client secret `k10-oidc-auth`.** The Kasten chart creates its own Secret with that name, so the install fails with `exists and cannot be imported`. The repo uses `kasten-oidc-client`.
5. **Use the full resource name `addons.harvesterhci.io`.** Plain `addon` resolves to RKE2's `addons.k3s.cattle.io` and returns NotFound.
6. **Judge the add-on by its values and certificate, not pod age.** Re-applying unchanged values starts no new install job, so hours-old pods are normal on a re-run. What matters is the values check in 3.1 (3 matches) and Rancher serving the ct.local certificate in 3.2. If it doesn't, Kasten's login fails.
7. **Windows checkouts break the scripts.** CRLF line endings cause `env: 'bash\r': No such file or directory`. Run `git config core.autocrlf input` and `sed -i 's/\r$//' scripts/*.sh` (step 0.1).
8. **The EULA is accepted in the dashboard, not at install.** The chart no longer sets `eula`, so the first login asks for it (step 5.3).

## Troubleshooting

| Symptom | Likely cause | Check / fix |
|---|---|---|
| `whereami` → UNKNOWN or RANCHER when you expect HARVESTER | wrong kubeconfig file | `use-harvester`; recheck step 0.2 |
| Certificate not Ready | issuer or namespace problem | `kubectl describe certificate -n <ns> wildcard-ct-local` ; `kubectl -n cert-manager logs deploy/cert-manager` |
| Rancher still shows an old certificate | secrets not synced into the vcluster | `use-rancher; kubectl -n cattle-system get secret tls-rancher-ingress` ; syncer logs (3.1) |
| `/oidc/.well-known/...` returns 404 | feature not active | 4.1: `spec.value` true **and** Rancher restarted |
| auth-svc: `no such host rancher.ct.local` | CoreDNS entry missing on Harvester | step 2.1 |
| auth-svc: `x509: certificate signed by unknown authority` | Kasten doesn't trust the CA | step 1.4 ConfigMap, then `kubectl -n kasten-io rollout restart deploy/auth-svc` |
| auth-svc: `.../k10-oidc-auth-creds/client-id: no such file` | wrong or missing client secret | step 5.1; `clientSecretName` must be `kasten-oidc-client` |
| Rancher error page: `invalid redirect_uri` | callback URL mismatch | compare Rancher's error with `spec.redirectURIs` (4.2), and tell Claude the URL Kasten sent |
| `kasten.ct.local` → 404, or `k10-ingress` has no ADDRESS | ingress class differs from Harvester's controller | step 0.3; CLASS must match `rancher-expose` |
| `addons.k3s.cattle.io "rancher-vcluster" not found` | kubectl's short name `addon` picked RKE2's resource | use `addons.harvesterhci.io` |
| Pods in `rancher-vcluster` all hours old after step 3.1 | expected if the same values were already applied; otherwise the change didn't roll out | values grep = 3 and step 3.2 passes → fine; grep < 3 → re-apply 3.1 |
| Helm job: `exists and cannot be imported into the current release` | leftovers from an earlier attempt | step 0.4, then re-run 1.3 and onwards |
| Backup: `Failed to find VolumeSnapshotClass with annotation in the cluster` | no Kasten-annotated VolumeSnapshotClass for the PVC's CSI driver | step 5.4: `05-kasten/k10-volumesnapshotclass-longhorn.yaml` |
| Same error naming `Secret "k10-oidc-auth"` | client secret given the chart's reserved name | delete it; recreate as `kasten-oidc-client` (step 5.1) |
| Kasten pods running but `cannot resolve rancher.ct.local`, and `whereami` → RANCHER | Kasten installed inside the vcluster | step 0.4 (remove it there), then 5.2 with `use-harvester` |
| `env: 'bash\r': No such file or directory` | CRLF line endings from a Windows checkout | `sed -i 's/\r$//' scripts/*.sh` |
| `jq: command not found` | jq missing in WSL Fedora | `sudo dnf install -y jq` |
| Dashboard RBAC pages empty or `forbidden` for the Kasten admin | k10-admin has no RBAC permissions | step 5.5 |
| test-vm user can't delete or expire a new restore point | the sync job hasn't run since the backup | wait up to 5 min, or `kubectl -n kasten-io create job k10-rpc-sync-now --from=cronjob/k10-rpc-sync` |
| `k10-rpc-sync` pod `InvalidImageName` / `ErrImagePull` | `rancher/shell` tag not set or not available | step 5.6: pick a tag already in your environment |
| `denied request: ValidatingAdmissionPolicy 'k10-rbac-guardrail'` | a Kasten user tried to change a non-`k10-*` role or binding | intended; name custom roles `k10-*` |
| `error: the server doesn't have a resource type "settings"` from `whereami`-style checks | kubeconfig points at the vcluster | step 0.2: rebuild `~/.kube/harvester.yaml` from a node's `rke2.yaml` |
