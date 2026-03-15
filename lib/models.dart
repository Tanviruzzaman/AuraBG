import 'dart:typed_data';
import 'dart:ui';

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
