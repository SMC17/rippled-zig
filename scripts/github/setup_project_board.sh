#!/usr/bin/env bash
set -euo pipefail

# Bootstraps a GitHub Project v2 execution board for this repository.
# Requires gh auth token scopes: read:project, project.
# Usage:
#   scripts/github/setup_project_board.sh [owner] [repo] [title]

OWNER="${1:-SMC17}"
REPO="${2:-rippled-zig}"
TITLE="${3:-rippled-zig Execution Board}"
FULL_REPO="${OWNER}/${REPO}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required command not found: $1" >&2
    exit 1
  }
}

need_cmd gh
need_cmd jq

SCOPES="$(gh auth status 2>&1 | sed -n "s/.*Token scopes: '\(.*\)'/\1/p")"
if [[ "$SCOPES" != *"project"* ]]; then
  cat >&2 <<MSG
error: gh token is missing project scopes.
run:
  gh auth refresh -s read:project -s project
Then rerun this script.
MSG
  exit 1
fi

echo "Creating or reusing project: $TITLE"
existing_num="$(gh project list --owner "$OWNER" --format json --jq ".projects[] | select(.title == \"$TITLE\") | .number" | head -n1 || true)"
if [[ -n "$existing_num" ]]; then
  project_number="$existing_num"
  echo "Found existing project #$project_number"
else
  project_number="$(gh project create --owner "$OWNER" --title "$TITLE" --format json --jq .number)"
  echo "Created project #$project_number"
fi

project_url="$(gh project view "$project_number" --owner "$OWNER" --format json --jq .url)"
project_id="$(gh project view "$project_number" --owner "$OWNER" --format json --jq .id)"

echo "Linking repository to project"
gh project link "$project_number" --owner "$OWNER" --repo "$FULL_REPO" >/dev/null || true

ensure_field() {
  local field_name="$1"
  local options_csv="$2"

  local field_id
  field_id="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq ".fields[] | select(.name == \"$field_name\") | .id" | head -n1 || true)"
  if [[ -z "$field_id" ]]; then
    gh project field-create "$project_number" --owner "$OWNER" --name "$field_name" --data-type SINGLE_SELECT --single-select-options "$options_csv" >/dev/null
  fi
}

ensure_field "Lane" "Now,Next,Blocked,good-first"
ensure_field "Track" "control-plane,rpc,submit,gate-d,simulation,wasm,security,research"

lane_field_id="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Lane") | .id')"
track_field_id="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Track") | .id')"

lane_now_opt="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Lane") | .options[] | select(.name=="Now") | .id')"
lane_next_opt="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Lane") | .options[] | select(.name=="Next") | .id')"
lane_blocked_opt="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Lane") | .options[] | select(.name=="Blocked") | .id')"
lane_gfi_opt="$(gh project field-list "$project_number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Lane") | .options[] | select(.name=="good-first") | .id')"

track_opt_for_label() {
  local label="$1"
  gh project field-list "$project_number" --owner "$OWNER" --format json --jq ".fields[] | select(.name==\"Track\") | .options[] | select(.name==\"$label\") | .id"
}

echo "Adding open issues to project"
issues_json="$(gh issue list --repo "$FULL_REPO" --state open --limit 200 --json number,url,labels)"

while IFS= read -r issue_url; do
  [[ -z "$issue_url" ]] && continue
  gh project item-add "$project_number" --owner "$OWNER" --url "$issue_url" >/dev/null || true
done < <(printf '%s' "$issues_json" | jq -r '.[].url')

# Build a map from issue number to project item ID.
items_json="$(gh project item-list "$project_number" --owner "$OWNER" --limit 500 --format json)"

assign_fields_for_issue() {
  local number="$1"
  local labels_json="$2"

  local item_id
  item_id="$(printf '%s' "$items_json" | jq -r ".items[] | select(.content.number == $number) | .id" | head -n1)"
  [[ -z "$item_id" || "$item_id" == "null" ]] && return 0

  local lane_opt="$lane_next_opt"
  if printf '%s' "$labels_json" | jq -e '.[] | select(.name == "good first issue")' >/dev/null; then
    lane_opt="$lane_gfi_opt"
  fi
  if printf '%s' "$labels_json" | jq -e '.[] | select(.name == "priority:p0")' >/dev/null; then
    lane_opt="$lane_now_opt"
  fi
  if printf '%s' "$labels_json" | jq -e '.[] | select(.name == "blocked")' >/dev/null; then
    lane_opt="$lane_blocked_opt"
  fi

  gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$lane_field_id" --single-select-option-id "$lane_opt" >/dev/null || true

  for t in control-plane rpc submit gate-d simulation wasm security research; do
    if printf '%s' "$labels_json" | jq -e ".[] | select(.name == \"track:$t\")" >/dev/null; then
      opt_id="$(track_opt_for_label "$t")"
      if [[ -n "$opt_id" ]]; then
        gh project item-edit --id "$item_id" --project-id "$project_id" --field-id "$track_field_id" --single-select-option-id "$opt_id" >/dev/null || true
      fi
      break
    fi
  done
}

while IFS= read -r entry; do
  num="$(printf '%s' "$entry" | jq -r '.number')"
  labels="$(printf '%s' "$entry" | jq -c '.labels')"
  assign_fields_for_issue "$num" "$labels"
done < <(printf '%s' "$issues_json" | jq -c '.[]')

cat <<MSG
Done.
Project: $project_url
Suggested board setup in UI:
- Group by: Lane
- Save views: Now (Lane=Now), Next (Lane=Next), Blocked (Lane=Blocked), Good First (Lane=good-first)

For automatic issue intake, set:
- Repository variable: EXECUTION_PROJECT_URL=$project_url
- Repository secret: PROJECTS_TOKEN (PAT with read:project, project, repo)
MSG
