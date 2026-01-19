class SyncSummary {
  int total = 0;      // 总日历数
  int success = 0;    // 成功数
  int failed = 0;     // 失败数
  int processing = 0; // 正在同步数

  // 详情记录
  List<String> successLog = [];
  List<String> errorLog = [];

  void reset(int count) {
    total = count;
    success = 0;
    failed = 0;
    processing = 0;
    successLog.clear();
    errorLog.clear();
  }
}