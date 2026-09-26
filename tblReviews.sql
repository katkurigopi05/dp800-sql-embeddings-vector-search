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
ORDER BY Distance DESC;

-- 62d, 63, 64. ANN and ENN/KNN, vector indexes, and VECTOR_SEARCH
ALTER DATABASE SCOPED CONFIGURATION SET PREVIEW_FEATURES = ON;


GO
UPDATE tblReviews
SET    vctVector = NULL
WHERE  ID > 85;

CREATE VECTOR INDEX idxVector
    ON tblReviews (vctVector) WITH (METRIC = 'COSINE', TYPE = 'DISKANN');

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