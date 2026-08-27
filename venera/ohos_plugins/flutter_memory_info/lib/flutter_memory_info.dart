class MemoryInfo {
  static Future<int> getFreePhysicalMemorySize() async => 4 << 30;

  static Future<int> getTotalPhysicalMemorySize() async => 8 << 30;
}
