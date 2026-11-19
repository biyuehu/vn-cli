---
title: Sync
---

# Sync

SenaVN synchronizes your local library, playtime sessions, and metadata with a GitHub repository using 3-way merge conflict resolution.

---

## 1. Getting Your GitHub Personal Access Token

To allow SenaVN to read and write your backup repository, generate a Personal Access Token (PAT):

1. **Create a Backup Repository**:
   - Go to [GitHub](https://github.com/) and create a new repository (e.g. `sena-backup`).

2. **Generate Token**:
   - Click your profile photo in the top-right corner $\to$ **Settings**.
   - In the left sidebar, scroll down to the bottom and click **Developer settings**.
   - Under **Personal access tokens**, click **Tokens (classic)**.
   - Click **Generate new token** $\to$ **Generate new token (classic)**.
   - **Note**: Enter a description (e.g., `SenaVN Sync`).
   - **Expiration**: Select your preferred expiration period (e.g., `No expiration` or `90 days`).
   - **Select scopes**: Check the **`repo`** scope.
   - Scroll to the bottom and click **Generate token**.
   - Copy the generated token string (`ghp_...`). *(GitHub will not show it again).*

---

## 2. Configuration

Configure repository coordinates and your access token in SenaVN:

```sh
# Target repository in owner/repo format
sena config sync.repo "username/sena-backup"

# Personal Access Token generated above
sena config sync.token "ghp_xxxxxxxxxxxxxxxxxxxx"

# Optional: Target branch and data file path (defaults: main / data.json)
sena config sync.branch "main"
sena config sync.path "data.json"
```

---

## 3. Running Sync

```sh
# Perform full bidirectional synchronization
sena sync

# Simulate merge and preview planned changes without writing to DB or GitHub
sena sync --dry-run
```

---

## 4. How 3-Way Merge Works

```text
Local SQLite (sena.db) <====== 3-Way Merge ======> GitHub Repository (data.json)
```

1. **Last-Write-Wins (LWW)**: Game metadata is merged field-by-field. If conflicts occur, the newer `updateDate` takes precedence.
2. **Session Deduplication**: Play session timelines (`play_sessions`) are unioned and deduplicated by session ID and timestamps.
3. **Tombstone Propagation**: Hard-deleted games (`sena rm <id> -H`) record an atomic tombstone in `deleted_games`. Sync propagates tombstones to cloud and deletes matching records on other synced devices.
4. **Resurrection Safety**: If a game was deleted on one machine but modified or played on another with a newer timestamp, it automatically resurrects and clears historical tombstones.
