#include <filesystem>

#include "../zip.h"
#include <iostream>
#include <fstream>
#include <thread>

void createTestFiles() {
  std::filesystem::create_directories(std::filesystem::path("test/test"));
  std::ofstream out("test/test.txt");
  out << "Hello World!\n";
  out.close();
  std::ofstream out2("test/test2.txt");
  out2 << "Hello World!\n";
  out2.close();
  std::ofstream out3("test/test/test3.txt");
  out3 << "Hello World!\n";
  out3.close();
}

void compressTest() {
  const char* files[3] {
    "test/test.txt",
    "test/test2.txt",
    "test/test/test3.txt"
  };
  const char* entries[] {
    "test.txt",
    "test2.txt",
    "test/test3.txt",
  };
  auto zip = zip_open("test.zip", 7, 'w');
  auto handler = zip_entry_thread_write_files(zip, entries, files, 3);
  for (;;) {
    auto status = zip_thread_write_status(zip, handler);
    if (status == ZipWriteStatus::ZIP_WRITE_STATUS_OK) {
      break;
    } else if (status == ZipWriteStatus::ZIP_WRITE_STATUS_ERROR) {
      std::cerr << "Error while writing to test zip" << std::endl;
      exit(1);
    }
    std::this_thread::sleep_for(std::chrono::seconds(1));
  }
  zip_close(zip);
}

int main() {
  createTestFiles();
  compressTest();
}