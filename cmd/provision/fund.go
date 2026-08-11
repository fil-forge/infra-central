package main

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/fil-forge/infra-central/internal/fund"
)

// Default amounts, matching smelt's. They stay well under the Calibration USDFC
// faucet's 10-per-day cap so one grant covers a top-up with headroom.
const (
	defaultDeposit         = "3"
	defaultLockupAllowance = "3"
	defaultRateAllowance   = "0.1"
	defaultMaxLockupPeriod = 86400 // epochs, roughly 30 days at 30s each
)

// fundPhase moves USDFC into the payer's FilecoinPay account.
//
// Unlike seed and vault, no deployment calls this. Bringing up a stage must not
// move money, so the caller is an operator running `make fund-payer`, which shows
// the plan and asks before it lets this sign anything.
//
// The payer key is read from SSM into this function's memory and handed
// straight to the signer. It is never returned, never logged, and never leaves
// AWS, which is the whole reason this is a Lambda phase rather than a script
// with a `cast` invocation.
func (d *deps) fund(ctx context.Context, req Request) (*Response, error) {
	cfg := fund.Config{
		RPCURL:      d.cfg.ChainRPCURL,
		ChainID:     d.cfg.ChainID,
		USDFC:       d.cfg.USDFCAddress,
		FilecoinPay: d.cfg.FilecoinPayAddress,
		Operator:    d.cfg.FWSSAddress,
	}

	fundReq := fund.Request{
		Deposit:         valueOr(req.Deposit, defaultDeposit),
		LockupAllowance: valueOr(req.LockupAllowance, defaultLockupAllowance),
		RateAllowance:   valueOr(req.RateAllowance, defaultRateAllowance),
		MaxLockupPeriod: uint64OrDefault(req.MaxLockupPeriod, defaultMaxLockupPeriod),
		ForceDeposit:    req.ForceDeposit,
	}

	payerKey, err := d.store.GetSecret(ctx, "signing-service", "payer-key")
	if err != nil {
		return nil, fmt.Errorf("read the payer key: %w", err)
	}

	// Without an explicit confirmation this reports what it would do and signs
	// nothing. The operator sees the plan first, every time.
	if !req.Confirm {
		plan, err := fund.Prepare(ctx, cfg, payerKey, fundReq)
		if err != nil {
			return nil, err
		}
		slog.Info("fund plan prepared", "payer", plan.Payer, "chain", plan.ChainID)
		return &Response{Phase: "fund", DryRun: true, FundPlan: plan}, nil
	}

	slog.Info("broadcasting funding transactions", "chain", cfg.ChainID)
	result, err := fund.Execute(ctx, cfg, payerKey, fundReq)
	if err != nil {
		return nil, err
	}

	slog.Info("funding complete",
		"transactions", len(result.Transactions),
		"account_funds", result.FundsAfter)

	return &Response{Phase: "fund", FundResult: result}, nil
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

func uint64OrDefault(value, fallback uint64) uint64 {
	if value == 0 {
		return fallback
	}
	return value
}
