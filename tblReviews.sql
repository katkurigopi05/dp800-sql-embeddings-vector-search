-- AI_GENERATE_CHUNKS, float16 vectors and vector indexes are preview features
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;


GO
--Design and implement chunks for embeddings
DECLARE @SingleReview AS VARCHAR (8000);

SELECT @SingleReview = Review
FROM   tblReviews;

--WHERE ID = 106;
SELECT @SingleReview,
       LEN(@SingleReview);

--SELECT * FROM ai_generate_chunks(SOURCE =@SingleReview,CHUNK_TYPE = FIXED,CHUNK_SIZE = 500,OVERLAP =25)
SELECT   *
FROM     tblReviews CROSS APPLY AI_GENERATE_CHUNKS (SOURCE = Review, CHUNK_TYPE = FIXED, CHUNK_SIZE = 500, OVERLAP = 25, ENABLE_CHUNK_SET_ID = 1)
ORDER BY ID DESC;

--DELETE FROM tblReviews
--WHERE ID = 106;
SELECT *
FROM   tblReviews;


GO
--generate embeddings (EmbeddingModel = Google Gemini free tier, 1536 dimensions; see setup-gemini-embeddings.sh)
SELECT AI_GENERATE_EMBEDDINGS('This product was great.' USE MODEL EmbeddingModel);

DECLARE @StartNumber AS INT = 1;

DECLARE @MaxID AS INT = (SELECT MAX(ID)
                         FROM   tblReviews);

WHILE @StartNumber <= @MaxID
    BEGIN
        SELECT ID,
               ProductName,
               Review,
               AI_GENERATE_EMBEDDINGS(Review USE MODEL EmbeddingModel) AS Embedding
        FROM   tblReviews
        WHERE  ID BETWEEN @StartNumber AND @StartNumber + 19;
        SET @StartNumber = @StartNumber + 20;
        WAITFOR DELAY '00:00:04'; -- stay under the free-tier rate limit
    END


GO
-- 61. Vector column (already added and filled by embeddings-local.sql, so only add it if missing)
IF COL_LENGTH('dbo.tblReviews', 'vctVector') IS NULL
    ALTER TABLE tblReviews
        ADD vctVector VECTOR(1536);

SELECT COUNT(*) AS Total,
       COUNT(vctVector) AS Embedded
FROM   tblReviews;

ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;


GO
-- 61. Half-precision vector (float16): half the storage, needs PREVIEW_FEATURES = ON
IF COL_LENGTH('dbo.tblReviews', 'vctVector2') IS NULL
    ALTER TABLE tblReviews
        ADD vctVector2 VECTOR(1536, float16);


GO
-- On this SQL Server 2025 build a table with a vector index is read-only (Msg 42231), so drop
-- idxVector before the UPDATEs below. Section 64 creates it again.
DROP INDEX IF EXISTS idxVector ON tblReviews;


GO
-- Fill float16 copies from the existing float32 embeddings (no new API calls).
-- A direct CAST from float32 to float16 is not allowed (Msg 42238), so convert via the JSON text form.
UPDATE tblReviews
SET    vctVector2 = CAST (CAST (vctVector AS NVARCHAR (MAX)) AS VECTOR(1536, float16))
WHERE  vctVector IS NOT NULL
       AND vctVector2 IS NULL;


GO
-- Storage: actual bytes stored in each column
SELECT COUNT(vctVector2) AS RowsWithFloat16,
       SUM(DATALENGTH(vctVector)) AS Float32Bytes,
       SUM(DATALENGTH(vctVector2)) AS Float16Bytes
FROM   tblReviews;


GO
-- Accuracy: the same search against both columns
DECLARE @q32 AS VECTOR(1536) = AI_GENERATE_EMBEDDINGS('battery drains quickly' USE MODEL EmbeddingModel);

DECLARE @q16 AS VECTOR(1536, float16) = CAST (CAST (@q32 AS NVARCHAR (MAX)) AS VECTOR(1536, float16));

SELECT   TOP 10 ID,
                ProductName,
                VECTOR_DISTANCE('cosine', vctVector, @q32) AS Distance32,
                VECTOR_DISTANCE('cosine', vctVector2, @q16) AS Distance16,
                ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', vctVector, @q32)) AS Rank32,
                ROW_NUMBER() OVER (ORDER BY VECTOR_DISTANCE('cosine', vctVector2, @q16)) AS Rank16
FROM     tblReviews
WHERE    vctVector2 IS NOT NULL
ORDER BY Distance32;


GO
-- Clean up when you're finished with float16:
-- ALTER TABLE tblReviews DROP COLUMN vctVector2;
-- Don't do this: one UPDATE over every row fires ~106 API calls at once. On the free tier the
-- last calls hit the rate limit, and AI_GENERATE_EMBEDDINGS returns NULL instead of raising an
-- error, so existing embeddings were silently overwritten with NULL (IDs 103-106).
-- UPDATE tblReviews
-- SET vctVector = AI_GENERATE_EMBEDDINGS(Review USE MODEL EmbeddingModel)
-- FROM tblReviews;
-- 65. Batched version: only rows without an embedding, 10 at a time
DECLARE @NumberOfRowsUpdated AS INT = 999;

WHILE @NumberOfRowsUpdated > 0
    BEGIN
        UPDATE TOP (10)
         tblReviews
        SET    vctVector = AI_GENERATE_EMBEDDINGS(Review USE MODEL EmbeddingModel)
        FROM   tblReviews
        WHERE  vctVector IS NULL
               AND Review IS NOT NULL;
        SET @NumberOfRowsUpdated = @@ROWCOUNT; -- read @@ROWCOUNT first: WAITFOR resets it to 0
        WAITFOR DELAY '00:00:04'; -- stay under the free-tier rate limit
    END

SELECT COUNT(*) AS Total,
       COUNT(vctVector) AS Embedded
FROM   tblReviews;


GO
--creating a stored procedure to generate embeddings
CREATE OR ALTER PROCEDURE UpdateReviewEmbeddings
AS
BEGIN
    DECLARE @NumberOfRowsUpdated AS INT = 999;
    WHILE @NumberOfRowsUpdated > 0
        BEGIN
            UPDATE TOP (10)
             tblReviews
            SET    vctVector = AI_GENERATE_EMBEDDINGS(Review USE MODEL EmbeddingModel)
            FROM   tblReviews
            WHERE  vctVector IS NULL
                   AND Review IS NOT NULL;
            SET @NumberOfRowsUpdated = @@ROWCOUNT; -- read @@ROWCOUNT first: WAITFOR resets it to 0
            WAITFOR DELAY '00:00:04'; -- stay under the free-tier rate limit
        END
END


GO
EXECUTE UpdateReviewEmbeddings ;

SELECT COUNT(*) AS Total,
       COUNT(vctVector) AS Embedded
FROM   tblReviews;

SELECT *,
       VECTOR_NORMALIZE(vctVector, 'norminf') AS NormalizedVector,
       VECTOR_NORM(vctVector, 'norminf') AS VectorNorm
FROM   tblReviews;

SELECT *,
       VECTORPROPERTY(vctVector, 'Dimensions') AS Dimensions,
       VECTORPROPERTY(vctVector, 'BaseType') AS BaseType
FROM   tblReviews;

--VECTOR_DISTANCE
DECLARE @vctTarget AS VECTOR(1536);

SELECT @vctTarget = vctVector
FROM   tblReviews
WHERE  ID = 1;

SELECT   TOP (10) ID,
                  Category,
                  ProductName,
                  Review,
                  VECTOR_DISTANCE('cosine', vctVector, @vctTarget) AS Distance
FROM     tblReviews
ORDER BY Distance; -- smallest cosine distance = most similar

-- 62d, 63, 64. ANN and ENN/KNN, vector indexes, and VECTOR_SEARCH
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;


GO
-- This wipes the embeddings for IDs 86-106. They can't be regenerated while idxVector exists
-- (the table is read-only), and the hybrid search below then never returns those reviews.
-- UPDATE tblReviews
-- SET    vctVector = NULL
-- WHERE  ID > 85;
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  name = 'idxVector'
                      AND object_id = OBJECT_ID('dbo.tblReviews'))
    CREATE VECTOR INDEX idxVector
        ON tblReviews (vctVector) WITH (METRIC = 'COSINE', TYPE = 'DISKANN');


GO
DECLARE @vctTarget AS VECTOR(1536);

SELECT @vctTarget = vctVector
FROM   tblReviews
WHERE  ID = 1;

SELECT   *
FROM     VECTOR_SEARCH(
             TABLE = dbo.tblReviews,
             COLUMN = vctVector,
             SIMILAR_TO = @vctTarget,
             METRIC = 'cosine',
             TOP_N = 10
         ) AS SearchResults
ORDER BY distance;


GO
--CREATE FULL TEXT SEARCH
IF NOT EXISTS (SELECT 1
               FROM   sys.fulltext_catalogs
               WHERE  name = 'catReviews')
    CREATE FULLTEXT CATALOG catReviews
        WITH ACCENT_SENSITIVITY = ON
        AS DEFAULT;

ALTER FULLTEXT CATALOG catReviews REBUILD WITH ACCENT_SENSITIVITY = ON;

SELECT *
FROM   sys.fulltext_catalogs;

-- CHANGE_TRACKING AUTO (the default) populates the index now and keeps it in sync.
-- CHANGE_TRACKING OFF, NO POPULATION would leave it empty, so every CONTAINS returns nothing.
IF NOT EXISTS (SELECT 1
               FROM   sys.fulltext_indexes
               WHERE  object_id = OBJECT_ID('dbo.tblReviews'))
    CREATE FULLTEXT INDEX ON tblReviews
        (Review LANGUAGE 1033)
        KEY INDEX [PK_tblReviews]
        ON catReviews
        WITH CHANGE_TRACKING AUTO;

-- Population runs in the background; wait for it so the queries below see every row
WAITFOR DELAY '00:00:02';

WHILE FULLTEXTCATALOGPROPERTY('catReviews', 'PopulateStatus') <> 0
    WAITFOR DELAY '00:00:01';

SELECT *
FROM   sys.fulltext_indexes;


GO
--Implement full-text search - using the CONTAINS and FREETEXT functions
SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), 'sound');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), 'sound OR MAC');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), '"three star"');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), '"three star*"');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), 'FORMSOF(INFLECTIONAL,"worked")');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), 'NEAR((not, working), 1)');

SELECT *
FROM   tblReviews
WHERE  CONTAINS ((Review), 'NEAR((not, working), 3)');

SELECT *
FROM   CONTAINSTABLE (tblReviews, Review, 'star');

SELECT *
FROM   CONTAINSTABLE (tblReviews, Review, 'star') AS CT
       INNER JOIN
       tblReviews AS R
       ON R.ID = CT.[KEY];

SELECT *
FROM   CONTAINSTABLE (tblReviews, Review, 'star', 3) AS CT
       INNER JOIN
       tblReviews AS R
       ON R.ID = CT.[KEY];

SELECT *
FROM   tblReviews
WHERE  FREETEXT ((Review), 'second hand');

SELECT *
FROM   tblReviews
WHERE  FREETEXT ((Review), 'price too high');

SELECT *
FROM   FREETEXTTABLE (tblReviews, Review, 'price too high', 4) AS CT
       INNER JOIN
       tblReviews AS R
       ON R.ID = CT.[KEY];


GO
-- Implement hybrid search and reciprocal rank fusion, and evaluate results
DROP TABLE IF EXISTS #tblFullTextSearch;

DROP TABLE IF EXISTS #tblSemanticSearch;

DECLARE @SearchTerm AS NVARCHAR (4000) = 'good review';

--Fulltext search
SELECT   TOP 15 id,
                RANK() OVER (ORDER BY FTRank DESC) AS rank
INTO     #tblFullTextSearch
FROM     (SELECT   TOP 15 id,
                          Category,
                          ProductName,
                          ftt.[RANK] AS FTRank
          FROM     tblReviews AS R
                   INNER JOIN
                   FREETEXTTABLE (tblReviews, *, @SearchTerm) AS ftt
                   ON R.id = ftt.[key]
          ORDER BY FTRank DESC) AS FreetextDocuments
ORDER BY rank ASC;

SELECT *
FROM   #tblFullTextSearch;

--vector search
DECLARE @vctTarget AS VECTOR(1536) = AI_GENERATE_EMBEDDINGS(@SearchTerm USE MODEL EmbeddingModel);

WITH   tblSemanticSearch
AS     (SELECT   TOP (15) ID,
                          distance
        FROM     VECTOR_SEARCH(
                     TABLE = dbo.tblReviews,
                     COLUMN = vctVector,
                     SIMILAR_TO = @vctTarget,
                     METRIC = 'cosine',
                     TOP_N = 15
                 ) AS SearchResults
        ORDER BY Distance)
SELECT ID,
       RANK() OVER (ORDER BY Distance) AS rank
INTO   #tblSemanticSearch
FROM   tblSemanticSearch;

SELECT *
FROM   #tblSemanticSearch;

--Reciprocal Rank Fusion (RRF)
WITH   tblRRF
AS     (SELECT   TOP 15 COALESCE (Semantic.id, FULLText.id) AS id,
                        Semantic.rank AS SemanticRank,
                        FullText.rank AS KeywordRank,
                        COALESCE (1.0 / (60 + Semantic.rank), 0.0) + COALESCE (1.0 / (60 + FullText.rank), 0.0) AS score
        FROM     #tblSemanticSearch AS Semantic
                 FULL OUTER JOIN
                 #tblFullTextSearch AS FullText
                 ON Semantic.ID = FullText.ID
        ORDER BY score DESC)
SELECT RRF.*,
       Category,
       ProductName,
       Review
FROM   tblRRF AS RRF
       INNER JOIN
       dbo.tblReviews AS R
       ON RRF.ID = R.ID
ORDER BY RRF.score DESC;


--Identify use cases for RAG


DECLARE @Payload NVARCHAR(MAX);
DECLARE @Response NVARCHAR(MAX);
DECLARE @strQuestion NVARCHAR(MAX) ='What is a good laptop for me to use for work?';
DECLARE @vctQuestion VECTOR(1536);
DECLARE @context NVARCHAR(MAX);


SET @vctQuestion = AI_GENERATE_EMBEDDINGS(@strQuestion USE MODEL EmbeddingModel);

--Retrieve closest review based on cosine similarity
--set @context = (
--SELECT TOP(5) WITH APPROXIMATE ID, Category, ProductName, Review

--FROM VECTOR_SEARCH(
--TABLE =dbo.tblReviews,
   -- COLUMN = vctVector,
    --SIMILAR_TO = @vctQuestion,
    --METRIC ='cosine',
    --TOP_N =5
--)
--ORDER BY distance

SET @context =(
SELECT   ID, Category, ProductName, Review, distance
FROM     VECTOR_SEARCH(
             TABLE = dbo.tblReviews,
             COLUMN = vctVector,
             SIMILAR_TO = @vctQuestion,
             METRIC = 'cosine',
             TOP_N = 5
         ) AS SearchResults
ORDER BY distance
FOR JSON PATH
);
SELECT @context as Context;
--Build prompt
-- Gemini's OpenAI-compatible endpoint needs 'model' (Azure OpenAI takes the deployment name in the URL instead)
SET @payload =JSON_OBJECT('model': 'gemini-flash-latest', 'messages': JSON_ARRAY(
    JSON_OBJECT('role':'system', 'content':'You are a helpful assistant that answers questions about products.'), JSON_OBJECT(
               'role':'user', 'content': 'Product reviews:' + ISNULL(@context, '[]') + CHAR(10) + CHAR(10) + 'Customer question:' + @strQuestion)));
SELECT @payload as PayLoad;

--Send prompt using sp_invoke_external_rest_endpoint, extract response
-- Reuses the Gemini credential from setup-gemini-embeddings.sh (@url starts with the credential name).
-- Return code 0 = HTTP 2xx; otherwise it is the HTTP status code (e.g. 429 = free-tier rate limit).
DECLARE @ReturnCode AS INT;

EXECUTE @ReturnCode = sp_invoke_external_rest_endpoint
    @url = N'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
    @method = 'POST',
    @credential = [https://generativelanguage.googleapis.com/v1beta/openai],
    @payload = @Payload,
    @timeout = 120,
    @response = @Response OUTPUT;

-- Failure: show the HTTP status and raw error. Success: show the model's answer.
-- Run this whole block (DECLARE through here) in one go - the variables only live for one batch.
IF @ReturnCode <> 0
    SELECT @ReturnCode AS HttpStatus,
           @Response AS Response;
ELSE
    -- The API's own JSON is under $.result. JSON_VALUE returns NULL for values over 4000 characters
    -- (and RETURNING isn't supported on this build), so read the answer with OPENJSON ... NVARCHAR(MAX).
    SELECT Answer,
           FinishReason,
           PromptTokens,
           CompletionTokens
    FROM   OPENJSON (@Response, '$.result') WITH (
               Answer NVARCHAR (MAX) '$.choices[0].message.content',
               FinishReason NVARCHAR (50) '$.choices[0].finish_reason',
               PromptTokens INT '$.usage.prompt_tokens',
               CompletionTokens INT '$.usage.completion_tokens');


GO
-- 52. Handle changes (section 28): change event streaming (CES), change data capture (CDC),
-- Change Tracking and Azure Logic Apps
-- CES streams changes to Azure Event Hubs, which has no free or local option, so it stays as
-- reference only. On this build sp_enable_event_stream is deprecated in favour of
-- sp_enable_change_event_stream, and the other procedures have *_change_event_stream_* names too.
-- CES and CDC can't both be enabled in one database (Msg 22898 / 23650), and DP800 uses CDC.
-- The master key already exists (README step 2).
-- CREATE DATABASE SCOPED CREDENTIAL <CredentialName>
--     WITH IDENTITY = 'SHARED ACCESS SIGNATURE', SECRET = '<Generated SAS Token>';
-- EXECUTE sys.sp_enable_change_event_stream;
-- EXECUTE sys.sp_create_change_event_stream_group
--     @stream_group_name = N'<EventStreamGroupName>',
--     @destination_type = N'AzureEventHubsAmqp',
--     @destination_location = N'<AzureEventHubsHostName>/<EventHubsInstance>',
--     @destination_credential = <CredentialName>,
--     @max_message_size_kb = <MaxMessageSize>,
--     @partition_key_scheme = N'<PartitionKeyScheme>';
-- EXECUTE sys.sp_add_object_to_change_event_stream_group N'<EventStreamGroupName>', N'dbo.tblReviews';
SELECT name,
       is_event_stream_enabled,
       is_cdc_enabled
FROM   sys.databases;


GO
-- Change Data Capture (CDC). The capture job runs in SQL Server Agent, which is already
-- running in this container.
SELECT is_cdc_enabled,
       *
FROM   sys.databases;

IF NOT EXISTS (SELECT 1
               FROM   sys.databases
               WHERE  name = DB_NAME()
                      AND is_cdc_enabled = 1)
    EXECUTE sys.sp_cdc_enable_db;


GO
-- The message about CLR being disabled is informational. The VECTOR columns are captured too
-- (as varbinary).
IF NOT EXISTS (SELECT 1
               FROM   sys.tables
               WHERE  object_id = OBJECT_ID('dbo.tblReviews')
                      AND is_tracked_by_cdc = 1)
    EXECUTE sys.sp_cdc_enable_table
        @source_schema = N'dbo',
        @source_name = N'tblReviews',
        @role_name = NULL;

SELECT *
FROM   [cdc].[captured_columns];


GO
-- idxVector makes the table read-only (Msg 42231), and the error is raised when the batch
-- compiles, so drop it in its own batch. It's created again at the end of this section.
DROP INDEX IF EXISTS idxVector ON tblReviews;


GO
UPDATE dbo.tblReviews
SET    ID = 200
WHERE  ID = 100;

-- The capture job reads the log every 5 seconds, so wait before reading the changes
WAITFOR DELAY '00:00:10';

-- Changing the primary key is recorded as a delete (__$operation 1) and an insert (2),
-- not as an update pair (3 = before, 4 = after)
SELECT *
FROM   [cdc].[dbo_tblReviews_CT];

DECLARE @from_lsn AS BINARY (10);

DECLARE @to_lsn AS BINARY (10);

SET @from_lsn = sys.fn_cdc_get_min_lsn('dbo_tblReviews');

SET @to_lsn = sys.fn_cdc_get_max_lsn();

SELECT *
FROM   cdc.fn_cdc_get_all_changes_dbo_tblReviews(@from_lsn, @to_lsn, 'all');


GO
-- Change Tracking (DP800 instead of the course's Azure database name)
IF NOT EXISTS (SELECT 1
               FROM   sys.change_tracking_databases
               WHERE  database_id = DB_ID('DP800'))
    ALTER DATABASE DP800
        SET CHANGE_TRACKING = ON
        (CHANGE_RETENTION = 3 DAYS, AUTO_CLEANUP = ON);

IF NOT EXISTS (SELECT 1
               FROM   sys.change_tracking_tables
               WHERE  object_id = OBJECT_ID('dbo.tblReviews'))
    ALTER TABLE dbo.tblReviews ENABLE CHANGE_TRACKING WITH (TRACK_COLUMNS_UPDATED = ON);

SELECT *
FROM   sys.change_tracking_databases;

SELECT *
FROM   sys.change_tracking_tables;


GO
DECLARE @synchronization_version AS BIGINT;

-- Obtain the current synchronization version. This will be used next time that changes are obtained.
SET @synchronization_version = CHANGE_TRACKING_CURRENT_VERSION();

UPDATE dbo.tblReviews
SET    ID = 100
WHERE  ID = 200;

-- NULL returns every tracked change
DECLARE @last_synchronization_version AS BIGINT;

SELECT CT.* --, CT.SYS_CHANGE_OPERATION, CT.SYS_CHANGE_COLUMNS, CT.SYS_CHANGE_CONTEXT
FROM   CHANGETABLE (CHANGES tblReviews, @last_synchronization_version) AS CT;

-- Our data already says 'Ink jet printers' (the course's WHERE matches 0 rows), so rename the other way
UPDATE dbo.tblReviews
SET    Category = 'Inkjet printers'
WHERE  Category = 'Ink jet printers';

-- TRACK_COLUMNS_UPDATED = ON records which columns an update changed, not just which rows
SELECT CT.SYS_CHANGE_VERSION,
       CT.SYS_CHANGE_OPERATION,
       CT.ID,
       CHANGE_TRACKING_IS_COLUMN_IN_MASK(COLUMNPROPERTY(OBJECT_ID('dbo.tblReviews'), 'Category', 'ColumnId'), CT.SYS_CHANGE_COLUMNS) AS CategoryChanged
FROM   CHANGETABLE (CHANGES tblReviews, @synchronization_version) AS CT
WHERE  CT.SYS_CHANGE_OPERATION = 'U';


GO
-- Azure Logic Apps: the SQL connector's "When an item is modified" trigger polls a rowversion
-- column. Logic Apps runs in Azure, so reaching this local container would need an on-premises
-- data gateway; only the table change is done here.
IF COL_LENGTH('dbo.tblReviews', 'RowVer') IS NULL
    ALTER TABLE dbo.tblReviews
        ADD RowVer ROWVERSION;


GO
-- Recreate the vector index dropped above (same as section 64)
IF NOT EXISTS (SELECT 1
               FROM   sys.indexes
               WHERE  name = 'idxVector'
                      AND object_id = OBJECT_ID('dbo.tblReviews'))
    CREATE VECTOR INDEX idxVector
        ON tblReviews (vctVector) WITH (METRIC = 'COSINE', TYPE = 'DISKANN');

SELECT *
FROM   dbo.tblReviews;


GO
-- Clean up when you're finished with this section. Drop idxVector first (the UPDATE fails
-- otherwise), then recreate it with section 64:
-- UPDATE dbo.tblReviews SET Category = 'Ink jet printers' WHERE Category = 'Inkjet printers';
-- ALTER TABLE dbo.tblReviews DROP COLUMN RowVer;
-- ALTER TABLE dbo.tblReviews DISABLE CHANGE_TRACKING;
-- ALTER DATABASE DP800 SET CHANGE_TRACKING = OFF;
-- EXECUTE sys.sp_cdc_disable_table @source_schema = N'dbo', @source_name = N'tblReviews', @capture_instance = N'dbo_tblReviews';
-- EXECUTE sys.sp_cdc_disable_db;


--52b, 55e. Change Data Capture (CDC)
EXEC sys.sp_cdc_enable_db
GO
SELECT *
FROM sys.databases







