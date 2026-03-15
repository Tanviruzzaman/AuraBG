import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'models.dart';

class BackgroundEditor extends StatefulWidget {
  const BackgroundEditor({super.key});

  @override
  State<BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<BackgroundEditor> {
  // ── Core ──────────────────────────────────────────────────────────────────
  File? _selectedImage;
  Uint8List? _processedImage;
  bool _isLoading = false;
  bool _isDownloading = false;
  String _loadingMsg = '';
  bool _isDragging = false;
  bool _isOverDeleteZone = false;
  double? _imageAspectRatio;
  int _mainRotationQuarter = 0;
  double _baseScale = 1.0;
  double _baseRotation = 0.0;

  // ── Flip ──────────────────────────────────────────────────────────────────
  bool _isFlippedHorizontal = false;

  // ── Adjustments ───────────────────────────────────────────────────────────
  double _brightness = 0.0; // -1.0 → 1.0
  double _contrast = 1.0; //  0.5 → 2.0
  double _saturation = 1.0; //  0.0 → 2.0

  // ── Background ────────────────────────────────────────────────────────────
  Color _backgroundColor = Colors.white;
  bool _useGradient = false;
  Color _gradientColor1 = const Color(0xFF6A0DAD);
  Color _gradientColor2 = const Color(0xFF0D6EFD);

  // ── Aspect ratio ──────────────────────────────────────────────────────────
  double? _forcedAspectRatio; // null = natural image ratio

  // ── Draw tool ─────────────────────────────────────────────────────────────
  bool _isDrawMode = false;
  Color _drawColor = Colors.red;
  double _drawStrokeWidth = 6.0;
  List<DrawPath> _drawPaths = [];
  DrawPath? _currentDrawPath;

  // ── Items ─────────────────────────────────────────────────────────────────
  List<TextItem> _textItems = [];
  List<ImageItem> _overlayImages = [];

  // ── Undo history ──────────────────────────────────────────────────────────
  // Each entry: 'text' | 'overlay' | 'draw'
  List<String> _actionHistory = [];

  // ── Misc ──────────────────────────────────────────────────────────────────
  final String _apiKey = "ohqKH3YTqhAuoJNdoUaKjUp3";
  final GlobalKey _imageAreaKey = GlobalKey();

  final List<Color> _palette = [
    Colors.white,
    Colors.black,
    Colors.red,
    Colors.pink,
    Colors.purple,
    Colors.deepPurple,
    Colors.indigo,
    Colors.blue,
    Colors.lightBlue,
    Colors.cyan,
    Colors.teal,
    Colors.green,
    Colors.lightGreen,
    Colors.lime,
    Colors.yellow,
    Colors.amber,
    Colors.orange,
    Colors.deepOrange,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
  ];

  // ═══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  double get _displayAspectRatio {
    if (_forcedAspectRatio != null) return _forcedAspectRatio!;
    final r = _imageAspectRatio ?? 1.0;
    return _mainRotationQuarter % 2 != 0 ? 1 / r : r;
  }

  /// GPU color-filter matrix combining brightness, contrast, saturation.
  List<double> _colorMatrix() {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final s = _saturation;
    final c = _contrast;
    final b = _brightness * 128;
    final sr = (1 - s) * lr;
    final sg = (1 - s) * lg;
    final sb = (1 - s) * lb;
    final off = 128.0 * (1 - c) + b;
    return [
      c * (sr + s),
      c * sg,
      c * sb,
      0,
      off,
      c * sr,
      c * (sg + s),
      c * sb,
      0,
      off,
      c * sr,
      c * sg,
      c * (sb + s),
      0,
      off,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  bool get _isDefaultFilter =>
      _brightness == 0.0 && _contrast == 1.0 && _saturation == 1.0;

  Future<void> _readAspectRatio(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _imageAspectRatio = frame.image.width / frame.image.height;
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Image picking
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _pickImage({bool camera = false}) async {
    try {
      final src = camera ? ImageSource.camera : ImageSource.gallery;
      final file = await ImagePicker().pickImage(
        source: src,
        imageQuality: 100,
      );
      if (file == null) return;
      final bytes = await File(file.path).readAsBytes();
      await _readAspectRatio(bytes);
      if (!mounted) return;
      setState(() {
        _selectedImage = File(file.path);
        _processedImage = null;
        _backgroundColor = Colors.white;
        _useGradient = false;
        _textItems = [];
        _overlayImages = [];
        _drawPaths = [];
        _actionHistory = [];
        _mainRotationQuarter = 0;
        _isFlippedHorizontal = false;
        _brightness = 0;
        _contrast = 1;
        _saturation = 1;
        _forcedAspectRatio = null;
      });
    } catch (e) {
      _snack("Error picking image: $e");
    }
  }

  Future<void> _addOverlayImage() async {
    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (file == null) return;
      final bytes = await File(file.path).readAsBytes();
      if (!mounted) return;
      setState(() {
        _overlayImages.add(
          ImageItem(bytes: bytes, position: const Offset(80, 80)),
        );
        _actionHistory.add('overlay');
      });
    } catch (e) {
      _snack("Error adding overlay: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // AI Background removal
  // ═══════════════════════════════════════════════════════════════════════════

  // ── BG removal: dialog choosing local vs API ─────────────────────────────

  void _showBgRemovalDialog() {
    if (_selectedImage == null) {
      _snack("Pick an image first.");
      return;
    }
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Remove Background',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.green.shade900,
                child: const Icon(
                  Icons.phone_android,
                  color: Colors.greenAccent,
                ),
              ),
              title: const Text('On-Device  (Free, No API Key)'),
              subtitle: const Text(
                'ML runs locally — works offline, best for people & portraits',
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 14),
              onTap: () {
                Navigator.pop(context);
                _removeBackgroundLocal();
              },
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: Colors.deepPurple.shade900,
                child: const Icon(
                  Icons.cloud_outlined,
                  color: Colors.deepPurpleAccent,
                ),
              ),
              title: const Text('remove.bg API  (Any Subject)'),
              subtitle: const Text(
                'Higher quality for objects, products, animals',
              ),
              trailing: const Icon(Icons.arrow_forward_ios, size: 14),
              onTap: () {
                Navigator.pop(context);
                _removeBackground();
              },
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // ── BG removal: on-device ML Kit ─────────────────────────────────────────

  Future<void> _removeBackgroundLocal() async {
    setState(() {
      _isLoading = true;
      _loadingMsg = "Analyzing with on-device ML…";
    });
    SelfieSegmenter? segmenter;
    try {
      segmenter = SelfieSegmenter(
        mode: SegmenterMode.stream,
        enableRawSizeMask: false,
      );
      final inputImage = InputImage.fromFile(_selectedImage!);
      final mask = await segmenter.processImage(inputImage);
      if (mask == null) throw "ML could not segment this image.";

      setState(() => _loadingMsg = "Removing background…");
      final imageBytes = await _selectedImage!.readAsBytes();
      final result = await compute(_applySegMask, {
        'bytes': imageBytes,
        'conf': mask.confidences.toList(),
        'mw': mask.width,
        'mh': mask.height,
      });

      await _readAspectRatio(result);
      if (!mounted) return;
      setState(() {
        _processedImage = result;
        _isLoading = false;
        _loadingMsg = '';
      });
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _loadingMsg = '';
        });
      _snack("On-device removal failed: $e");
    } finally {
      await segmenter?.close();
    }
  }

  // ── BG removal: remove.bg API ─────────────────────────────────────────────

  Future<void> _removeBackground() async {
    if (_selectedImage == null) {
      _snack("Pick an image first.");
      return;
    }
    setState(() {
      _isLoading = true;
      _loadingMsg = "Removing background (API)…";
    });
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.remove.bg/v1.0/removebg'),
      );
      req.headers['X-Api-Key'] = _apiKey;
      req.files.add(
        await http.MultipartFile.fromPath('image_file', _selectedImage!.path),
      );
      req.fields['size'] = 'auto';
      final res = await req.send();
      if (res.statusCode == 200) {
        final body = await http.Response.fromStream(res);
        await _readAspectRatio(body.bodyBytes);
        if (!mounted) return;
        setState(() {
          _processedImage = body.bodyBytes;
          _isLoading = false;
          _loadingMsg = '';
        });
      } else {
        setState(() {
          _isLoading = false;
          _loadingMsg = '';
        });
        _snack("Failed to remove background (${res.statusCode}).");
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
        _loadingMsg = '';
      });
      _snack("Connection error: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Flip
  // ═══════════════════════════════════════════════════════════════════════════

  void _flipImage() =>
      setState(() => _isFlippedHorizontal = !_isFlippedHorizontal);

  // ═══════════════════════════════════════════════════════════════════════════
  // Background color / gradient
  // ═══════════════════════════════════════════════════════════════════════════

  void _pickBgColor() {
    setState(() => _useGradient = false);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Background Color'),
        content: SingleChildScrollView(
          child: BlockPicker(
            pickerColor: _backgroundColor,
            onColorChanged: (c) {
              setState(() => _backgroundColor = c);
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  void _showGradientPicker() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Gradient Background',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  _gradientColorCircle(
                    'Start',
                    _gradientColor1,
                    ctx,
                    setSheet,
                    (c) {
                      setState(() => _gradientColor1 = c);
                      setSheet(() {});
                    },
                  ),
                  const SizedBox(width: 16),
                  _gradientColorCircle('End', _gradientColor2, ctx, setSheet, (
                    c,
                  ) {
                    setState(() => _gradientColor2 = c);
                    setSheet(() {});
                  }),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Container(
                      height: 60,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [_gradientColor1, _gradientColor2],
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    setState(() => _useGradient = true);
                    Navigator.pop(ctx);
                  },
                  child: const Text('Apply Gradient'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gradientColorCircle(
    String label,
    Color color,
    BuildContext ctx,
    StateSetter setSheet,
    ValueChanged<Color> onPicked,
  ) {
    return GestureDetector(
      onTap: () async {
        await showDialog(
          context: ctx,
          builder: (_) => AlertDialog(
            title: Text(label),
            content: SingleChildScrollView(
              child: BlockPicker(
                pickerColor: color,
                onColorChanged: (c) {
                  onPicked(c);
                  Navigator.pop(ctx);
                },
              ),
            ),
          ),
        );
      },
      child: Column(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.grey.shade400, width: 2),
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Adjustments  (brightness / contrast / saturation)
  // ═══════════════════════════════════════════════════════════════════════════

  void _showAdjustments() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Adjustments',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              _adjSlider('Brightness', _brightness, -1.0, 1.0, (v) {
                setState(() => _brightness = v);
                setSheet(() {});
              }),
              _adjSlider('Contrast', _contrast, 0.5, 2.0, (v) {
                setState(() => _contrast = v);
                setSheet(() {});
              }),
              _adjSlider('Saturation', _saturation, 0.0, 2.0, (v) {
                setState(() => _saturation = v);
                setSheet(() {});
              }),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _brightness = 0;
                        _contrast = 1;
                        _saturation = 1;
                      });
                      setSheet(() {});
                    },
                    child: const Text('Reset'),
                  ),
                  const SizedBox(width: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Done'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _adjSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> cb,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 96,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: cb,
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            value.toStringAsFixed(2),
            style: const TextStyle(fontSize: 12),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Aspect ratio
  // ═══════════════════════════════════════════════════════════════════════════

  void _showAspectRatioDialog() {
    final presets = <String, double?>{
      'Free': null,
      '1 : 1': 1.0,
      '4 : 3': 4 / 3,
      '3 : 4': 3 / 4,
      '16 : 9': 16 / 9,
      '9 : 16': 9 / 16,
    };
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Aspect Ratio'),
        content: Wrap(
          spacing: 10,
          runSpacing: 10,
          children: presets.entries.map((e) {
            final selected = _forcedAspectRatio == e.value;
            return GestureDetector(
              onTap: () {
                setState(() => _forcedAspectRatio = e.value);
                Navigator.pop(context);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade800,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  e.key,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Draw tool
  // ═══════════════════════════════════════════════════════════════════════════

  void _showDrawOptions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Draw Tool',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (_isDrawMode)
                    TextButton(
                      onPressed: () {
                        setState(() => _isDrawMode = false);
                        Navigator.pop(ctx);
                      },
                      child: const Text('Exit Draw Mode'),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 100,
                    child: Text(
                      'Stroke',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _drawStrokeWidth,
                      min: 1,
                      max: 40,
                      divisions: 39,
                      onChanged: (v) {
                        setState(() => _drawStrokeWidth = v);
                        setSheet(() {});
                      },
                    ),
                  ),
                  SizedBox(
                    width: 36,
                    child: Text(
                      _drawStrokeWidth.round().toString(),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Color',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: _palette
                      .map(
                        (c) => GestureDetector(
                          onTap: () {
                            setState(() => _drawColor = c);
                            setSheet(() {});
                          },
                          child: Container(
                            margin: const EdgeInsets.only(right: 8),
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: c,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: _drawColor == c
                                    ? Colors.blue
                                    : Colors.transparent,
                                width: 3,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () {
                    setState(() => _isDrawMode = true);
                    Navigator.pop(ctx);
                  },
                  icon: const Icon(Icons.draw),
                  label: const Text('Start Drawing'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Undo
  // ═══════════════════════════════════════════════════════════════════════════

  void _undo() {
    if (_actionHistory.isEmpty) {
      _snack("Nothing to undo.");
      return;
    }
    final last = _actionHistory.removeLast();
    setState(() {
      if (last == 'text' && _textItems.isNotEmpty) _textItems.removeLast();
      if (last == 'overlay' && _overlayImages.isNotEmpty)
        _overlayImages.removeLast();
      if (last == 'draw' && _drawPaths.isNotEmpty) _drawPaths.removeLast();
    });
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Text editor
  // ═══════════════════════════════════════════════════════════════════════════

  void _showTextEditor({int? index}) {
    final isEdit = index != null;
    final item = isEdit ? _textItems[index] : null;
    final ctrl = TextEditingController(text: item?.text ?? '');
    Color tempColor = item?.color ?? Colors.white;
    int tempStyle = item?.style ?? 0;
    double tempSize = item?.fontSize ?? 32.0;
    bool tempBold = item?.isBold ?? true;
    bool tempItalic = item?.isItalic ?? false;

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.92),
      pageBuilder: (ctx, anim, secAnim) => StatefulBuilder(
        builder: (ctx, setD) => Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(
              children: [
                // Top bar
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text(
                          "Cancel",
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                      // Style + Bold + Italic
                      Row(
                        children: [
                          _textStyleBtn(
                            Icons.text_format,
                            tempStyle == 0,
                            () => setD(() => tempStyle = 0),
                          ),
                          _textStyleBtn(
                            Icons.check_box_outline_blank,
                            tempStyle == 1,
                            () => setD(() => tempStyle = 1),
                          ),
                          _textStyleBtn(
                            Icons.filter_none,
                            tempStyle == 2,
                            () => setD(() => tempStyle = 2),
                          ),
                          const SizedBox(width: 8),
                          _toggleChip(
                            'B',
                            tempBold,
                            () => setD(() => tempBold = !tempBold),
                            bold: true,
                          ),
                          const SizedBox(width: 4),
                          _toggleChip(
                            'I',
                            tempItalic,
                            () => setD(() => tempItalic = !tempItalic),
                            italic: true,
                          ),
                        ],
                      ),
                      FilledButton(
                        onPressed: () {
                          if (ctrl.text.isNotEmpty) {
                            setState(() {
                              if (isEdit) {
                                _textItems[index]
                                  ..text = ctrl.text
                                  ..color = tempColor
                                  ..style = tempStyle
                                  ..fontSize = tempSize
                                  ..isBold = tempBold
                                  ..isItalic = tempItalic;
                              } else {
                                _textItems.add(
                                  TextItem(
                                    text: ctrl.text,
                                    color: tempColor,
                                    position: const Offset(80, 200),
                                    style: tempStyle,
                                    fontSize: tempSize,
                                    isBold: tempBold,
                                    isItalic: tempItalic,
                                  ),
                                );
                                _actionHistory.add('text');
                              }
                            });
                          }
                          Navigator.pop(ctx);
                        },
                        child: const Text("Done"),
                      ),
                    ],
                  ),
                ),
                // Font size slider
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.text_fields,
                        color: Colors.white38,
                        size: 16,
                      ),
                      Expanded(
                        child: Slider(
                          value: tempSize,
                          min: 12,
                          max: 96,
                          onChanged: (v) => setD(() => tempSize = v),
                        ),
                      ),
                      const Icon(
                        Icons.text_fields,
                        color: Colors.white,
                        size: 28,
                      ),
                    ],
                  ),
                ),
                // Text input
                Expanded(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        controller: ctrl,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: tempStyle == 0
                              ? tempColor
                              : (tempColor.computeLuminance() > 0.5
                                    ? Colors.black
                                    : Colors.white),
                          fontSize: tempSize,
                          fontWeight: tempBold
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontStyle: tempItalic
                              ? FontStyle.italic
                              : FontStyle.normal,
                          backgroundColor: tempStyle == 1
                              ? tempColor
                              : tempStyle == 2
                              ? tempColor.withValues(alpha: 0.5)
                              : null,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: "Type here…",
                          hintStyle: TextStyle(color: Colors.white24),
                        ),
                        maxLines: null,
                      ),
                    ),
                  ),
                ),
                // Color row
                Container(
                  height: 60,
                  padding: const EdgeInsets.only(bottom: 8),
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: _palette.length,
                    itemBuilder: (_, i) {
                      final c = _palette[i];
                      return GestureDetector(
                        onTap: () => setD(() => tempColor = c),
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 5),
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: c,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: tempColor == c
                                  ? Colors.blue
                                  : Colors.transparent,
                              width: 3,
                            ),
                            boxShadow: const [
                              BoxShadow(color: Colors.black38, blurRadius: 4),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _textStyleBtn(IconData icon, bool active, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, color: active ? Colors.blue : Colors.white60),
        onPressed: onTap,
      );

  Widget _toggleChip(
    String label,
    bool active,
    VoidCallback onTap, {
    bool bold = false,
    bool italic = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? Colors.blue : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: active ? Colors.blue : Colors.white38),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal,
            fontStyle: italic ? FontStyle.italic : FontStyle.normal,
            fontSize: 16,
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Pencil sketch effect
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _applySketch() async {
    if (_selectedImage == null && _processedImage == null) {
      _snack('Pick an image first.');
      return;
    }
    setState(() { _isLoading = true; _loadingMsg = 'Creating sketch…'; });
    try {
      final imageBytes = _processedImage ?? await _selectedImage!.readAsBytes();
      final result = await compute(_sketchEffect, imageBytes);
      setState(() { _processedImage = result; _isLoading = false; _loadingMsg = ''; });
    } catch (e) {
      setState(() { _isLoading = false; _loadingMsg = ''; });
      _snack('Sketch failed: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Save to gallery
  // ═══════════════════════════════════════════════════════════════════════════

  Future<void> _saveImage() async {
    if (_processedImage == null && _selectedImage == null) {
      _snack("No image to save.");
      return;
    }
    setState(() => _isDownloading = true);
    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Future.delayed(const Duration(milliseconds: 120));

      final boundary =
          _imageAreaKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) throw "Capture area not found";

      final image = await boundary.toImage(pixelRatio: 5.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw "Image data error";

      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/aurabg_${DateTime.now().millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(byteData.buffer.asUint8List());
      await Gal.putImage(path);

      setState(() => _isDownloading = false);
      _snack("Saved to Gallery!");
    } catch (e) {
      setState(() => _isDownloading = false);
      _snack("Save failed: $e");
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "AuraBG Pro",
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          if (_actionHistory.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: _undo,
            ),
          IconButton(
            icon: const Icon(Icons.download_rounded),
            tooltip: 'Save',
            onPressed: _saveImage,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Canvas ──────────────────────────────────────────────────────────
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Center(
                child: AspectRatio(
                  aspectRatio: _displayAspectRatio,
                  child: Stack(
                    children: [
                      RepaintBoundary(
                        key: _imageAreaKey,
                        child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color: _useGradient ? null : _backgroundColor,
                            gradient: _useGradient
                                ? LinearGradient(
                                    colors: [_gradientColor1, _gradientColor2],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  )
                                : null,
                          ),
                          child: Stack(
                            children: [
                              // Main image
                              if (_selectedImage != null ||
                                  _processedImage != null)
                                Center(
                                  child: _isDefaultFilter
                                      ? _mainImageWidget()
                                      : ColorFiltered(
                                          colorFilter: ColorFilter.matrix(
                                            _colorMatrix(),
                                          ),
                                          child: _mainImageWidget(),
                                        ),
                                ),
                              // Placeholder
                              if (_selectedImage == null &&
                                  _processedImage == null)
                                Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.add_a_photo_outlined,
                                        size: 64,
                                        color: Colors.grey.shade500,
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        "Tap Gallery to start",
                                        style: TextStyle(
                                          color: Colors.grey.shade500,
                                          fontSize: 15,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              // Overlay images
                              ..._overlayImages.asMap().entries.map(
                                (e) => _buildOverlayItem(e.key, e.value),
                              ),
                              // Text items
                              ..._textItems.asMap().entries.map(
                                (e) => _buildTextItem(e.key, e.value),
                              ),
                              // Draw paths
                              Positioned.fill(
                                child: CustomPaint(
                                  painter: _DrawPainter(
                                    paths: _drawPaths,
                                    current: _currentDrawPath,
                                  ),
                                ),
                              ),
                              // Draw gesture overlay (active only in draw mode)
                              if (_isDrawMode)
                                Positioned.fill(
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onPanStart: (d) => setState(() {
                                      _currentDrawPath = DrawPath(
                                        points: [d.localPosition],
                                        color: _drawColor,
                                        strokeWidth: _drawStrokeWidth,
                                      );
                                    }),
                                    onPanUpdate: (d) => setState(
                                      () => _currentDrawPath?.points.add(
                                        d.localPosition,
                                      ),
                                    ),
                                    onPanEnd: (_) {
                                      if (_currentDrawPath != null) {
                                        setState(() {
                                          _drawPaths.add(_currentDrawPath!);
                                          _actionHistory.add('draw');
                                          _currentDrawPath = null;
                                        });
                                      }
                                    },
                                    child: const ColoredBox(
                                      color: Colors.transparent,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      // Loading overlay
                      if (_isLoading || _isDownloading)
                        ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const CircularProgressIndicator(
                                  color: Colors.white,
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  _isDownloading ? "Saving…" : _loadingMsg,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Delete zone
                      if (_isDragging)
                        Positioned(
                          bottom: 16,
                          left: 0,
                          right: 0,
                          child: Center(
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: _isOverDeleteZone
                                    ? Colors.red.withValues(alpha: 0.85)
                                    : Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.delete,
                                color: Colors.white,
                                size: _isOverDeleteZone ? 40 : 28,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          // ── Draw mode banner ─────────────────────────────────────────────────
          if (_isDrawMode)
            ColoredBox(
              color: Colors.red.shade700,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    const Icon(Icons.draw, color: Colors.white, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        "Draw Mode Active",
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _isDrawMode = false),
                      child: const Text(
                        "Exit",
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // ── Toolbar ──────────────────────────────────────────────────────────
          _buildToolbar(),
        ],
      ),
    );
  }

  // ───── Main image widget ───────────────────────────────────────────────────

  Widget _mainImageWidget() {
    return Transform(
      transform: Matrix4.diagonal3Values(
        _isFlippedHorizontal ? -1.0 : 1.0,
        1.0,
        1.0,
      ),
      alignment: Alignment.center,
      child: RotatedBox(
        quarterTurns: _mainRotationQuarter,
        child: _processedImage != null
            ? Image.memory(_processedImage!, fit: BoxFit.contain)
            : Image.file(_selectedImage!, fit: BoxFit.contain),
      ),
    );
  }

  // ───── Overlay image widget ────────────────────────────────────────────────

  Widget _buildOverlayItem(int idx, ImageItem item) {
    return Positioned(
      left: item.position.dx,
      top: item.position.dy,
      child: Transform(
        transform: Matrix4.diagonal3Values(
          item.scale * (item.isFlipped ? -1.0 : 1.0),
          item.scale,
          1.0,
        )..rotateZ(item.rotation),
        alignment: Alignment.center,
        child: GestureDetector(
          onDoubleTap: () => setState(() => item.isFlipped = !item.isFlipped),
          onScaleStart: (d) => setState(() {
            _isDragging = true;
            _baseScale = item.scale;
            _baseRotation = item.rotation;
          }),
          onScaleUpdate: (d) => setState(() {
            item.position += d.focalPointDelta;
            item.scale = (_baseScale * d.scale).clamp(0.1, 5.0);
            item.rotation = _baseRotation + d.rotation;
            _isOverDeleteZone = _overDelete(item.position);
          }),
          onScaleEnd: (_) {
            if (_isOverDeleteZone) setState(() => _overlayImages.removeAt(idx));
            setState(() {
              _isDragging = false;
              _isOverDeleteZone = false;
            });
          },
          child: Image.memory(item.bytes, width: 150),
        ),
      ),
    );
  }

  // ───── Text item widget ────────────────────────────────────────────────────

  Widget _buildTextItem(int idx, TextItem item) {
    return Positioned(
      left: item.position.dx,
      top: item.position.dy,
      child: Transform(
        transform: Matrix4.diagonal3Values(item.scale, item.scale, 1.0)
          ..rotateZ(item.rotation),
        alignment: Alignment.center,
        child: GestureDetector(
          onTap: () => _showTextEditor(index: idx),
          onScaleStart: (d) => setState(() {
            _isDragging = true;
            _baseScale = item.scale;
            _baseRotation = item.rotation;
          }),
          onScaleUpdate: (d) => setState(() {
            item.position += d.focalPointDelta;
            item.scale = (_baseScale * d.scale).clamp(0.1, 5.0);
            item.rotation = _baseRotation + d.rotation;
            _isOverDeleteZone = _overDelete(item.position);
          }),
          onScaleEnd: (_) {
            if (_isOverDeleteZone) setState(() => _textItems.removeAt(idx));
            setState(() {
              _isDragging = false;
              _isOverDeleteZone = false;
            });
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: item.style == 1
                  ? item.color
                  : item.style == 2
                  ? item.color.withValues(alpha: 0.5)
                  : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              item.text,
              style: TextStyle(
                color: item.style == 0
                    ? item.color
                    : (item.color.computeLuminance() > 0.5
                          ? Colors.black
                          : Colors.white),
                fontSize: item.fontSize,
                fontWeight: item.isBold ? FontWeight.bold : FontWeight.normal,
                fontStyle: item.isItalic ? FontStyle.italic : FontStyle.normal,
                shadows: item.style == 0
                    ? const [
                        Shadow(
                          blurRadius: 4,
                          color: Colors.black45,
                          offset: Offset(2, 2),
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _overDelete(Offset position) {
    final box = _imageAreaKey.currentContext?.findRenderObject() as RenderBox?;
    return box != null && position.dy > box.size.height - 80;
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // Toolbar
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildToolbar() {
    return Container(
      height: 82,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        children: [
          _btn(Icons.photo_library_outlined, 'Gallery', () => _pickImage()),
          _btn(
            Icons.camera_alt_outlined,
            'Camera',
            () => _pickImage(camera: true),
          ),
          _btn(Icons.add_photo_alternate_outlined, 'Overlay', _addOverlayImage),
          _btn(
            Icons.auto_awesome,
            'AI BG',
            _showBgRemovalDialog,
            accent: Colors.deepPurpleAccent,
          ),
          _sep(),
          _btn(
            Icons.rotate_right,
            'Rotate',
            () => setState(
              () => _mainRotationQuarter = (_mainRotationQuarter + 1) % 4,
            ),
          ),
          _btn(Icons.flip, 'Flip', _flipImage),
          _btn(Icons.aspect_ratio, 'Ratio', _showAspectRatioDialog),
          _btn(Icons.tune, 'Adjust', _showAdjustments),
          _sep(),
          _btn(Icons.palette_outlined, 'Color', _pickBgColor),
          _btn(Icons.gradient, 'Gradient', _showGradientPicker),
          _sep(),
          _btn(Icons.text_fields, 'Text', () => _showTextEditor()),
          _btn(
            Icons.draw_outlined,
            'Draw',
            _showDrawOptions,
            accent: _isDrawMode ? Colors.redAccent : null,
          ),
          _sep(),
          _btn(Icons.edit, 'Sketch', _applySketch, accent: Colors.brown),
          _sep(),
          _btn(
            Icons.download_rounded,
            'Save',
            _saveImage,
            accent: Colors.green,
          ),
        ],
      ),
    );
  }

  Widget _btn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color? accent,
  }) {
    final color = accent ?? Theme.of(context).colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: 66,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 26, color: color),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                color: color,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sep() => Container(
    width: 1,
    margin: const EdgeInsets.symmetric(vertical: 18, horizontal: 2),
    color: Colors.grey.withValues(alpha: 0.3),
  );
}

// ═══════════════════════════════════════════════════════════════════════════════
// Top-level isolate function — applies ML segmentation mask to image pixels
// ═══════════════════════════════════════════════════════════════════════════════

Uint8List _applySegMask(Map<String, dynamic> params) {
  final Uint8List bytes = params['bytes'] as Uint8List;
  final List<double> conf = List<double>.from(params['conf'] as Iterable);
  final int mw = params['mw'] as int;
  final int mh = params['mh'] as int;

  final src = img.decodeImage(bytes)!;
  final dst = img.Image(width: src.width, height: src.height, numChannels: 4);

  // scaleX/Y map from full-image coords → (smaller) mask coords.
  // e.g. 4000-px photo with 256-px mask → scaleX ≈ 0.064
  final double scaleX = (mw - 1) / (src.width  - 1).toDouble();
  final double scaleY = (mh - 1) / (src.height - 1).toDouble();

  for (int y = 0; y < src.height; y++) {
    final double fy = y * scaleY;
    final int    y0 = fy.floor().clamp(0, mh - 1);
    final int    y1 = (y0 + 1).clamp(0, mh - 1);
    final double dy = fy - y0;

    for (int x = 0; x < src.width; x++) {
      final double fx = x * scaleX;
      final int    x0 = fx.floor().clamp(0, mw - 1);
      final int    x1 = (x0 + 1).clamp(0, mw - 1);
      final double dx = fx - x0;

      // Bilinear interpolation of the confidence mask → smooth sub-pixel edges
      // instead of nearest-neighbour (which gives ~16-px-wide blocky jumps on
      // a typical 4 MP photo with a 256-px mask).
      final double c = conf[y0 * mw + x0] * (1 - dx) * (1 - dy) +
                       conf[y0 * mw + x1] *      dx  * (1 - dy) +
                       conf[y1 * mw + x0] * (1 - dx) *      dy  +
                       conf[y1 * mw + x1] *      dx  *      dy;

      final p = src.getPixel(x, y);
      // Soft feathering: fully opaque above 0.65, fully transparent below 0.30
      final int a = c >= 0.65
          ? 255
          : c <= 0.30
          ? 0
          : ((c - 0.30) / 0.35 * 255).round().clamp(0, 255);
      dst.setPixelRgba(x, y, p.r.toInt(), p.g.toInt(), p.b.toInt(), a);
    }
  }

  return Uint8List.fromList(img.encodePng(dst));
}

// ═══════════════════════════════════════════════════════════════════════════════
// Pencil sketch — top-level isolate function
// Algorithm: grayscale → invert → gaussian blur → color-dodge blend
// ═══════════════════════════════════════════════════════════════════════════════

Uint8List _sketchEffect(Uint8List bytes) {
  final src  = img.decodeImage(bytes)!;
  // Step 1: grayscale
  final gray = img.grayscale(img.Image.from(src));
  // Step 2: invert the grayscale copy
  final inv  = img.invert(img.Image.from(gray));
  // Step 3: gaussian blur on the inverted image (radius controls pencil softness)
  final blurred = img.gaussianBlur(inv, radius: 12);
  // Step 4: color-dodge blend — gray / (1 - blurred)  → pencil-sketch look
  final out = img.Image(width: src.width, height: src.height, numChannels: 4);
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final g = gray.getPixel(x, y).r.toInt();       // 0-255 gray value
      final b = blurred.getPixel(x, y).r.toInt();    // 0-255 blur value
      final dodge = b >= 255 ? 255 : ((g * 255) ~/ (255 - b)).clamp(0, 255);
      // Preserve alpha from original if available
      final origA = src.numChannels == 4 ? src.getPixel(x, y).a.toInt() : 255;
      out.setPixelRgba(x, y, dodge, dodge, dodge, origA);
    }
  }
  return Uint8List.fromList(img.encodePng(out));
}


// ═══════════════════════════════════════════════════════════════════════════════
// Custom painter for freehand draw paths
// ═══════════════════════════════════════════════════════════════════════════════

class _DrawPainter extends CustomPainter {
  final List<DrawPath> paths;
  final DrawPath? current;
  const _DrawPainter({required this.paths, this.current});

  @override
  void paint(Canvas canvas, Size size) {
    for (final dp in [...paths, if (current case final c?) c]) {
      if (dp.points.length < 2) continue;
      final paint = Paint()
        ..color = dp.color
        ..strokeWidth = dp.strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke;
      final path = Path()..moveTo(dp.points.first.dx, dp.points.first.dy);
      for (final pt in dp.points.skip(1)) {
        path.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(_DrawPainter old) => true;
}
