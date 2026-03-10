import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AuraBG',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const BackgroundEditor(),
    );
  }
}

class TextItem {
  String text;
  Color color;
  Offset position;
  double scale;
  double rotation;

  TextItem({
    required this.text,
    required this.color,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
  });
}

class ImageItem {
  Uint8List bytes;
  Offset position;
  double scale;
  double rotation;

  ImageItem({
    required this.bytes,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
  });
}

class BackgroundEditor extends StatefulWidget {
  const BackgroundEditor({super.key});

  @override
  State<BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<BackgroundEditor> {
  File? _selectedImage;
  Uint8List? _processedImage;
  Color _backgroundColor = Colors.transparent;
  List<TextItem> _textItems = [];
  List<ImageItem> _overlayImages = []; 
  bool _isLoading = false;
  bool _isDownloading = false; 
  bool _isDragging = false;
  bool _isOverDeleteZone = false;
  double? _imageAspectRatio;
  int _mainRotationQuarter = 0; 

  double _baseScale = 1.0;
  double _baseRotation = 0.0;

  final String _apiKey = "78Rst8pawhsUuXhQeuUiRJrz";
  final GlobalKey _imageAreaKey = GlobalKey();

  final List<Color> _availableColors = [
    Colors.white, Colors.black, Colors.red, Colors.pink, Colors.purple,
    Colors.deepPurple, Colors.indigo, Colors.blue, Colors.lightBlue,
    Colors.cyan, Colors.teal, Colors.green, Colors.lightGreen,
    Colors.lime, Colors.yellow, Colors.amber, Colors.orange,
    Colors.deepOrange, Colors.brown, Colors.grey, Colors.blueGrey,
  ];

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _updateAspectRatio(Uint8List bytes) async {
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frameInfo = await codec.getNextFrame();
    setState(() {
      _imageAspectRatio = frameInfo.image.width / frameInfo.image.height;
    });
  }

  Future<void> _pickMainImage() async {
    try {
      final pickedFile = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (pickedFile != null) {
        final bytes = await File(pickedFile.path).readAsBytes();
        await _updateAspectRatio(bytes);
        if (!mounted) return;
        setState(() {
          _selectedImage = File(pickedFile.path);
          _processedImage = null;
          _backgroundColor = Colors.transparent;
          _textItems = [];
          _overlayImages = [];
          _mainRotationQuarter = 0;
        });
      }
    } catch (e) {
      _showSnackBar("Error picking image: $e");
    }
  }

  Future<void> _addOverlayImage() async {
    try {
      final pickedFile = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 100);
      if (pickedFile != null) {
        final bytes = await File(pickedFile.path).readAsBytes();
        if (!mounted) return;
        setState(() {
          _overlayImages.add(ImageItem(
            bytes: bytes,
            position: const Offset(100, 100),
          ));
        });
      }
    } catch (e) {
      _showSnackBar("Error adding overlay image: $e");
    }
  }

  Future<void> _removeBackground() async {
    if (_selectedImage == null) return;
    if (_apiKey.isEmpty || _apiKey.contains("YOUR_REMOVE_BG")) {
      _showSnackBar("Please enter a valid API Key.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final request = http.MultipartRequest('POST', Uri.parse('https://api.remove.bg/v1.0/removebg'));
      request.headers.addAll({'X-Api-Key': _apiKey});
      request.files.add(await http.MultipartFile.fromPath('image_file', _selectedImage!.path));
      request.fields['size'] = 'auto';

      final response = await request.send();
      if (response.statusCode == 200) {
        final resData = await http.Response.fromStream(response);
        await _updateAspectRatio(resData.bodyBytes);
        if (!mounted) return;
        setState(() {
          _processedImage = resData.bodyBytes;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
        _showSnackBar("Failed to remove background.");
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showSnackBar("Connection error: $e");
    }
  }

  void _pickBgColor() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Background Color'),
        content: SingleChildScrollView(
          child: BlockPicker(
            pickerColor: _backgroundColor == Colors.transparent ? Colors.white : _backgroundColor,
            onColorChanged: (color) {
              setState(() => _backgroundColor = color);
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  void _showTextEditor({int? index}) {
    String initialText = index != null ? _textItems[index].text : "";
    Color initialColor = index != null ? _textItems[index].color : Colors.white;
    TextEditingController controller = TextEditingController(text: initialText);
    Color tempTextColor = initialColor;

    showGeneralDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.9),
      pageBuilder: (context, animation, secondaryAnimation) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel", style: TextStyle(color: Colors.white, fontSize: 18))),
                          ElevatedButton(
                            onPressed: () {
                              if (controller.text.isNotEmpty) {
                                setState(() {
                                  if (index != null) {
                                    _textItems[index].text = controller.text;
                                    _textItems[index].color = tempTextColor;
                                  } else {
                                    _textItems.add(TextItem(text: controller.text, color: tempTextColor, position: const Offset(100, 300)));
                                  }
                                });
                              }
                              Navigator.pop(context);
                            },
                            child: const Text("Done"),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: Center(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 20), child: TextField(controller: controller, autofocus: true, textAlign: TextAlign.center, style: TextStyle(color: tempTextColor, fontSize: 40, fontWeight: FontWeight.bold), decoration: const InputDecoration(border: InputBorder.none, hintText: "Type here...", hintStyle: TextStyle(color: Colors.white24)), maxLines: null)))),
                    Container(height: 70, padding: const EdgeInsets.only(bottom: 20), child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: _availableColors.length, padding: const EdgeInsets.symmetric(horizontal: 10), itemBuilder: (context, i) {
                      final color = _availableColors[i];
                      return GestureDetector(onTap: () => setDialogState(() => tempTextColor = color), child: Container(margin: const EdgeInsets.symmetric(horizontal: 8), width: 35, height: 35, decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: tempTextColor == color ? Colors.white : Colors.transparent, width: 3), boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)])));
                    })),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _downloadImage() async {
    if (_processedImage == null && _selectedImage == null) return;
    setState(() => _isDownloading = true);

    try {
      if (!await Gal.hasAccess()) await Gal.requestAccess();
      await Future.delayed(const Duration(milliseconds: 100));

      RenderRepaintBoundary? boundary = _imageAreaKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) throw "Capture area not found";

      ui.Image capturedUiImage = await boundary.toImage(pixelRatio: 5.0); 
      ByteData? byteData = await capturedUiImage.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) throw "Could not generate image data";
      Uint8List pngBytes = byteData.buffer.asUint8List();

      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/aura_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(path);
      await file.writeAsBytes(pngBytes);

      await Gal.putImage(path);

      setState(() => _isDownloading = false);
      _showSnackBar("Saved to Gallery!");
    } catch (e) {
      debugPrint("Save failed: $e");
      setState(() => _isDownloading = false);
      _showSnackBar("Save failed. Please restart the app.");
    }
  }

  @override
  Widget build(BuildContext context) {
    double displayAspectRatio = _imageAspectRatio ?? 1.0;
    if (_mainRotationQuarter % 2 != 0) {
      displayAspectRatio = 1 / displayAspectRatio;
    }

    return Scaffold(
      appBar: AppBar(title: const Text("AuraBG Pro", style: TextStyle(fontWeight: FontWeight.bold)), centerTitle: true, actions: [IconButton(icon: const Icon(Icons.download), onPressed: _downloadImage)]),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: AspectRatio(
                  aspectRatio: displayAspectRatio,
                  child: Stack(
                    children: [
                      RepaintBoundary(
                        key: _imageAreaKey,
                        child: Container(
                          width: double.infinity, height: double.infinity,
                          decoration: BoxDecoration(
                            color: _backgroundColor == Colors.transparent ? Colors.white : _backgroundColor, 
                          ),
                          child: Stack(
                            children: [
                              Center(
                                child: RotatedBox(
                                  quarterTurns: _mainRotationQuarter,
                                  child: _processedImage != null 
                                      ? Image.memory(_processedImage!, fit: BoxFit.contain) 
                                      : _selectedImage != null 
                                          ? Image.file(_selectedImage!, fit: BoxFit.contain) 
                                          : const Icon(Icons.add_a_photo, size: 50, color: Colors.grey),
                                ),
                              ),
                              
                              // Overlay Images with 360 Rotation
                              ..._overlayImages.asMap().entries.map((entry) {
                                int idx = entry.key;
                                ImageItem item = entry.value;
                                return Positioned(
                                  left: item.position.dx, top: item.position.dy,
                                  child: Transform(
                                    transform: Matrix4.identity()
                                      ..scale(item.scale)
                                      ..rotateZ(item.rotation),
                                    alignment: Alignment.center,
                                    child: GestureDetector(
                                      onScaleStart: (d) { 
                                        setState(() { 
                                          _isDragging = true; 
                                          _baseScale = item.scale;
                                          _baseRotation = item.rotation;
                                        }); 
                                      },
                                      onScaleUpdate: (d) {
                                        setState(() {
                                          item.position += d.focalPointDelta;
                                          item.scale = (_baseScale * d.scale).clamp(0.1, 5.0);
                                          item.rotation = _baseRotation + d.rotation;
                                          _isOverDeleteZone = (item.position.dy > (_imageAreaKey.currentContext!.findRenderObject() as RenderBox).size.height - 80);
                                        });
                                      },
                                      onScaleEnd: (d) {
                                        if (_isOverDeleteZone) setState(() { _overlayImages.removeAt(idx); });
                                        setState(() { _isDragging = false; _isOverDeleteZone = false; });
                                      },
                                      child: Image.memory(item.bytes, width: 150),
                                    ),
                                  ),
                                );
                              }),

                              // Text Items with 360 Rotation
                              ..._textItems.asMap().entries.map((entry) {
                                int idx = entry.key;
                                TextItem item = entry.value;
                                return Positioned(
                                  left: item.position.dx, top: item.position.dy,
                                  child: Transform(
                                    transform: Matrix4.identity()
                                      ..scale(item.scale)
                                      ..rotateZ(item.rotation),
                                    alignment: Alignment.center,
                                    child: GestureDetector(
                                      onTap: () => _showTextEditor(index: idx),
                                      onScaleStart: (d) { 
                                        setState(() { 
                                          _isDragging = true; 
                                          _baseScale = item.scale;
                                          _baseRotation = item.rotation;
                                        }); 
                                      },
                                      onScaleUpdate: (d) {
                                        setState(() {
                                          item.position += d.focalPointDelta;
                                          item.scale = (_baseScale * d.scale).clamp(0.1, 5.0);
                                          item.rotation = _baseRotation + d.rotation;
                                          _isOverDeleteZone = (item.position.dy > (_imageAreaKey.currentContext!.findRenderObject() as RenderBox).size.height - 80);
                                        });
                                      },
                                      onScaleEnd: (d) {
                                        if (_isOverDeleteZone) setState(() { _textItems.removeAt(idx); });
                                        setState(() { _isDragging = false; _isOverDeleteZone = false; });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8), 
                                        child: Text(item.text, style: TextStyle(color: item.color, fontSize: 28, fontWeight: FontWeight.bold, shadows: const [Shadow(blurRadius: 4, color: Colors.black45, offset: Offset(2, 2))]))),
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        ),
                      ),
                      if (_isLoading || _isDownloading) Container(color: Colors.black26, child: const Center(child: CircularProgressIndicator())),
                      if (_isDragging) Positioned(bottom: 20, left: 0, right: 0, child: Center(child: AnimatedContainer(duration: const Duration(milliseconds: 200), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: _isOverDeleteZone ? Colors.red.withOpacity(0.8) : Colors.black54, shape: BoxShape.circle), child: Icon(Icons.delete, color: Colors.white, size: _isOverDeleteZone ? 40 : 30)))),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(child: ElevatedButton.icon(onPressed: _pickMainImage, icon: const Icon(Icons.image), label: const Text("Main Image"))),
                    const SizedBox(width: 10),
                    Expanded(child: ElevatedButton.icon(onPressed: _addOverlayImage, icon: const Icon(Icons.add_photo_alternate), label: const Text("Overlay"))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: ElevatedButton.icon(onPressed: _removeBackground, icon: const Icon(Icons.auto_awesome), label: const Text("Remove BG"))),
                    const SizedBox(width: 10),
                    Expanded(child: ElevatedButton.icon(onPressed: () {
                      setState(() { _mainRotationQuarter = (_mainRotationQuarter + 1) % 4; });
                    }, icon: const Icon(Icons.rotate_right), label: const Text("Rotate"))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: ElevatedButton.icon(onPressed: _pickBgColor, icon: const Icon(Icons.palette), label: const Text("BG Color"))),
                    const SizedBox(width: 10),
                    Expanded(child: ElevatedButton.icon(onPressed: () => _showTextEditor(), icon: const Icon(Icons.text_fields), label: const Text("Add Text"))),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
