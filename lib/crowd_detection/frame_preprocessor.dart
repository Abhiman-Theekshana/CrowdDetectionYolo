import 'dart:typed_data';
import 'package:image/image.dart' as img;

class FramePreprocessor {
  static const int inputSize = 320;

  static Float32List preprocessRgb(Uint8List rgbBytes, int width, int height) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgbBytes.buffer,
      numChannels: 3,
      order: img.ChannelOrder.rgb,
    );

    final resized = img.copyResize(image, width: inputSize, height: inputSize);

    final floatList = Float32List(1 * inputSize * inputSize * 3);
    int index = 0;
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        floatList[index++] = pixel.r / 255.0;
        floatList[index++] = pixel.g / 255.0;
        floatList[index++] = pixel.b / 255.0;
      }
    }
    return floatList;
  }

  static Float32List preprocessPng(Uint8List pngBytes) {
    final image = img.decodeImage(pngBytes);
    if (image == null) throw Exception('Failed to decode image');

    final resized = img.copyResize(image, width: inputSize, height: inputSize);

    final floatList = Float32List(1 * inputSize * inputSize * 3);
    int index = 0;
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        floatList[index++] = pixel.r / 255.0;
        floatList[index++] = pixel.g / 255.0;
        floatList[index++] = pixel.b / 255.0;
      }
    }
    return floatList;
  }
}
