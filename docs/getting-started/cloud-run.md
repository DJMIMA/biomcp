# Deploy to Google Cloud Run

BioMCP can run as a remote MCP server on Cloud Run by using the Streamable HTTP
entrypoint:

```bash
biomcp serve-http --host 0.0.0.0 --port "$PORT"
```

The container in this repository already does that. It binds to `0.0.0.0`,
honors Cloud Run's `PORT` environment variable, and exposes MCP at `/mcp`.

## What gets deployed

- `Dockerfile` builds the release `biomcp` binary, sets container-safe cache
  defaults, and starts `serve-http`.
- `cloudbuild.yaml` builds the image, pushes it to Artifact Registry, and
  deploys a Cloud Run service.
- The default Cloud Run deployment is private and sets `--max-instances=1`
  because BioMCP's Streamable HTTP transport keeps MCP session state in the
  serving process.

After deployment, remote MCP clients should connect to:

```text
https://SERVICE_URL/mcp
```

Probe routes are:

```text
GET https://SERVICE_URL/health
GET https://SERVICE_URL/readyz
GET https://SERVICE_URL/
```

## One-time Google Cloud setup

Set your project values:

```bash
export PROJECT_ID="your-gcp-project"
export PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
export REGION="asia-northeast1"
export SERVICE_NAME="biomcp"
export AR_REPOSITORY="containers"
export GITHUB_OWNER="your-github-owner"
export GITHUB_REPO="biomcp"
export CONNECTION_NAME="biomcp-github"
export TRIGGER_NAME="biomcp-cloud-run"
export BUILD_SA_NAME="biomcp-cloud-build"
export BUILD_SA="${BUILD_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud config set project "$PROJECT_ID"
```

Enable the APIs:

```bash
gcloud services enable \
  artifactregistry.googleapis.com \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  secretmanager.googleapis.com
```

Create an Artifact Registry Docker repository:

```bash
gcloud artifacts repositories create "$AR_REPOSITORY" \
  --repository-format=docker \
  --location="$REGION" \
  --description="BioMCP Cloud Run images"
```

Create a dedicated Cloud Build trigger service account and grant it deployment
permissions:

```bash
gcloud iam service-accounts create "$BUILD_SA_NAME" \
  --display-name="BioMCP Cloud Run deployer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/run.developer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/artifactregistry.writer"

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/logging.logWriter"

gcloud iam service-accounts add-iam-policy-binding \
  "$RUNTIME_SA" \
  --member="serviceAccount:${BUILD_SA}" \
  --role="roles/iam.serviceAccountUser"
```

## Connect GitHub to Cloud Build

Create a Cloud Build GitHub connection. This command prints browser links to
authorize GitHub and install the Cloud Build GitHub app.

```bash
gcloud builds connections create github "$CONNECTION_NAME" \
  --region="$REGION"
```

After the connection is authorized and installed, link this repository:

```bash
gcloud builds repositories create "$GITHUB_REPO" \
  --remote-uri="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git" \
  --connection="$CONNECTION_NAME" \
  --region="$REGION"
```

Create a trigger that deploys `main` on every push:

```bash
gcloud builds triggers create github \
  --name="$TRIGGER_NAME" \
  --repository="projects/${PROJECT_ID}/locations/${REGION}/connections/${CONNECTION_NAME}/repositories/${GITHUB_REPO}" \
  --branch-pattern="^main$" \
  --build-config="cloudbuild.yaml" \
  --region="$REGION" \
  --service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}" \
  --substitutions="_REGION=${REGION},_SERVICE_NAME=${SERVICE_NAME},_AR_REPOSITORY=${AR_REPOSITORY}"
```

Run the trigger once manually, or push to `main`:

```bash
gcloud builds triggers run "$TRIGGER_NAME" \
  --region="$REGION" \
  --branch="main"
```

## Configure API keys

Most BioMCP workflows run without credentials, but some providers support or
require API keys. Prefer Secret Manager over plain environment variables.

Example for Semantic Scholar:

```bash
printf "%s" "$S2_API_KEY" | gcloud secrets create biomcp-s2-api-key --data-file=-

gcloud secrets add-iam-policy-binding biomcp-s2-api-key \
  --member="serviceAccount:${RUNTIME_SA}" \
  --role="roles/secretmanager.secretAccessor"

gcloud run services update "$SERVICE_NAME" \
  --region="$REGION" \
  --set-secrets="S2_API_KEY=biomcp-s2-api-key:latest"
```

Useful BioMCP secret-backed variables include:

| Variable | Purpose |
|----------|---------|
| `NCBI_API_KEY` | Higher NCBI/PubMed/PubTator throughput |
| `S2_API_KEY` | Semantic Scholar authenticated quota |
| `OPENFDA_API_KEY` | Higher OpenFDA quota |
| `NCI_API_KEY` | NCI CTS trial queries |
| `ONCOKB_TOKEN` | OncoKB variant helper |
| `ALPHAGENOME_API_KEY` | AlphaGenome variant prediction |
| `DISGENET_API_KEY` | DisGeNET association sections |
| `UMLS_API_KEY` | Optional `discover` clinical crosswalks |

Because `cloudbuild.yaml` does not set regular environment variables during
deployment, secret mappings added to the Cloud Run service are not overwritten
by the default deploy step. If you add environment-variable flags to
`cloudbuild.yaml` later, keep the secret mappings there too.

## Authentication

The default deployment uses `--no-allow-unauthenticated`. Keep this for private
MCP servers, then use a client or proxy that can provide Google identity
authentication.

If you intentionally want a public endpoint, remove `--no-allow-unauthenticated`
from `cloudbuild.yaml` and use `--allow-unauthenticated` in the deploy step
instead. Do this only when the endpoint is protected elsewhere or public access
is acceptable.

## Local verification

Build and run the same container locally:

```bash
docker build -t biomcp:local .
docker run --rm -p 8080:8080 -e PORT=8080 biomcp:local
```

Check the probes:

```bash
curl http://127.0.0.1:8080/health
curl http://127.0.0.1:8080/readyz
curl http://127.0.0.1:8080/
```

## References

- [Cloud Run continuous deployment from Git](https://cloud.google.com/run/docs/continuous-deployment)
- [Cloud Build GitHub triggers](https://cloud.google.com/build/docs/automating-builds/create-github-app-triggers)
- [Cloud Build GitHub connection command](https://cloud.google.com/sdk/gcloud/reference/builds/connections/create/github)
