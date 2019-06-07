/*
EXEC msdb.dbo.sp_delete_database_backuphistory @database_name = N'OrderSchemaManage'
GO

USE [master]
GO

ALTER DATABASE [OrderSchemaManage]
	SET SINGLE_USER WITH ROLLBACK IMMEDIATE
GO

USE [master]
GO

DROP DATABASE [OrderSchemaManage]
GO

USE [master]
GO
*/
CREATE DATABASE [OrderSchemaManage]
GO

/*
	此設定與 Azure SQL Database 相同
	https://blogs.msdn.microsoft.com/sqlcat/2013/12/26/be-aware-of-the-difference-in-isolation-levels-if-porting-an-application-from-windows-azure-sql-db-to-sql-server-in-windows-azure-virtual-machine/
*/

--啟用 SNAPSHOT_ISOLATION
ALTER DATABASE [OrderSchemaManage]
	SET ALLOW_SNAPSHOT_ISOLATION ON
GO

--啟用 READ_COMMITTED_SNAPSHOT
ALTER DATABASE [OrderSchemaManage]
	SET READ_COMMITTED_SNAPSHOT ON
	WITH ROLLBACK IMMEDIATE
GO

USE [OrderSchemaManage]
GO

CREATE SCHEMA [Orders]
GO

CREATE SCHEMA [Events]
GO


--儲存預存程序錯誤的事件紀錄資料表
CREATE TABLE [Events].[EventDatabaseErrorLog] (
	[No]                INT IDENTITY(1, 1),
	[ErrorTime]         DATETIME DEFAULT (SYSDATETIMEOFFSET()),
	[ErrorDatabase]     NVARCHAR(100),
	[LoginName]         NVARCHAR(100),
	[UserName]          NVARCHAR(128),
	[ErrorNumber]       INT,
	[ErrorSeverity]     INT,
	[ErrorState]        INT,
	[ErrorProcedure]    NVARCHAR(130),
	[ErrorLine]         INT,
	[ErrorMessage]      NVARCHAR(MAX),
	
    CONSTRAINT [PK_Events_DatabaseErrorLog] PRIMARY KEY ([No] ASC)
)
GO


CREATE PROCEDURE [Events].[AddEventDatabaseError] 
    @No INT = 0 OUTPUT
AS
    DECLARE @seed INT

    SET NOCOUNT ON

    BEGIN TRY
        IF ERROR_NUMBER() IS NULL
        BEGIN
            RETURN
        END

        --
        --如果有進行中的交易正在使用時不進行記錄
        -- (尚未 rollback 或 commit)
        --
        IF XACT_STATE() = (- 1)
        BEGIN
            RETURN
        END

        INSERT INTO [Events].[EventDatabaseErrorLog] (
            [ErrorDatabase]
            ,[LoginName]
            ,[UserName]
            ,[ErrorNumber]
            ,[ErrorSeverity]
            ,[ErrorState]
            ,[ErrorProcedure]
            ,[ErrorLine]
            ,[ErrorMessage]
            )
        VALUES (
            CONVERT(NVARCHAR(100), DB_NAME())
            ,CONVERT(NVARCHAR(100), SYSTEM_USER)
            ,CONVERT(NVARCHAR(128), CURRENT_USER)
            ,ERROR_NUMBER()
            ,ERROR_SEVERITY()
            ,ERROR_STATE()
            ,ERROR_PROCEDURE()
            ,ERROR_LINE()
            ,ERROR_MESSAGE()
            )
    END TRY

    BEGIN CATCH
        RETURN (- 1)
    END CATCH
GO

--產生 CHAR(18) 訂單編號的純量函數
--	YYMMDDHHMMSS000000
CREATE FUNCTION [Orders].[GetOrderSchema] 
(
	@CurrentDate	DATETIME2(0)
	,@Index			SMALLINT
)
RETURNS CHAR(18)
BEGIN
	DECLARE @Code		CHAR(6)
	DECLARE @VarCode	VARCHAR(6)
	DECLARE @Prefix		CHAR(12)

    DECLARE @PrefixDate CHAR(6)
    DECLARE @PrefixTime CHAR(6)

	DECLARE @Length		SMALLINT

	SET @Code = '000000'
	SET @VarCode = CONVERT(VARCHAR(8),@Index)

    --YYMMDD
	SET @PrefixDate = CONVERT(CHAR(6),RIGHT(CONVERT(CHAR(8),@CurrentDate,112),6))

    --HHMMSS
    SET @PrefixTime = CONVERT(CHAR(6),REPLACE(CONVERT(CHAR(8),@CurrentDate,114),':',''))

    SET @Prefix = (@PrefixDate + @PrefixTime)
	SET @Length = LEN(@Code)

	SET @Code = RIGHT((@Code + @VarCode),@Length)

	--RETURN (YYMMDDHHMMSS + 000000)
	RETURN (@Prefix + @Code)
END
GO

/* 儲存訂單編號的資料表 */
CREATE TABLE [Orders].[OrderSchemaBuffer]
(
	[TableName]			NVARCHAR(150),
	[PresentDateTime]	DATETIME2(0) NOT NULL,
	[Index]				SMALLINT NOT NULL,
	[Schema]			AS (
							[Orders].[GetOrderSchema]([PresentDateTime],[Index])
						),

	CONSTRAINT [pk_Orders_OrderSchemaBuffer]
		PRIMARY KEY([TableName])
)
GO

--訂單資料表主索引鍵使用序列
CREATE SEQUENCE [Orders].[OrderMainSeq]
	START WITH 1
	INCREMENT BY 1
GO

/* 訂單編號主資料表 */
CREATE TABLE [Orders].[OrderMains]
(
	[No]			INT NOT NULL,
	[Schema]		CHAR(18),
	[OrderDate]		DATETIMEOFFSET DEFAULT (SYSDATETIMEOFFSET())

	CONSTRAINT [pk_Orders_OrderMains] PRIMARY KEY ([No]),

	CONSTRAINT [un_Orders_OrderMains_Schema] UNIQUE ([Schema])
)
GO

/* 初始化訂單編號儲存資料表的資料列內容 */
INSERT INTO [Orders].[OrderSchemaBuffer] ([TableName],[PresentDateTime],[Index]) 
	VALUES (N'Orders.OrderMains',GETDATE(),1)
GO

/* 取得新一筆訂單要使用的訂單編號 */
CREATE PROCEDURE [Orders].[GetNewOrderSchema]
	@CurrentDate	DATETIME2(0),
	@OutSchema		CHAR(18) OUT,
	@Success		BIT OUT
AS
	DECLARE @IsTransaction	BIT
	DECLARE @output			TABLE
	(
		[PresentDate]		DATETIME2(0),
		[Index]				SMALLINT,

		PRIMARY KEY ([PresentDate])
	)

	BEGIN TRY
		IF XACT_STATE() = 0
		BEGIN
			BEGIN TRANSACTION
			SET @IsTransaction = 1
		END

		--若當下時間已經超過/重設 Index 數值
		UPDATE [Orders].[OrderSchemaBuffer]
			SET [Index] = CASE
					WHEN [PresentDateTime] = CAST(GETDATE() AS DATETIME2(0)) THEN [Index] + 1
					ELSE CAST(1 AS INT)
				END
				,[PresentDateTime] = GETDATE()
			OUTPUT INSERTED.[PresentDateTime]
				,INSERTED.[Index]
			INTO @output

		--取得要新增到訂單的訂單編號
		SET @OutSchema = (
			SELECT [Orders].[GetOrderSchema]([PresentDate],[Index]) [OutSchema]
			FROM @output
		)
		
		IF @IsTransaction = 1
		BEGIN
			COMMIT TRANSACTION
		END

		SET @Success = 1
	END TRY

	BEGIN CATCH
		IF @IsTransaction = 1
		BEGIN
			ROLLBACK TRANSACTION
		END

		EXEC [Events].[AddEventDatabaseError]

		SET @Success = 0
	END CATCH
GO

--建立訂單資料的預存程序/部分
CREATE PROCEDURE [Orders].[AddOrder]
	@Success		BIT OUT
AS
BEGIN TRY
	BEGIN TRANSACTION
	
	DECLARE @No				INT
	DECLARE @OutSchema		CHAR(18)

	DECLARE @CurrentDate	DATETIME2(0)

	SET @CurrentDate = GETDATE()

	--取得此筆訂單的訂單編號
	EXEC [Orders].[GetNewOrderSchema] 
		@CurrentDate
		, @OutSchema OUT
		, @Success OUT

	SET @No = NEXT VALUE FOR [Orders].[OrderMainSeq]

	INSERT INTO [Orders].[OrderMains] (
		[No]
		,[Schema]
	) VALUES (
		@No
		,@OutSchema
	)

	SET @Success = 1

	COMMIT TRANSACTION
END TRY

BEGIN CATCH
	ROLLBACK TRANSACTION

	EXEC [Events].[AddEventDatabaseError]

	SET @Success = 0
END CATCH
GO