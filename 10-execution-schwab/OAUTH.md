# Schwab OAuth 2.0

The authentication flow. Every detail matters because the token is the
only thing standing between code and capital.

## 1. Token Lifetimes

| Token | Lifetime | Source |
|---|---|---|
| Access token | ~30 minutes |  |
| Refresh token | ~7 days |  |

The access token is short-lived. The refresh token is the long-lived
credential. When the refresh token expires, the account owner must
re-authorize manually.

## 2. The Flow

**Initial authorization (manual, once per refresh cycle):**

1. Build the authorization URL with the app key and redirect URI.
2. Owner visits the URL, logs in, approves the app.
3. Schwab redirects to the registered URI with an authorization code.
4. Exchange the code for an access token and a refresh token.
5. Store the refresh token in the state directory.

**Token refresh (automatic, every ~30 minutes):**

1. POST to the token endpoint with the refresh token.
2. Receive a new access token and (optionally) a new refresh token.
3. Update the stored refresh token if a new one is issued.

**Refresh token expiry (every ~7 days):**

1. The token endpoint returns an error.
2. Raise `BrokerAuthExpired`.
3. Halt all trading.
4. Notify the owner to re-authorize.

## 3. Storage

The refresh token is stored at:

    /mnt/cache/appdata/quant/state/schwab_refresh_token

Permissions: `0600` (owner read/write only). The container runs as UID
99 (Unraid `nobody`). The file is owned by 99:100.

**Do not** commit the token to Git. **Do not** log it. **Do not** store
it in a Parquet file. It is a credential, not data.

## 4. Error Handling

| Error | Meaning | Action |
|---|---|---|
| 401 Unauthorized | Access token expired or invalid | Refresh and retry once |
| 403 Forbidden | App not authorized for this endpoint | Log FAIL, halt |
| `BrokerAuthExpired` | Refresh token expired | Halt, notify owner |
| 429 Too Many Requests | Rate limit | Exponential backoff  |

## 5. Implementation Notes

The Rust adapter uses `reqwest` for the token POST. The request is:

    POST https://api.schwabapi.com/v1/oauth/token
    Content-Type: application/x-www-form-urlencoded
    Authorization: Basic {base64(app_key:app_secret)}
    
    grant_type=refresh_token&refresh_token={token}

The response is JSON with `access_token`, `refresh_token`, `expires_in`.
Store `expires_in` and refresh proactively at `expires_in - 60` seconds.

## 6. What Not to Do

- Do not hardcode the app key or secret. Read from environment.
- Do not store tokens in the Parquet lake.
- Do not log token values.
- Do not assume the refresh token never expires.
- Do not retry authorization failures more than once.