import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
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

class BackgroundEditor extends StatefulWidget {
  const BackgroundEditor({super.key});

  @override
  State<BackgroundEditor> createState() => _BackgroundEditorState();
}

class _BackgroundEditorState extends State<BackgroundEditor> {
  File? _selectedImage;       // Original picked file
  Uint8List? _processedImage; // PNG from remove.bg
  Color _backgroundColor = Colors.transparent; 
  bool _isLoading = false;

  final String _apiKey = "78Rst8pawhsUuXhQeuUiRJrz";

  // Helper to show SnackBar safely
  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  // Pick Image from Gallery
  Future<void> _pickImage() async {
    try {
      final pickedFile = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (pickedFile != null) {
        if (!mounted) return;
        setState(() {
          _selectedImage = File(pickedFile.path);
          _processedImage = null; 
          _backgroundColor = Colors.transparent;
        });
      }
    } catch (e) {
      _showSnackBar("Error picking image: $e");
    }
  }

  // Remove Background using API
  Future<void> _removeBackground() async {
    if (_selectedImage == null) return;
    
    if (_apiKey.isEmpty || _apiKey.contains("YOUR_REMOVE_BG")) {
      _showSnackBar("Please enter a valid Remove.bg API Key.");
      return;
    }

    setState(() => _isLoading = true);

    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('https://api.remove.bg/v1.0/removebg'),
      );

      request.headers.addAll({'X-Api-Key': _apiKey});
      request.files.add(await http.MultipartFile.fromPath('image_file', _selectedImage!.path));
      request.fields['size'] = 'auto';

      final response = await request.send();

      if (response.statusCode == 200) {
        final resData = await http.Response.fromStream(response);
        if (!mounted) return;
        setState(() {
          _processedImage = resData.bodyBytes;
          _isLoading = false;
        });
      } else {
        final resData = await http.Response.fromStream(response);
        debugPrint("Error: ${response.statusCode} - ${resData.body}");
        if (!mounted) return;
        setState(() => _isLoading = false);
        _showSnackBar("API Error: ${response.statusCode}. Check credits.");
      }
    } catch (e) {
      debugPrint("Request Exception: $e");
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar("Connection error. Please check your internet.");
    }
  }

  // Choose Color
  void _pickColor() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Background Color'),
        content: SingleChildScrollView(
          child: BlockPicker(
            pickerColor: _backgroundColor,
            onColorChanged: (color) {
              setState(() => _backgroundColor = color);
              Navigator.pop(context);
            },
          ),
        ),
      ),
    );
  }

  // SAVE HIGH QUALITY TO GALLERY
  Future<void> _downloadImage() async {
    if (_processedImage == null) return;

    setState(() => _isLoading = true);

    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
      }

      final foreground = img.decodeImage(_processedImage!);
      if (foreground == null) throw "Could not decode image";

      final fullImage = img.Image(
        width: foreground.width,
        height: foreground.height,
      );

      if (_backgroundColor != Colors.transparent) {
        final bgColor = img.ColorRgb8(
          _backgroundColor.red,
          _backgroundColor.green,
          _backgroundColor.blue,
        );
        img.fill(fullImage, color: bgColor);
      } else {
        img.fill(fullImage, color: img.ColorRgb8(255, 255, 255));
      }

      img.compositeImage(fullImage, foreground);
      final finalBytes = Uint8List.fromList(img.encodePng(fullImage));

      final tempDir = await getTemporaryDirectory();
      final path = '${tempDir.path}/aura_bg_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File(path);
      await file.writeAsBytes(finalBytes);

      await Gal.putImage(path);

      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar("Image saved to Gallery!");
    } catch (e) {
      debugPrint("Save Error: $e");
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showSnackBar("Failed to save. Error: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text("AuraBG", style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: theme.colorScheme.inversePrimary,
        actions: [
          if (_processedImage != null)
            IconButton(
              icon: const Icon(Icons.download_for_offline),
              onPressed: _isLoading ? null : _downloadImage,
              tooltip: "Save to Gallery",
            ),
        ],
      ),
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [theme.colorScheme.inversePrimary.withValues(alpha: 0.3), Colors.white],
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _backgroundColor == Colors.transparent ? Colors.white : _backgroundColor,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      )
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        if (_processedImage != null)
                          Image.memory(_processedImage!, fit: BoxFit.contain)
                        else if (_selectedImage != null)
                          Image.file(_selectedImage!, fit: BoxFit.contain)
                        else
                          const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.image_outlined, size: 80, color: Colors.grey),
                                SizedBox(height: 16),
                                Text(
                                  "Select an image to start",
                                  style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.w500),
                                ),
                              ],
                            ),
                          ),
                        if (_isLoading)
                          Container(
                            color: Colors.black.withValues(alpha: 0.3),
                            child: const Center(
                              child: CircularProgressIndicator(),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Column(
                children: [
                  if (_isLoading && _processedImage != null)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text(
                        "Processing High Quality...",
                        style: TextStyle(fontWeight: FontWeight.bold, color: Colors.deepPurple),
                      ),
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _isLoading ? null : _pickImage,
                          icon: const Icon(Icons.photo_library),
                          label: const Text("Gallery"),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: (_selectedImage == null || _isLoading) ? null : _removeBackground,
                          icon: const Icon(Icons.auto_awesome),
                          label: const Text("Remove BG"),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: theme.colorScheme.primary,
                            foregroundColor: theme.colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: (_processedImage == null || _isLoading) ? null : _pickColor,
                    icon: const Icon(Icons.color_lens),
                    label: const Text("Change Background Color"),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(double.infinity, 56),
                      backgroundColor: theme.colorScheme.secondaryContainer,
                      foregroundColor: theme.colorScheme.onSecondaryContainer,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
