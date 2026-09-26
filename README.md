# DP-800 practice on SQL Server 2025 (free)

My practice work for **DP-800: Microsoft SQL Server AI Developer**: chunking text, generating embeddings, storing them in `VECTOR` columns, semantic, full-text and hybrid search, retrieval-augmented generation (RAG), and tracking data changes.

The course uses Azure SQL Database with paid Microsoft Foundry models. This repo runs the same T-SQL for free: **SQL Server 2025 Developer Edition in Docker** plus **Google Gemini's free models**: `gemini-embedding-001` for embeddings (1536 dimensions) and `gemini-flash-latest` for the RAG answers. The embedding size matches `text-embedding-3-small`, so the course scripts work with `VECTOR(1536)` unchanged.

## Topics covered

| Course topic | Where |
|---|---|
| 52. Handle changes: change data capture (CDC), Change Tracking, and a `rowversion` column for the Logic Apps SQL trigger. Change event streaming is reference only (it needs Azure Event Hubs) | `tblReviews.sql` |
| 54. Create and manage external models | `setup-gemini-embeddings.sh` |
| 57. Design and implement chunks for embeddings (`AI_GENERATE_CHUNKS`) | `tblReviews.sql` |
| 58. Generate embeddings (`AI_GENERATE_EMBEDDINGS`) | `tblReviews.sql` |
| 61. Vector data type and size (`VECTOR(1536)` vs `VECTOR(1536, float16)`) | `tblReviews.sql` |
| 62. Semantic search with `VECTOR_DISTANCE` | `embeddings-local.sql`, `tblReviews.sql` |
| 62d, 63, 64. Approximate (ANN) vs exact (ENN/KNN) search, a DiskANN vector index and `VECTOR_SEARCH` | `tblReviews.sql` |
| 65. Batch-filling embeddings with a stored procedure | `tblReviews.sql`, `embeddings-local.sql` |
| Vector functions: `VECTOR_NORM`, `VECTOR_NORMALIZE`, `VECTORPROPERTY` | `tblReviews.sql` |
| Full-text search: `CONTAINS`, `FREETEXT`, `CONTAINSTABLE`, `FREETEXTTABLE` | `tblReviews.sql` |
| Hybrid search: full-text and vector ranks fused with reciprocal rank fusion | `tblReviews.sql` |
| RAG: the top 5 reviews from `VECTOR_SEARCH` sent to Gemini through `sp_invoke_external_rest_endpoint` | `tblReviews.sql` |

## Files

| File | Purpose |
|---|---|
| `Reviews.sql` | Creates `tblReviews` with 106 product reviews (sample data) |
| `tblReviews.csv` | The same 106 reviews as CSV (`ID`, `Category`, `ProductName`, `Review`), without embeddings |
| `setup-gemini-embeddings.sh` | Creates `EmbeddingModel` pointing at Gemini; asks for the API key with hidden input and stores it only in a database credential |
| `embeddings-local.sql` | Adds `vctVector`, fills it in batches, runs a semantic search |
| `tblReviews.sql` | My step-by-step course work, one topic at a time |
| `Answer for best laptop` | A sample answer from the RAG query |
| `.env.sql2025.example` | Template for local connection settings |

## Setup

**1. Start SQL Server 2025** (on Apple Silicon it runs under Rosetta emulation):

```bash
cp .env.sql2025.example .env.sql2025   # then set the two passwords
set -a; source .env.sql2025; set +a

docker run -d --name dp800-sql2025 --platform linux/amd64 \
  -e ACCEPT_EULA=Y -e MSSQL_PID=Developer -e MSSQL_AGENT_ENABLED=true \
  -e "MSSQL_SA_PASSWORD=$SQL2025_PASSWORD" \
  -p 1434:1433 -v dp800-sql2025-data:/var/opt/mssql \
  mcr.microsoft.com/mssql/server:2025-latest
```

SQL Server Agent (`MSSQL_AGENT_ENABLED`) runs the CDC capture job. Full-text search isn't in the stock image, so install it inside the container and restart:

```bash
docker exec -u 0 dp800-sql2025 bash -c "apt-get update && apt-get install -y mssql-server-fts"
docker restart dp800-sql2025
```

The package is lost if the container is recreated from the image, so run these two commands again. Your databases survive on the `dp800-sql2025-data` volume.

**2. Create the database and load the data:**

```bash
export SQLCMDPASSWORD=$SQL2025_PASSWORD
sqlcmd -S localhost,1434 -U sa -C -Q "EXEC sp_configure 'external rest endpoint enabled', 1; RECONFIGURE; CREATE DATABASE DP800;"
sqlcmd -S localhost,1434 -U sa -C -d DP800 -i Reviews.sql
sqlcmd -S localhost,1434 -U sa -C -d DP800 -Q "CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$SQL2025_MASTER_KEY_PASSWORD';"
```

**3. Get a free Gemini API key** at <https://aistudio.google.com/apikey>. New keys start with `AQ.`. Then run:

```bash
./setup-gemini-embeddings.sh   # should print Dimensions 1536
```

**4. Run `embeddings-local.sql`**, then work through `tblReviews.sql` one batch at a time (each batch ends at a `GO`). Run the RAG block in one go: its variables only exist until the next `GO`.

Connect your editor to `localhost,1434`, database `DP800`, SQL login `sa`, with **Trust server certificate** on.

## What I learned

- **`AI_GENERATE_EMBEDDINGS` returns NULL when a call fails**; it doesn't raise an error. One `UPDATE` over all rows hit the free-tier rate limit and silently overwrote 4 embeddings with NULL. Batch the work (`UPDATE TOP (10) … WHERE vctVector IS NULL`, with a `WAITFOR` between batches), then check `COUNT(vctVector)` against `COUNT(*)`.
- **`WAITFOR` resets `@@ROWCOUNT` to 0.** In a batching loop, read `@@ROWCOUNT` straight after the `UPDATE`, or the loop stops after the first batch.
- **float16 halves the storage with almost no loss:** 652,112 bytes became 326,480 for 106 rows. A search returned the same top 10 in the same order, with distances differing only from the 5th decimal place.
- **A direct `CAST` from float32 to float16 is blocked** (`Msg 42238`). Convert through the JSON text form instead: `CAST(CAST(v AS NVARCHAR(MAX)) AS VECTOR(1536, float16))`.
- **Azure SQL Database can only call allow-listed Azure domains**, so third-party models such as Gemini or Ollama only work from SQL Server 2025 that you run yourself.
- **A standard `VECTOR` holds at most 1998 dimensions**, so Gemini's default 3072 has to be reduced with `PARAMETERS = '{"dimensions":1536}'`.
- **A vector index makes the table read-only** on this build (`Msg 42231`), and the error is raised when the batch compiles. Drop the index in its own batch before an `UPDATE`, then create it again.
- **`VECTOR_SEARCH` needs `TOP_N` on SQL Server 2025.** `SELECT TOP (N) WITH APPROXIMATE` only parses on Azure SQL.
- **`JSON_VALUE` returns NULL for values over 4000 characters**, and `RETURNING` isn't supported here. Read long model answers with `OPENJSON … WITH (Answer NVARCHAR(MAX) '$.…')`.
- **Change event streaming and CDC can't both be enabled in one database** (`Msg 22898` / `23650`).
- **CDC records a primary-key change as a delete and an insert**, not as an update pair.
- GitHub Models (a former free option) was retired on 30 July 2026.

## Data attribution

`Reviews.sql` and `tblReviews.csv` are derived from [SAP-samples/datahub-dine](https://github.com/SAP-samples/datahub-dine) (Apache License 2.0), as adapted for the DP-800 course. See the header of that file.
