#!/bin/bash
set -e

# Spice.ai Cloud Management API helper script
# Usage: bash scripts/spice-cloud.sh <command> [args...]
# Calls the canonical /v1/projects routes (apps were renamed to projects; the
# legacy /v1/apps routes and the *-app command names below still work).

BASE_URL="https://api.spice.ai"

if [ -z "$SPICE_API_TOKEN" ] && [ "${1:-}" != "health" ]; then
  echo "Error: SPICE_API_TOKEN environment variable is not set" >&2
  echo "Use a personal access token (https://spice.ai/account/tokens) or an OAuth client-credentials access token" >&2
  exit 1
fi

AUTH_HEADER="Authorization: Bearer $SPICE_API_TOKEN"

api_get() {
  curl -sf -H "$AUTH_HEADER" "$BASE_URL$1"
}

api_post() {
  curl -sf -X POST -H "$AUTH_HEADER" -H "Content-Type: application/json" "$BASE_URL$1" -d "$2"
}

api_put() {
  curl -sf -X PUT -H "$AUTH_HEADER" -H "Content-Type: application/json" "$BASE_URL$1" -d "$2"
}

api_delete() {
  curl -sf -X DELETE -H "$AUTH_HEADER" "$BASE_URL$1"
}

usage() {
  echo "Usage: spice-cloud.sh <command> [args...]" >&2
  echo "" >&2
  echo "Commands (aliases in parentheses):" >&2
  echo "  health                                  Check API health (no token needed)" >&2
  echo "  list-regions                            List available regions" >&2
  echo "  list-projects                           List projects (list-apps)" >&2
  echo "  get-project <projectId>                 Get project details (get-app)" >&2
  echo "  create-project <name> <region> [desc]   Create a project, region us-east-1|us-west-2 (create-app)" >&2
  echo "  update-project <projectId> <json>       Update project with JSON body (update-app)" >&2
  echo "  delete-project <projectId>              Delete a project (delete-app)" >&2
  echo "  fork-project <projectId> [name] [region] Fork a project; the fork is not deployed" >&2
  echo "  list-forks <projectId>                  List the forks of a project" >&2
  echo "  list-deployments <projectId> [status]   List deployments" >&2
  echo "  deploy <projectId> [branch] [message]   Create a deployment" >&2
  echo "  list-secrets <projectId>                List secrets (values masked)" >&2
  echo "  add-secret <projectId> <name> <value>   Create or update a secret" >&2
  echo "  delete-secret <projectId> <name>        Delete a secret" >&2
  echo "  get-api-keys <projectId>                Get API keys" >&2
  echo "  rotate-key <projectId> [key_number]     Regenerate API key (1|2|0)" >&2
  echo "  list-members                            List org members" >&2
  echo "  add-member <username>                   Add org member" >&2
  echo "  remove-member <memberId>                Remove org member" >&2
  echo "  list-images [channel]                   List runtime image tags (stable|enterprise)" >&2
  exit 1
}

case "${1:-}" in
  health)
    curl -sf "$BASE_URL/v1/health"
    ;;
  list-regions)
    api_get "/v1/regions"
    ;;
  list-projects|list-apps)
    api_get "/v1/projects"
    ;;
  get-project|get-app)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    api_get "/v1/projects/$2"
    ;;
  create-project|create-app)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "Error: name and region required" >&2; exit 1; }
    BODY="{\"name\":\"$2\",\"region\":\"$3\""
    [ -n "${4:-}" ] && BODY="$BODY,\"description\":\"$4\""
    BODY="$BODY}"
    echo "Creating project '$2' in region '$3'..." >&2
    api_post "/v1/projects" "$BODY"
    ;;
  update-project|update-app)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "Error: projectId and JSON body required" >&2; exit 1; }
    echo "Updating project $2..." >&2
    api_put "/v1/projects/$2" "$3"
    ;;
  delete-project|delete-app)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    echo "Deleting project $2..." >&2
    api_delete "/v1/projects/$2"
    echo "Project $2 deleted" >&2
    ;;
  fork-project)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    BODY="{"
    SEP=""
    if [ -n "${3:-}" ]; then BODY="$BODY${SEP}\"name\":\"$3\""; SEP=","; fi
    if [ -n "${4:-}" ]; then BODY="$BODY${SEP}\"region\":\"$4\""; SEP=","; fi
    BODY="$BODY}"
    echo "Forking project $2..." >&2
    api_post "/v1/projects/$2/forks" "$BODY"
    ;;
  list-forks)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    api_get "/v1/projects/$2/forks"
    ;;
  list-deployments)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    STATUS_FILTER=""
    [ -n "${3:-}" ] && STATUS_FILTER="?status=$3"
    api_get "/v1/projects/$2/deployments$STATUS_FILTER"
    ;;
  deploy)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    BODY="{"
    SEP=""
    if [ -n "${3:-}" ]; then BODY="$BODY${SEP}\"branch\":\"$3\""; SEP=","; fi
    if [ -n "${4:-}" ]; then BODY="$BODY${SEP}\"commit_message\":\"$4\""; SEP=","; fi
    BODY="$BODY}"
    echo "Deploying project $2..." >&2
    api_post "/v1/projects/$2/deployments" "$BODY"
    ;;
  list-secrets)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    api_get "/v1/projects/$2/secrets"
    ;;
  add-secret)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] || [ -z "${4:-}" ] && { echo "Error: projectId, name, and value required" >&2; exit 1; }
    echo "Setting secret '$3' for project $2..." >&2
    api_post "/v1/projects/$2/secrets" "{\"name\":\"$3\",\"value\":\"$4\"}"
    ;;
  delete-secret)
    [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "Error: projectId and secret name required" >&2; exit 1; }
    echo "Deleting secret '$3' from project $2..." >&2
    api_delete "/v1/projects/$2/secrets/$3"
    echo "Secret '$3' deleted" >&2
    ;;
  get-api-keys)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    api_get "/v1/projects/$2/api-keys"
    ;;
  rotate-key)
    [ -z "${2:-}" ] && { echo "Error: projectId required" >&2; exit 1; }
    KEY_NUM="${3:-1}"
    echo "Regenerating API key $KEY_NUM for project $2..." >&2
    api_post "/v1/projects/$2/api-keys" "{\"key_number\":$KEY_NUM}"
    ;;
  list-members)
    api_get "/v1/members"
    ;;
  add-member)
    [ -z "${2:-}" ] && { echo "Error: username required" >&2; exit 1; }
    echo "Adding member '$2'..." >&2
    api_post "/v1/members" "{\"username\":\"$2\",\"roles\":[\"member\"]}"
    ;;
  remove-member)
    [ -z "${2:-}" ] && { echo "Error: memberId required" >&2; exit 1; }
    echo "Removing member $2..." >&2
    api_delete "/v1/members/$2"
    echo "Member $2 removed" >&2
    ;;
  list-images)
    CHANNEL="${2:-stable}"
    api_get "/v1/container-images?channel=$CHANNEL"
    ;;
  *)
    usage
    ;;
esac
