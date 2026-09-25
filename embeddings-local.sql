-- Local SQL Server 2025 (localhost,1434), database DP800
-- Run setup-gemini-embeddings.sh first so EmbeddingModel exists.

-- 61. Vector column (gemini-embedding-001 reduced to 1536 dimensions)
IF COL_LENGTH('dbo.tblReviews', 'vctVector') IS NULL
    ALTER TABLE tblReviews ADD vctVector VECTOR(1536);
GO

-- 65. Fill embeddings in small batches (safe to re-run; only NULL rows are processed)
CREATE OR ALTER PROC UpdateReviewEmbeddings AS
BEGIN
  DECLARE @NumberOfRowsUpdated INT = 999;
  WHILE @NumberOfRowsUpdated > 0
  BEGIN
    UPDATE TOP (10) tblReviews
    SET vctVector = AI_GENERATE_EMBEDDINGS(Review USE MODEL EmbeddingModel)
    WHERE vctVector IS NULL AND Review IS NOT NULL;

    SET @NumberOfRowsUpdated = @@ROWCOUNT;
    WAITFOR DELAY '00:00:04';
  END
END
GO

EXEC UpdateReviewEmbeddings;

SELECT COUNT(*) AS Total, COUNT(vctVector) AS Embedded FROM tblReviews;
GO

-- 62. Semantic search with VECTOR_DISTANCE (exact nearest neighbours)
DECLARE @vctTarget VECTOR(1536) =
    AI_GENERATE_EMBEDDINGS(N'battery drains quickly' USE MODEL EmbeddingModel);

SELECT TOP 10 ID, ProductName, Review,
       VECTOR_DISTANCE('cosine', vctVector, @vctTarget) AS Distance
FROM tblReviews
WHERE vctVector IS NOT NULL
ORDER BY Distance;
