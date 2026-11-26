import 'package:flutter/material.dart';

import '../models/volume_range.dart';

class VolumeAutomationScreen extends StatefulWidget {
  const VolumeAutomationScreen({
    super.key,
    required this.initialRanges,
    required this.onSave,
  });

  final List<VolumeRange> initialRanges;
  final Future<void> Function(List<VolumeRange> ranges) onSave;

  @override
  State<VolumeAutomationScreen> createState() => _VolumeAutomationScreenState();
}

class _VolumeAutomationScreenState extends State<VolumeAutomationScreen> {
  late List<VolumeRange> _ranges;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ranges = List<VolumeRange>.from(widget.initialRanges)
      ..sort((a, b) => a.startMs.compareTo(b.startMs));
  }

  String _formatTime(int milliseconds) {
    final totalSeconds = milliseconds ~/ 1000;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  int? _parseTime(String value) {
    final match = RegExp(r'^(\d{1,4}):([0-5]\d)$').firstMatch(value.trim());
    if (match == null) return null;
    final minutes = int.parse(match.group(1)!);
    final seconds = int.parse(match.group(2)!);
    return (minutes * 60 + seconds) * 1000;
  }

  Future<void> _editRange({VolumeRange? existing, int? index}) async {
    final startController = TextEditingController(
      text: existing == null ? '00:00' : _formatTime(existing.startMs),
    );
    final endController = TextEditingController(
      text: existing == null ? '01:00' : _formatTime(existing.endMs),
    );
    var percent = existing?.percent ?? 15;
    String? error;

    final result = await showDialog<VolumeRange>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'افزودن زمان‌بندی' : 'ویرایش زمان‌بندی'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: startController,
                        keyboardType: TextInputType.datetime,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: 'از زمان',
                          hintText: '01:00',
                          helperText: 'دقیقه:ثانیه',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: endController,
                        keyboardType: TextInputType.datetime,
                        textAlign: TextAlign.center,
                        decoration: const InputDecoration(
                          labelText: 'تا زمان',
                          hintText: '02:00',
                          helperText: 'دقیقه:ثانیه',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    const Expanded(child: Text('میزان صدا')),
                    Text('$percent٪', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
                Slider(
                  value: percent.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 100,
                  label: '$percent٪',
                  onChanged: (value) => setDialogState(() => percent = value.round()),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            FilledButton(
              onPressed: () {
                final start = _parseTime(startController.text);
                final end = _parseTime(endController.text);
                if (start == null || end == null) {
                  setDialogState(() => error = 'زمان را با قالب دقیقه:ثانیه وارد کن؛ مثلاً 05:30.');
                  return;
                }
                if (start >= end) {
                  setDialogState(() => error = 'زمان پایان باید بعد از زمان شروع باشد.');
                  return;
                }
                for (var i = 0; i < _ranges.length; i++) {
                  if (i == index) continue;
                  final other = _ranges[i];
                  if (start < other.endMs && end > other.startMs) {
                    setDialogState(() => error = 'این بازه با یک زمان‌بندی دیگر تداخل دارد.');
                    return;
                  }
                }
                Navigator.pop(
                  dialogContext,
                  VolumeRange(startMs: start, endMs: end, percent: percent),
                );
              },
              child: const Text('ذخیره بازه'),
            ),
          ],
        ),
      ),
    );

    startController.dispose();
    endController.dispose();
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _ranges.add(result);
      } else {
        _ranges[index] = result;
      }
      _ranges.sort((a, b) => a.startMs.compareTo(b.startMs));
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(List<VolumeRange>.from(_ranges));
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ذخیره زمان‌بندی ناموفق بود: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('نقشه تغییرات صدا'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('ذخیره'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              'برای هر بازه، زمان شروع، پایان و درصد صدا را تعیین کن. پس از شروع هر بازه، همان درصد تا شروع بازه بعدی حفظ می‌شود؛ حتی اگر بین دو بازه فاصله باشد.',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.start,
            ),
          ),
          Expanded(
            child: _ranges.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.schedule_rounded, size: 52, color: colors.primary),
                          const SizedBox(height: 12),
                          const Text(
                            'هنوز زمان‌بندی‌ای ثبت نشده است.',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'با افزودن بازه، مشخص کن در هر زمان از ویس صدا روی چند درصد قرار بگیرد.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                    itemCount: _ranges.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final range = _ranges[index];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            child: Text('${index + 1}'),
                          ),
                          title: Text(
                            '${_formatTime(range.startMs)} تا ${_formatTime(range.endMs)}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text('میزان صدا: ${range.percent}٪'),
                          onTap: () => _editRange(existing: range, index: index),
                          trailing: IconButton(
                            tooltip: 'حذف بازه',
                            onPressed: () => setState(() => _ranges.removeAt(index)),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _saving ? null : () => _editRange(),
                  icon: const Icon(Icons.add),
                  label: const Text('افزودن بازه زمانی'),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
