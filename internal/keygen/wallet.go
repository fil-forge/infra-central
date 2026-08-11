package keygen

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	secec "gitlab.com/yawning/secp256k1-voi/secec"
	"golang.org/x/crypto/sha3"
)

// EVMWallet is a freshly-generated secp256k1 key pair. These are real, random
// keys because they transact against Filecoin, so unlike the local dev stack
// they cannot be derived from Anvil's publicly known accounts.
//
// The private key is held only in memory and serialized on demand; callers
// store it in SSM as a SecureString and never log it. Only Address is safe to
// return to the caller's stack.
type EVMWallet struct {
	priv    []byte // 32-byte secp256k1 private key
	Address string // 0x EIP-55 checksummed address — the value to fund via faucet
}

// GenerateEVMWallet creates a new random secp256k1 wallet and derives its EVM
// address (keccak256 of the uncompressed public key, low 20 bytes).
func GenerateEVMWallet() (*EVMWallet, error) {
	priv, err := secec.GenerateKey()
	if err != nil {
		return nil, fmt.Errorf("generate secp256k1 key: %w", err)
	}
	return newEVMWallet(priv)
}

// newEVMWallet derives the EVM address for an existing secp256k1 private key.
func newEVMWallet(priv *secec.PrivateKey) (*EVMWallet, error) {
	// Uncompressed public key is 0x04 || X(32) || Y(32); the EVM address is
	// keccak256(X || Y)[12:].
	pub := priv.PublicKey().Bytes()
	if len(pub) != 65 {
		return nil, fmt.Errorf("unexpected public key length %d (want 65)", len(pub))
	}
	h := sha3.NewLegacyKeccak256()
	h.Write(pub[1:])
	addr := h.Sum(nil)[12:]

	return &EVMWallet{
		priv:    priv.Bytes(),
		Address: toChecksumAddress(addr),
	}, nil
}

// ParseEVMWalletRawHex parses the serialization produced by RawHex (64 lowercase
// hex chars, no 0x prefix) back into a wallet, re-deriving its address.
func ParseEVMWalletRawHex(stored string) (*EVMWallet, error) {
	return newEVMWalletFromKeyHex(strings.TrimSpace(stored))
}

// ParseEVMWalletHex0x parses the serialization produced by Hex0x (0x-prefixed
// hex) back into a wallet, re-deriving its address.
func ParseEVMWalletHex0x(stored string) (*EVMWallet, error) {
	return newEVMWalletFromKeyHex(strings.TrimPrefix(strings.TrimSpace(stored), "0x"))
}

// ParseEVMWalletPiriHex parses the serialization produced by PiriWalletHex
// (hex-encoded Filecoin delegated-wallet JSON) back into a wallet, re-deriving
// its address.
func ParseEVMWalletPiriHex(stored string) (*EVMWallet, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(stored))
	if err != nil {
		return nil, fmt.Errorf("decode wallet hex: %w", err)
	}
	var wallet struct {
		Type       string `json:"Type"`
		PrivateKey string `json:"PrivateKey"`
	}
	if err := json.Unmarshal(raw, &wallet); err != nil {
		return nil, fmt.Errorf("decode wallet JSON: %w", err)
	}
	keyBytes, err := base64.StdEncoding.DecodeString(wallet.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("decode wallet private key base64: %w", err)
	}
	return newEVMWalletFromKeyBytes(keyBytes)
}

func newEVMWalletFromKeyHex(keyHex string) (*EVMWallet, error) {
	keyBytes, err := hex.DecodeString(keyHex)
	if err != nil {
		return nil, fmt.Errorf("decode private key hex: %w", err)
	}
	return newEVMWalletFromKeyBytes(keyBytes)
}

func newEVMWalletFromKeyBytes(key []byte) (*EVMWallet, error) {
	priv, err := secec.NewPrivateKey(key)
	if err != nil {
		return nil, fmt.Errorf("parse secp256k1 private key: %w", err)
	}
	return newEVMWallet(priv)
}

// RawHex returns the private key as 64 lowercase hex chars with no 0x prefix —
// the format the signing-service expects at --signing-key-path (payer-key.hex).
func (w *EVMWallet) RawHex() string {
	return hex.EncodeToString(w.priv)
}

// Hex0x returns the private key as a 0x-prefixed hex string — the format the
// delegator config's contract.transactor.key field expects.
func (w *EVMWallet) Hex0x() string {
	return "0x" + w.RawHex()
}

// PiriWalletHex returns the hex-encoded Filecoin "delegated" wallet JSON that
// piri's --wallet-file expects:
// hex({"Type":"delegated","PrivateKey":"<base64 of raw key bytes>"}).
func (w *EVMWallet) PiriWalletHex() string {
	walletJSON := fmt.Sprintf(`{"Type":"delegated","PrivateKey":"%s"}`,
		base64.StdEncoding.EncodeToString(w.priv))
	return hex.EncodeToString([]byte(walletJSON))
}

// toChecksumAddress renders a 20-byte address as a 0x EIP-55 mixed-case string.
func toChecksumAddress(addr []byte) string {
	lower := hex.EncodeToString(addr)
	h := sha3.NewLegacyKeccak256()
	h.Write([]byte(lower))
	hash := hex.EncodeToString(h.Sum(nil))

	out := []byte("0x")
	for i := 0; i < len(lower); i++ {
		c := lower[i]
		if c >= '0' && c <= '9' {
			out = append(out, c)
			continue
		}
		// Uppercase the hex letter when the corresponding hash nibble >= 8.
		if hash[i] >= '8' {
			out = append(out, c-('a'-'A'))
		} else {
			out = append(out, c)
		}
	}
	return string(out)
}
