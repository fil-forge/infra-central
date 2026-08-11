package cidr

import "testing"

func TestSubnet(t *testing.T) {
	// The four subnets the network module actually asks for: two public, then
	// two private offset by the number of AZs.
	cases := []struct {
		newBits int
		netNum  int
		want    string
	}{
		{4, 0, "10.20.0.0/20"},
		{4, 1, "10.20.16.0/20"},
		{4, 2, "10.20.32.0/20"},
		{4, 3, "10.20.48.0/20"},
		{4, 15, "10.20.240.0/20"},
		{8, 1, "10.20.1.0/24"},
		{0, 0, "10.20.0.0/16"},
	}

	for _, test := range cases {
		got, err := Subnet("10.20.0.0/16", test.newBits, test.netNum)
		if err != nil {
			t.Fatalf("Subnet(10.20.0.0/16, %d, %d): %v", test.newBits, test.netNum, err)
		}
		if got != test.want {
			t.Errorf("Subnet(10.20.0.0/16, %d, %d) = %s, want %s", test.newBits, test.netNum, got, test.want)
		}
	}
}

func TestSubnetRejects(t *testing.T) {
	cases := []struct {
		name    string
		prefix  string
		newBits int
		netNum  int
	}{
		{"netNum past the new bits", "10.20.0.0/16", 4, 16},
		{"more new bits than the mask has left", "10.20.0.0/16", 17, 0},
		{"negative netNum", "10.20.0.0/16", 4, -1},
		{"not a prefix", "10.20.0.0", 4, 0},
		{"ipv6", "2001:db8::/32", 4, 0},
	}

	for _, test := range cases {
		if _, err := Subnet(test.prefix, test.newBits, test.netNum); err == nil {
			t.Errorf("%s: expected an error, got none", test.name)
		}
	}
}
