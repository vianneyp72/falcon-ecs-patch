#!/usr/bin/env bash
# falcon-ecs-patch: repeatable Falcon Container sensor patching for ECS Fargate task definitions.
# Wraps the official patching utility that ships inside the falcon-container image.
set -euo pipefail

VERSION="0.2.3"
INIT_NAME="crowdstrike-falcon-init-container"
SENSOR_REPO="falcon-container"   # override with --sensor-repo (e.g. falcon-sensor/falcon-container)
PULL_SCRIPT_URL="https://github.com/CrowdStrike/falcon-scripts/releases/latest/download/falcon-container-sensor-pull.sh"

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
usage_die() { log "ERROR: $*"; log "Run '$(basename "$0") --help' for usage."; exit 2; }

usage() {
  cat <<EOF
falcon-ecs-patch $VERSION

Usage:
  $(basename "$0") setup --region R [--falcon-cloud C]
  $(basename "$0") audit --cluster C --region R [--fail-on-unprotected]
  $(basename "$0") patch --cluster C --service S --region R [--deploy]
  $(basename "$0") patch --cluster C --all --region R [--deploy]
  $(basename "$0") patch --family F[:REV] --region R [--deploy]
  $(basename "$0") patch --file task-definition.json --region R [--output patched.json]

Commands:
  setup   Copy the Falcon Container sensor image into your ECR (once per account and region).
  audit   Read-only. Mark every service in a cluster PROTECTED or UNPROTECTED.
  patch   Export, patch, and diff a task definition. Dry run unless --deploy is given.

Options:
  --region R            AWS region (or AWS_REGION)
  --cluster C           ECS cluster name
  --service S           Patch the task definition this service runs, then update the service
  --all                 Patch every unprotected Fargate service in the cluster
  --family F[:REV]      Patch the latest revision of a family, or a specific revision (no service update)
  --from-revision N     With --service: patch revision N of the service's family (an unpatched one)
                        instead of the revision the service runs. This is how you move to a newer
                        sensor: already-patched task definitions are skipped
  --file FILE           Patch a task definition JSON file (for pipelines that keep it in Git). Never
                        registers anything: writes the patched JSON to --output
  --output FILE         With --file: where to write the patched JSON (default: under --out)
  --cid CID             Falcon CID with checksum (or FALCON_CID)
  --sensor-image URI    Sensor image in ECR (default: newest tag in the sensor repo)
  --sensor-repo NAME    ECR repo holding the sensor image (default: $SENSOR_REPO). The last path
                        segment must be 'falcon-container'; a prefix is allowed (ns/falcon-container)
  --skip-container N    Do not inject the sensor into container N (repeatable)
  --falconctl-opts S    Sensor options baked into the task, e.g. "--tags=prod,web"
  --falcon-cloud C      setup only: us-1, us-2, eu-1, us-gov-1, us-gov-2 (default: auto)
  --ca-bundle FILE      PEM bundle to trust when reading app image metadata (corporate TLS proxy).
                        Must be a FULL bundle (system roots plus your proxy CA). Default: \$SSL_CERT_FILE
  --out DIR             Where original and patched JSON are written (default: ./falcon-ecs-patch-out)
  --deploy              Register the patched revision (and update the service with --service/--all).
                        The new task definition ARN is printed on stdout
  --yes                 Skip the confirmation prompt for --deploy
  --fail-on-unprotected audit exits 3 when an unprotected Fargate service is found
  -h, --help            Show this help
  --version             Show the version

Environment:
  FALCON_CID, FALCON_CLIENT_ID, FALCON_CLIENT_SECRET, AWS_REGION, IMAGE_PULL_TOKEN
  The client secret is read from the environment only, never from a flag.

Exit codes: 0 ok, 1 error, 2 usage, 3 audit found unprotected services.
EOF
}

# ---------- argument parsing ----------
CMD="${1:-}"
if [ $# -gt 0 ]; then shift; fi

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
CLUSTER=""; SERVICE=""; FAMILY=""; ALL=0; FILE=""; OUTPUT=""; FROM_REV=""
CID="${FALCON_CID:-}"; SENSOR_IMAGE=""; FALCONCTL_OPTS=""; FALCON_CLOUD=""
CA_BUNDLE="${FALCON_ECS_PATCH_CA_BUNDLE:-${SSL_CERT_FILE:-}}"
OUT_DIR="./falcon-ecs-patch-out"; DEPLOY=0; YES=0; FAIL_UNPROTECTED=0
SKIP=()

case "$CMD" in
  -h|--help|help|"") usage; exit 0 ;;
  --version) echo "$VERSION"; exit 0 ;;
  setup|audit|patch) ;;
  *) usage_die "Unknown command '$CMD'" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) ALL=1; shift ;;
    --deploy) DEPLOY=1; shift ;;
    --yes) YES=1; shift ;;
    --fail-on-unprotected) FAIL_UNPROTECTED=1; shift ;;
    --region|--cluster|--service|--family|--file|--output|--from-revision|--cid|--sensor-image|--sensor-repo|--skip-container|--falconctl-opts|--falcon-cloud|--ca-bundle|--out)
      [ $# -ge 2 ] || usage_die "$1 needs a value"
      case "$1" in
        --region) REGION="$2" ;;
        --cluster) CLUSTER="$2" ;;
        --service) SERVICE="$2" ;;
        --family) FAMILY="$2" ;;
        --from-revision) FROM_REV="$2" ;;
        --file) FILE="$2" ;;
        --output) OUTPUT="$2" ;;
        --cid) CID="$2" ;;
        --sensor-image) SENSOR_IMAGE="$2" ;;
        --sensor-repo) SENSOR_REPO="$2" ;;
        --skip-container) SKIP+=("$2") ;;
        --falconctl-opts) FALCONCTL_OPTS="$2" ;;
        --falcon-cloud) FALCON_CLOUD="$2" ;;
        --ca-bundle) CA_BUNDLE="$2" ;;
        --out) OUT_DIR="$2" ;;
      esac
      shift 2 ;;
    --client-secret|--client-id) usage_die "Pass Falcon API credentials with FALCON_CLIENT_ID / FALCON_CLIENT_SECRET, not flags (flags show up in process lists and CI logs)." ;;
    *) usage_die "Unknown option '$1'" ;;
  esac
done

[ -n "$REGION" ] || usage_die "--region is required (or set AWS_REGION)"

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

# ---------- shared helpers ----------
ACCOUNT_ID=""; ECR_REGISTRY=""
init_aws() {
  need aws; need jq
  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) \
    || die "AWS credentials not working. Run 'aws sts get-caller-identity' to check."
  ECR_REGISTRY="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"
}

ecr_login() {
  need docker
  docker info >/dev/null 2>&1 || die "Docker is not running. Start it and retry."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null 2>&1 \
    || die "docker login to $ECR_REGISTRY failed."
}

latest_sensor_image() {
  local tag
  tag=$(aws ecr describe-images --repository-name "$SENSOR_REPO" --region "$REGION" \
    --query 'sort_by(imageDetails[?imageTags!=null],&imagePushedAt)[-1].imageTags[0]' --output text 2>/dev/null || true)
  if [ -z "$tag" ] || [ "$tag" = "None" ]; then
    die "No sensor image found in ECR repo '$SENSOR_REPO' ($REGION). Run: $(basename "$0") setup --region $REGION"
  fi
  echo "$ECR_REGISTRY/$SENSOR_REPO:$tag"
}

sensor_has_amd64() { # ECR image URI: registry/repo[:tag]; reads the manifest, not the local Docker store
  local ref="${1#*/}" repo tag m mt cfg
  repo="${ref%:*}"; tag="${ref##*:}"
  m=$(aws ecr batch-get-image --repository-name "$repo" --image-ids "imageTag=$tag" --region "$REGION" \
    --accepted-media-types application/vnd.docker.distribution.manifest.v2+json application/vnd.docker.distribution.manifest.list.v2+json application/vnd.oci.image.manifest.v1+json application/vnd.oci.image.index.v1+json \
    --query 'images[0].imageManifest' --output text 2>/dev/null) || return 1
  [ -n "$m" ] && [ "$m" != "None" ] || return 1
  mt=$(jq -r '.mediaType // ""' <<<"$m")
  case "$mt" in
    *list*|*index*) jq -e '[.manifests[].platform | select(.os=="linux" and .architecture=="amd64")] | length > 0' <<<"$m" >/dev/null ;;
    *)
      cfg=$(jq -r '.config.digest' <<<"$m")
      [ "$(aws ecr get-download-url-for-layer --repository-name "$repo" --layer-digest "$cfg" --region "$REGION" --query downloadUrl --output text \
        | xargs curl -s | jq -r '.architecture')" = "amd64" ] ;;
  esac
}

make_pull_token() {
  if [ -n "${IMAGE_PULL_TOKEN:-}" ]; then printf '%s' "$IMAGE_PULL_TOKEN"; return; fi
  local pw auth
  pw=$(aws ecr get-login-password --region "$REGION")
  auth=$(printf 'AWS:%s' "$pw" | base64 | tr -d '\n')
  printf '{"auths":{"%s":{"auth":"%s"}}}' "$ECR_REGISTRY" "$auth" | base64 | tr -d '\n'
}

is_protected() { jq -e --arg n "$INIT_NAME" '[.containerDefinitions[].name] | index($n) != null' >/dev/null; }

# ---------- setup ----------
cmd_setup() {
  [ -n "${FALCON_CLIENT_ID:-}" ] && [ -n "${FALCON_CLIENT_SECRET:-}" ] \
    || die "Set FALCON_CLIENT_ID and FALCON_CLIENT_SECRET (scopes: Falcon Images Download Read, Sensor Download Read)."
  need curl; init_aws
  aws ecr describe-repositories --repository-names "$SENSOR_REPO" --region "$REGION" >/dev/null 2>&1 \
    || aws ecr create-repository --repository-name "$SENSOR_REPO" --region "$REGION" >/dev/null
  ecr_login

  local tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expand now: $tmp is function-local and out of scope when EXIT fires
  trap "rm -rf '$tmp'" EXIT
  log "Downloading the CrowdStrike sensor pull script..."
  curl -fsSL "$PULL_SCRIPT_URL" -o "$tmp/pull.sh" || die "Could not download the pull script."
  local cloud=(); [ -z "$FALCON_CLOUD" ] || cloud=(--region "$FALCON_CLOUD")
  case "$SENSOR_REPO" in */falcon-container|falcon-container) ;; *) die "--sensor-repo must end in 'falcon-container' (the copy keeps the image name).";; esac
  local dest="$ECR_REGISTRY"; case "$SENSOR_REPO" in */*) dest="$ECR_REGISTRY/${SENSOR_REPO%/*}";; esac
  log "Copying the falcon-container image into $dest ..."
  FALCON_CLIENT_ID="$FALCON_CLIENT_ID" FALCON_CLIENT_SECRET="$FALCON_CLIENT_SECRET" \
    bash "$tmp/pull.sh" --type falcon-container --platform x86_64 \
      ${cloud[@]+"${cloud[@]}"} --copy "$dest" >&2 \
    || die "Sensor copy failed. Check the API client scopes and that Docker is running."

  local img; img=$(latest_sensor_image)
  log ""
  log "Sensor image ready. Use it with --sensor-image, or let patch find the newest tag:"
  echo "$img"
}

# ---------- audit ----------
# Emits one TSV row per service: name, td-arn, launch, arch, status, sensor-tag
audit_rows() {
  local arns
  arns=$(aws ecs list-services --cluster "$CLUSTER" --region "$REGION" --query 'serviceArns' --output text) \
    || die "Could not list services in cluster '$CLUSTER' ($REGION). Check the cluster name, region, and credentials."
  [ -n "$arns" ] && [ "$arns" != "None" ] || return 0
  tr '\t' '\n' <<<"$arns" | xargs -n 10 aws ecs describe-services --cluster "$CLUSTER" --region "$REGION" --output json --services \
    | jq -c '.services[]' | while IFS= read -r svc; do
      local name td td_json launch arch status sensor
      name=$(jq -r '.serviceName' <<<"$svc")
      td=$(jq -r '.taskDefinition' <<<"$svc")
      td_json=$(aws ecs describe-task-definition --task-definition "$td" --region "$REGION" --query taskDefinition --output json)
      launch=$(jq -r '.launchType // (if ((.capacityProviderStrategy[0].capacityProvider // "") | test("^FARGATE")) then "FARGATE" else "" end)' <<<"$svc")
      if [ -z "$launch" ]; then
        launch=$(jq -r 'if (.requiresCompatibilities // []) == ["FARGATE"] then "FARGATE" else "EC2" end' <<<"$td_json")
      fi
      arch=$(jq -r '.runtimePlatform.cpuArchitecture // "X86_64"' <<<"$td_json")
      if [ "$launch" != "FARGATE" ]; then status="OUT-OF-SCOPE"
      elif is_protected <<<"$td_json"; then status="PROTECTED"
      else status="UNPROTECTED"; fi
      sensor=$(jq -r --arg n "$INIT_NAME" '[.containerDefinitions[] | select(.name==$n) | .image | split(":")[-1]][0] // "-"' <<<"$td_json")
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${td##*/}" "$launch" "$arch" "$status" "$sensor"
    done
}

cmd_audit() {
  [ -n "$CLUSTER" ] || usage_die "audit needs --cluster"
  init_aws
  local rows; rows=$(audit_rows) || exit 1
  if [ -z "$rows" ]; then log "No services found in cluster '$CLUSTER'."; return 0; fi
  { printf 'SERVICE\tTASK-DEFINITION\tLAUNCH\tARCH\tSTATUS\tSENSOR\n'; printf '%s\n' "$rows"; } | column -t -s "$(printf '\t')"
  local n; n=$(printf '%s\n' "$rows" | awk -F'\t' '$5=="UNPROTECTED"' | wc -l | tr -d ' ')
  log ""
  log "$n unprotected Fargate service(s)."
  if [ "$FAIL_UNPROTECTED" -eq 1 ] && [ "$n" -gt 0 ]; then exit 3; fi
}

# ---------- patch ----------
run_patcher() { # in.json out.json
  local indir inname args
  indir=$(cd "$(dirname "$1")" && pwd); inname=$(basename "$1")
  args=(-cid "$CID" -image "$SENSOR_IMAGE" -pulltoken "$PULL_TOKEN")
  [ -z "$FALCONCTL_OPTS" ] || args+=(--falconctl-opts "$FALCONCTL_OPTS")
  local ca=()
  if [ -n "$CA_BUNDLE" ]; then
    [ -r "$CA_BUNDLE" ] || die "CA bundle not readable: $CA_BUNDLE"
    ca=(-e SSL_CERT_FILE=/etc/ssl/custom-ca.pem -v "$CA_BUNDLE:/etc/ssl/custom-ca.pem:ro")
  fi
  docker run --rm --platform linux/amd64 ${ca[@]+"${ca[@]}"} -v "$indir:/var/run/spec" "$SENSOR_IMAGE" \
    "${args[@]}" -ecs-spec-file "/var/run/spec/$inname" >"$2" 2>"$2.log"
}

check_execution_role() { # td_json
  local role; role=$(jq -r '.executionRoleArn // empty' <<<"$1")
  if [ -z "$role" ]; then
    die "Task definition has no executionRoleArn. Fargate cannot pull the sensor image from ECR without one."
  fi
  local repo_arn="arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/$SENSOR_REPO" decision
  decision=$(aws iam simulate-principal-policy --policy-source-arn "$role" \
    --action-names ecr:BatchGetImage ecr:GetDownloadUrlForLayer --resource-arns "$repo_arn" \
    --query 'EvaluationResults[].EvalDecision' --output text 2>/dev/null || true)
  if [ -z "$decision" ]; then
    log "  WARN  could not check ECR pull access for ${role##*/} (needs iam:SimulatePrincipalPolicy). Confirm it can pull from ECR."
  elif printf '%s' "$decision" | grep -qv allowed; then
    die "Execution role ${role##*/} cannot pull from ECR repo '$SENSOR_REPO'. Attach AmazonECSTaskExecutionRolePolicy."
  fi
}

patch_one() { # td_ref (family[:rev]|arn)  svc_name_or_empty  [file]
  local ref="$1" svc="$2" src_file="${3:-}" td_json family rev
  if [ -n "$src_file" ]; then
    [ -r "$src_file" ] || die "Cannot read $src_file"
    td_json=$(jq -c 'if has("taskDefinition") then .taskDefinition else . end' "$src_file") \
      || die "$src_file is not valid JSON."
    jq -e '.family and .containerDefinitions' <<<"$td_json" >/dev/null \
      || die "$src_file does not look like a task definition (needs family and containerDefinitions)."
    family=$(jq -r '.family' <<<"$td_json"); rev="file"
  else
    td_json=$(aws ecs describe-task-definition --task-definition "$ref" --region "$REGION" --query taskDefinition --output json) \
      || die "Task definition '$ref' not found in $REGION."
    family=$(jq -r '.family' <<<"$td_json"); rev=$(jq -r '.revision' <<<"$td_json")
  fi
  local label="$family:$rev"
  log ""
  log "== $label"

  if is_protected <<<"$td_json"; then log "  SKIP  already protected (has $INIT_NAME). Nothing to do."; return 0; fi
  jq -e '(.requiresCompatibilities // []) | index("FARGATE") != null' <<<"$td_json" >/dev/null \
    || die "$label is not Fargate-compatible (requiresCompatibilities must include FARGATE). This tool supports ECS on Fargate only."
  if [ "$(jq -r '.runtimePlatform.cpuArchitecture // "X86_64"' <<<"$td_json")" = "ARM64" ]; then
    die "$label runs on ARM64 (Graviton). v0.1 supports X86_64 only."
  fi
  if [ -n "$src_file" ]; then
    jq -e '.executionRoleArn // empty' <<<"$td_json" >/dev/null \
      || log "  WARN  no executionRoleArn in the file. Fargate cannot pull the sensor image from ECR without one."
  else
    check_execution_role "$td_json"
  fi

  local controller="ECS"
  if [ -n "$svc" ] && [ -n "$CLUSTER" ]; then
    local sj; sj=$(aws ecs describe-services --cluster "$CLUSTER" --services "$svc" --region "$REGION" --query 'services[0]' --output json 2>/dev/null || echo '{}')
    controller=$(jq -r '.deploymentController.type // "ECS"' <<<"$sj")
    local pip; pip=$(jq -r '.networkConfiguration.awsvpcConfiguration.assignPublicIp // "n/a"' <<<"$sj")
    [ "$pip" != "DISABLED" ] || log "  WARN  service has no public IP. Tasks need a NAT gateway or equivalent route to reach the Falcon cloud (TLS 443)."
    log "  Rollout: $(jq -r '"min healthy \(.deploymentConfiguration.minimumHealthyPercent // "?")%, max \(.deploymentConfiguration.maximumPercent // "?")%, circuit breaker " + (if .deploymentConfiguration.deploymentCircuitBreaker.enable then "ON (rolls back on failed deployments)" else "OFF" end)' <<<"$sj"), task size $(jq -r '"\(.cpu // "?") CPU / \(.memory // "?") MiB"' <<<"$td_json")"
    jq -e '.deploymentConfiguration.deploymentCircuitBreaker.enable == true' <<<"$sj" >/dev/null \
      || log "  NOTE  the circuit breaker is off. Enable it so a failed rollout rolls back automatically."
    [ "$controller" = "ECS" ] || log "  NOTE  deployment controller is $controller. The service will not be updated; use your $controller deployment with the new revision."
  fi

  local dir="$OUT_DIR/$family"; mkdir -p "$dir"
  local orig="$dir/rev$rev.original.json" patched="$dir/rev$rev.patched.json"
  local skip_json; skip_json=$(printf '%s\n' ${SKIP[@]+"${SKIP[@]}"} | jq -R . | jq -sc 'map(select(length>0))')
  jq --argjson skip "$skip_json" '
    del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy,.tags,.deregisteredAt)
    | .containerDefinitions |= map(if (.name as $n | $skip | index($n)) then .dockerLabels += {"sensor.falcon-system.crowdstrike.com/injection":"disabled"} else . end)
  ' <<<"$td_json" >"$orig"

  if ! jq -e '[.containerDefinitions[] | select((.dockerLabels["sensor.falcon-system.crowdstrike.com/injection"] // "") != "disabled")] | length > 0' "$orig" >/dev/null; then
    log "  SKIP  every container is excluded by --skip-container. Nothing to patch."; return 0
  fi

  log "  Patching with the official utility..."
  if ! run_patcher "$orig" "$patched" || ! jq -e . "$patched" >/dev/null 2>&1; then
    log "  Utility output:"; sed 's/^/    /' "$patched.log" >&2 || true
    if grep -q "credentials tried" "$patched.log" 2>/dev/null; then
      die "Patching failed for $label. 'credentials tried' can mean (1) the app image registry needs credentials: set IMAGE_PULL_TOKEN, or (2) a corporate TLS proxy (Zscaler, etc.) is re-signing traffic: pass --ca-bundle <full-bundle.pem>."
    fi
    die "Patching failed for $label. See $patched.log"
  fi
  is_protected <"$patched" || die "Patched file for $label does not contain $INIT_NAME. See $patched.log"

  log "  Changes ($orig -> $patched):"
  jq -r --arg n "$INIT_NAME" '.containerDefinitions[] | if .name==$n then "    + added init container: \(.name)  (image \(.image))" else "    ~ wrapped entrypoint, added SYS_PTRACE: \(.name)" end' "$patched" >&2
  [ ${#SKIP[@]} -eq 0 ] || log "    (skipped via label: ${SKIP[*]})"
  log "  Full diff:"
  diff -u <(jq -S . "$orig") <(jq -S . "$patched") | sed 's/^/    /' >&2 || true

  if [ -n "$src_file" ]; then
    local dest="${OUTPUT:-$patched}"
    [ "$dest" = "$patched" ] || cp "$patched" "$dest"
    log "  Patched file written: $dest"
    log "  Register it with your normal pipeline (aws ecs register-task-definition, Terraform, CDK)."
    return 0
  fi
  if [ "$DEPLOY" -ne 1 ]; then
    log "  Dry run: nothing registered. Add --deploy to register and roll out."
    return 0
  fi
  if [ "$YES" -ne 1 ]; then
    [ -t 0 ] || die "--deploy needs a terminal to confirm, or pass --yes in CI."
    printf 'Register patched %s%s? [y/N] ' "$family" "${svc:+ and update service $svc}" >&2
    read -r ans; case "$ans" in y|Y|yes) ;; *) log "Aborted."; return 0 ;; esac
  fi

  local new_arn
  new_arn=$(aws ecs register-task-definition --region "$REGION" --cli-input-json "file://$patched" \
    --query 'taskDefinition.taskDefinitionArn' --output text) || die "register-task-definition failed."
  log "  Registered: ${new_arn##*/}"
  printf '%s\n' "$new_arn"
  if [ -n "$svc" ] && [ "$controller" != "ECS" ]; then
    log "  Not updating $svc (deployment controller $controller). Deploy ${new_arn##*/} with your $controller process."
  elif [ -n "$svc" ]; then
    local prev; prev=$(aws ecs describe-services --cluster "$CLUSTER" --services "$svc" --region "$REGION" --query 'services[0].taskDefinition' --output text)
    aws ecs update-service --cluster "$CLUSTER" --service "$svc" --task-definition "$new_arn" --region "$REGION" >/dev/null
    log "  Rolling out $svc, waiting for the service to stabilize..."
    aws ecs wait services-stable --cluster "$CLUSTER" --services "$svc" --region "$REGION" \
      || die "Service did not stabilize. ECS keeps the previous tasks running. Roll back with: aws ecs update-service --cluster $CLUSTER --service $svc --task-definition $prev --region $REGION"
    log "  Done. Roll back with: aws ecs update-service --cluster $CLUSTER --service $svc --task-definition $prev --region $REGION"
  fi
}

cmd_patch() {
  [ -n "$CID" ] || die "Set the Falcon CID with --cid or FALCON_CID (include the checksum)."
  local modes=0; [ -z "$SERVICE" ] || modes=$((modes+1)); [ -z "$FAMILY" ] || modes=$((modes+1)); [ "$ALL" -eq 0 ] || modes=$((modes+1)); [ -z "$FILE" ] || modes=$((modes+1))
  [ "$modes" -eq 1 ] || usage_die "patch needs exactly one of --service, --family, --all, --file"
  [ -z "$FROM_REV" ] || [ -n "$SERVICE" ] || usage_die "--from-revision works with --service"
  [ -z "$FILE" ] || [ "$DEPLOY" -eq 0 ] || usage_die "--file never registers anything. Drop --deploy and register the --output file with your pipeline."
  [ -z "$OUTPUT" ] || [ -n "$FILE" ] || usage_die "--output works with --file"
  if [ -n "$SERVICE" ] || [ "$ALL" -eq 1 ]; then [ -n "$CLUSTER" ] || usage_die "--service and --all need --cluster"; fi
  init_aws; need docker; ecr_login
  [ -n "$SENSOR_IMAGE" ] || SENSOR_IMAGE=$(latest_sensor_image)
  sensor_has_amd64 "$SENSOR_IMAGE" \
    || die "Sensor image $SENSOR_IMAGE has no linux/amd64 build, which Fargate x86_64 tasks need (often a single-arch arm64 copy made on Apple Silicon). Re-copy it into a new repo: $(basename "$0") setup --region $REGION --sensor-repo <new-name>/falcon-container"
  PULL_TOKEN=$(make_pull_token)
  log "Sensor image: $SENSOR_IMAGE"
  [ -z "$CA_BUNDLE" ] || log "CA bundle:    $CA_BUNDLE"
  [ "$DEPLOY" -eq 1 ] || log "Mode: dry run (add --deploy to apply)"

  if [ -n "$FILE" ]; then
    patch_one "" "" "$FILE"
  elif [ -n "$FAMILY" ]; then
    patch_one "$FAMILY" ""
  elif [ -n "$SERVICE" ]; then
    local td; td=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --region "$REGION" \
      --query 'services[0].taskDefinition' --output text 2>/dev/null || true)
    { [ -n "$td" ] && [ "$td" != "None" ]; } || die "Service '$SERVICE' not found in cluster '$CLUSTER'."
    if [ -n "$FROM_REV" ]; then
      local fam; fam=$(aws ecs describe-task-definition --task-definition "$td" --region "$REGION" --query 'taskDefinition.family' --output text)
      patch_one "$fam:$FROM_REV" "$SERVICE"
    else
      patch_one "$td" "$SERVICE"
    fi
  else
    local rows names; rows=$(audit_rows) || exit 1
    names=$(awk -F'\t' '$5=="UNPROTECTED"{print $1}' <<<"$rows")
    if [ -z "$rows" ]; then
      log "No services found in cluster '$CLUSTER'."
    elif [ -z "$names" ]; then
      local ok="OK"; if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then ok=$'\033[32m\xe2\x9c\x93\033[0m'; else ok=$'\xe2\x9c\x93'; fi
      log "$ok All Fargate services in cluster '$CLUSTER' are protected. Nothing to patch."
    else
      while IFS= read -r s <&3; do
        local td; td=$(aws ecs describe-services --cluster "$CLUSTER" --services "$s" --region "$REGION" --query 'services[0].taskDefinition' --output text)
        patch_one "$td" "$s"
      done 3<<<"$names"
    fi
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "$CMD" in
    setup) cmd_setup ;;
    audit) cmd_audit ;;
    patch) cmd_patch ;;
  esac
fi
