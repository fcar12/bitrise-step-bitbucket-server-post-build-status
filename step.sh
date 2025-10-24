#!/usr/bin/env bash

# Exit early if manually triggered
if [ "$BITRISE_TRIGGER_METHOD" = "manual" ]; then
  echo "- Build triggered manually, skipping"
  exit 0
fi

join_ws() { local IFS=; local s="${*/#/$1}"; echo "${s#"$1$1$1"}"; }
joinStrings() { local a=("${@:3}"); printf "%s" "$2${a[@]/#/$1}"; }

INVALID_INPUT=false
if [ -z "$domain" ]; then
  INVALID_INPUT=true
  echo "- Missing input field: domain"
fi

# username/password are required unless client_cert+client_key will be used
# (we'll validate cert/key later). Only mark missing username/password as an error
# if cert auth is not provided.
if [ -z "$client_cert" ] || [ -z "$client_key" ]; then
  if [ -z "$username" ]; then
    INVALID_INPUT=true
    echo "- Missing input field: username"
  fi

  if [ -z "$password" ]; then
    INVALID_INPUT=true
    echo "- Missing input field: password"
  fi
fi

if [ -z "$git_clone_commit_hash" ]; then
  git_clone_commit_hash=`git rev-parse HEAD`

  echo "- Missing input field: git_clone_commit_hash, falling back to 'git rev-parse HEAD' ($git_clone_commit_hash)"

  if [ -z "$git_clone_commit_hash" ]; then
    echo "- Unable to get git commit from current directory or git_clone_commit_hash input field"
    INVALID_INPUT=true
  fi
fi

if [ -z "$app_title" ]; then
  INVALID_INPUT=true
  echo "- Missing input field: app_title"
fi

if [ -z "$build_number" ]; then
  INVALID_INPUT=true
  echo "- Missing input field: build_number"
fi

if [ -z "$build_url" ]; then
  INVALID_INPUT=true
  echo "- Missing input field: build_url"
fi

if [ -z "$triggered_workflow_id" ]; then
  INVALID_INPUT=true
  echo "- Missing input field: triggered_workflow_id"
fi

# Optional client certificate auth (mTLS)
# If provided, both client_cert and client_key must be set. They can be paths to PEM files
# or inline PEM contents. If inline content is provided, the script writes them to temp files.
USE_CERT_AUTH=false
CERT_TEMP_FILES=()
cleanup_certs() {
  for f in "${CERT_TEMP_FILES[@]}"; do
    if [ -n "$f" ] && [ -f "$f" ]; then
      rm -f "$f"
    fi
  done
}
trap cleanup_certs EXIT

if [ -n "$client_cert" ] || [ -n "$client_key" ]; then
  if [ -z "$client_cert" ] || [ -z "$client_key" ]; then
    echo "- If using client_cert/client_key both must be provided"
    INVALID_INPUT=true
  else
    # helper to ensure value is a file; if not, write to temp file
    mktemp_and_maybe_write() {
      local val="$1"
      if [ -f "$val" ]; then
        echo "$val"
        return 0
      fi
      local tmp
      tmp="$(mktemp)" || return 1
      echo "$val" > "$tmp"
      echo "$tmp"
    }

    CERT_FILE_PATH="$(mktemp_and_maybe_write "$client_cert")" || CERT_FILE_PATH=""
    KEY_FILE_PATH="$(mktemp_and_maybe_write "$client_key")" || KEY_FILE_PATH=""

    if [ -z "$CERT_FILE_PATH" ] || [ -z "$KEY_FILE_PATH" ]; then
      echo "- Unable to prepare client_cert/client_key files"
      INVALID_INPUT=true
    else
      # if mktemp_and_maybe_write produced temp files (not original paths), remember to cleanup
      if [ ! -f "$client_cert" ]; then CERT_TEMP_FILES+=("$CERT_FILE_PATH"); fi
      if [ ! -f "$client_key" ]; then CERT_TEMP_FILES+=("$KEY_FILE_PATH"); fi
      USE_CERT_AUTH=true
    fi
  fi
fi

if [ -n "$preset_status" ] && [ "$preset_status" != "AUTO" ]; then
  if [ "$preset_status" == "INPROGRESS" ] || [ "$preset_status" == "SUCCESSFUL" ] || [ "$preset_status" == "FAILED" ]; then
    BITBUCKET_BUILD_STATE=$preset_status
  else
    echo "- Invalid preset_status, must be one of [\"AUTO\", \"INPROGRESS\", \"SUCCESSFUL\", \"FAILED\"]"
    INVALID_INPUT=true
  fi
elif [ -z "$BITRISE_BUILD_STATUS" ]; then
  echo "- Missing env var: \$BITRISE_BUILD_STATUS"
  INVALID_INPUT=true
elif [ "$BITRISE_BUILD_STATUS" == "0" ]; then
  BITBUCKET_BUILD_STATE="SUCCESSFUL"
elif [ "$BITRISE_BUILD_STATUS" == "1" ]; then
  BITBUCKET_BUILD_STATE="FAILED"
else
  echo "- Invalid \$BITRISE_BUILD_STATUS. Should be \"0\" or \"1\", not '$BITRISE_BUILD_STATUS'"
  INVALID_INPUT=true
fi

if [ "$INVALID_INPUT" == true ]; then
  exit 1
fi

# Print non-sensitive inputs for debugging (do NOT print secrets: password, client_cert, client_key)
echo "--- step inputs (non-sensitive) ---"
echo "- domain: $domain"
echo "- username: $username"
echo "- preset_status: ${preset_status:-AUTO}"
echo "- BITRISE_BUILD_STATUS: ${BITRISE_BUILD_STATUS:-<unset>}"
echo "- computed Bitbucket state: ${BITBUCKET_BUILD_STATE:-<unset>}"
echo "- git_clone_commit_hash: ${git_clone_commit_hash:-<unset>}"
echo "- app_title: ${app_title:-<unset>}"
echo "- build_number: ${build_number:-<unset>}"
echo "- build_url: ${build_url:-<unset>}"
echo "- triggered_workflow_id: ${triggered_workflow_id:-<unset>}"
echo "- using_cert_auth: $USE_CERT_AUTH"
echo "- trigger_method: $BITRISE_TRIGGER_METHOD"
echo "-----------------------------------"

BITBUCKET_API_ENDPOINT="https://$domain/rest/build-status/1.0/commits/$git_clone_commit_hash"

echo "Post build status: $BITBUCKET_BUILD_STATE"
echo "API Endpoint: $BITBUCKET_API_ENDPOINT"

# Build curl auth args: prefer client cert/key if provided, otherwise use username:password
if [ "$USE_CERT_AUTH" = true ]; then
  CURL_AUTH_ARGS=(--cert "$CERT_FILE_PATH" --key "$KEY_FILE_PATH")
else
  CURL_AUTH_ARGS=(-u "$username:$password")
fi

# Bitbucket is storing a build status per COMMIT_HASH && KEY.
#
# Updating the build status of an existing build from INPROGRESS to FAILED or SUCCESSFUL needs to have the SAME commit_hash AND key.
# Re-running a failed build with the same commit should also have the same key so the status is updated.
#
# Docs: https://developer.atlassian.com/server/bitbucket/how-tos/updating-build-status-for-commits/

curl "$BITBUCKET_API_ENDPOINT" \
  -X POST \
  -i \
  "${CURL_AUTH_ARGS[@]}" \
  -H 'Content-Type: application/json' \
  --data-binary \
      $"{
        \"state\": \"$BITBUCKET_BUILD_STATE\",
        \"key\": \"Bitrise - $BITRISE_BUILD_SLUG - Build $triggered_workflow_id - #$BITRISE_BUILD_NUMBER\",
        \"name\": \"Bitrise $app_title ($triggered_workflow_id) #$build_number\",
        \"url\": \"$build_url\",
        \"description\": \"workflow: $triggered_workflow_id\"
       }" \
   --compressed
