import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

typedef _StartNative =
    Uint64 Function(Uint8, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _Start =
    int Function(int, Pointer<Uint8>, Pointer<Uint8>, Pointer<Uint8>);
typedef _FinishNative = Int32 Function(Uint64, Pointer<Uint8>, Pointer<Uint8>);
typedef _Finish = int Function(int, Pointer<Uint8>, Pointer<Uint8>);
typedef _FreeNative = Void Function(Uint64);
typedef _Free = void Function(int);

class NativePake {
  NativePake(String code, List<int> context) {
    if (!RegExp(r'^[0-9]{8}$').hasMatch(code) || context.length != 32) {
      throw const FormatException('Enter the eight-digit pairing code.');
    }
    final password = calloc<Uint8>(8),
        identity = calloc<Uint8>(32),
        out = calloc<Uint8>(33);
    try {
      password.asTypedList(8).setAll(0, code.codeUnits);
      identity.asTypedList(32).setAll(0, context);
      _handle = _start(0, password, identity, out);
      if (_handle == 0) {
        throw const FormatException('Could not start device pairing.');
      }
      message = List<int>.from(out.asTypedList(33));
    } finally {
      password.asTypedList(8).fillRange(0, 8, 0);
      calloc.free(password);
      calloc.free(identity);
      calloc.free(out);
    }
  }
  static DynamicLibrary _load() {
    final override = Platform.environment['EASYPRIVACY_PAIRING_LIBRARY'];
    if (override != null) return DynamicLibrary.open(override);
    if (Platform.isAndroid) {
      return DynamicLibrary.open('libeasyprivacy_pairing.so');
    }
    final dir = File(Platform.resolvedExecutable).parent.path;
    return DynamicLibrary.open(
      Platform.isWindows
          ? '$dir/easyprivacy_pairing.dll'
          : '$dir/lib/libeasyprivacy_pairing.so',
    );
  }

  static final _library = _load();
  static final _Start _start = _library.lookupFunction<_StartNative, _Start>(
    'ep_pake_start',
  );
  static final _Finish _finish = _library
      .lookupFunction<_FinishNative, _Finish>('ep_pake_finish');
  static final _Free _free = _library.lookupFunction<_FreeNative, _Free>(
    'ep_pake_free',
  );
  int _handle = 0;
  late final List<int> message;
  List<int> finish(List<int> peer) {
    if (peer.length != 33 || _handle == 0) {
      throw const FormatException('Invalid pairing response.');
    }
    final input = calloc<Uint8>(33), output = calloc<Uint8>(32);
    try {
      input.asTypedList(33).setAll(0, peer);
      final handle = _handle;
      _handle = 0;
      if (_finish(handle, input, output) != 0) {
        throw const FormatException('The pairing exchange failed.');
      }
      return List<int>.from(output.asTypedList(32));
    } finally {
      output.asTypedList(32).fillRange(0, 32, 0);
      calloc.free(input);
      calloc.free(output);
    }
  }

  void close() {
    if (_handle != 0) {
      _free(_handle);
      _handle = 0;
    }
  }
}
