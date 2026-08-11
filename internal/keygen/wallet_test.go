package keygen

import (
	"encoding/hex"
	"regexp"
	"strings"
	"testing"
)

var addressRE = regexp.MustCompile(`^0x[0-9a-fA-F]{40}$`)

func TestGenerateEVMWalletProducesAnEIP55Address(t *testing.T) {
	w, err := GenerateEVMWallet()
	if err != nil {
		t.Fatalf("GenerateEVMWallet: %v", err)
	}
	if !addressRE.MatchString(w.Address) {
		t.Errorf("address = %q, want a 0x-prefixed 20-byte hex string", w.Address)
	}
}

func TestGenerateEVMWalletProduces32ByteKey(t *testing.T) {
	w, err := GenerateEVMWallet()
	if err != nil {
		t.Fatalf("GenerateEVMWallet: %v", err)
	}
	b, err := hex.DecodeString(w.RawHex())
	if err != nil {
		t.Fatalf("RawHex is not valid hex: %v", err)
	}
	if len(b) != 32 {
		t.Errorf("RawHex decodes to %d bytes, want 32", len(b))
	}
}

// Each consumer expects a different serialization of the same key, so each one
// has to survive a round trip and re-derive the identical address. A format
// that parses but yields a different address would silently point a funded
// wallet somewhere else.
func TestEVMWalletSerializationRoundTrips(t *testing.T) {
	serializations := map[string]struct {
		encode func(*EVMWallet) string
		decode func(string) (*EVMWallet, error)
	}{
		"RawHex, read by the signing service": {
			encode: (*EVMWallet).RawHex,
			decode: ParseEVMWalletRawHex,
		},
		"Hex0x, read by the delegator transactor": {
			encode: (*EVMWallet).Hex0x,
			decode: ParseEVMWalletHex0x,
		},
		"PiriWalletHex, read by piri": {
			encode: (*EVMWallet).PiriWalletHex,
			decode: ParseEVMWalletPiriHex,
		},
	}

	original, err := GenerateEVMWallet()
	if err != nil {
		t.Fatalf("GenerateEVMWallet: %v", err)
	}

	for name, format := range serializations {
		t.Run(name, func(t *testing.T) {
			parsed, err := format.decode(format.encode(original))
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if parsed.Address != original.Address {
				t.Errorf("address after round trip = %q, want %q", parsed.Address, original.Address)
			}
		})
	}
}

// The four vectors published with EIP-55 itself. These pin the keccak-based
// capitalisation, which is the part of address rendering that fails silently:
// a wrong-case address still looks like an address.
func TestToChecksumAddressMatchesEIP55Vectors(t *testing.T) {
	vectors := []string{
		"0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed",
		"0xfB6916095ca1df60bB79Ce92cE3Ea74c37c5d359",
		"0xdbF03B407c01E7cD3CBea99509d93f8DDDC8C6FB",
		"0xD1220A0cf47c7B9Be7A2E6BA89F429762e7b9aDb",
	}

	for _, want := range vectors {
		t.Run(want, func(t *testing.T) {
			raw, err := hex.DecodeString(strings.TrimPrefix(strings.ToLower(want), "0x"))
			if err != nil {
				t.Fatalf("decode vector: %v", err)
			}
			if got := toChecksumAddress(raw); got != want {
				t.Errorf("toChecksumAddress() = %q, want %q", got, want)
			}
		})
	}
}
