# GitHub Projects Setup

Status: bootstrap guide for execution board automation.

## Goal
Create a Project v2 board with lanes:
- `Now`
- `Next`
- `Blocked`
- `good-first`

And automate issue intake/routing by labels.

## One-Time Prerequisites
1. Refresh `gh` scopes locally:
```bash
gh auth refresh -s read:project -s project
```
2. Ensure `jq` is installed.

## Bootstrap Project Board
Run:
```bash
scripts/github/setup_project_board.sh
```

This script will:
- create/reuse project `rippled-zig Execution Board`
- link repo
- create fields `Lane` and `Track`
- add open issues to the board
- assign default lane/track from labels

## Save Board Views (UI)
After script completes, open the project URL and create saved views:
1. `Now` view: filter `Lane:Now`
2. `Next` view: filter `Lane:Next`
3. `Blocked` view: filter `Lane:Blocked`
4. `Good First` view: filter `Lane:good-first`

Recommended grouping: `Group by Lane`.

## Enable Automation Workflow
Workflow file: `.github/workflows/project-intake.yml`

Set repository settings:
1. Repository variable:
- `EXECUTION_PROJECT_URL` = project URL from bootstrap output
2. Repository secret:
- `PROJECTS_TOKEN` = PAT with scopes `repo`, `read:project`, `project`

Behavior:
- On issue open/reopen/label changes, issue is auto-added to project.
- Lane is auto-set by labels:
  - `blocked` -> `Blocked`
  - `good first issue` -> `good-first`
  - `priority:p0` -> `Now`
  - else -> `Next`
- Track is auto-set from `track:*` labels.

## Operational Notes
- Without project scopes, project APIs fail; docs/issues still function.
- `PROJECT_STATUS.md` remains release-decision authority.
