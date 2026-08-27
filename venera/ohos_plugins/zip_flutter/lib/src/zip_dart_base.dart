import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zip_flutter/src/multithreading.dart';
import 'generated_bindings.dart';
import 'package:path/path.dart' as path;

typedef _ZipFilePtr = ffi.Pointer<zip_t>;

const String _libName = 'zip_flutter';

final _dylib = () {
  if (Platform.operatingSystem == 'ohos') {
    // Built by the ohos entry module's CMake target `zip_flutter`.
    return ffi.DynamicLibrary.open('libzip_flutter.so');
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return ffi.DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return ffi.DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return ffi.DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

final NativeLibrary _lib = NativeLibrary(_dylib);

int _onExtractEntry(ffi.Pointer<ffi.Char> filename, ffi.Pointer<ffi.Void> arg) {
  return 0;
}

/// A class that collects pointers and frees them when the object is destroyed.
class _Collector {
  static final finalizer = Finalizer<List<ffi.Pointer>>((token) {
    for (var pointer in token) {
      malloc.free(pointer);
    }
  });

  _Collector() {
    finalizer.attach(this, _pointers);
  }

  final List<ffi.Pointer> _pointers = [];

  void add(ffi.Pointer pointer) {
    _pointers.add(pointer);
  }

  void call(ffi.Pointer pointer) {
    add(pointer);
  }

  ffi.Pointer<T> allocate<T extends ffi.NativeType>(int count) {
    var pointer = malloc.allocate<T>(count);
    add(pointer);
    return pointer;
  }
}

extension _StringNavite on String {
  ffi.Pointer<ffi.Int8> toNative([_Collector? collector]) {
    final pointer = toNativeUtf8();
    collector?.add(pointer);
    return pointer.cast();
  }
}

enum ZipOpenMode {
  readonly(114),
  write(119),
  append(97);

  final int value;

  const ZipOpenMode(this.value);
}

class ZipFile {
  final _ZipFilePtr _zip;

  /// Opens zip archive with compression level using the given mode.
  ///
  /// To read a zip archive, use [ZipOpenMode.readonly].
  factory ZipFile.open(String path,
      {int level = 6, ZipOpenMode mode = ZipOpenMode.write}) {
    var res = _lib.zip_open(path.toNativeUtf8().cast(), level, mode.value);
    if (res == ffi.nullptr) {
      throw const ZipException("Failed to open file.");
    }
    var zip = ZipFile._create(res);
    return zip;
  }

  /// Open zip archive in readonly mode.
  factory ZipFile.openRead(String path) {
    return ZipFile.open(path, mode: ZipOpenMode.readonly);
  }

  ZipFile._create(this._zip);

  /// Opens an entry by [name] in the zip archive.
  /// Then compresses [sourceFile] file for the current zip entry.
  ///
  /// example:
  ///
  /// ```dart
  /// var zip = ZipFile.open("/home/test.zip");
  /// zip.addFile("1.txt", "/home/1.txt");
  /// zip.addFile("folder/2.txt", "/home/2.txt");
  /// zip.close();
  /// ```
  void addFile(String name, String sourceFile) {
    var collector = _Collector();
    var res = _lib.zip_entry_open(_zip, name.toNative(collector).cast());
    if (res < 0) {
      throw const ZipException("Failed to open entry.");
    }
    res = _lib.zip_entry_fwrite(_zip, sourceFile.toNative(collector).cast());
    if (res < 0) {
      throw ZipException("Failed to write content.\n"
          "Input: $sourceFile\n"
          "Trying write to $name\n"
          "Error Code $res\n");
    }
    res = _lib.zip_entry_close(_zip);
    if (res < 0) {
      throw const ZipException("Failed to close entry.");
    }
  }

  /// Adds a file to the zip archive from bytes.
  ///
  /// This method has lower performance than the [addFile] method
  /// because it copies the bytes into native memory.
  void addFileFromBytes(String name, Uint8List bytes) {
    var collector = _Collector();
    var res = _lib.zip_entry_open(_zip, name.toNative(collector).cast());
    if (res < 0) {
      throw const ZipException("Failed to open entry.");
    }
    var data = collector.allocate<ffi.Uint8>(bytes.length);
    for (int i = 0; i < bytes.length; i++) {
      data[i] = bytes[i];
    }
    res = _lib.zip_entry_write(_zip, data.cast(), bytes.length);
    if (res < 0) {
      throw ZipException("Failed to write content.\n"
          "Trying write to $name\n"
          "Error Code $res\n");
    }
    res = _lib.zip_entry_close(_zip);
    if (res < 0) {
      throw const ZipException("Failed to close entry.");
    }
  }

  /// Adds multiple files to the zip archive.
  ///
  /// This method will create a new thread to write the files and not block the current thread.
  ///
  /// Do not use this method with other methods that write to the zip archive at the same time.
  Future<void> addFilesAsync(
      List<String> names, List<String> sourceFiles) async {
    if (names.length != sourceFiles.length) {
      throw const ZipException(
          "Names and source files must have the same length.");
    }
    var collector = _Collector();
    var count = names.length;
    var entryNames = collector.allocate<ffi.Pointer<ffi.Char>>(
        count * ffi.sizeOf<ffi.Pointer<ffi.Char>>());
    var fileNames = collector.allocate<ffi.Pointer<ffi.Char>>(
        count * ffi.sizeOf<ffi.Pointer<ffi.Char>>());
    for (int i = 0; i < count; i++) {
      entryNames[i] = names[i].toNative(collector).cast();
      fileNames[i] = sourceFiles[i].toNative(collector).cast();
    }
    var handler = _lib.zip_entry_thread_write_files(
      _zip,
      entryNames,
      fileNames,
      names.length,
    );
    while (true) {
      var status = _lib.zip_thread_write_status(_zip, handler);
      if (status == ZipWriteStatus.ZIP_WRITE_STATUS_OK) {
        break;
      } else if (status == ZipWriteStatus.ZIP_WRITE_STATUS_ERROR) {
        throw const ZipException("Failed to write content.");
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  /// Adds an empty directory to the zip archive.
  void addDirectory(String name) {
    var collector = _Collector();
    if (name.endsWith("\\") || name.endsWith("/")) {
      name = name.substring(0, name.length - 1);
    }
    // A entry which is a directory must end with a slash '/', '\' is not allowed.
    name = "$name/";
    var res = _lib.zip_entry_open(_zip, name.toNative(collector).cast());
    if (res < 0) {
      throw const ZipException("Failed to open entry.");
    }
    res = _lib.zip_entry_close(_zip);
    if (res < 0) {
      throw const ZipException("Failed to close entry.");
    }
  }

  /// close zip file.
  void close() {
    _lib.zip_close(_zip);
  }

  /// Get the number of entries in the zip archive.
  int get entriesCount => _lib.zip_entries_total(_zip);

  /// Open a new entry by index in the zip archive.
  /// This function is only valid if zip archive was opened in readonly mode.
  ZipEntry getEntryByIndex(int index) {
    try {
      var res = _lib.zip_entry_openbyindex(_zip, index);
      if (res < 0) {
        throw const ZipException("Failed to open entry.");
      }
      return ZipEntry(
        _lib.zip_entry_name(_zip).cast<Utf8>().toDartString(),
        index,
        _lib.zip_entry_isdir(_zip) != 0,
        _lib.zip_entry_size(_zip),
        _lib.zip_entry_crc32(_zip),
        this,
      );
    } finally {
      _lib.zip_entry_close(_zip);
    }
  }

  /// Open an entry by name in the zip archive.
  ///
  /// For zip archive opened in write or append mode the function will append
  /// a new entry. In readonly mode the function tries to locate the entry
  /// in global dictionary.
  ZipEntry getEntryByName(String name) {
    try {
      var res = _lib.zip_entry_open(_zip, name.toNativeUtf8().cast());
      if (res < 0) {
        throw const ZipException("Failed to open entry.");
      }
      return ZipEntry(
        name,
        _lib.zip_entry_index(_zip),
        _lib.zip_entry_isdir(_zip) != 0,
        _lib.zip_entry_size(_zip),
        _lib.zip_entry_crc32(_zip),
        this,
      );
    } finally {
      _lib.zip_entry_close(_zip);
    }
  }

  /// Get all entries in the zip archive.
  List<ZipEntry> getAllEntries() {
    var entries = <ZipEntry>[];
    for (int i = 0; i < entriesCount; i++) {
      entries.add(getEntryByIndex(i));
    }
    return entries;
  }

  /// Delete a zip archive entry.
  void deleteEntry(String name) {
    var collector = _Collector();
    var res = _lib.zip_entries_delete(
        _zip, name.toNative(collector).cast().cast(), 1);
    if (res < 0) {
      throw const ZipException("Failed to delete entry.");
    }
  }

  /// Extracts a zip archive file into directory.
  ///
  /// The method will block the current thread.
  static void openAndExtract(String zipFile, String extractTo) {
    var collector = _Collector();
    ffi.Pointer<ffi.Int32> arg = collector.allocate(4);

    ffi.Pointer<
            ffi.NativeFunction<
                ffi.Int Function(
                    ffi.Pointer<ffi.Char> filename, ffi.Pointer<ffi.Void> arg)>>
        func = ffi.Pointer.fromFunction(_onExtractEntry, 0);

    _lib.zip_extract(
      zipFile.toNative(collector).cast(),
      extractTo.toNative(collector).cast(),
      func,
      arg.cast(),
    );

    malloc.free(arg);
  }

  /// Extracts a zip archive file into a directory.
  ///
  /// Set [isolates] to the number of isolates to use for extraction.
  ///
  /// The method will not block the current thread.
  static Future<void> openAndExtractAsync(String zipFile, String extractTo,
      [int isolates = 1]) {
    return isolatesExtract(zipFile, extractTo, isolates);
  }

  /// Compresses a folder to a zip archive.
  ///
  /// The method will block the current thread.
  static void compressFolder(String sourceFolder, String zipFileName) {
    sourceFolder = path.absolute(sourceFolder);
    var zip = ZipFile.open(zipFileName);
    void walk(String path) {
      for (var entry in Directory(path).listSync()) {
        if (entry is Directory) {
          walk(entry.path);
        } else {
          var filePathInZip = entry.path.replaceFirst(sourceFolder, "");
          if (filePathInZip.startsWith('/') || filePathInZip.startsWith('\\')) {
            filePathInZip = filePathInZip.substring(1);
          }
          zip.addFile(filePathInZip, entry.path);
        }
      }
    }

    walk(sourceFolder);
    zip.close();
  }

  /// Compresses a folder to a zip archive using multiple threads.
  ///
  /// Set [threads] to the number of threads to use for compression.
  ///
  /// The method will not block the current thread.
  static Future<void> compressFolderAsync(
      String sourceFolder, String zipFileName,
      [int threads = 1]) {
    return compressFolderMultiThreaded(sourceFolder, zipFileName, threads);
  }
}

class ZipEntry {
  final String name;
  final int index;
  final bool isDir;
  final int size;
  final int crc32;
  final ZipFile _file;

  const ZipEntry(
      this.name, this.index, this.isDir, this.size, this.crc32, ZipFile file)
      : _file = file;

  /// Deletes zip archive entry
  void delete() {
    var collector = _Collector();
    var res = _lib.zip_entries_delete(
        _file._zip, name.toNative(collector).cast().cast(), 1);
    if (res < 0) {
      throw const ZipException("Failed to delete an entry");
    }
  }

  /// Extracts zip archive entry as Uint8List
  Uint8List read() {
    if (isDir) {
      throw const ZipException("Entry is Directory");
    }
    var res = _lib.zip_entry_openbyindex(_file._zip, index);
    if (res < 0) {
      throw const ZipException("Failed to open entry");
    }
    try {
      int size = _lib.zip_entry_size(_file._zip);
      var buf = malloc.allocate<ffi.Uint8>(size);
      res = _lib.zip_entry_noallocread(_file._zip, buf.cast(), size);
      if (res < 0) {
        throw const ZipException("Failed to read data");
      }
      return buf.asTypedList(size, finalizer: malloc.nativeFree);
    } finally {
      _lib.zip_entry_close(_file._zip);
    }
  }

  void writeToFile(String path) {
    if (isDir) {
      throw const ZipException("Entry is Directory");
    }
    var file = File(path);
    file.createSync(recursive: true);
    var res = _lib.zip_entry_openbyindex(_file._zip, index);
    if (res < 0) {
      throw const ZipException("Failed to open entry");
    }
    res = _lib.zip_entry_fread(_file._zip, path.toNativeUtf8().cast());
    if (res < 0) {
      throw const ZipException("Failed to write data");
    }
    res = _lib.zip_entry_close(_file._zip);
    if (res < 0) {
      throw const ZipException("Failed to close entry");
    }
  }

  @override
  String toString() {
    return 'ZipEntry{name: $name, index: $index, isDir: $isDir, size: $size, crc32: $crc32}';
  }
}

class ZipException implements Exception {
  const ZipException(this.message);

  final String message;

  @override
  String toString() => "ZipException: $message";
}

final _tdeflFreeData =
    _dylib.lookup<ffi.NativeFunction<ffi.Void Function(ffi.UnsignedChar)>>(
        'tdefl_free_data');

/// Compresses data using the miniz tdefl algorithm.
Uint8List tdeflCompressData(
    Uint8List data, bool withZlibHeader, bool computeAdler32, int level) {
  var flags = 0;
  if (withZlibHeader) {
    flags |= TDEFL_COMPRESS_FLAGS.TDEFL_COMPRESS_WRITE_ZLIB_HEADER;
  }
  if (computeAdler32) {
    flags |= TDEFL_COMPRESS_FLAGS.TDEFL_COMPRESS_COMPUTE_ADLER32;
  }
  level = level.clamp(0, 10);
  const levelFlags = [0, 1, 6, 32, 16, 32, 128, 256, 512, 768, 1500];
  flags |= levelFlags[level];
  var collector = _Collector();
  var dataPointer = collector.allocate<ffi.Uint8>(data.length);
  for (int i = 0; i < data.length; i++) {
    dataPointer[i] = data[i];
  }
  var outSize = collector.allocate<ffi.Size>(ffi.sizeOf<ffi.Size>());
  var compressed =
      _lib.tdefl_compress_data(dataPointer.cast(), data.length, outSize, flags);
  return compressed
      .cast<ffi.Uint8>()
      .asTypedList(outSize.value, finalizer: _tdeflFreeData.cast());
}
