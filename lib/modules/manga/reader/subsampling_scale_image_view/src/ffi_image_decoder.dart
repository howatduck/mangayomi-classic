import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Required parameters to decode an image region
class DecodeParams {
  final String filePath;
  final int left;
  final int top;
  final int right;
  final int bottom;
  final int sampleSize;
  final bool cropBorders;

  DecodeParams({
    required this.filePath,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.sampleSize,
    this.cropBorders = false,
  });

  Map<String, dynamic> toJson() => {
    "filePath": filePath,
    "left": left,
    "top": top,
    "right": right,
    "bottom": bottom,
    "sampleSize": sampleSize,
    "cropBorders": cropBorders,
  };
  factory DecodeParams.fromJson(Map<String, dynamic> json) {
    return DecodeParams(
      bottom: json['bottom'],
      filePath: json['filePath'],
      left: json['left'],
      top: json['top'],
      right: json['right'],
      sampleSize: json['sampleSize'],
      cropBorders: json['cropBorders'] ?? false,
    );
  }
}

/// Result returned after decoding a region
class DecodeResult {
  final int? pointerAddress;
  final int width;
  final int height;
  final String? error;

  DecodeResult({
    this.pointerAddress,
    this.width = 0,
    this.height = 0,
    this.error,
  });
}

/// FFI interop interface with the native C++ library.
/// Manages loading the dynamic library and asynchronous execution
/// of decoding tasks in background Isolates.
class FfiImageDecoder {
  static DynamicLibrary? _dylib;

  bool _isRunning = false;

  // CLASSIC PATCH: the bundled native decoder loads AImageDecoder
  // symbols (Android 11+ / API 30) at init and can never work below
  // that, so the software fallback is chosen deterministically from
  // the OS version instead of latching onto an error string after a
  // wasted FFI attempt. On API 30+ nothing latches: a failed decode
  // falls back per image only.
  static bool? _sdkBelow30Cache;

  static bool _sdkBelow30() {
    final cached = _sdkBelow30Cache;
    if (cached != null) return cached;
    var result = false;
    if (Platform.isAndroid) {
      final v = Platform.operatingSystemVersion;
      final sdk = RegExp(r'SDK (\d+)').firstMatch(v);
      if (sdk != null) {
        result = int.parse(sdk.group(1)!) < 30;
      } else {
        final rel = RegExp(r'Android (\d+)').firstMatch(v);
        if (rel != null) result = int.parse(rel.group(1)!) < 11;
      }
    }
    return _sdkBelow30Cache = result;
  }

  // Tokens cancelled while a software-fallback decode is in flight.
  // The fallback does not go through the FFI job queue, so cancel()
  // records the token here and decodeRegionAsync frees the buffer
  // itself instead of handing ownership to a caller that went away.
  final Set<Object> _classicCancelledTokens = <Object>{};

  // Frees the fallback buffer when the caller cancelled mid-decode.
  DecodeResult? _classicGuardCancelled(
    DecodeResult? result,
    Object? cancelToken,
  ) {
    if (result == null || cancelToken == null) return result;
    if (!_classicCancelledTokens.remove(cancelToken)) return result;
    if (result.pointerAddress != null) {
      calloc.free(Pointer<Uint8>.fromAddress(result.pointerAddress!));
    }
    return DecodeResult(error: 'Cancelled');
  }
  Future<void>? _startFuture;
  Isolate? _cIsolate;
  ReceivePort? _receivePort;
  SendPort? _sendPort;

  final List<_DecodeJob> _queue = [];
  // Max concurrent decode jobs sent to the isolate.
  // 3 parallel jobs keeps tile throughput high without overloading memory.
  static const int _maxConcurrent = 3;
  int _activeJobs = 0;

  void cancel(Object token) {
    // CLASSIC PATCH: also remember the token so an in-flight software
    // fallback decode can free its buffer instead of leaking it.
    _classicCancelledTokens.add(token);
    _queue.removeWhere((job) {
      if (job.cancelToken == token) {
        if (!job.completer.isCompleted) {
          if (job.action == 'getDimensions') {
            job.completer.complete(null);
          } else {
            job.completer.complete(DecodeResult(error: 'Cancelled'));
          }
        }
        return true;
      }
      return false;
    });
  }

  Future<void> start() {
    if (_isRunning) {
      return Future.value();
    }
    _startFuture ??= _doStart();
    return _startFuture!;
  }

  Future<void> _doStart() async {
    try {
      await _initCIsolate();
    } catch (e, stackTrace) {
      if (kDebugMode) {
        print('Error starting FFI isolate: $e');
        print(stackTrace);
      }
      await stop();
    } finally {
      _startFuture = null;
    }
  }

  Future<void> _initCIsolate() async {
    _receivePort = ReceivePort();

    _cIsolate = await Isolate.spawn(
      _cIsolateEntryPoint,
      _receivePort!.sendPort,
    );

    final completer = Completer<SendPort>();
    _receivePort!.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      }
    });

    _sendPort = await completer.future;
    _isRunning = true;
  }

  static DynamicLibrary get dylib {
    if (_dylib == null) {
      if (Platform.isAndroid) {
        _dylib = DynamicLibrary.open("libsubsampling_scale_image_view.so");
      } else if (Platform.isIOS || Platform.isMacOS) {
        try {
          _dylib = DynamicLibrary.open(
            "subsampling_scale_image_view.framework/subsampling_scale_image_view",
          );
        } catch (_) {
          _dylib = DynamicLibrary.process();
        }
      } else if (Platform.isWindows) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = [
          "$exeDir\\subsampling_scale_image_view.dll",
          "subsampling_scale_image_view.dll",
          "libsubsampling_scale_image_view.dll",
          "$exeDir\\libsubsampling_scale_image_view.dll",
          "${Directory.current.path}\\build\\native_assets\\windows\\subsampling_scale_image_view.dll",
          "$exeDir\\..\\..\\..\\native_assets\\windows\\subsampling_scale_image_view.dll",
        ];
        for (final path in candidates) {
          try {
            _dylib = DynamicLibrary.open(path);
            if (_dylib != null) break;
          } catch (_) {}
        }
        _dylib ??= DynamicLibrary.process();
      } else if (Platform.isLinux) {
        final exeDir = File(Platform.resolvedExecutable).parent.path;
        final candidates = [
          "$exeDir/lib/libsubsampling_scale_image_view.so",
          "$exeDir/libsubsampling_scale_image_view.so",
          "libsubsampling_scale_image_view.so",
          "${Directory.current.path}/build/native_assets/linux/libsubsampling_scale_image_view.so",
        ];
        for (final path in candidates) {
          try {
            _dylib = DynamicLibrary.open(path);
            if (_dylib != null) break;
          } catch (_) {}
        }
        _dylib ??= DynamicLibrary.process();
      } else {
        _dylib = DynamicLibrary.process();
      }
    }
    return _dylib!;
  }

  static final Pointer<Opaque> Function(
    Pointer<Utf8>,
    bool,
    Pointer<Int32>,
    Pointer<Int32>,
  )
  _initDecoder = dylib
      .lookupFunction<
        Pointer<Opaque> Function(
          Pointer<Utf8>,
          Bool,
          Pointer<Int32>,
          Pointer<Int32>,
        ),
        Pointer<Opaque> Function(
          Pointer<Utf8>,
          bool,
          Pointer<Int32>,
          Pointer<Int32>,
        )
      >('init_decoder');

  static final bool Function(
    Pointer<Opaque>,
    int,
    int,
    int,
    int,
    int,
    Pointer<Uint8>,
  )
  _decodeRegion = dylib
      .lookupFunction<
        Bool Function(
          Pointer<Opaque>,
          Int32,
          Int32,
          Int32,
          Int32,
          Int32,
          Pointer<Uint8>,
        ),
        bool Function(Pointer<Opaque>, int, int, int, int, int, Pointer<Uint8>)
      >('decode_region');

  static final void Function(Pointer<Opaque>) _freeDecoder = dylib
      .lookupFunction<
        Void Function(Pointer<Opaque>),
        void Function(Pointer<Opaque>)
      >('free_decoder');

  /// Decodes a specific region of the image asynchronously in a background Isolate.
  /// This prevents blocking the main UI thread during disk reads and decoding.
  static Future<void> _cIsolateEntryPoint(SendPort mainSendPort) async {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    // LRU Cache using LinkedHashMap for O(1) access, insertion, and ordering.
    // Keys are inserted in access order; to evict, remove first entry.
    final Map<String, Pointer<Opaque>> cachedContexts = {};
    final Map<String, List<int>> cachedDimensions = {};
    // lruOrder tracks insertion order; LinkedHashMap isn't directly available in isolate
    // so we use a plain Map (Dart Maps maintain insertion order since Dart 2) as O(1) ordered set.
    final Map<String, bool> lruOrder = {};
    const int maxCacheSize = 5;

    receivePort.listen((message) async {
      if (message is Map<String, dynamic>) {
        final responsePort = message['responsePort'] as SendPort;
        final action = message['action'] as String?;
        final params = DecodeParams.fromJson(message['params']);

        final key = "${params.filePath}_${params.cropBorders}";
        Pointer<Opaque> ctx = cachedContexts[key] ?? Pointer.fromAddress(0);
        int imgWidth = 0;
        int imgHeight = 0;

        if (ctx.address == 0) {
          // LRU Eviction: O(1) — remove first (oldest) entry from ordered map
          if (cachedContexts.length >= maxCacheSize) {
            final oldestKey = lruOrder.keys.first;
            lruOrder.remove(oldestKey);
            final oldestCtx = cachedContexts.remove(oldestKey);
            cachedDimensions.remove(oldestKey);
            if (oldestCtx != null && oldestCtx.address != 0) {
              _freeDecoder(oldestCtx);
            }
          }

          final Pointer<Utf8> pathPtr = params.filePath.toNativeUtf8();
          final Pointer<Int32> wPtr = calloc<Int32>();
          final Pointer<Int32> hPtr = calloc<Int32>();
          try {
            final Pointer<Opaque> newCtx = _initDecoder(
              pathPtr,
              params.cropBorders,
              wPtr,
              hPtr,
            );
            if (newCtx.address == 0) {
              responsePort.send({
                'success': false,
                'error':
                    "Failed to initialize decoder for file: ${params.filePath}",
              });
              return;
            }
            ctx = newCtx;
            cachedContexts[key] = ctx;
            lruOrder[key] = true; // O(1) insertion at end
            imgWidth = wPtr.value;
            imgHeight = hPtr.value;
            cachedDimensions[key] = [imgWidth, imgHeight];
          } catch (e) {
            responsePort.send({
              'success': false,
              'error': "Error initializing FFI decoder: $e",
            });
            return;
          } finally {
            calloc.free(pathPtr);
            calloc.free(wPtr);
            calloc.free(hPtr);
          }
        } else {
          // Update LRU order: O(1) — remove and re-insert at end
          lruOrder.remove(key);
          lruOrder[key] = true;
          final dims = cachedDimensions[key]!;
          imgWidth = dims[0];
          imgHeight = dims[1];
        }

        if (action == 'getDimensions') {
          responsePort.send({
            'success': true,
            'width': imgWidth,
            'height': imgHeight,
          });
          return;
        }

        // Calculates required size for destination pixel buffer (RGBA)
        final int rectWidth = params.right - params.left;
        final int rectHeight = params.bottom - params.top;
        final int destWidth = rectWidth ~/ params.sampleSize;
        final int destHeight = rectHeight ~/ params.sampleSize;
        final int bufferSize = destWidth * destHeight * 4;

        final Pointer<Uint8> rgbaBuffer = calloc<Uint8>(bufferSize);

        try {
          final bool success = _decodeRegion(
            ctx,
            params.left,
            params.top,
            params.right,
            params.bottom,
            params.sampleSize,
            rgbaBuffer,
          );

          if (!success) {
            calloc.free(rgbaBuffer);
            responsePort.send({'error': "Region decoding failed."});
            return;
          }

          responsePort.send({
            'success': true,
            'pointerAddress': rgbaBuffer.address,
            'width': imgWidth,
            'height': imgHeight,
          });
        } catch (e) {
          calloc.free(rgbaBuffer);
          responsePort.send({'success': false, 'error': "FFI error: $e"});
        }
      } else if (message == 'dispose') {
        for (final ctx in cachedContexts.values) {
          if (ctx.address != 0) {
            _freeDecoder(ctx);
          }
        }
        cachedContexts.clear();
        lruOrder.clear();
        cachedDimensions.clear();
        receivePort.close();
      }
    });
  }

  Future<DecodeResult?> decodeRegionAsync(
    DecodeParams params, {
    Object? cancelToken,
  }) async {
    if (_sdkBelow30()) {
      return _classicGuardCancelled(
        await _classicDecodeRegion(params),
        cancelToken,
      );
    }
    await start();
    if (_sendPort == null) {
      if (kDebugMode) {
        print('FfiImageDecoder isolate is not running');
      }
      return null;
    }

    final completer = Completer<DecodeResult?>();
    final job = _DecodeJob(
      params: params,
      completer: completer,
      cancelToken: cancelToken,
    );

    _queue.add(job);
    _processNext();

    final ffiResult = await completer.future;
    if (ffiResult != null &&
        ffiResult.pointerAddress != null &&
        ffiResult.error == null) {
      return ffiResult;
    }
    if (ffiResult?.error == 'Cancelled') return ffiResult;
    // CLASSIC PATCH: the native decoder needs AImageDecoder (Android
    // 11+); where it cannot run, decode with dart:ui instead.
    return _classicGuardCancelled(
          await _classicDecodeRegion(params),
          cancelToken,
        ) ??
        ffiResult;
  }

  Future<List<int>?> getImageDimensionsAsync(
    String filePath, {
    bool cropBorders = false,
    Object? cancelToken,
  }) async {
    if (_sdkBelow30()) return _classicReadDimensions(filePath);
    await start();
    if (_sendPort == null) {
      if (kDebugMode) {
        print('FfiImageDecoder isolate is not running');
      }
      return null;
    }

    final completer = Completer<List<int>?>();
    final job = _DecodeJob(
      params: DecodeParams(
        filePath: filePath,
        left: 0,
        top: 0,
        right: 0,
        bottom: 0,
        sampleSize: 1,
        cropBorders: cropBorders,
      ),
      completer: completer,
      cancelToken: cancelToken,
      action: 'getDimensions',
    );

    _queue.add(job);
    _processNext();

    final dims = await completer.future;
    if (dims != null) return dims;
    // CLASSIC PATCH: fall back to parsing the image header in Dart.
    return _classicReadDimensions(filePath);
  }

  void _processNext() {
    // Sort once before dispatching, not per iteration.
    // Priority: getDimensions first, then high sampleSize (base layer), LIFO within.
    if (_queue.length > 1) {
      _queue.sort((a, b) {
        final aPriority = a.action == 'getDimensions'
            ? 1000
            : a.params.sampleSize;
        final bPriority = b.action == 'getDimensions'
            ? 1000
            : b.params.sampleSize;
        return bPriority.compareTo(
          aPriority,
        ); // descending: highest priority last for removeLast
      });
    }

    while (_activeJobs < _maxConcurrent && _queue.isNotEmpty) {
      final job = _queue.removeLast();
      _activeJobs++;

      final responsePort = ReceivePort();
      responsePort.listen((response) {
        responsePort.close();
        _activeJobs--;

        if (!job.completer.isCompleted) {
          if (response is Map<String, dynamic>) {
            if (response['success'] == true) {
              if (job.action == 'getDimensions') {
                job.completer.complete([
                  response['width'] as int,
                  response['height'] as int,
                ]);
              } else {
                final pointerAddress = response['pointerAddress'] as int?;
                job.completer.complete(
                  DecodeResult(
                    pointerAddress: pointerAddress,
                    width: response['width'] as int,
                    height: response['height'] as int,
                  ),
                );
              }
            } else {
              if (kDebugMode) {
                print('Image job failed: ${response['error']}');
              }
              // CLASSIC PATCH: no process-wide latch on errors. Below
              // API 30 the fallback is pre-selected by _sdkBelow30();
              // on API 30+ a failure falls back per image in the
              // callers above.
              if (job.action == 'getDimensions') {
                job.completer.complete(null);
              } else {
                job.completer.complete(DecodeResult(error: response['error']));
              }
            }
          } else {
            job.completer.complete(null);
          }
        }

        _processNext();
      });

      _sendPort!.send({
        'action': job.action,
        'params': job.params.toJson(),
        'responsePort': responsePort.sendPort,
      });
    }
  }

  bool getImageDimensions(
    String filePath,
    List<int> outSize, {
    bool cropBorders = false,
  }) {
    final Pointer<Utf8> pathPtr = filePath.toNativeUtf8();
    final Pointer<Int32> wPtr = calloc<Int32>();
    final Pointer<Int32> hPtr = calloc<Int32>();

    try {
      final Pointer<Opaque> ctx = _initDecoder(
        pathPtr,
        cropBorders,
        wPtr,
        hPtr,
      );
      if (ctx.address == 0) return false;

      outSize[0] = wPtr.value;
      outSize[1] = hPtr.value;
      _freeDecoder(ctx);
      return true;
    } catch (_) {
      return false;
    } finally {
      calloc.free(pathPtr);
      calloc.free(wPtr);
      calloc.free(hPtr);
    }
  }

  Future<void> stop() async {
    _startFuture = null;
    if (!_isRunning && _cIsolate == null && _receivePort == null) {
      return;
    }

    try {
      _sendPort?.send('dispose');
    } catch (_) {}
    _cIsolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    _sendPort = null;
    _cIsolate = null;
    _receivePort = null;
    _isRunning = false;
    _activeJobs = 0;

    for (final job in _queue) {
      if (!job.completer.isCompleted) {
        if (job.action == 'getDimensions') {
          job.completer.complete(null);
        } else {
          job.completer.complete(DecodeResult(error: 'Cancelled'));
        }
      }
    }
    _queue.clear();
  }
}

class _DecodeJob {
  final DecodeParams params;
  final Completer<dynamic> completer;
  final Object? cancelToken;
  final String? action;

  _DecodeJob({
    required this.params,
    required this.completer,
    this.cancelToken,
    this.action,
  });
}

final ffiImageDecoder = FfiImageDecoder();

// ---------------------------------------------------------------------------
// CLASSIC PATCH helpers: software fallback for devices without AImageDecoder
// (Android < 11). The bundled native decoder loads its AImageDecoder symbols
// at init time and fails on every file there, so dimensions are parsed from
// the image header and regions are decoded with the dart:ui codec instead.
// The returned pixel buffer follows the native contract: RGBA8888 memory the
// caller owns and frees with calloc.free.
// ---------------------------------------------------------------------------

Future<List<int>?> _classicReadDimensions(String path) async {
  RandomAccessFile? raf;
  try {
    final file = File(path);
    final length = await file.length();
    raf = await file.open();
    final toRead = length < 1048576 ? length : 1048576;
    final b = await raf.read(toRead);
    if (b.length >= 10) {
      final bd = ByteData.sublistView(b);
      // PNG
      if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
        return [bd.getUint32(16), bd.getUint32(20)];
      }
      // GIF
      if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
        return [bd.getUint16(6, Endian.little), bd.getUint16(8, Endian.little)];
      }
      // WebP
      if (b.length >= 30 &&
          b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
          b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
        if (b[12] == 0x56 && b[15] == 0x58) {
          // VP8X
          final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
          final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
          return [w, h];
        }
        if (b[12] == 0x56 && b[15] == 0x4C) {
          // VP8L
          final w = 1 + (b[21] | ((b[22] & 0x3F) << 8));
          final h = 1 + ((b[22] >> 6) | (b[23] << 2) | ((b[24] & 0x0F) << 10));
          return [w, h];
        }
        // VP8 (lossy)
        final w = bd.getUint16(26, Endian.little) & 0x3FFF;
        final h = bd.getUint16(28, Endian.little) & 0x3FFF;
        return [w, h];
      }
      // BMP
      if (b[0] == 0x42 && b[1] == 0x4D && b.length >= 26) {
        final w = bd.getInt32(18, Endian.little);
        final h = bd.getInt32(22, Endian.little);
        return [w, h < 0 ? -h : h];
      }
      // JPEG: walk segments looking for a start-of-frame marker
      if (b[0] == 0xFF && b[1] == 0xD8) {
        var i = 2;
        while (i + 9 < b.length) {
          if (b[i] != 0xFF) {
            i++;
            continue;
          }
          final marker = b[i + 1];
          if (marker == 0xFF) {
            i++;
            continue;
          }
          if (marker == 0xD8 ||
              marker == 0x01 ||
              (marker >= 0xD0 && marker <= 0xD9)) {
            i += 2;
            continue;
          }
          final segLen = bd.getUint16(i + 2);
          final isSof = marker >= 0xC0 &&
              marker <= 0xCF &&
              marker != 0xC4 &&
              marker != 0xC8 &&
              marker != 0xCC;
          if (isSof) {
            return [bd.getUint16(i + 7), bd.getUint16(i + 5)];
          }
          i += 2 + segLen;
        }
      }
    }
    return null;
  } catch (_) {
    return null;
  } finally {
    try {
      await raf?.close();
    } catch (_) {}
  }
}

Future<DecodeResult?> _classicDecodeRegion(DecodeParams params) async {
  ui.ImmutableBuffer? buffer;
  try {
    final bytes = await File(params.filePath).readAsBytes();
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);

    // CLASSIC PATCH (OOM guard): a long webtoon page (e.g. 1000x30000)
    // expands to ~120 MB of RGBA, and decoding several full-size pages
    // in a row OOMs small-heap devices. When the longest side exceeds
    // 4096 px, decode at a reduced target size and scale the requested
    // region by the same factor. Trade-off: pinch-zoom on such pages
    // tops out at the reduced resolution.
    var scale = 1.0;
    int fullW = 0;
    int fullH = 0;
    final dims = await _classicReadDimensions(params.filePath);
    if (dims != null && dims[0] > 0 && dims[1] > 0) {
      fullW = dims[0];
      fullH = dims[1];
      final longest = fullW > fullH ? fullW : fullH;
      if (longest > 4096) scale = 4096 / longest;
    }

    final codec = await ui.instantiateImageCodecFromBuffer(
      buffer,
      targetWidth: scale < 1.0 ? (fullW * scale).round() : null,
      targetHeight: scale < 1.0 ? (fullH * scale).round() : null,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final full = frame.image;
    buffer.dispose();
    buffer = null;

    final srcL = params.left * scale;
    final srcT = params.top * scale;
    final srcR = params.right * scale;
    final srcB = params.bottom * scale;
    final sample = params.sampleSize < 1 ? 1 : params.sampleSize;
    final destW = ((srcR - srcL) / sample).floor();
    final destH = ((srcB - srcT) / sample).floor();
    if (destW <= 0 || destH <= 0) {
      full.dispose();
      return null;
    }

    ui.Image out = full;
    if (srcL != 0 ||
        srcT != 0 ||
        (srcR - srcL) != full.width ||
        (srcB - srcT) != full.height ||
        sample != 1) {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawImageRect(
        full,
        ui.Rect.fromLTRB(srcL, srcT, srcR, srcB),
        ui.Rect.fromLTWH(0, 0, destW.toDouble(), destH.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      out = await recorder.endRecording().toImage(destW, destH);
      full.dispose();
    }

    final byteData = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
    out.dispose();
    if (byteData == null) return null;
    final data = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    final ptr = calloc<Uint8>(data.length);
    ptr.asTypedList(data.length).setAll(0, data);
    return DecodeResult(
      pointerAddress: ptr.address,
      width: destW,
      height: destH,
    );
  } catch (_) {
    try {
      buffer?.dispose();
    } catch (_) {}
    return null;
  }
}
