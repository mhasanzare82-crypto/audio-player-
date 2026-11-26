import 'package:flutter/material.dart';

import '../models/volume_automation_profile.dart';
import '../services/volume_automation_controller.dart';

class VolumeAutomationScreen extends StatefulWidget {
  const VolumeAutomationScreen({
    super.key,
    required this.initialProfile,
    required this.controller,
    required this.onSave,
  });

  final VolumeAutomationProfile initialProfile;
  final VolumeAutomationController controller;
  final Future<void> Function(VolumeAutomationProfile profile) onSave;

  @override
  State<VolumeAutomationScreen> createState() => _VolumeAutomationScreenState();
}

class _VolumeAutomationScreenState extends State<VolumeAutomationScreen> {
  late VolumeAutomationProfile _profile;
  int _selectedPoint = 0;
  final List<Offset> _drawingOffsets = <Offset>[];
  bool _isDrawing = false;
  bool _saving = false;
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;
  late final TextEditingController _secondsController;

  @override
  void initState() {
    super.initState();
    _profile = widget.initialProfile;
    final totalSeconds = (_profile.durationMs / 1000).round();
    _hoursController = TextEditingController(text: (totalSeconds ~/ 3600).toString());
    _minutesController = TextEditingController(text: ((totalSeconds % 3600) ~/ 60).toString());
    _secondsController = TextEditingController(text: (totalSeconds % 60).toString());
    widget.controller.isRunning.addListener(_handleRunningChanged);
  }

  void _handleRunningChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.isRunning.removeListener(_handleRunningChanged);
    _hoursController.dispose();
    _minutesController.dispose();
    _secondsController.dispose();
    super.dispose();
  }

  bool get _isRunning => widget.controller.isRunning.value;

  void _setPoints(List<VolumeAutomationPoint> points) {
    final sorted = [...points]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    setState(() {
      _profile = _profile.copyWith(points: sorted);
      _selectedPoint = _selectedPoint.clamp(0, sorted.length - 1).toInt();
    });
  }

  Rect _plotRect(Size size) => Rect.fromLTRB(
        42,
        14,
        size.width - 14,
        size.height - 34,
      );

  void _beginFreehand(Offset position, Size size) {
    if (_isRunning) return;
    final plot = _plotRect(size);
    if (!plot.contains(position)) return;
    setState(() {
      _drawingOffsets
        ..clear()
        ..add(position);
      _isDrawing = true;
    });
  }

  void _appendFreehand(Offset position, Size size) {
    if (_isRunning || !_isDrawing) return;
    final plot = _plotRect(size);
    final point = Offset(
      position.dx.clamp(plot.left, plot.right).toDouble(),
      position.dy.clamp(plot.top, plot.bottom).toDouble(),
    );
    if (_drawingOffsets.isNotEmpty &&
        (point - _drawingOffsets.last).distance < 2.0) {
      return;
    }
    setState(() => _drawingOffsets.add(point));
  }

  void _finishFreehand(Size size) {
    if (!_isDrawing) return;
    final plot = _plotRect(size);
    final stroke = List<Offset>.of(_drawingOffsets);
    setState(() {
      _isDrawing = false;
      _drawingOffsets.clear();
    });
    if (stroke.length < 2) return;

    // The horizontal axis is elapsed time. Keep the user's stroke in
    // left-to-right order so the resulting profile is deterministic.
    final raw = <VolumeAutomationPoint>[];
    for (final offset in stroke) {
      final normalizedX =
          ((offset.dx - plot.left) / plot.width).clamp(0.0, 1.0);
      final normalizedY =
          (1 - (offset.dy - plot.top) / plot.height).clamp(0.0, 1.0);
      final timeMs = (normalizedX * _profile.durationMs).round();
      if (raw.isNotEmpty && timeMs <= raw.last.timeMs) continue;
      raw.add(VolumeAutomationPoint(
        timeMs: timeMs,
        volume: normalizedY.toDouble(),
      ));
    }
    if (raw.length < 2) return;

    final points = <VolumeAutomationPoint>[
      if (raw.first.timeMs > 0)
        VolumeAutomationPoint(timeMs: 0, volume: raw.first.volume),
      ...raw,
    ];
    if (points.last.timeMs < _profile.durationMs) {
      points.add(VolumeAutomationPoint(
        timeMs: _profile.durationMs,
        volume: points.last.volume,
      ));
    } else if (points.last.timeMs > _profile.durationMs) {
      points[points.length - 1] = VolumeAutomationPoint(
        timeMs: _profile.durationMs,
        volume: points.last.volume,
      );
    }
    if (points.length < 2) return;
    _selectedPoint = 0;
    _setPoints(points);
  }

  void _clearDrawing() {
    if (_isRunning) return;
    _setPoints([
      const VolumeAutomationPoint(timeMs: 0, volume: 1),
      VolumeAutomationPoint(timeMs: _profile.durationMs, volume: 1),
    ]);
  }

  void _changeDuration() {
    if (_isRunning) return;
    final hours = int.tryParse(_hoursController.text) ?? 0;
    final minutes = int.tryParse(_minutesController.text) ?? 0;
    final seconds = int.tryParse(_secondsController.text) ?? 0;
    if (hours < 0 || hours > 99 ||
        minutes < 0 || minutes > 59 ||
        seconds < 0 || seconds > 59) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('زمان را درست وارد کن؛ دقیقه و ثانیه باید بین ۰ تا ۵۹ باشند.')),
      );
      return;
    }
    final nextDuration = ((hours * 3600) + (minutes * 60) + seconds) * 1000;
    if (nextDuration < 1000) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('مدت نمودار باید حداقل یک ثانیه باشد.')),
      );
      return;
    }
    final oldDuration = _profile.durationMs;
    final scaled = _profile.points.map((point) {
      if (point.timeMs == 0) {
        return VolumeAutomationPoint(timeMs: 0, volume: point.volume);
      }
      if (point.timeMs == oldDuration) {
        return VolumeAutomationPoint(timeMs: nextDuration, volume: point.volume);
      }
      return VolumeAutomationPoint(
        timeMs: (point.timeMs / oldDuration * nextDuration).round(),
        volume: point.volume,
      );
    }).toList();
    final points = <VolumeAutomationPoint>[scaled.first];
    for (var i = 1; i < scaled.length - 1; i++) {
      final minimum = points.last.timeMs + 100;
      final maximum = nextDuration - (scaled.length - 1 - i) * 100;
      final time = scaled[i].timeMs.clamp(minimum, maximum).toInt();
      points.add(VolumeAutomationPoint(timeMs: time, volume: scaled[i].volume));
    }
    points.add(scaled.last);
    setState(() {
      _profile = VolumeAutomationProfile(
        durationMs: nextDuration,
        repeat: _profile.repeat,
        points: points,
      );
    });
  }

  Future<void> _saveProfile() async {
    setState(() => _saving = true);
    try {
      await widget.onSave(_profile);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('الگوی تغییرات صدا ذخیره شد.')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ذخیره الگو ناموفق بود: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _togglePlayback() {
    if (_isRunning) {
      widget.controller.stop();
    } else {
      widget.controller.start(_profile);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('نقشه تغییرات صدا'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(
              'منحنی دلخواهت را روی نمودار رسم کن',
              textDirection: TextDirection.rtl,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 5),
            Text(
              'محور افقی زمان و محور عمودی درصد صدای خروجی پلیر است.',
              textDirection: TextDirection.rtl,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 270,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onPanStart: (details) =>
                        _beginFreehand(details.localPosition, size),
                    onPanUpdate: (details) =>
                        _appendFreehand(details.localPosition, size),
                    onPanEnd: (_) => _finishFreehand(size),
                    onPanCancel: () => _finishFreehand(size),
                    child: CustomPaint(
                      size: size,
                      painter: _VolumeCurvePainter(
                        profile: _profile,
                        selectedPoint: -1,
                        drawingOffsets: List<Offset>.of(_drawingOffsets),
                        gridColor: colors.outlineVariant,
                        curveColor: colors.primary,
                        pointColor: colors.primary,
                        textColor: colors.onSurfaceVariant,
                        surfaceColor: colors.surface,
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'انگشتت را از سمت چپ به راست روی نمودار بکش؛ مسیر رسم‌شده مستقیماً تغییرات صدا را تعیین می‌کند.',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 18),
            const Align(
              alignment: Alignment.centerRight,
              child: Text('مدت کل نمودار (حداکثر ۹۹ ساعت و ۵۹ دقیقه و ۵۹ ثانیه)'),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _hoursController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'ساعت', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _minutesController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'دقیقه', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _secondsController,
                    enabled: !_isRunning,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    decoration: const InputDecoration(labelText: 'ثانیه', border: OutlineInputBorder(), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: _isRunning ? null : _changeDuration,
                icon: const Icon(Icons.schedule),
                label: const Text('اعمال مدت زمان'),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('تکرار نمودار از ابتدا'),
              subtitle: Text(
                _profile.repeat
                    ? 'پس از پایان، نمودار دوباره اجرا می‌شود.'
                    : 'نمودار فقط یک بار اجرا می‌شود.',
              ),
              value: _profile.repeat,
              onChanged: _isRunning
                  ? null
                  : (value) => setState(
                        () => _profile = _profile.copyWith(repeat: value),
                      ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRunning ? null : _clearDrawing,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('پاک‌کردن مسیر'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _saveProfile,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: const Text('ذخیره الگو'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ValueListenableBuilder<bool>(
              valueListenable: widget.controller.isRunning,
              builder: (context, running, _) => FilledButton.tonalIcon(
                onPressed: _togglePlayback,
                icon: Icon(running ? Icons.stop_rounded : Icons.play_arrow_rounded),
                label: Text(running ? 'توقف اجرای نمودار' : 'شروع پیش‌نمایش و اجرا'),
              ),
            ),
            ValueListenableBuilder<double>(
              valueListenable: widget.controller.currentValue,
              builder: (context, value, _) {
                if (widget.controller.isRunning.value ||
                    (value - 1).abs() < 0.001) {
                  return const SizedBox.shrink();
                }
                return TextButton.icon(
                  onPressed: widget.controller.stop,
                  icon: const Icon(Icons.volume_up_rounded),
                  label: const Text('بازگردانی صدای پایه'),
                );
              },
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<double>(
              valueListenable: widget.controller.currentValue,
              builder: (context, value, _) => Text(
                'ضریب فعلی منحنی: ${(value * 100).round()}٪',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'این منحنی فقط صدای خروجی همین پلیر را کنترل می‌کند و صدای سایر برنامه‌های گوشی را تغییر نمی‌دهد.',
              textDirection: TextDirection.rtl,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumeCurvePainter extends CustomPainter {
  const _VolumeCurvePainter({
    required this.profile,
    required this.selectedPoint,
    required this.gridColor,
    required this.curveColor,
    required this.pointColor,
    required this.textColor,
    required this.surfaceColor,
    required this.drawingOffsets,
  });

  final VolumeAutomationProfile profile;
  final int selectedPoint;
  final Color gridColor;
  final Color curveColor;
  final Color pointColor;
  final Color textColor;
  final Color surfaceColor;
  final List<Offset> drawingOffsets;

  Rect _plotRect(Size size) => Rect.fromLTRB(
        42,
        14,
        size.width - 14,
        size.height - 34,
      );

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _plotRect(size);
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final axisPaint = Paint()
      ..color = textColor
      ..strokeWidth = 1.2;

    for (var step = 0; step <= 4; step++) {
      final y = plot.top + plot.height * step / 4;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
      _drawLabel(
        canvas,
        '${100 - step * 25}%',
        Offset(0, y - 8),
        textColor,
        width: 36,
      );
    }

    for (var step = 0; step <= 4; step++) {
      final x = plot.left + plot.width * step / 4;
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), gridPaint);
      final seconds = (profile.durationMs * step / 4 / 1000).round();
      _drawLabel(
        canvas,
        '${seconds}s',
        Offset(x - 18, plot.bottom + 8),
        textColor,
        width: 36,
      );
    }

    canvas.drawLine(Offset(plot.left, plot.top), Offset(plot.left, plot.bottom), axisPaint);
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), axisPaint);

    final path = Path();
    for (var i = 0; i < profile.points.length; i++) {
      final point = profile.points[i];
      final offset = Offset(
        plot.left + plot.width * point.timeMs / profile.durationMs,
        plot.bottom - plot.height * point.volume,
      );
      if (i == 0) {
        path.moveTo(offset.dx, offset.dy);
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = curveColor
        ..strokeWidth = 3
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );

    for (var i = 0; i < profile.points.length; i++) {
      final point = profile.points[i];
      final offset = Offset(
        plot.left + plot.width * point.timeMs / profile.durationMs,
        plot.bottom - plot.height * point.volume,
      );
      canvas.drawCircle(
        offset,
        i == selectedPoint ? 8 : 3,
        Paint()..color = pointColor,
      );
    }

    if (drawingOffsets.isNotEmpty) {
      final preview = Path()..moveTo(drawingOffsets.first.dx, drawingOffsets.first.dy);
      for (final offset in drawingOffsets.skip(1)) {
        preview.lineTo(offset.dx, offset.dy);
      }
      canvas.drawPath(
        preview,
        Paint()
          ..color = curveColor
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

  }

  void _drawLabel(
    Canvas canvas,
    String text,
    Offset position,
    Color color, {
    required double width,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: 10),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: width);
    painter.paint(canvas, position);
  }

  @override
  bool shouldRepaint(covariant _VolumeCurvePainter oldDelegate) {
    return oldDelegate.profile != profile ||
        oldDelegate.selectedPoint != selectedPoint ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.curveColor != curveColor ||
        oldDelegate.textColor != textColor ||
        oldDelegate.drawingOffsets != drawingOffsets;
  }
}
