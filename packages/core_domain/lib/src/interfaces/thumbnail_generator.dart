import 'dart:typed_data';

import '../result.dart';

class ImageThumbnail {
  const ImageThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
    required this.mimeType,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final String mimeType;
}

sealed class ThumbnailError {
  const ThumbnailError();
}

class UnsupportedImage extends ThumbnailError {
  const UnsupportedImage();
}

class ThumbnailTooLarge extends ThumbnailError {
  const ThumbnailTooLarge();
}

class ThumbnailGenerationFailed extends ThumbnailError {
  const ThumbnailGenerationFailed(this.error);
  final Object error;
}

abstract class ThumbnailGenerator {
  Future<Result<ImageThumbnail?, ThumbnailError>> generate(
    Uint8List source, {
    int maxEdge = 512,
    int maxBytes = 256 * 1024,
  });
}
