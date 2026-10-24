import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// Windows SDK JOBOBJECT_EXTENDED_LIMIT_INFORMATION. Windows x64/ARM64 use
// 8-byte SIZE_T/ULONG_PTR; the layout is intentionally expressed as ABI fields.
final class _JobLimits extends Struct {
  @Int64()
  external int processTime;
  @Int64()
  external int jobTime;
  @Uint32()
  external int flags;
  @UintPtr()
  external int minWorkingSet;
  @UintPtr()
  external int maxWorkingSet;
  @Uint32()
  external int activeProcesses;
  @UintPtr()
  external int affinity;
  @Uint32()
  external int priority;
  @Uint32()
  external int scheduling;
  @Array(6)
  external Array<Uint64> ioCounters;
  @UintPtr()
  external int processMemory;
  @UintPtr()
  external int jobMemory;
  @UintPtr()
  external int peakProcessMemory;
  @UintPtr()
  external int peakJobMemory;
}

/// A noninherited handle owned by Files. Windows closes it even after a crash
/// or forced process exit, killing the attached engine and its descendants.
/// Only the returned child PID is assigned; Core's broker is never in this job.
class EngineProcessOwner {
  EngineProcessOwner(int pid) {
    if (!Platform.isWindows) return;
    final kernel = DynamicLibrary.open('kernel32.dll');
    final create = kernel
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>),
          Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>)
        >('CreateJobObjectW');
    final set = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
          int Function(Pointer<Void>, int, Pointer<Void>, int)
        >('SetInformationJobObject');
    final open = kernel
        .lookupFunction<
          Pointer<Void> Function(Uint32, Int32, Uint32),
          Pointer<Void> Function(int, int, int)
        >('OpenProcess');
    final assign = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)
        >('AssignProcessToJobObject');
    _close = kernel
        .lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('CloseHandle');
    final job = create(nullptr, nullptr);
    final limits = calloc<_JobLimits>();
    Pointer<Void> process = nullptr;
    var assigned = false;
    try {
      limits.ref.flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
      if (job == nullptr ||
          set(job, 9, limits.cast(), sizeOf<_JobLimits>()) == 0) {
        throw const ProcessException(
          'Sync',
          [],
          'Could not protect the engine process lifetime.',
        );
      }
      process = open(0x0101, 0, pid); // PROCESS_SET_QUOTA | PROCESS_TERMINATE
      if (process == nullptr || assign(job, process) == 0) {
        throw const ProcessException(
          'Sync',
          [],
          'Could not attach the engine to Files.',
        );
      }
      _job = job;
      assigned = true;
    } finally {
      calloc.free(limits);
      if (process != nullptr) _close!(process);
      if (!assigned && job != nullptr) _close!(job);
    }
  }
  Pointer<Void>? _job;
  int Function(Pointer<Void>)? _close;
  void close() {
    final job = _job;
    _job = null;
    if (job != null) _close!(job);
  }
}
