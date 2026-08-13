package fund

import (
	"fmt"
	"math/big"
	"strings"
)

// usdfcDecimals is USDFC's precision. Amounts are quoted to operators in whole
// tokens ("3", "0.1") and held on chain as integers of 1e-18 tokens.
const usdfcDecimals = 18

// ParseUSDFC converts a decimal token amount to its on-chain integer value.
//
// Deliberately string arithmetic rather than big.Float. A float64 cannot hold
// 0.1 exactly, and the rounding error would land in a value that moves money.
// Splitting on the decimal point and padding is exact by construction.
func ParseUSDFC(amount string) (*big.Int, error) {
	trimmed := strings.TrimSpace(amount)
	if trimmed == "" {
		return nil, fmt.Errorf("amount is empty")
	}
	if strings.HasPrefix(trimmed, "-") {
		return nil, fmt.Errorf("amount %q is negative", amount)
	}

	whole, frac, hasFrac := strings.Cut(trimmed, ".")
	if whole == "" {
		whole = "0"
	}
	if hasFrac && len(frac) > usdfcDecimals {
		return nil, fmt.Errorf("amount %q has more than %d decimal places", amount, usdfcDecimals)
	}

	digits := whole + frac + strings.Repeat("0", usdfcDecimals-len(frac))

	value, ok := new(big.Int).SetString(digits, 10)
	if !ok {
		return nil, fmt.Errorf("amount %q is not a decimal number", amount)
	}
	return value, nil
}

// FormatUSDFC renders an on-chain integer as a decimal token amount, for
// operator-facing output. Trailing zeros are trimmed so 3000000000000000000
// reads as "3" rather than "3.000000000000000000".
func FormatUSDFC(value *big.Int) string {
	if value == nil {
		return "0"
	}

	unit := new(big.Int).Exp(big.NewInt(10), big.NewInt(usdfcDecimals), nil)
	whole, frac := new(big.Int).QuoRem(value, unit, new(big.Int))

	if frac.Sign() == 0 {
		return whole.String()
	}

	padded := fmt.Sprintf("%0*s", usdfcDecimals, frac.String())
	return whole.String() + "." + strings.TrimRight(padded, "0")
}
