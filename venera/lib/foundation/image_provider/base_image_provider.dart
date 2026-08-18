import 'dart:async' show Future, StreamController, scheduleMicrotask;
import 'dart:convert';
import 'dart:math';
import 'dart:ui' as ui show Codec;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:venera/foundation/cache_manager.dart';
import 'package:venera/foundation/log.dart';

abstract class BaseImageProvider<T extends BaseImageProvider<T>>
    extends ImageProvider<T> {
  const BaseImageProvider();

  static const int maxImagePixel = 2560 * 1440;

  /// A 1x1 grey "broken image" pixel used to finish loading safely after all
  /// retries are exhausted, so the UI shows a visible failed thumb instead of
  /// an Unhandled Exception that crashes the app (desktop/Windows).
  static final Uint8List _brokenPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=');

  Future<ui.Codec> _loadBroken(ImageDecoderCallback decode) {
    return ImmutableBuffer.fromUint8List(_brokenPng).then(decode);
  }

  static TargetImageSize _getTargetSize(int width, int height) {
    // ignore invalid size
    if (width <= 0 || height <= 0) {
      return TargetImageSize(width: width, height: height);
    }
    // ignore too wide or too tall image
    final imageRatio = width / height;
    if (imageRatio > 2 || imageRatio < 0.5) {
      return TargetImageSize(width: width, height: height);
    }
    // resize if too large
    if (width * height > maxImagePixel) {
      final ratio = sqrt(maxImagePixel / (width * height));
      return TargetImageSize(width: (width * ratio).round(), height: (height * ratio).round());
    }
    return TargetImageSize(width: width, height: height);
  }

  @override
  ImageStreamCompleter loadImage(T key, ImageDecoderCallback decode) {
    final chunkEvents = StreamController<ImageChunkEvent>();
    return MultiFrameImageStreamCompleter(
      codec: _loadBufferAsync(key, chunkEvents, decode),
      chunkEvents: chunkEvents.stream,
      scale: 1.0,
      informationCollector: () sync* {
        yield DiagnosticsProperty<ImageProvider>(
          'Image provider: $this \n Image key: $key',
          this,
          style: DiagnosticsTreeStyle.errorProperty,
        );
      },
    );
  }

  Future<ui.Codec> _loadBufferAsync(
    T key,
    StreamController<ImageChunkEvent> chunkEvents,
    ImageDecoderCallback decode,
  ) async {
    try {
      int retryTime = 1;

      bool stop = false;

      chunkEvents.onCancel = () {
        stop = true;
      };

      Uint8List? data;

      while (data == null && !stop) {
        try {
          data = await load(chunkEvents, () {
            if (stop) {
              throw const _ImageLoadingStopException();
            }
          });
        } on _ImageLoadingStopException {
          rethrow;
        } catch (e) {
          var msg = e.toString();
          if (msg.contains("Invalid Status Code: 404")) {
            rethrow;
          }
          if (msg.contains("Invalid Status Code: 403")) {
            rethrow;
          }
          // Transient failures (TLS handshake / 429 / 5xx server errors such as
          // the hot_manga 530 thumbnail errors) get a longer backoff and more
          // retries so they can recover instead of crashing or showing broken.
          final transient = msg.contains("handshake") ||
              RegExp(r'Invalid Status Code: (5\d\d|429)').hasMatch(msg);
          if (transient && retryTime < 4) {
            retryTime = 4;
          }
          retryTime <<= 1;
          final cap = transient ? (1 << 5) : (1 << 3);
          if (retryTime > cap || stop) {
            rethrow;
          }
          await Future.delayed(Duration(seconds: retryTime));
        }
      }

      if (stop) {
        throw const _ImageLoadingStopException();
      }

      if (data!.isEmpty) {
        throw Exception("Empty image data");
      }

      try {
        final buffer = await ImmutableBuffer.fromUint8List(data);
        return await decode(
          buffer,
          getTargetSize: enableResize ? _getTargetSize : null,
        );
      } catch (e) {
        await CacheManager().delete(this.key);
        if (data.length < 2 * 1024) {
          // data is too short, it's likely that the data is text, not image
          try {
            var text =
                const Utf8Codec(allowMalformed: false).decoder.convert(data);
            throw Exception("Expected image data, but got text: $text");
          } catch (e) {
            // ignore
          }
        }
        rethrow;
      }
    } on _ImageLoadingStopException {
      rethrow;
    } catch (e, s) {
      scheduleMicrotask(() {
        PaintingBinding.instance.imageCache.evict(key);
      });
      Log.error("Image Loading", e, s);
      // After retries are exhausted, finish with a broken-image placeholder so
      // the UI shows a visible failed thumbnail instead of letting the error
      // Future escape as an Unhandled Exception (which crashes on Windows).
      try {
        return await _loadBroken(decode);
      } catch (_) {
        rethrow;
      }
    } finally {
      chunkEvents.close();
    }
  }

  Future<Uint8List> load(
    StreamController<ImageChunkEvent> chunkEvents,
    void Function() checkStop,
  );

  String get key;

  @override
  bool operator ==(Object other) {
    return other is BaseImageProvider<T> && key == other.key;
  }

  @override
  int get hashCode => key.hashCode;

  @override
  String toString() {
    return "$runtimeType($key)";
  }

  bool get enableResize => false;
}

typedef FileDecoderCallback = Future<ui.Codec> Function(Uint8List);

class _ImageLoadingStopException implements Exception {
  const _ImageLoadingStopException();
}
