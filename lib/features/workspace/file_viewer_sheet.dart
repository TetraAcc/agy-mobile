import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/network/api_client.dart';
import '../../core/utils/file_utils.dart';
import '../../models/models.dart';

class FileViewerSheet extends StatefulWidget {
  final String? rootId;
  final String name;
  final String path;
  final String content;
  final int totalLines;
  final bool truncated;
  final int size;
  final double mtime;
  final bool canWrite;
  final Future<FileSaveResult> Function(String content, double? expectedMtime)? onSave;
  final ValueChanged<String>? onInsertReference;

  const FileViewerSheet({
    super.key,
    this.rootId,
    required this.name,
    required this.path,
    required this.content,
    required this.totalLines,
    required this.truncated,
    required this.size,
    this.mtime = 0.0,
    this.canWrite = false,
    this.onSave,
    this.onInsertReference,
  });

  static void show(
    BuildContext context, {
    String? rootId,
    required String name,
    required String path,
    required String content,
    required int totalLines,
    required bool truncated,
    required int size,
    double mtime = 0.0,
    bool canWrite = false,
    Future<FileSaveResult> Function(String content, double? expectedMtime)? onSave,
    ValueChanged<String>? onInsertReference,
    required void Function(String path) onDownloadFallback,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    if (content.contains('\x00') || FileUtils.isBinaryFile(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('📦 文件 [$name] 为二进制文件，已自动转为下载通道'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
          action: SnackBarAction(
            label: '立即下载',
            textColor: Colors.cyanAccent,
            onPressed: () => onDownloadFallback(path),
          ),
        ),
      );
      onDownloadFallback(path);
      return;
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => FileViewerSheet(
        rootId: rootId,
        name: name,
        path: path,
        content: content,
        totalLines: totalLines,
        truncated: truncated,
        size: size,
        mtime: mtime,
        canWrite: canWrite,
        onSave: onSave,
        onInsertReference: onInsertReference,
      ),
    );
  }

  @override
  State<FileViewerSheet> createState() => _FileViewerSheetState();
}

class _FileViewerSheetState extends State<FileViewerSheet> {
  late String _content;
  late int _totalLines;
  late int _size;
  late double _mtime;
  bool _isEditing = false;
  bool _isSaving = false;
  String? _saveError;
  late final TextEditingController _editController;

  @override
  void initState() {
    super.initState();
    _content = widget.content;
    _totalLines = widget.totalLines;
    _size = widget.size;
    _mtime = widget.mtime;
    _editController = TextEditingController(text: _content);
  }

  @override
  void dispose() {
    _editController.dispose();
    super.dispose();
  }

  bool get _canEditNow =>
      widget.canWrite && !widget.truncated && widget.onSave != null && widget.rootId != null;

  void _enterEditMode() {
    _editController.text = _content;
    setState(() {
      _isEditing = true;
      _saveError = null;
    });
  }

  void _cancelEdit() {
    _editController.text = _content;
    setState(() {
      _isEditing = false;
      _saveError = null;
    });
  }

  Future<void> _saveChanges() async {
    final onSave = widget.onSave;
    if (onSave == null || _isSaving) return;
    setState(() {
      _isSaving = true;
      _saveError = null;
    });
    try {
      final res = await onSave(_editController.text, _mtime > 0 ? _mtime : null);
      if (!mounted) return;
      setState(() {
        _content = _editController.text;
        _totalLines = res.totalLines;
        _size = res.size;
        _mtime = res.mtime;
        _isEditing = false;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存 ${widget.name}'), duration: const Duration(seconds: 2)),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = e.statusCode == 409 ? '文件在磁盘上已被修改，请重新加载后再编辑' : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _saveError = '保存失败: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primary = Theme.of(context).colorScheme.primary;
    final lines = _content.split('\n');
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.88,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            _isEditing ? Icons.edit_note_rounded : Icons.description_outlined,
                            color: primary,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _isEditing ? '${widget.name}（编辑中）' : widget.name,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        widget.path,
                        style: TextStyle(
                          fontSize: 10,
                          color: isDark ? Colors.white38 : Colors.black38,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_isEditing && widget.onInsertReference != null)
                      TextButton.icon(
                        onPressed: () {
                          widget.onInsertReference!('`${widget.path}` ');
                          Navigator.pop(context);
                        },
                        icon: const Icon(Icons.alternate_email_rounded, size: 15),
                        label: const Text('引用', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        ),
                      ),
                    if (!_isEditing && _canEditNow)
                      TextButton.icon(
                        onPressed: _enterEditMode,
                        icon: const Icon(Icons.edit_outlined, size: 15),
                        label: const Text('编辑', style: TextStyle(fontSize: 12)),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        ),
                      ),
                    if (_isEditing) ...[
                      TextButton(
                        onPressed: _isSaving ? null : _cancelEdit,
                        child: const Text('取消', style: TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 4),
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveChanges,
                        icon: _isSaving
                            ? const SizedBox(
                                width: 13,
                                height: 13,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.save_rounded, size: 15),
                        label: Text(_isSaving ? '保存中' : '保存', style: const TextStyle(fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        ),
                      ),
                    ] else ...[
                      IconButton(
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        tooltip: '复制全文',
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: _content));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制到剪贴板')),
                          );
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (_saveError != null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withValues(alpha: 0.5)),
                ),
                child: Text(
                  _saveError!,
                  style: TextStyle(fontSize: 11.5, color: Colors.redAccent.shade100),
                ),
              ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withValues(alpha: 0.05)
                    : Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  Text(
                    widget.truncated ? '共 $_totalLines 行 (已显示前 2000 行，暂不可编辑)' : '共 $_totalLines 行',
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white60 : Colors.black54),
                  ),
                  const Spacer(),
                  Text(
                    '${(_size / 1024).toStringAsFixed(1)} KB',
                    style: TextStyle(fontSize: 11, color: isDark ? Colors.white38 : Colors.black38),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF090D16) : const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _isEditing
                        ? primary.withValues(alpha: 0.6)
                        : (isDark ? const Color(0xFF23324A) : const Color(0xFFE2E8F0)),
                  ),
                ),
                child: _isEditing
                    ? TextField(
                        controller: _editController,
                        maxLines: null,
                        expands: true,
                        keyboardType: TextInputType.multiline,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12.5,
                          color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                          height: 1.5,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(12),
                        ),
                      )
                    : SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    for (int i = 1; i <= lines.length; i++)
                                      Text(
                                        '$i  ',
                                        style: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,
                                          color: isDark ? Colors.white24 : Colors.black26,
                                          height: 1.45,
                                        ),
                                      ),
                                  ],
                                ),
                                SelectableText(
                                  _content,
                                  style: TextStyle(
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                    color: isDark ? const Color(0xFFE2E8F0) : const Color(0xFF1E293B),
                                    height: 1.45,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
