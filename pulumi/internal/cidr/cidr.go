// Package cidr provides the address arithmetic the network module used to get
// from Terraform's cidrsubnet function.
//
// Pulumi programs are ordinary Go, so there is no interpolation language to
// borrow this from. It is a dozen lines and it is exercised by a test, which is
// more than the Terraform function offered.
package cidr

import (
	"encoding/binary"
	"fmt"
	"net"
)

// Subnet carves a subnet out of prefix, mirroring Terraform's
// cidrsubnet(prefix, newBits, netNum): it extends the prefix length by newBits
// and sets the extension to netNum.
//
//	Subnet("10.20.0.0/16", 4, 1) == "10.20.16.0/20"
//
// IPv4 only. Every network in this project is IPv4, and an IPv6 prefix would
// need a 128-bit accumulator rather than the uint32 below, so it is rejected
// rather than quietly truncated.
func Subnet(prefix string, newBits, netNum int) (string, error) {
	_, network, err := net.ParseCIDR(prefix)
	if err != nil {
		return "", fmt.Errorf("parse %q: %w", prefix, err)
	}

	ip := network.IP.To4()
	if ip == nil {
		return "", fmt.Errorf("parse %q: not an IPv4 prefix", prefix)
	}

	ones, bits := network.Mask.Size()
	if newBits < 0 {
		return "", fmt.Errorf("cidr %q: newBits must not be negative, got %d", prefix, newBits)
	}

	newOnes := ones + newBits
	if newOnes > bits {
		return "", fmt.Errorf("cidr %q: %d new bits exceeds the %d left in a /%d", prefix, newBits, bits-ones, ones)
	}

	// A /20 out of a /16 leaves 4 bits of subnet space, so netNum has to fit in
	// 16 values. Terraform fails the same way rather than wrapping.
	if netNum < 0 || netNum >= 1<<newBits {
		return "", fmt.Errorf("cidr %q: netNum %d does not fit in %d new bits", prefix, netNum, newBits)
	}

	addr := binary.BigEndian.Uint32(ip) | uint32(netNum)<<(bits-newOnes)

	out := make(net.IP, net.IPv4len)
	binary.BigEndian.PutUint32(out, addr)

	return fmt.Sprintf("%s/%d", out, newOnes), nil
}
