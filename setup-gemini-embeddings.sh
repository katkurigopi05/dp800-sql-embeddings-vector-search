#!/usr/bin/env bash
# Registers Google Gemini (free tier) as EmbeddingModel in the local SQL Server 2025 DP800 database.
# The API key is read with hidden input and only stored inside the database credential.
set -euo pipefail
cd "$(dirname "$0")"

set -a; source .env.sql2025; set +a
export SQLCMDPASSWORD="$SQL2025_PASSWORD"

CRED='https://generativelanguage.googleapis.com/v1beta/openai'

read -r -s -p "Paste your Gemini API key (input hidden): " GEMINI_KEY; echo

# Strip terminal bracketed-paste markers, whitespace, surrounding quotes and a "GEMINI_API_KEY=" prefix
GEMINI_KEY=$(printf '%s' "$GEMINI_KEY" | sed -e $'s/\e\\[20[01]~//g' | tr -d '[:space:]')
GEMINI_KEY=${GEMINI_KEY#*=}
GEMINI_KEY=${GEMINI_KEY//\"/}
GEMINI_KEY=${GEMINI_KEY//\'/}

# Only reject characters that would break the SQL/JSON secret; don't guess Google's key format
if [[ ${#GEMINI_KEY} -lt 20 || "$GEMINI_KEY" =~ [^[:print:]] || "$GEMINI_KEY" == *\\* ]]; then
  echo "Key rejected: length ${#GEMINI_KEY}, starts with '${GEMINI_KEY:0:4}'." >&2
  echo "Unusual characters: '$(printf '%s' "$GEMINI_KEY" | tr -d 'A-Za-z0-9_.-' | cat -v)'" >&2
  echo "Copy the key again from https://aistudio.google.com/apikey (use the copy button)." >&2
  exit 1
fi
echo "Key accepted (length ${#GEMINI_KEY}, starts with '${GEMINI_KEY:0:4}')."

TMP=$(mktemp); chmod 600 "$TMP"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<SQL
SET NOCOUNT ON;
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = 'EmbeddingModel')
    DROP EXTERNAL MODEL EmbeddingModel;
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = '$CRED')
    DROP DATABASE SCOPED CREDENTIAL [$CRED];

CREATE DATABASE SCOPED CREDENTIAL [$CRED]
WITH IDENTITY = 'HTTPEndpointHeaders',
     SECRET = '{"Authorization":"Bearer $GEMINI_KEY"}';

CREATE EXTERNAL MODEL EmbeddingModel
WITH (
    LOCATION   = '$CRED/embeddings',
    API_FORMAT = 'OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL      = 'gemini-embedding-001',
    CREDENTIAL = [$CRED],
    PARAMETERS = '{"dimensions":1536,"sql_rest_options":{"retry_count":3}}'
);
GO
DECLARE @e NVARCHAR(MAX) =
    CAST(AI_GENERATE_EMBEDDINGS(N'This product was great.' USE MODEL EmbeddingModel) AS NVARCHAR(MAX));
SELECT (SELECT COUNT(*) FROM OPENJSON(@e)) AS Dimensions, LEFT(@e, 80) AS FirstValues;
SQL

echo "Creating EmbeddingModel and testing it..."
sqlcmd -S "$SQL2025_SERVER" -U sa -C -b -d DP800 -W -i "$TMP"
echo "Done. Dimensions should be 1536 — then run embeddings-local.sql."
