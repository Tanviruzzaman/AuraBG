import 'dart:typed_data';
import 'dart:ui';

class TextItem {
  String text;
  Color color;
  Offset position;
  double scale;
  double rotation;
  int style; // 0: Normal, 1: Full Background, 2: Translucent
  double fontSize;
  bool isBold;
  bool isItalic;

  TextItem({
    required this.text,
    required this.color,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.style = 0,
    this.fontSize = 32.0,
    this.isBold = true,
    this.isItalic = false,
  });
}

class ImageItem {
  Uint8List bytes;
  Offset position;
  double scale;
  double rotation;
  bool isFlipped;

  ImageItem({
    required this.bytes,
    required this.position,
    this.scale = 1.0,
    this.rotation = 0.0,
    this.isFlipped = false,
  });
}

class DrawPath {
  List<Offset> points;
  Color color;
  double strokeWidth;

  DrawPath({
    required this.points,
    required this.color,
    required this.strokeWidth,
  });
}
