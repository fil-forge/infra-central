package fund

import (
	"math/big"
	"testing"
)

// These values are signed into transactions that move money, so the conversion
// has to be exact. 0.1 is the case a float64 gets wrong.
func TestParseUSDFC(t *testing.T) {
	cases := map[string]string{
		"3":                    "3000000000000000000",
		"0.1":                  "100000000000000000",
		"0.000000000000000001": "1",
		"10":                   "10000000000000000000",
		"0":                    "0",
		".5":                   "500000000000000000",
		"1.230":                "1230000000000000000",
	}

	for input, want := range cases {
		t.Run(input, func(t *testing.T) {
			got, err := ParseUSDFC(input)
			if err != nil {
				t.Fatalf("ParseUSDFC(%q): %v", input, err)
			}
			if got.String() != want {
				t.Errorf("ParseUSDFC(%q) = %s, want %s", input, got, want)
			}
		})
	}
}

func TestParseUSDFCRejectsBadInput(t *testing.T) {
	rejected := map[string]string{
		"a negative amount":                 "-1",
		"more precision than the token has": "0.0000000000000000001",
		"a non-number":                      "three",
		"an empty string":                   "",
		"hex":                               "0x10",
	}

	for name, input := range rejected {
		t.Run(name, func(t *testing.T) {
			if _, err := ParseUSDFC(input); err == nil {
				t.Errorf("ParseUSDFC(%q) was accepted", input)
			}
		})
	}
}

func TestFormatUSDFC(t *testing.T) {
	cases := map[string]string{
		"3000000000000000000":  "3",
		"100000000000000000":   "0.1",
		"1":                    "0.000000000000000001",
		"0":                    "0",
		"1230000000000000000":  "1.23",
		"10000000000000000000": "10",
	}

	for input, want := range cases {
		t.Run(input, func(t *testing.T) {
			value, _ := new(big.Int).SetString(input, 10)
			if got := FormatUSDFC(value); got != want {
				t.Errorf("FormatUSDFC(%s) = %q, want %q", input, got, want)
			}
		})
	}
}

func TestUSDFCRoundTrips(t *testing.T) {
	amounts := []string{"3", "0.1", "1.23", "10", "0.000000000000000001"}

	for _, amount := range amounts {
		t.Run(amount, func(t *testing.T) {
			parsed, err := ParseUSDFC(amount)
			if err != nil {
				t.Fatalf("ParseUSDFC: %v", err)
			}
			if got := FormatUSDFC(parsed); got != amount {
				t.Errorf("round trip of %q gave %q", amount, got)
			}
		})
	}
}
