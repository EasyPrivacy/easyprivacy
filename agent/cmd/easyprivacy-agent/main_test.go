package main

import "testing"

func TestLoopbackListenAddress(t *testing.T) {
	tests := []struct {
		address  string
		expected bool
	}{
		{address: "127.0.0.1:7443", expected: true},
		{address: "[::1]:7443", expected: true},
		{address: "localhost:7443", expected: true},
		{address: "0.0.0.0:7443", expected: false},
		{address: ":7443", expected: false},
		{address: "invalid", expected: false},
	}

	for _, test := range tests {
		t.Run(test.address, func(t *testing.T) {
			if got := isLoopbackListenAddress(test.address); got != test.expected {
				t.Fatalf("isLoopbackListenAddress(%q) = %t, expected %t", test.address, got, test.expected)
			}
		})
	}
}

func TestRandomTokenHasEnoughEntropy(t *testing.T) {
	first, err := randomToken()
	if err != nil {
		t.Fatal(err)
	}
	second, err := randomToken()
	if err != nil {
		t.Fatal(err)
	}
	if len(first) < 40 {
		t.Fatalf("token is unexpectedly short: %d characters", len(first))
	}
	if first == second {
		t.Fatal("two generated tokens unexpectedly matched")
	}
}
