# 使用 StoredProcedure 進行訂單編號管理範例程式碼

產生的訂單編號格式為

(YYMMDDHHMMSS + 000000)

日期時間與序號的關係如下

```
20190101235958000001  --GETDATE() return 2019-01-01 23:59:58
20190101235958000002
20190101235958000003
20190101235959000001  --GETDATE() return 2019-01-01 23:59:59
20190101235959000002
```

當秒數遞增時序號就會自動從 1 開始且不會有訂單編號重複的問題產生

使用 .NET Core ConsoleApp 產生多個 Task 進行壓力測試
