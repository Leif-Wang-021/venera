import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:venera/components/components.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/context.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/ext.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

enum _SortRule { name, date, size }

/// Built-in lightweight file manager for the local comics storage directory.
///
/// Manages the comic files (sorting / multi-select batch ops / live search /
/// breadcrumb navigation) inside the app sandbox storage, since HarmonyOS
/// hides it from the system file manager.
class StorageBrowserPage extends StatefulWidget {
  final String path;

  const StorageBrowserPage({super.key, required this.path});

  @override
  State<StorageBrowserPage> createState() => _StorageBrowserPageState();
}

class _Entry {
  final String path;
  final String name;
  final bool isDir;
  final int size;
  final DateTime modified;

  const _Entry(this.path, this.name, this.isDir, this.size, this.modified);
}

class _StorageBrowserPageState extends State<StorageBrowserPage> {
  String currentPath = '';
  final List<String> _history = [];
  final Set<String> _selected = {};
  _SortRule _sort = _SortRule.name;
  String _search = '';
  bool _multi = false;
  bool _busy = false;

  String get _root => widget.path;

  @override
  void initState() {
    super.initState();
    currentPath = widget.path;
    final saved = appdata.settings['storageSort'];
    if (saved == 'date') {
      _sort = _SortRule.date;
    } else if (saved == 'size') {
      _sort = _SortRule.size;
    }
  }

  void _persistSort() {
    appdata.settings['storageSort'] = _sort.name;
    appdata.saveData();
  }

  void _refresh() => setState(() {});

  void _enterDir(String path) {
    _history.add(currentPath);
    currentPath = path;
    _selected.clear();
    _search = '';
    setState(() {});
  }

  void _goBack() {
    if (_history.isNotEmpty) {
      currentPath = _history.removeLast();
      _selected.clear();
      _search = '';
      setState(() {});
    }
  }

  List<_Entry> _listLocal(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return d.listSync().map((e) {
        final isDir = e is Directory;
        var size = 0;
        DateTime modified;
        try {
          final st = FileSystemEntity.typeSync(e.path);
          if (st == FileSystemEntityType.file) {
            size = File(e.path).lengthSync();
          }
          modified = e.statSync().modified;
        } catch (_) {
          modified = DateTime.fromMillisecondsSinceEpoch(0);
        }
        return _Entry(e.path, e.path.split('/').last, isDir, size, modified);
      }).toList();
    } catch (e) {
      Log.error('StorageMgr', e);
      return const [];
    }
  }

  int _countEntries(String dir) {
    try {
      return Directory(dir).listSync().length;
    } catch (_) {
      return 0;
    }
  }

  List<_Entry> _collect() {
    final entries = _search.trim().isEmpty
        ? _listLocal(currentPath)
        : _searchRecursive(currentPath, _search.trim().toLowerCase(), 0);
    return _sortEntries(entries);
  }

  List<_Entry> _searchRecursive(String dir, String q, int depth) {
    final out = <_Entry>[];
    if (depth > 3) return out;
    try {
      for (final e in Directory(dir).listSync()) {
        final name = e.path.split('/').last;
        final isDir = e is Directory;
        if (name.toLowerCase().contains(q)) {
          var size = 0;
          if (!isDir) {
            try {
              size = File(e.path).lengthSync();
            } catch (_) {}
          }
          out.add(_Entry(
            e.path,
            isDir
                ? '$name/'
                : name,
            isDir,
            size,
            _safeModified(e),
          ));
        }
        if (isDir) {
          out.addAll(_searchRecursive(e.path, q, depth + 1));
        }
      }
    } catch (_) {}
    return out;
  }

  DateTime _safeModified(FileSystemEntity e) {
    try {
      return e.statSync().modified;
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
  }

  List<_Entry> _sortEntries(List<_Entry> source) {
    final dirs = source.where((e) => e.isDir).toList();
    final files = source.where((e) => !e.isDir).toList();
    int cmp(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    dirs.sort((a, b) => cmp(a.name, b.name));
    switch (_sort) {
      case _SortRule.name:
        files.sort((a, b) => cmp(a.name, b.name));
      case _SortRule.date:
        files.sort((a, b) => b.modified.compareTo(a.modified));
      case _SortRule.size:
        files.sort((a, b) => b.size.compareTo(a.size));
    }
    return [...dirs, ...files];
  }

  // ---- operations ----

  Future<void> _pickTarget(void Function(String) onChosen) async {
    final target = await showDialog<String>(
      context: context,
      builder: (c) => _TargetFolderDialog(root: _root, current: currentPath),
    );
    if (target != null) onChosen(target);
  }

  Future<void> _rename(_Entry e) async {
    await showInputDialog(
      context: context,
      title: "Rename".tl,
      initialValue: e.name,
      onConfirm: (v) {
        final name = v.trim();
        if (name.isEmpty) return 'Empty name';
        final target = p.join(p.dirname(e.path), name);
        if (target == e.path) return null;
        if (FileSystemEntity.typeSync(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return 'Exists';
        }
        try {
          final src = e.isDir ? Directory(e.path) : File(e.path);
          src.renameSync(target);
          _refresh();
          return null;
        } catch (err) {
          return err.toString();
        }
      },
      confirmText: "Confirm".tl,
    );
  }

  Future<void> _copySingle(_Entry e) async {
    _pickTarget((target) => _run('Copy', () async {
      await _copyInto(e, target);
    }));
  }

  Future<void> _copyInto(_Entry e, String targetDir) async {
    final dest = p.join(targetDir, e.name);
    if (FileSystemEntity.typeSync(dest, followLinks: false) !=
        FileSystemEntityType.notFound) {
      if (mounted) context.showMessage(message: 'Exists');
      return;
    }
    final src = e.isDir ? Directory(e.path) : File(e.path);
    if (e.isDir) {
      await copyDirectoryIsolate(Directory(e.path), Directory(dest));
    } else {
      await (src as File).copy(dest);
    }
  }

  Future<void> _moveSingles(List<_Entry> list, String targetDir) async {
    for (final e in list) {
      final dest = p.join(targetDir, e.name);
      try {
        final src = e.isDir ? Directory(e.path) : File(e.path);
        if (FileSystemEntity.typeSync(dest, followLinks: false) !=
            FileSystemEntityType.notFound) {
          src.renameSync('${dest}.dup');
        }
        if (e.isDir) {
          await copyDirectoryIsolate(Directory(e.path), Directory(dest));
          await src.delete(recursive: true);
        } else {
          await (src as File).copy(dest);
          await src.delete();
        }
      } catch (err) {
        Log.error('StorageMgr', err);
      }
    }
  }

  Future<void> _deleteSingle(_Entry e) async {
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            children: [
              Text('确定要删除 [@n] 吗？'.tlParams({'n': e.name})),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: Text("cancel".tl),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(c).colorScheme.error),
                    onPressed: () => Navigator.pop(c, true),
                    child: Text("Delete".tl),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final src = e.isDir ? Directory(e.path) : File(e.path);
      if (e.isDir) {
        await src.delete(recursive: true);
      } else {
        await src.delete();
      }
      _refresh();
    } catch (err) {
      if (mounted) context.showMessage(message: err.toString());
    }
  }

  Future<void> _deleteSelected() async {
    final n = _selected.length;
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      builder: (c) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            children: [
              Text('确定要删除 [@n] 项吗？'.tlParams({'n': '$n'})),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(c, false),
                    child: Text("cancel".tl),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(c).colorScheme.error),
                    onPressed: () => Navigator.pop(c, true),
                    child: Text("Delete @a".tlParams({'a': '$n'})),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    final list = _selected.map((s) {
      final isDir =
          FileSystemEntity.typeSync(s, followLinks: false) ==
              FileSystemEntityType.directory;
      return _Entry(s, s.split('/').last, isDir, 0, DateTime.now());
    }).toList();
    for (final e in list) {
      try {
        if (e.isDir) {
          await Directory(e.path).delete(recursive: true);
        } else {
          await File(e.path).delete();
        }
      } catch (err) {
        Log.error('StorageMgr', err);
      }
    }
    _selected.clear();
    _refresh();
  }

  Future<void> _moveSelectedToList() async {
    final list = _selected.map((s) {
      final isDir =
          FileSystemEntity.typeSync(s, followLinks: false) ==
              FileSystemEntityType.directory;
      return _Entry(s, s.split('/').last, isDir, 0, DateTime.now());
    }).toList();
    _selected.clear();
    _refresh();
    _pickTarget((target) => _run('Move', () => _moveSingles(list, target)));
  }

  Future<void> _newFolder() async {
    await showInputDialog(
      context: context,
      title: "Create Folder".tl,
      onConfirm: (v) {
        final name = v.trim();
        if (name.isEmpty) return 'Empty name';
        final dir = Directory(p.join(currentPath, name));
        try {
          if (dir.existsSync()) return 'Exists';
          dir.createSync();
          _refresh();
          return null;
        } catch (err) {
          return err.toString();
        }
      },
      confirmText: "Confirm".tl,
    );
  }

  Future<void> _run(String tag, Future<void> Function() fn) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await fn();
    } catch (e) {
      Log.error('StorageMgr', e);
      if (mounted) context.showMessage(message: e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- UI ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: Appbar(
        title: Text(_multi
            ? '已选 @n 项'.tlParams({'n': '${_selected.length}'})
            : '漫画文件'.tl),
        actions: [
          if (!_multi)
            IconButton(
              icon: const Icon(Icons.sort),
              tooltip: "Sort".tl,
              onPressed: _showSortSheet,
            ),
          IconButton(
            icon: Icon(_multi ? Icons.close : Icons.checklist),
            tooltip: _multi ? "Exit".tl : "Multi-Select".tl,
            onPressed: () {
              setState(() {
                _multi = !_multi;
                _selected.clear();
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _breadcrumbBar(),
          if (!_multi) _searchBar(),
          Expanded(child: _buildList()),
          if (_multi) _multiBar(),
        ],
      ),
    );
  }

  Widget _breadcrumbBar() {
    final rootRel =
        currentPath == _root
            ? ''
            : currentPath.substring(_root.length).replaceAll('\\', '/');
    var segs =
        rootRel.isEmpty ? <String>[] : rootRel.split('/').where((s) => s.isNotEmpty).toList();
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 20),
            tooltip: "Back".tl,
            onPressed: currentPath == _root ? null : _goBack,
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _breadcrumbChildren(_root.split('/').last, segs),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _breadcrumbChildren(String rootName, List<String> segs) {
    final nodes = <Widget>[];
    void crumb(String label, String target, {bool last = false}) {
      nodes.add(InkWell(
        onTap: last || currentPath == target
            ? null
            : () {
                _history.add(currentPath);
                currentPath = target;
                setState(() {});
              },
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: last ? FontWeight.w600 : FontWeight.w400,
              color: last
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ));
      nodes.add(Text('/',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.outline)));
    }

    if (segs.isEmpty) {
      crumb(rootName, _root, last: true);
      return nodes.where((n) => !(n is Text && (n as Text).data == '/')).toList();
    }
    // Build path chain
    var path = _root;
    crumb(rootName, _root);
    var parts = <MapEntry<String, String>>[MapEntry(rootName, _root)];
    for (final s in segs) {
      path = '$path/$s';
      parts.add(MapEntry(s, path));
    }
    if (parts.length > 4) {
      // truncate middle
      final first = parts.sublist(0, 1);
      final last = parts.sublist(parts.length - 2);
      final shown = [...first, MapEntry('...', ''), ...last];
      return _crumbRow(shown);
    }
    return _crumbRow(parts);
  }

  List<Widget> _crumbRow(List<MapEntry<String, String>> parts) {
    final nodes = <Widget>[];
    final last = parts.last;
    for (final part in parts) {
      if (part.key == '...') {
        nodes.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('...',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline)),
        ));
        nodes.add(Text('/',
            style: TextStyle(
                fontSize: 12, color: Theme.of(context).colorScheme.outline)));
        continue;
      }
      final isLast = part == last;
      nodes.add(InkWell(
        onTap: isLast
            ? null
            : () {
                _history.add(currentPath);
                currentPath = part.value;
                setState(() {});
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Text(
            part.key,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
              color: isLast
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
      ));
      nodes.add(Text('/',
          style: TextStyle(
              fontSize: 12, color: Theme.of(context).colorScheme.outline)));
    }
    return nodes;
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: TextField(
        onChanged: (v) => setState(() => _search = v),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _search.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () => setState(() => _search = ''),
                )
              : null,
          hintText: "Search".tl,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }

  Widget _buildList() {
    final items = _collect();
    if (items.isEmpty) {
      return Center(
        child: Text(
          _search.isNotEmpty ? "No search results found".tl : "Empty".tl,
          style: TextStyle(color: Theme.of(context).colorScheme.outline),
        ),
      );
    }
    return ListView.builder(
      itemCount: items.length,
      itemBuilder: (context, i) {
        final e = items[i];
        final selected = _selected.contains(e.path);
        return ListTile(
          dense: true,
          leading: Icon(
            e.isDir ? Icons.folder : _iconFor(e.name),
            color: e.isDir
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          title: Text(
            _search.isNotEmpty && e.path.contains('/') && !e.isDir
                ? e.path
                : e.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            _subtitle(e),
            style: TextStyle(
                fontSize: 11, color: Theme.of(context).colorScheme.outline),
          ),
          trailing: _multi
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => _toggleSelect(e.path),
                )
              : null,
          selected: selected,
          onTap: () {
            if (_multi) {
              _toggleSelect(e.path);
            } else if (e.isDir) {
              _enterDir(e.path);
            } else {
              context.showMessage(message: e.name);
            }
          },
          onLongPress: () {
            if (_multi) {
              _toggleSelect(e.path);
            } else {
              _showActions(e);
            }
          },
        );
      },
    );
  }

  IconData _iconFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (['cbz', 'zip', '7z', 'cb7'].contains(ext)) return Icons.archive;
    if (['png', 'jpg', 'jpeg', 'webp', 'gif'].contains(ext)) {
      return Icons.image;
    }
    return Icons.insert_drive_file;
  }

  String _subtitle(_Entry e) {
    if (e.isDir) {
      return _countEntries(e.path) == 0
          ? '0'
          : '${_countEntries(e.path)}';
    }
    return byteSize2(e.size);
  }

  void _toggleSelect(String path) {
    setState(() {
      if (_selected.contains(path)) {
        _selected.remove(path);
      } else {
        _selected.add(path);
      }
    });
  }

  void _showActions(_Entry e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.checklist),
              title: Text("Multi-Select".tl),
              onTap: () {
                Navigator.pop(c);
                setState(() {
                  _multi = true;
                  _selected.add(e.path);
                });
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_rename_outline),
              title: Text("Rename".tl),
              onTap: () {
                Navigator.pop(c);
                _rename(e);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.copy),
              title: Text("Copy".tl),
              onTap: () {
                Navigator.pop(c);
                _copySingle(e);
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.drive_file_move_outline),
              title: Text("Move".tl),
              onTap: () {
                Navigator.pop(c);
                _pickTarget((t) => _run('Move',
                    () => _moveSingles([e], t)));
              },
            ),
            ListTile(
              dense: true,
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: Text("Delete".tl),
              onTap: () {
                Navigator.pop(c);
                _deleteSingle(e);
              },
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.create_new_folder),
              title: Text("Create Folder".tl),
              onTap: () {
                Navigator.pop(c);
                _newFolder();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final rule in _SortRule.values)
              RadioListTile<_SortRule>(
                dense: true,
                value: rule,
                groupValue: _sort,
                title: Text(_sortLabel(rule)),
                onChanged: (v) {
                  setState(() => _sort = v ?? _SortRule.name);
                  _persistSort();
                  Navigator.pop(c);
                },
              ),
          ],
        ),
      ),
    );
  }

  String _sortLabel(_SortRule r) {
    switch (r) {
      case _SortRule.name:
        return "Sort by name".tl;
      case _SortRule.date:
        return "Sort by date".tl;
      case _SortRule.size:
        return "Sort by size".tl;
    }
  }

  Widget _multiBar() {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 4,
        bottom: 8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        children: [
          Text('已选 @n 项'.tlParams({'n': '${_selected.length}'})),
          const Spacer(),
          TextButton(
            onPressed: () => setState(() => _selected.addAll(
                _collect().map((e) => e.path))),
            child: Text("Select All".tl),
          ),
          TextButton(
            onPressed: _selected.isEmpty ? null : _moveSelectedToList,
            child: Text("Move".tl),
          ),
          TextButton(
            onPressed: _selected.isEmpty ? null : _deleteSelected,
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error),
            child: Text("Delete".tl),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }
}

String byteSize2(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Folder picker restricted to the storage root (app sandbox).
class _TargetFolderDialog extends StatefulWidget {
  final String root;
  final String current;

  const _TargetFolderDialog({required this.root, required this.current});

  @override
  State<_TargetFolderDialog> createState() => _TargetFolderDialogState();
}

class _TargetFolderDialogState extends State<_TargetFolderDialog> {
  late String path = widget.current;
  String? error;

  @override
  Widget build(BuildContext context) {
    final dirs = _dirs();
    return AlertDialog(
      title: Text("Select target folder".tl),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline)),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_upward, size: 18),
                  tooltip: "Back".tl,
                  onPressed: path == widget.root
                      ? null
                      : () => setState(() =>
                          path = p.dirname(path)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (error != null)
              Text(
                error!,
                style:
                    TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error),
              ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    if (dirs.isNotEmpty)
                      ...dirs.map(
                        (d) => ListTile(
                          dense: true,
                          title: Text(d.split('/').last),
                          onTap: () => setState(() => path = d),
                        ),
                      )
                    else
                      const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('(empty)')),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.add, size: 18),
                      title: Text("Create Folder".tl),
                      onTap: () {
                        showInputDialog(
                          context: context,
                          title: "Create Folder".tl,
                          onConfirm: (v) {
                            final name = v.trim();
                            if (name.isEmpty) return 'Empty name';
                            final d = Directory(p.join(path, name));
                            try {
                              if (d.existsSync()) return 'Exists';
                              d.createSync();
                              setState(() {
                                path = d.path;
                              });
                              return null;
                            } catch (e) {
                              return e.toString();
                            }
                          },
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text("cancel".tl),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, path),
          child: Text("Select".tl),
        ),
      ],
    );
  }

  List<String> _dirs() {
    try {
      final d = Directory(path);
      if (!d.existsSync()) return const [];
      return d
          .listSync()
          .whereType<Directory>()
          .map((e) => e.path)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}