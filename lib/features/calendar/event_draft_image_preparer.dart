import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart'
    as image_compress;
import 'package:image_picker/image_picker.dart' show XFile;

class EventDraftImagePreparer {
  static const _maxUploadBytes = 8 * 1024 * 1024;
  static const _targetLongestSide = 1600;
  static const _jpegQuality = 80;

  static const _supportedExtensions = ['jpg', 'jpeg', 'png', 'webp'];

  Future<File> prepare(XFile xFile) async {
    final ext = _extension(xFile.path);
    if (!_supportedExtensions.contains(ext)) {
      throw const UnsupportedImageFormatException();
    }

    final sourceFile = File(xFile.path);
    final tmpPath =
        '${Directory.systemTemp.path}/calee_draft_${DateTime.now().millisecondsSinceEpoch}.jpg';

    try {
      final result =
          await image_compress.FlutterImageCompress.compressAndGetFile(
        xFile.path,
        tmpPath,
        minWidth: _targetLongestSide,
        minHeight: _targetLongestSide,
        quality: _jpegQuality,
        format: image_compress.CompressFormat.jpeg,
        keepExif: false,
      );

      if (result != null) {
        final compressed = File(result.path);
        final compressedSize = await compressed.length();
        if (compressedSize <= _maxUploadBytes) {
          return compressed;
        }
        try {
          await compressed.delete();
        } catch (_) {
          // Ignore temporary-file cleanup failures.
        }
      }
    } catch (_) {
      // Fall through to original
    }

    final sourceSize = await sourceFile.length();
    if (sourceSize <= _maxUploadBytes) {
      return sourceFile;
    }

    throw const ImageTooLargeException();
  }

  static String _extension(String filePath) {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0 || dot >= filePath.length - 1) return '';
    return filePath.substring(dot + 1).toLowerCase();
  }
}

class UnsupportedImageFormatException implements Exception {
  const UnsupportedImageFormatException();
}

class ImageTooLargeException implements Exception {
  const ImageTooLargeException();
}
