Create PROCEDURE Recover_Truncated_Data_Proc
@Database_Name NVARCHAR(MAX),
@SchemaName_n_TableName NVARCHAR(MAX),
@Date_From datetime='1900/01/01',
@Date_To datetime ='9999/12/31'
AS
DECLARE @Fileid INT
DECLARE @Pageid INT
DECLARE @Slotid INT
 
DECLARE @ConsolidatedPageID VARCHAR(MAX)
Declare @AllocUnitID as bigint
Declare @TransactionID as VARCHAR(MAX)
 
/*  Pick The actual data
*/
declare @temppagedata table
(
[ParentObject] sysname,
[Object] sysname,
[Field] sysname,
[Value] sysname)
 
declare @pagedata table
(
[Page ID] sysname,
[AllocUnitId] bigint,
[ParentObject] sysname,
[Object] sysname,
[Field] sysname,
[Value] sysname)
 
 
    DECLARE Page_Data_Cursor CURSOR FOR
    /*We need to filter LOP_MODIFY_ROW,LOP_MODIFY_COLUMNS from log for modified records & Get its Slot No, Page ID & AllocUnit ID*/
    SELECT LTRIM(RTRIM(Replace([Description],'Deallocated',''))) AS [PAGE ID]
    ,[Slot ID],[AllocUnitId]
    FROM    sys.fn_dblog(NULL, NULL)  
    WHERE   
    AllocUnitId IN
    (Select [Allocation_unit_id] from sys.allocation_units allocunits
    INNER JOIN sys.partitions partitions ON (allocunits.type IN (1, 3)  
    AND partitions.hobt_id = allocunits.container_id) OR (allocunits.type = 2 
    AND partitions.partition_id = allocunits.container_id)  
    Where object_id=object_ID('' + @SchemaName_n_TableName + ''))
    AND Operation IN ('LOP_MODIFY_ROW') AND [Context] IN ('LCX_PFS') 
    AND Description Like '%Deallocated%'
    /*Use this subquery to filter the date*/
 
    AND [TRANSACTION ID] IN (SELECT DISTINCT [TRANSACTION ID] FROM    sys.fn_dblog(NULL, NULL) 
    WHERE Context IN ('LCX_NULL') AND Operation in ('LOP_BEGIN_XACT')  
    AND [Transaction Name]='TRUNCATE TABLE'
    AND  CONVERT(NVARCHAR(11),[Begin Time]) BETWEEN @Date_From AND @Date_To)
 
    /****************************************/
 
    GROUP BY [Description],[Slot ID],[AllocUnitId]
    ORDER BY [Slot ID]    
     
    OPEN Page_Data_Cursor
 
    FETCH NEXT FROM Page_Data_Cursor INTO @ConsolidatedPageID, @Slotid,@AllocUnitID
 
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @hex_pageid AS VARCHAR(Max)
        /*Page ID contains File Number and page number It looks like 0001:00000130.
          In this example 0001 is file Number &  00000130 is Page Number & These numbers are in Hex format*/
        SET @Fileid=SUBSTRING(@ConsolidatedPageID,0,CHARINDEX(':',@ConsolidatedPageID)) -- Seperate File ID from Page ID
        SET @hex_pageid ='0x'+ SUBSTRING(@ConsolidatedPageID,CHARINDEX(':',@ConsolidatedPageID)+1,Len(@ConsolidatedPageID))  ---Seperate the page ID
        SELECT @Pageid=Convert(INT,cast('' AS XML).value('xs:hexBinary(substring(sql:variable("@hex_pageid"),sql:column("t.pos")) )', 'varbinary(max)')) -- Convert Page ID from hex to integer
        FROM (SELECT CASE substring(@hex_pageid, 1, 2) WHEN '0x' THEN 3 ELSE 0 END) AS t(pos) 
                     
        DELETE @temppagedata
        -- Now we need to get the actual data (After truncate) from the page
 
        INSERT INTO @temppagedata EXEC( 'DBCC PAGE(' + @DataBase_Name + ', ' + @fileid + ', ' + @pageid + ', 1) with tableresults,no_infomsgs;'); 
        ---Check if any index page is there
        If (Select Count(*) From @temppagedata Where [Field]='Record Type' And [Value]='INDEX_RECORD')=0
        Begin
            DELETE @temppagedata
            INSERT INTO @temppagedata EXEC( 'DBCC PAGE(' + @DataBase_Name + ', ' + @fileid + ', ' + @pageid + ', 3) with tableresults,no_infomsgs;'); 
        End
        Else
        Begin
           DELETE @temppagedata
        End
 
        INSERT INTO @pagedata SELECT @ConsolidatedPageID,@AllocUnitID,[ParentObject],[Object],[Field] ,[Value] FROM @temppagedata
        FETCH NEXT FROM Page_Data_Cursor INTO  @ConsolidatedPageID, @Slotid,@AllocUnitID
    END
 
CLOSE Page_Data_Cursor
DEALLOCATE Page_Data_Cursor
 
DECLARE @Newhexstring VARCHAR(MAX);
 
DECLARE @ModifiedRawData TABLE
(
  [ID] INT IDENTITY(1,1),
  [PAGE ID] VARCHAR(MAX),
  [Slot ID] INT,
  [AllocUnitId] BIGINT,
  [RowLog Contents 0_var] VARCHAR(MAX),
  [RowLog Contents 0] VARBINARY(8000)
)
--The truncated data is in multiple rows in the page, so we need to convert it into one row as a single hex value.
--This hex value is in string format
 
INSERT INTO @ModifiedRawData ([PAGE ID],[Slot ID],[AllocUnitId]
,[RowLog Contents 0_var])
SELECT [Page ID],Substring([ParentObject],CHARINDEX('Slot', [ParentObject])+4, (CHARINDEX('Offset', [ParentObject])-(CHARINDEX('Slot', [ParentObject])+4)) ) as [Slot ID]
,[AllocUnitId]
,(
SELECT REPLACE(STUFF((SELECT REPLACE(SUBSTRING([Value],CHARINDEX(':',[Value])+1,CHARINDEX('†',[Value])-CHARINDEX(':',[Value])),'†','')
FROM @pagedata C  WHERE B.[Page ID]= C.[Page ID] And Substring(B.[ParentObject],CHARINDEX('Slot', B.[ParentObject])+4, (CHARINDEX('Offset', B.[ParentObject])-(CHARINDEX('Slot', B.[ParentObject])+4)) )=Substring(C.[ParentObject],CHARINDEX('Slot', C.[ParentObject])+4, (CHARINDEX('Offset', C.[ParentObject])-(CHARINDEX('Slot', C.[ParentObject])+4)) ) And
[Object] Like '%Memory Dump%'
FOR XML PATH('') ),1,1,'') ,' ','')
) AS [Value]
From @pagedata B
Where [Object] Like '%Memory Dump%'
Group By [Page ID],[ParentObject],[AllocUnitId]
Order By [Slot ID]
 
-- Convert the hex value data in string, convert it into Hex value as well. 
UPDATE @ModifiedRawData  SET [RowLog Contents 0] = cast('' AS XML).value('xs:hexBinary(substring(sql:column("[RowLog Contents 0_var]"), 0) )', 'varbinary(max)')
FROM @ModifiedRawData
 
DECLARE @RowLogContents VARBINARY(8000)
Declare @AllocUnitName NVARCHAR(Max)
Declare @SQL NVARCHAR(Max)
DECLARE @bitTable TABLE
(
  [ID] INT,
  [Bitvalue] INT
)
----Create table to set the bit position of one byte.
 
INSERT INTO @bitTable
SELECT 0,2 UNION ALL
SELECT 1,2 UNION ALL
SELECT 2,4 UNION ALL
SELECT 3,8 UNION ALL
SELECT 4,16 UNION ALL
SELECT 5,32 UNION ALL
SELECT 6,64 UNION ALL
SELECT 7,128
 
--Create table to collect the row data.
DECLARE @DeletedRecords TABLE
(
    [RowLogContents]    VARBINARY(8000),
    [AllocUnitID]       BIGINT,
    [Transaction ID]    NVARCHAR(Max),
    [Slot ID]           INT,
    [FixedLengthData]   SMALLINT,
    [TotalNoOfCols]     SMALLINT,
    [NullBitMapLength]  SMALLINT,
    [NullBytes]         VARBINARY(8000),
    [TotalNoofVarCols]  SMALLINT,
    [ColumnOffsetArray] VARBINARY(8000),
    [VarColumnStart]    SMALLINT,
    [NullBitMap]        VARCHAR(MAX)
)
--Create a common table expression to get all the row data plus how many bytes we have for each row.
;WITH RowData AS (
SELECT
 
[RowLog Contents 0] AS [RowLogContents] 
 
,[AllocUnitID] AS [AllocUnitID] 
 
,[ID] AS [Transaction ID]  
 
,[Slot ID] as [Slot ID]
--[Fixed Length Data] = Substring (RowLog content 0, Status Bit A+ Status Bit B + 1,2 bytes)
,CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) AS [FixedLengthData]  --@FixedLengthData
 
 --[TotalnoOfCols] =  Substring (RowLog content 0, [Fixed Length Data] + 1,2 bytes)
,CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2)))) as  [TotalNoOfCols]
 
--[NullBitMapLength]=ceiling([Total No of Columns] /8.0)
,CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)) as [NullBitMapLength] 
 
--[Null Bytes] = Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [NullBitMapLength] )
,SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 3,
CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0))) as [NullBytes]
 
--[TotalNoofVarCols] = Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [Null Bitmap length] + 2 )
,(CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) In (0x30,0x70) THEN
CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0],
CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 3
+ CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)), 2))))  ELSE null  END) AS [TotalNoofVarCols] 
 
--[ColumnOffsetArray]= Substring (RowLog content 0, Status Bit A+ Status Bit B + [Fixed Length Data] +1, [Null Bitmap length] + 2 , [TotalNoofVarCols]*2 )
,(CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) In (0x30,0x70) THEN
SUBSTRING([RowLog Contents 0]
, CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 3
+ CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)) + 2
, (CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) In (0x30,0x70) THEN
CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0],
CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 3
+ CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)), 2))))  ELSE null  END)
* 2)  ELSE null  END) AS [ColumnOffsetArray] 
 
--  Variable column Start = Status Bit A+ Status Bit B + [Fixed Length Data] + [Null Bitmap length] + 2+([TotalNoofVarCols]*2)
,CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1)In (0x30,0x70)
THEN  (
CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 4 
 
+ CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)) 
 
+ ((CASE WHEN SUBSTRING([RowLog Contents 0], 1, 1) In (0x30,0x70) THEN
CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0],
CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 3
+ CONVERT(INT, ceiling(CONVERT(INT, CONVERT(BINARY(2), REVERSE(SUBSTRING([RowLog Contents 0], CONVERT(SMALLINT, CONVERT(BINARY(2)
,REVERSE(SUBSTRING([RowLog Contents 0], 2 + 1, 2)))) + 1, 2))))/8.0)), 2))))  ELSE null  END) * 2)) 
 
ELSE null End AS [VarColumnStart]
From @ModifiedRawData
),
 
---Use this technique to repeate the row till the no of bytes of the row.
N1 (n) AS (SELECT 1 UNION ALL SELECT 1),
N2 (n) AS (SELECT 1 FROM N1 AS X, N1 AS Y),
N3 (n) AS (SELECT 1 FROM N2 AS X, N2 AS Y),
N4 (n) AS (SELECT ROW_NUMBER() OVER(ORDER BY X.n)
           FROM N3 AS X, N3 AS Y)
 
insert into @DeletedRecords
Select   RowLogContents
        ,[AllocUnitID]
        ,[Transaction ID]
        ,[Slot ID]
        ,[FixedLengthData]
        ,[TotalNoOfCols]
        ,[NullBitMapLength]
        ,[NullBytes]
        ,[TotalNoofVarCols]
        ,[ColumnOffsetArray]
        ,[VarColumnStart]
         --Get the Null value against each column (1 means null zero means not null)
        ,[NullBitMap]=(REPLACE(STUFF((SELECT ',' +
        (CASE WHEN [ID]=0 THEN CONVERT(NVARCHAR(1),(SUBSTRING(NullBytes, n, 1) % 2))  ELSE CONVERT(NVARCHAR(1),((SUBSTRING(NullBytes, n, 1) / [Bitvalue]) % 2)) END) --as [nullBitMap]
FROM
N4 AS Nums
Join RowData AS C ON n<=NullBitMapLength
Cross Join @bitTable WHERE C.[RowLogContents]=D.[RowLogContents] ORDER BY [RowLogContents],n ASC FOR XML PATH('')),1,1,''),',',''))
FROM RowData D
 
CREATE TABLE [#temp_Data]
(
    [FieldName]  VARCHAR(MAX) COLLATE database_default NOT NULL,
    [FieldValue] VARCHAR(MAX) COLLATE database_default NOT NULL,
    [Rowlogcontents] VARBINARY(8000),
    [Transaction ID] VARCHAR(MAX) COLLATE database_default NOT NULL,
    [Slot ID] int
)
---Create common table expression and join it with the rowdata table
--to get each column details
;With CTE AS (
/*This part is for variable data columns*/
SELECT Rowlogcontents,
[Transaction ID],
[Slot ID],
NAME ,
cols.leaf_null_bit AS nullbit,
leaf_offset,
ISNULL(syscolumns.length, cols.max_length) AS [length],
cols.system_type_id,
cols.leaf_bit_position AS bitpos,
ISNULL(syscolumns.xprec, cols.precision) AS xprec,
ISNULL(syscolumns.xscale, cols.scale) AS xscale,
SUBSTRING([nullBitMap], cols.leaf_null_bit, 1) AS is_null,
--Calculate the variable column size from the variable column offset array
(CASE WHEN leaf_offset<1 and SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=0 THEN
CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * leaf_offset*-1) - 1, 2)))) ELSE 0 END) AS [Column value Size],
 
---Calculate the column length
(CASE WHEN leaf_offset<1 and SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=0 THEN  CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * (leaf_offset*-1)) - 1, 2))))
- ISNULL(NULLIF(CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * ((leaf_offset*-1) - 1)) - 1, 2)))), 0), [varColumnStart])
ELSE 0 END) AS [Column Length]
 
--Get the Hexa decimal value from the RowlogContent
--HexValue of the variable column=Substring([Column value Size] - [Column Length] + 1,[Column Length])
--This is the data of your column but in the Hexvalue
,CASE WHEN SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=1 THEN NULL ELSE
SUBSTRING(Rowlogcontents,((CASE WHEN leaf_offset<1 and SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=0 THEN CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * leaf_offset*-1) - 1, 2)))) ELSE 0 END)
- ((CASE WHEN leaf_offset<1 and SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=0 THEN  CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * (leaf_offset*-1)) - 1, 2))))
- ISNULL(NULLIF(CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * ((leaf_offset*-1) - 1)) - 1, 2)))), 0), [varColumnStart])
ELSE 0 END))) + 1,((CASE WHEN leaf_offset<1 and SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=0 THEN  CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * (leaf_offset*-1)) - 1, 2))))
- ISNULL(NULLIF(CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (SUBSTRING ([ColumnOffsetArray], (2 * ((leaf_offset*-1) - 1)) - 1, 2)))), 0), [varColumnStart])
ELSE 0 END))) END AS hex_Value
 
FROM @DeletedRecords A
Inner Join sys.allocation_units allocunits On A.[AllocUnitId]=allocunits.[Allocation_Unit_Id]
INNER JOIN sys.partitions partitions ON (allocunits.type IN (1, 3)
AND partitions.hobt_id = allocunits.container_id) OR (allocunits.type = 2 AND partitions.partition_id = allocunits.container_id)
INNER JOIN sys.system_internals_partition_columns cols ON cols.partition_id = partitions.partition_id
LEFT OUTER JOIN syscolumns ON syscolumns.id = partitions.object_id AND syscolumns.colid = cols.partition_column_id
WHERE leaf_offset<0
 
UNION
/*This part is for fixed data columns*/
SELECT  Rowlogcontents,
[Transaction ID],
[Slot ID],
NAME ,
cols.leaf_null_bit AS nullbit,
leaf_offset,
ISNULL(syscolumns.length, cols.max_length) AS [length],
cols.system_type_id,
cols.leaf_bit_position AS bitpos,
ISNULL(syscolumns.xprec, cols.precision) AS xprec,
ISNULL(syscolumns.xscale, cols.scale) AS xscale,
SUBSTRING([nullBitMap], cols.leaf_null_bit, 1) AS is_null,
(SELECT TOP 1 ISNULL(SUM(CASE WHEN C.leaf_offset >1 THEN max_length ELSE 0 END),0) FROM
sys.system_internals_partition_columns C WHERE cols.partition_id =C.partition_id And C.leaf_null_bit<cols.leaf_null_bit)+5 AS [Column value Size],
syscolumns.length AS [Column Length]
 
,CASE WHEN SUBSTRING([nullBitMap], cols.leaf_null_bit, 1)=1 THEN NULL ELSE
SUBSTRING
(
Rowlogcontents,(SELECT TOP 1 ISNULL(SUM(CASE WHEN C.leaf_offset >1 THEN max_length ELSE 0 END),0) FROM
sys.system_internals_partition_columns C where cols.partition_id =C.partition_id And C.leaf_null_bit<cols.leaf_null_bit)+5
,syscolumns.length) END AS hex_Value
FROM @DeletedRecords A
Inner Join sys.allocation_units allocunits ON A.[AllocUnitId]=allocunits.[Allocation_Unit_Id]
INNER JOIN sys.partitions partitions ON (allocunits.type IN (1, 3)
 AND partitions.hobt_id = allocunits.container_id) OR (allocunits.type = 2 AND partitions.partition_id = allocunits.container_id)
INNER JOIN sys.system_internals_partition_columns cols ON cols.partition_id = partitions.partition_id
LEFT OUTER JOIN syscolumns ON syscolumns.id = partitions.object_id AND syscolumns.colid = cols.partition_column_id
WHERE leaf_offset>0 )
 
--Converting data from Hexvalue to its orgional datatype.
--Implemented datatype conversion mechanism for each datatype
--Select * from sys.columns Where [object_id]=object_id('' + @SchemaName_n_TableName + '')
 
INSERT INTO #temp_Data
SELECT NAME,
CASE
 WHEN system_type_id IN (231, 239) THEN  LTRIM(RTRIM(CONVERT(NVARCHAR(max),hex_Value)))  --NVARCHAR ,NCHAR
 WHEN system_type_id IN (167,175) THEN  LTRIM(RTRIM(CONVERT(VARCHAR(max),REPLACE(hex_Value, 0x00, 0x20))))  --VARCHAR,CHAR
 WHEN system_type_id = 48 THEN CONVERT(VARCHAR(MAX), CONVERT(TINYINT, CONVERT(BINARY(1), REVERSE (hex_Value)))) --TINY INTEGER
 WHEN system_type_id = 52 THEN CONVERT(VARCHAR(MAX), CONVERT(SMALLINT, CONVERT(BINARY(2), REVERSE (hex_Value)))) --SMALL INTEGER
 WHEN system_type_id = 56 THEN CONVERT(VARCHAR(MAX), CONVERT(INT, CONVERT(BINARY(4), REVERSE(hex_Value)))) -- INTEGER
 WHEN system_type_id = 127 THEN CONVERT(VARCHAR(MAX), CONVERT(BIGINT, CONVERT(BINARY(8), REVERSE(hex_Value))))-- BIG INTEGER
 WHEN system_type_id = 61 Then CONVERT(VARCHAR(MAX),CONVERT(DATETIME,CONVERT(VARBINARY(8000),REVERSE (hex_Value))),100) --DATETIME
 WHEN system_type_id =58 Then CONVERT(VARCHAR(MAX),CONVERT(SMALLDATETIME,CONVERT(VARBINARY(8000),REVERSE(hex_Value))),100) --SMALL DATETIME
 WHEN system_type_id = 108 THEN CONVERT(VARCHAR(MAX),CONVERT(NUMERIC(38,20), CONVERT(VARBINARY,CONVERT(VARBINARY(1),xprec)+CONVERT(VARBINARY(1),xscale))+CONVERT(VARBINARY(1),0) + hex_Value)) --- NUMERIC  
 WHEN system_type_id In(60,122) THEN CONVERT(VARCHAR(MAX),Convert(MONEY,Convert(VARBINARY(8000),Reverse(hex_Value))),2) --MONEY,SMALLMONEY
 WHEN system_type_id =106 THEN CONVERT(VARCHAR(MAX), CAST(CONVERT(Decimal(38,34), CONVERT(VARBINARY,Convert(VARBINARY,xprec)+CONVERT(VARBINARY,xscale))+CONVERT(VARBINARY(1),0) + hex_Value) as FLOAT)) --- DECIMAL
 WHEN system_type_id = 104 THEN CONVERT(VARCHAR(MAX),CONVERT (BIT,CONVERT(BINARY(1), hex_Value)%2))  -- BIT
 WHEN system_type_id =62 THEN  RTRIM(LTRIM(STR(CONVERT(FLOAT,SIGN(CAST(CONVERT(VARBINARY(8000),Reverse(hex_Value)) AS BIGINT)) * (1.0 + (CAST(CONVERT(VARBINARY(8000),Reverse(hex_Value)) AS BIGINT) & 0x000FFFFFFFFFFFFF) * POWER(CAST(2 AS FLOAT), -52)) * POWER(CAST(2 AS FLOAT),((CAST(CONVERT(VARBINARY(8000),Reverse(hex_Value)) AS BIGINT) & 0x7ff0000000000000) / EXP(52 * LOG(2))-1023))),53,LEN(hex_Value)))) --- FLOAT
 When system_type_id =59 THEN  Left(LTRIM(STR(CAST(SIGN(CAST(Convert(VARBINARY(8000),REVERSE(hex_Value)) AS BIGINT))* (1.0 + (CAST(CONVERT(VARBINARY(8000),Reverse(hex_Value)) AS BIGINT) & 0x007FFFFF) * POWER(CAST(2 AS Real), -23)) * POWER(CAST(2 AS Real),(((CAST(CONVERT(VARBINARY(8000),Reverse(hex_Value)) AS INT) )& 0x7f800000)/ EXP(23 * LOG(2))-127))AS REAL),23,23)),8) --Real
 WHEN system_type_id In (165,173) THEN (CASE WHEN CHARINDEX(0x,cast('' AS XML).value('xs:hexBinary(sql:column("hex_Value"))', 'VARBINARY(8000)')) = 0 THEN '0x' ELSE '' END) +cast('' AS XML).value('xs:hexBinary(sql:column("hex_Value"))', 'varchar(max)') -- BINARY,VARBINARY
 WHEN system_type_id =36 THEN CONVERT(VARCHAR(MAX),CONVERT(UNIQUEIDENTIFIER,hex_Value)) --UNIQUEIDENTIFIER
 END AS FieldValue
,[Rowlogcontents]
,[Transaction ID]
,[Slot ID]
FROM CTE ORDER BY nullbit
 
--Create the column name in the same order to do pivot table.
 
DECLARE @FieldName VARCHAR(max)
SET @FieldName = STUFF(
(
SELECT ',' + CAST(QUOTENAME([Name]) AS VARCHAR(MAX)) FROM syscolumns WHERE id=object_id('' + @SchemaName_n_TableName + '')
 
FOR XML PATH('')
), 1, 1, '')
 
--Finally did pivot table and got the data back in the same format.
--The [Update Statement] column will give you the query that you can execute in case of recovery.
SET @sql = 'SELECT ' + @FieldName  + ' FROM #temp_Data 
PIVOT (Min([FieldValue]) FOR FieldName IN (' + @FieldName  + ')) AS pvt
ORDER BY Convert(int,[Transaction ID],Convert(int,[Slot ID]))'
 
EXEC sp_executesql @sql
 
GO
--Execute the procedure like
--Recover_Truncated_Data_Proc 'Database name''Schema.table name','Date from' ,'Date to'
 
--EXAMPLE #1 : FOR ALL TRUNCATED RECORDS
EXEC Recover_Truncated_Data_Proc 'cupidknot',' cupidknot.transactions'
GO
