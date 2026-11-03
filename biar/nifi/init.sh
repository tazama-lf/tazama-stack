#!/bin/sh

set -e

# none:     plain HTTP, no authentication.
# keycloak: HTTPS, authenticated with the machine identity certificate that the
#           biar-nifi image writes to the shared nifi_machine_identity volume.
NIFI_AUTH_MODE=$(printf '%s' "${NIFI_AUTH:-none}" | tr '[:upper:]' '[:lower:]')
MACHINE_IDENTITY_DIR="/opt/nifi/machine-identity"

case "$NIFI_AUTH_MODE" in
  none)
    BASE_URL="http://biar-nifi:8088/nifi-api"
    ;;
  keycloak)
    BASE_URL="https://biar-nifi:${NIFI_HTTPS_INTERNAL_PORT:-8443}/nifi-api"
    ;;
  *)
    echo "Unsupported NIFI_AUTH value: ${NIFI_AUTH} (expected none or keycloak)"
    exit 1
    ;;
esac

nifi_curl() {
  if [ "$NIFI_AUTH_MODE" = "keycloak" ]; then
    curl --cacert "$MACHINE_IDENTITY_DIR/ca.crt" \
      --cert "$MACHINE_IDENTITY_DIR/machine.crt" \
      --key "$MACHINE_IDENTITY_DIR/machine.key" \
      "$@"
  else
    curl "$@"
  fi
}

echo "NiFi auth mode: $NIFI_AUTH_MODE ($BASE_URL)"
PB_SENSITIVE_FALSE="${PB_SENSITIVE_FALSE:-${PB_SENSITIVE:-false}}"

echo "Waiting for NiFi API to be ready..."

# Wait until parameter-context API responds properly, with bounded retries.
WAIT_RETRIES="${NIFI_API_WAIT_RETRIES:-60}"
WAIT_DELAY_SECONDS="${NIFI_API_WAIT_DELAY_SECONDS:-5}"
WAIT_ATTEMPT=1

while [ "$WAIT_ATTEMPT" -le "$WAIT_RETRIES" ]; do
  if nifi_curl -s "$BASE_URL/flow/parameter-contexts" | grep -q "parameterContexts"; then
    break
  fi
  echo "NiFi API not ready yet (attempt $WAIT_ATTEMPT/$WAIT_RETRIES), retrying in ${WAIT_DELAY_SECONDS}s..."
  WAIT_ATTEMPT=$((WAIT_ATTEMPT + 1))
  sleep "$WAIT_DELAY_SECONDS"
done

if [ "$WAIT_ATTEMPT" -gt "$WAIT_RETRIES" ]; then
  echo "NiFi API did not become ready after $WAIT_RETRIES attempts"
  exit 1
fi

echo "NiFi API is ready"

CORE_PG_HOST="${CORE_PG_HOST:-}"
CORE_PG_PORT="${CORE_PG_PORT:-15432}"
CMS_PG_HOST="${CMS_PG_HOST:-}"
CMS_PG_PORT="${CMS_PG_PORT:-15433}"
PG_USER="${PG_USER:-postgres}"
PG_PASSWORD="${PG_PASSWORD:-}"
S3A_ACCESS_KEY="${S3A_ACCESS_KEY:-}"
S3A_SECRET_KEY="${S3A_SECRET_KEY:-}"

# Build the full parameter list (JSON fragments) from environment variables.
# Sensitive parameters (pg_password, ozone keys) are stored encrypted by NiFi
# and are never returned by the REST API once set.
# Values are JSON-escaped with a sed pass because user-supplied secrets may
# contain quotes or backslashes, and the runtime image (curlimages/curl) does
# not ship jq.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

PARAM_FRAGMENTS=""
add_param_fragment() {
  _name="$1"
  _value="$2"
  _sensitive="$3"
  _escaped_value=$(json_escape "$_value")
  if [ -n "$PARAM_FRAGMENTS" ]; then
    PARAM_FRAGMENTS="$PARAM_FRAGMENTS,"
  fi
  PARAM_FRAGMENTS="$PARAM_FRAGMENTS{\"parameter\":{\"name\":\"$_name\",\"value\":\"$_escaped_value\",\"sensitive\":$_sensitive}}"
}

add_param_fragment "$PB_NAME" "$PB_BUCKET" "$PB_SENSITIVE_FALSE"
add_param_fragment "$PB_HTTP_NAME" "$PB_HTTP_VALUE" "$PB_SENSITIVE_FALSE"
add_param_fragment "$PB_OZONE_NAME" "$PB_OZONE_ENDPOINT" "$PB_SENSITIVE_FALSE"
add_param_fragment "core_pg_host" "$CORE_PG_HOST" false
add_param_fragment "core_pg_port" "$CORE_PG_PORT" false
add_param_fragment "cms_pg_host" "$CMS_PG_HOST" false
add_param_fragment "cms_pg_port" "$CMS_PG_PORT" false
add_param_fragment "pg_user" "$PG_USER" false
add_param_fragment "pg_password" "$PG_PASSWORD" true
add_param_fragment "ozone_access_key" "$S3A_ACCESS_KEY" true
add_param_fragment "ozone_secret_key" "$S3A_SECRET_KEY" true

echo "Creating Parameter Context..."

CREATE_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X POST "$BASE_URL/parameter-contexts" \
  -H "Content-Type: application/json" \
  -d "{
    \"revision\": { \"version\": 0 },
    \"component\": {
      \"name\": \"$PB_CONTEXT_NAME\",
      \"parameters\": [ $PARAM_FRAGMENTS ]
    }
  }")

HTTP_CODE=$(echo "$CREATE_RESPONSE" | tail -n1)
BODY=$(echo "$CREATE_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "201" ] && [ "$HTTP_CODE" != "409" ]; then
  echo "Failed to create Parameter Context"
  echo "$BODY"
  exit 1
fi

echo "Parameter Context created or already exists"

echo "Fetching Parameter Context ID..."

# Retry until context appears
for i in $(seq 1 10); do
  PARAM_CONTEXT_ID=$(nifi_curl -s "$BASE_URL/flow/parameter-contexts" \
    | tr -d '\n' \
    | sed 's/.*"parameterContexts":\[\(.*\)\].*/\1/' \
    | sed 's/},{/}\n{/g' \
    | grep "\"name\":\"$PB_CONTEXT_NAME\"" \
    | grep -o '"id":"[^"]*"' \
    | head -n 1 \
    | cut -d'"' -f4)

  if [ -n "$PARAM_CONTEXT_ID" ]; then
    break
  fi

  echo "Waiting for Parameter Context to appear..."
  sleep 3
done

if [ -z "$PARAM_CONTEXT_ID" ]; then
  echo "Parameter Context still not found after retries"
  exit 1
fi

echo "Parameter Context ID: $PARAM_CONTEXT_ID"

echo "Ensuring required parameters exist in context..."

CONTEXT_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" "$BASE_URL/parameter-contexts/$PARAM_CONTEXT_ID")
CONTEXT_HTTP_CODE=$(echo "$CONTEXT_RESPONSE" | tail -n1)
CONTEXT_BODY=$(echo "$CONTEXT_RESPONSE" | sed '$d')

if [ "$CONTEXT_HTTP_CODE" != "200" ]; then
  echo "Failed to fetch Parameter Context details"
  echo "$CONTEXT_BODY"
  exit 1
fi

UPDATED_PARAMETERS_JSON=""
PARAMS_UPDATED=false

# Ensure every required parameter exists in the context. Sensitive values are
# returned masked by NiFi, so existence is checked by name only, and only the
# MISSING parameters are sent on update (omitted parameters keep their values).
ensure_param() {
  _name="$1"
  _value="$2"
  _sensitive="$3"
  if echo "$CONTEXT_BODY" | tr -d '\n' | grep -q "\"name\":\"$_name\""; then
    return 0
  fi
  _escaped_value=$(json_escape "$_value")
  if [ -n "$UPDATED_PARAMETERS_JSON" ]; then
    UPDATED_PARAMETERS_JSON="$UPDATED_PARAMETERS_JSON,"
  fi
  UPDATED_PARAMETERS_JSON="$UPDATED_PARAMETERS_JSON{\"parameter\":{\"name\":\"$_name\",\"value\":\"$_escaped_value\",\"sensitive\":$_sensitive}}"
  PARAMS_UPDATED=true
}

ensure_param "$PB_NAME" "$PB_BUCKET" "$PB_SENSITIVE_FALSE"
ensure_param "$PB_HTTP_NAME" "$PB_HTTP_VALUE" "$PB_SENSITIVE_FALSE"
ensure_param "$PB_OZONE_NAME" "$PB_OZONE_ENDPOINT" "$PB_SENSITIVE_FALSE"
ensure_param "core_pg_host" "$CORE_PG_HOST" false
ensure_param "core_pg_port" "$CORE_PG_PORT" false
ensure_param "cms_pg_host" "$CMS_PG_HOST" false
ensure_param "cms_pg_port" "$CMS_PG_PORT" false
ensure_param "pg_user" "$PG_USER" false
ensure_param "pg_password" "$PG_PASSWORD" true
ensure_param "ozone_access_key" "$S3A_ACCESS_KEY" true
ensure_param "ozone_secret_key" "$S3A_SECRET_KEY" true

if [ "$PARAMS_UPDATED" = "true" ]; then
  CONTEXT_REVISION_VERSION=$(echo "$CONTEXT_BODY" \
    | tr -d '\n' \
    | sed -n 's/.*"revision":[[:space:]]*{[^}]*"version":[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
    | head -n 1)

  if [ -z "$CONTEXT_REVISION_VERSION" ]; then
    echo "Failed to determine context revision version"
    exit 1
  fi

  UPDATE_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/parameter-contexts/$PARAM_CONTEXT_ID" \
    -H "Content-Type: application/json" \
    -d "{
      \"revision\": { \"version\": $CONTEXT_REVISION_VERSION },
      \"id\": \"$PARAM_CONTEXT_ID\",
      \"component\": {
        \"id\": \"$PARAM_CONTEXT_ID\",
        \"parameters\": [ $UPDATED_PARAMETERS_JSON ]
      }
    }")

  UPDATE_HTTP_CODE=$(echo "$UPDATE_RESPONSE" | tail -n1)
  UPDATE_BODY=$(echo "$UPDATE_RESPONSE" | sed '$d')

  if [ "$UPDATE_HTTP_CODE" != "200" ]; then
    echo "Failed to update required parameters in context"
    echo "$UPDATE_BODY"
    exit 1
  fi

  echo "Required parameters were added to existing context"
else
  echo "Required parameters already exist"
fi

echo "Fetching Root Process Group ID..."

ROOT_PG_ID=$(nifi_curl -s "$BASE_URL/flow/process-groups/root" \
  | tr -d '\n' \
  | awk -F'"id":"' '{print $2}' \
  | cut -d'"' -f1 \
  | head -n 1)

if [ -z "$ROOT_PG_ID" ]; then
  echo "Failed to determine Root Process Group ID"
  exit 1
fi

echo "Root PG ID: $ROOT_PG_ID"

TEMPLATE_TARGET_PG_ID="${NIFI_TEMPLATE_TARGET_PG_ID:-$ROOT_PG_ID}"

echo "Fetching revision..."

REVISION_VERSION=$(nifi_curl -s "$BASE_URL/process-groups/$ROOT_PG_ID" \
  | tr -d '\n' \
  | sed -n 's/.*"version":\([0-9]*\).*/\1/p' \
  | head -n 1)

if [ -z "$REVISION_VERSION" ]; then
  echo "Failed to determine revision for process group: $ROOT_PG_ID"
  exit 1
fi

echo "Revision: $REVISION_VERSION"

echo "Applying Parameter Context..."

nifi_curl -s -X PUT "$BASE_URL/process-groups/$ROOT_PG_ID" \
  -H "Content-Type: application/json" \
  -d "{
    \"revision\": { \"version\": $REVISION_VERSION },
    \"component\": {
      \"id\": \"$ROOT_PG_ID\",
      \"parameterContext\": {
        \"id\": \"$PARAM_CONTEXT_ID\"
      }
    }
  }" >/dev/null

echo "Parameter Context applied successfully"

IMPORT_NIFI_TEMPLATE="${IMPORT_NIFI_TEMPLATE:-true}"

# Instantiating a template always creates new components, so a rerun must not
# import it again once the flow is on the canvas.
flow_present() {
  nifi_curl -s "$BASE_URL/flow/process-groups/$TEMPLATE_TARGET_PG_ID" \
    | tr -d '\n' \
    | grep -q '"processors":\[{'
}

TEMPLATE_ALREADY_PRESENT=false

if [ "$IMPORT_NIFI_TEMPLATE" = "true" ] && flow_present; then
  echo "Flow already present in process group $TEMPLATE_TARGET_PG_ID; skipping template import"
  TEMPLATE_ALREADY_PRESENT=true
elif [ "$IMPORT_NIFI_TEMPLATE" = "true" ]; then
  TEMPLATE_FILE="${NIFI_TEMPLATE_FILE:-/nifi/tazama.xml}"
  TEMPLATE_X="${NIFI_TEMPLATE_X:-0.0}"
  TEMPLATE_Y="${NIFI_TEMPLATE_Y:-0.0}"

  if [ ! -f "$TEMPLATE_FILE" ]; then
    echo "Template import enabled but file not found: $TEMPLATE_FILE"
    exit 1
  fi

  TEMPLATE_NAME=$(tr -d '\n' < "$TEMPLATE_FILE" | sed -n 's:.*<name>[[:space:]]*\([^<]*\)[[:space:]]*</name>.*:\1:p' | head -n 1)
  TEMPLATE_ID=""

  echo "Uploading NiFi template from $TEMPLATE_FILE ..."

  UPLOAD_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X POST \
    "$BASE_URL/process-groups/$TEMPLATE_TARGET_PG_ID/templates/upload" \
    -H "Content-Type: multipart/form-data" \
    -F "template=@$TEMPLATE_FILE")

  UPLOAD_HTTP_CODE=$(echo "$UPLOAD_RESPONSE" | tail -n1)
  UPLOAD_BODY=$(echo "$UPLOAD_RESPONSE" | sed '$d')

  if [ "$UPLOAD_HTTP_CODE" != "201" ] && [ "$UPLOAD_HTTP_CODE" != "200" ]; then
    if echo "$UPLOAD_BODY" | grep -qi "already exists"; then
      echo "Template already exists in NiFi, reusing existing template ID"

      EXISTING_TEMPLATE_NAME=$(echo "$UPLOAD_BODY" | sed -n "s/.*template named '\([^']*\)'.*/\1/p" | head -n 1)
      if [ -z "$EXISTING_TEMPLATE_NAME" ]; then
        EXISTING_TEMPLATE_NAME="$TEMPLATE_NAME"
      fi

      TEMPLATES_BODY=$(nifi_curl -s "$BASE_URL/flow/templates")
      TEMPLATE_ID=$(echo "$TEMPLATES_BODY" \
        | tr -d '\n' \
        | sed 's/},{/}\n{/g' \
        | grep "\"name\":\"$EXISTING_TEMPLATE_NAME\"" \
        | sed -n 's/.*"template":{[^}]*"id":"\([^"]*\)".*/\1/p' \
        | head -n 1)

      if [ -z "$TEMPLATE_ID" ]; then
        TEMPLATE_ID=$(echo "$TEMPLATES_BODY" \
          | tr -d '\n' \
          | sed 's/},{/}\n{/g' \
          | grep "\"name\":\"$EXISTING_TEMPLATE_NAME\"" \
        | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' \
        | head -n 1)
      fi

      if [ -z "$TEMPLATE_ID" ]; then
        echo "Template exists but could not resolve template ID for name: $EXISTING_TEMPLATE_NAME"
        echo "$UPLOAD_BODY"
        exit 1
      fi
    else
      echo "Template upload failed"
      echo "$UPLOAD_BODY"
      exit 1
    fi
  fi

  if [ -z "$TEMPLATE_ID" ]; then
    TEMPLATE_ID=$(echo "$UPLOAD_BODY" \
      | tr -d '\n' \
      | sed -n 's/.*"template"[[:space:]]*:[[:space:]]*{[^}]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -n 1)

    if [ -z "$TEMPLATE_ID" ]; then
      TEMPLATE_ID=$(echo "$UPLOAD_BODY" \
        | tr -d '\n' \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
        | head -n 1)
    fi

    # The upload endpoint answers in XML (<templateEntity><template><id>...</id>).
    # Take the first <id> element.
    if [ -z "$TEMPLATE_ID" ]; then
      TEMPLATE_ID=$(echo "$UPLOAD_BODY" \
        | tr -d '\n' \
        | sed -n 's:</id>.*::; s:.*<id>\([^<]*\)$:\1:p' \
        | head -n 1)
    fi
  fi

  if [ -z "$TEMPLATE_ID" ]; then
    echo "Unable to extract template ID from upload response"
    echo "$UPLOAD_BODY"
    exit 1
  fi

  echo "Instantiating template ID: $TEMPLATE_ID"

  INSTANTIATE_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X POST \
    "$BASE_URL/process-groups/$TEMPLATE_TARGET_PG_ID/template-instance" \
    -H "Content-Type: application/json" \
    -d "{
      \"templateId\": \"$TEMPLATE_ID\",
      \"originX\": $TEMPLATE_X,
      \"originY\": $TEMPLATE_Y
    }")

  INSTANTIATE_HTTP_CODE=$(echo "$INSTANTIATE_RESPONSE" | tail -n1)
  INSTANTIATE_BODY=$(echo "$INSTANTIATE_RESPONSE" | sed '$d')

  if [ "$INSTANTIATE_HTTP_CODE" != "201" ] && [ "$INSTANTIATE_HTTP_CODE" != "200" ] && [ "$INSTANTIATE_HTTP_CODE" != "409" ]; then
    echo "Template instantiation failed"
    echo "$INSTANTIATE_BODY"
    exit 1
  fi

  echo "Template imported and instantiated successfully"

  if [ "$INSTANTIATE_HTTP_CODE" = "201" ] || [ "$INSTANTIATE_HTTP_CODE" = "200" ]; then
    # The template import strips sensitive properties, so the new controller
    # services have no passwords. Set them from biar/secrets.env while the
    # services are still disabled. Existing flows are never touched: rotate
    # these values in the NiFi UI.
    echo "Setting controller service credentials..."

    SERVICES_BODY=$(nifi_curl -s \
      "$BASE_URL/flow/process-groups/$TEMPLATE_TARGET_PG_ID/controller-services?includeAncestorGroups=false&includeDescendantGroups=true" \
      | tr -d '\n' \
      | sed 's/{"revision":/\n{"revision":/g')

    json_escape() {
      printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
    }

    # $1 = service name, $2 = service type, $3 = JSON object of properties
    set_service_properties() {
      SERVICE_LINE=$(printf '%s\n' "$SERVICES_BODY" \
        | grep "\"name\":\"$1\"" \
        | grep "\"type\":\"$2\"" \
        | head -n 1)
      SERVICE_ID=$(printf '%s' "$SERVICE_LINE" \
        | sed 's/^{"revision":{[^}]*}//' \
        | grep -o '"id":"[^"]*"' \
        | head -n 1 \
        | cut -d'"' -f4)
      SERVICE_VERSION=$(printf '%s' "$SERVICE_LINE" \
        | sed -n 's/^{"revision":{[^}]*"version":\([0-9][0-9]*\).*/\1/p')

      if [ -z "$SERVICE_ID" ] || [ -z "$SERVICE_VERSION" ]; then
        echo "WARNING: controller service '$1' not found; set its credentials in the NiFi UI"
        return 0
      fi

      # Read the body from stdin so the values never appear in the process list
      SERVICE_HTTP_CODE=$(printf '{"revision":{"version":%s},"component":{"id":"%s","properties":%s}}' \
          "$SERVICE_VERSION" "$SERVICE_ID" "$3" \
        | nifi_curl -s -o /dev/null -w "%{http_code}" -X PUT "$BASE_URL/controller-services/$SERVICE_ID" \
          -H "Content-Type: application/json" \
          --data-binary @-)

      if [ "$SERVICE_HTTP_CODE" = "200" ]; then
        echo "Credentials set on controller service '$1'"
      else
        echo "WARNING: setting credentials on '$1' failed (HTTP $SERVICE_HTTP_CODE); set them in the NiFi UI"
      fi
    }

    DBCP_TYPE="org.apache.nifi.dbcp.DBCPConnectionPool"
    AWS_TYPE="org.apache.nifi.processors.aws.credentials.provider.service.AWSCredentialsProviderControllerService"
    CORE_PG_PROPERTIES="{\"Password\":\"$(json_escape "$TAZAMA_CORE_PG_PASSWORD")\"}"
    EXT_PG_PROPERTIES="{\"Password\":\"$(json_escape "$TAZAMA_EXT_PG_PASSWORD")\"}"
    S3_PROPERTIES="{\"Access Key\":\"$(json_escape "$TAZAMA_S3_ACCESS_KEY")\",\"Secret Key\":\"$(json_escape "$TAZAMA_S3_SECRET_KEY")\"}"

    for DB in evaluation enrichment raw_history event_history configuration; do
      set_service_properties "$DB" "$DBCP_TYPE" "$CORE_PG_PROPERTIES"
    done
    set_service_properties tazama_cms "$DBCP_TYPE" "$EXT_PG_PROPERTIES"
    set_service_properties AWSCredentialsProviderControllerService "$AWS_TYPE" "$S3_PROPERTIES"
  fi
else
  echo "Template import skipped (IMPORT_NIFI_TEMPLATE=false)"
fi

# Enable services and start the flow only for a newly instantiated template.
# On a re-run where the flow already exists (TEMPLATE_ALREADY_PRESENT=true)
# the operator's current state - including a deliberately stopped flow -
# must be preserved, so no state changes are issued.
if [ "${IMPORT_NIFI_TEMPLATE:-true}" = "true" ] && [ "$TEMPLATE_ALREADY_PRESENT" != "true" ] && [ "${NIFI_AUTO_START:-true}" = "true" ]; then
    echo "Enabling controller services..."

    ENABLE_RETRIES="${NIFI_ENABLE_RETRIES:-30}"
    ENABLE_DELAY_SECONDS="${NIFI_ENABLE_DELAY_SECONDS:-5}"
    ENABLE_ATTEMPT=1
    SERVICES_ENABLED=false

    while [ "$ENABLE_ATTEMPT" -le "$ENABLE_RETRIES" ]; do
      ENABLE_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/flow/process-groups/$TEMPLATE_TARGET_PG_ID/controller-services" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"$TEMPLATE_TARGET_PG_ID\", \"state\": \"ENABLED\"}")
      ENABLE_HTTP_CODE=$(echo "$ENABLE_RESPONSE" | tail -n1)
      ENABLE_BODY=$(echo "$ENABLE_RESPONSE" | sed '$d')

      if [ "$ENABLE_HTTP_CODE" != "200" ]; then
        echo "WARNING: enable request returned HTTP $ENABLE_HTTP_CODE (attempt $ENABLE_ATTEMPT/$ENABLE_RETRIES)"
        echo "$ENABLE_BODY"
      fi

      SERVICES_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" "$BASE_URL/flow/process-groups/$TEMPLATE_TARGET_PG_ID/controller-services")
      SERVICES_HTTP_CODE=$(echo "$SERVICES_RESPONSE" | tail -n1)
      SERVICES_BODY=$(echo "$SERVICES_RESPONSE" | sed '$d')

      # Only trust a successful, well-formed response. A failed or empty
      # read must not be mistaken for "all services enabled".
      if [ "$SERVICES_HTTP_CODE" != "200" ] || ! echo "$SERVICES_BODY" | tr -d '\n' | grep -q '"controllerServices"'; then
        echo "WARNING: controller-services query returned HTTP $SERVICES_HTTP_CODE (attempt $ENABLE_ATTEMPT/$ENABLE_RETRIES), retrying"
        ENABLE_ATTEMPT=$((ENABLE_ATTEMPT + 1))
        sleep "$ENABLE_DELAY_SECONDS"
        continue
      fi

      NOT_ENABLED_COUNT=$(echo "$SERVICES_BODY" \
        | tr -d '\n' \
        | sed 's/},{/}\n{/g' \
        | grep -c '"state":"DISABLED"\|"state":"ENABLING"\|"state":"DISABLING"' || true)

      if [ "$NOT_ENABLED_COUNT" = "0" ]; then
        echo "All controller services are ENABLED"
        SERVICES_ENABLED=true
        break
      fi

      echo "Waiting for controller services to enable (attempt $ENABLE_ATTEMPT/$ENABLE_RETRIES, $NOT_ENABLED_COUNT pending)..."
      ENABLE_ATTEMPT=$((ENABLE_ATTEMPT + 1))
      sleep "$ENABLE_DELAY_SECONDS"
    done

    if [ "$SERVICES_ENABLED" != "true" ]; then
      echo "ERROR: controller services did not reach ENABLED after $ENABLE_RETRIES attempts - not starting the flow"
      exit 1
    fi

    echo "Starting flow..."

    START_RETRIES="${NIFI_START_RETRIES:-10}"
    START_ATTEMPT=1
    FLOW_STARTED=false

    while [ "$START_ATTEMPT" -le "$START_RETRIES" ]; do
      START_RESPONSE=$(nifi_curl -s -w "\n%{http_code}" -X PUT "$BASE_URL/flow/process-groups/$TEMPLATE_TARGET_PG_ID" \
        -H "Content-Type: application/json" \
        -d "{\"id\": \"$TEMPLATE_TARGET_PG_ID\", \"state\": \"RUNNING\"}")
      START_HTTP_CODE=$(echo "$START_RESPONSE" | tail -n1)
      START_BODY=$(echo "$START_RESPONSE" | sed '$d')

      if [ "$START_HTTP_CODE" = "200" ]; then
        echo "Flow started successfully"
        FLOW_STARTED=true
        break
      fi

      echo "Flow start returned HTTP $START_HTTP_CODE (attempt $START_ATTEMPT/$START_RETRIES)"
      echo "$START_BODY"
      START_ATTEMPT=$((START_ATTEMPT + 1))
      sleep "$ENABLE_DELAY_SECONDS"
    done

    if [ "$FLOW_STARTED" != "true" ]; then
      echo "ERROR: flow did not start after $START_RETRIES attempts"
      exit 1
    fi
else
  if [ "$TEMPLATE_ALREADY_PRESENT" = "true" ]; then
    echo "Flow already present - leaving services and flow state untouched (use the NiFi UI to manage an existing flow)"
  else
    echo "Auto enable/start skipped (NIFI_AUTO_START=false)"
  fi
fi

echo "Init script finished"
