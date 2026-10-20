// Package pake wraps the shared RustCrypto SPAKE2 implementation.
package pake

/*
#include <stdint.h>
#cgo linux,amd64 LDFLAGS: ${SRCDIR}/../../../native/pairing/target/x86_64-unknown-linux-gnu/release/libeasyprivacy_pairing.a -ldl -lpthread -lm
#cgo linux,arm64 LDFLAGS: ${SRCDIR}/../../../native/pairing/target/aarch64-unknown-linux-gnu/release/libeasyprivacy_pairing.a -ldl -lpthread -lm
uint64_t ep_pake_start(uint8_t role, const uint8_t *code, const uint8_t *context, uint8_t *message);
int32_t ep_pake_finish(uint64_t handle, const uint8_t *peer, uint8_t *key);
void ep_pake_free(uint64_t handle);
*/
import "C"

import (
	"errors"
	"unsafe"
)

type Exchange struct {
	handle  uint64
	Message []byte
}

func Start(role byte, code string, context [32]byte) (*Exchange, error) {
	if len(code) != 8 || role > 1 {
		return nil, errors.New("invalid pairing parameters")
	}
	message := make([]byte, 33)
	value := []byte(code)
	handle := C.ep_pake_start(C.uint8_t(role), (*C.uint8_t)(unsafe.Pointer(&value[0])), (*C.uint8_t)(unsafe.Pointer(&context[0])), (*C.uint8_t)(unsafe.Pointer(&message[0])))
	clear(value)
	if handle == 0 {
		return nil, errors.New("could not start pairing")
	}
	return &Exchange{handle: uint64(handle), Message: message}, nil
}

func (e *Exchange) Finish(peer []byte) ([]byte, error) {
	if len(peer) != 33 || e.handle == 0 {
		e.Close()
		return nil, errors.New("invalid pairing message")
	}
	key := make([]byte, 32)
	handle := e.handle
	e.handle = 0
	if C.ep_pake_finish(C.uint64_t(handle), (*C.uint8_t)(unsafe.Pointer(&peer[0])), (*C.uint8_t)(unsafe.Pointer(&key[0]))) != 0 {
		clear(key)
		return nil, errors.New("pairing failed")
	}
	return key, nil
}

func (e *Exchange) Close() {
	if e.handle != 0 {
		C.ep_pake_free(C.uint64_t(e.handle))
		e.handle = 0
	}
}
