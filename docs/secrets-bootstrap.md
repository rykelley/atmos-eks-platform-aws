# Secrets bootstrap

The `polarbear-app` Terraform component creates **two** AWS Secrets
Manager secrets per stage:

| Name pattern                                       | Managed by   | What's in it                                       |
|----------------------------------------------------|--------------|----------------------------------------------------|
| `<namespace>/<stage>/polarbear-app/aws`            | Terraform    | IAM user keys for the app's S3 bucket + bucket name + region |
| `<namespace>/<stage>/polarbear-app/integrations`   | **You**      | All 3rd-party API keys (Resend, Stripe, OAuth, …)  |

ESO syncs both into Kubernetes Secrets that the app's Pods use as
`envFrom`. The first one is fully automated. The second is created **empty**
on the first apply — you have to populate it once per stage.

This doc walks through populating the integrations secret.

---

## 1. Find the secret name

After `atmos terraform apply polarbear-app -s plat-platform-usw2-dev`
runs for the first time:

```bash
atmos terraform output polarbear-app -s plat-platform-usw2-dev \
  -- secrets_manager_integrations_secret_name
# → "plat/dev/polarbear-app/integrations"
```

(In prod the path is `plat/prod/polarbear-app/integrations`.)

---

## 2. Build the JSON payload

The secret stores a single JSON object whose keys match the values in
your `env_secrets` map in `stacks/catalog/polarbear-app.yaml`.

The default `env_secrets` map declares these keys (add / remove as you
edit the catalog):

```json
{
  "AUTH_SECRET":         "<openssl rand -base64 32>",
  "PRIVATE_ACCESS_KEY":  "<openssl rand -base64 32>",
  "BASIC_AUTH_USERNAME": "admin",
  "BASIC_AUTH_PASSWORD": "<random>",
  "RESEND_API_KEY":      "re_...",
  "STRIPE_SECRET_KEY":   "sk_live_...",
  "STRIPE_WEBHOOK_SIG":  "whsec_..."
}
```

If you also enabled OAuth or Telegram in the catalog:

```json
{
  "...": "...",
  "GOOGLE_AUTH_ID":     "...apps.googleusercontent.com",
  "GOOGLE_AUTH_SECRET": "...",
  "GITHUB_AUTH_ID":     "...",
  "GITHUB_AUTH_SECRET": "...",
  "TELEGRAM_BOT_TOKEN": "...:..."
}
```

---

## 3. Push the JSON into Secrets Manager

### Option A — AWS CLI

```bash
aws secretsmanager put-secret-value \
  --region us-west-2 \
  --secret-id "plat/dev/polarbear-app/integrations" \
  --secret-string file://./integrations.json
```

…where `integrations.json` is the file you built in step 2.
**Don't commit it to git.** Add it to your `.gitignore` if you keep it
locally for re-runs.

### Option B — AWS Console

1. AWS Console → Secrets Manager → `plat/dev/polarbear-app/integrations`
2. **Retrieve secret value → Edit → Plaintext** tab
3. Paste your JSON, click Save

---

## 4. Force ESO to re-sync

ESO polls every `refreshInterval` (1h by default), but you can force a
sync immediately:

```bash
kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app \
  force-sync=$(date +%s) --overwrite
```

Then verify:

```bash
kubectl get secret app-secrets-integrations -n polarbear-app \
  -o json | jq '.data | keys'
```

You should see one entry per key in `var.env_secrets`.

---

## 5. Roll the Pods to pick up the new env

```bash
kubectl rollout restart deployment polarbear-app -n polarbear-app
kubectl rollout status  deployment polarbear-app -n polarbear-app
```

Or just bump the image tag via Terraform and the new replica set will
get the fresh env automatically.

---

## Adding a NEW secret env var

1. Add the key to `env_secrets` in `stacks/catalog/polarbear-app.yaml`:
   ```yaml
   env_secrets:
     # ... existing entries ...
     SENDGRID_API_KEY: "SENDGRID_API_KEY"
   ```
2. Add the corresponding key/value to the JSON in Secrets Manager
   (steps 2–3 above).
3. Apply + restart:
   ```bash
   atmos terraform apply polarbear-app -s plat-platform-usw2-dev
   kubectl rollout restart deployment polarbear-app -n polarbear-app
   ```

---

## Rotating a secret

```bash
aws secretsmanager update-secret-version-stage ...   # or just put-secret-value
kubectl annotate externalsecret app-secrets-integrations \
  -n polarbear-app force-sync=$(date +%s) --overwrite
kubectl rollout restart deployment polarbear-app -n polarbear-app
```

ESO + the Deployment's pod-template `checksum/config` annotation handle
the cascade — no Terraform run required for value-only changes.

---

## How is the AWS keys secret different?

`<ns>/<stage>/polarbear-app/aws` is **fully managed by Terraform** —
its `secret_string` is set from the `aws_iam_access_key` resource. Don't
edit it by hand; Terraform will overwrite on the next apply.

To rotate the IAM user keys, taint the access key and re-apply:

```bash
atmos terraform taint polarbear-app -s plat-platform-usw2-dev \
  -- aws_iam_access_key.app[0]
atmos terraform apply polarbear-app -s plat-platform-usw2-dev
```

ESO will re-sync the new keys; the Pod-template checksum annotation will
trigger a rolling restart.
