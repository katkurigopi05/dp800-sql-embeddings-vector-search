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

